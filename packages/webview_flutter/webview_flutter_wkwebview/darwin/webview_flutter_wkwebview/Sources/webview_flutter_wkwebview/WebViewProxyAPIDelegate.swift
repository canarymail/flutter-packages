// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import WebKit

class WebViewImpl: WKWebView {
  let api: PigeonApiProtocolWKWebView
  unowned let registrar: ProxyAPIRegistrar

  init(
    api: PigeonApiProtocolWKWebView, registrar: ProxyAPIRegistrar, frame: CGRect,
    configuration: WKWebViewConfiguration
  ) {
    self.api = api
    self.registrar = registrar
    super.init(frame: frame, configuration: configuration)

    #if os(macOS)
        // Set drawsBackground to false for transparent background
        self.setValue(false, forKey: "drawsBackground")

        NotificationCenter.default.addObserver(
          self,
          selector: #selector(handleFocusWebView),
          name: Notification.Name("FocusWebView"),
          object: nil
        )
    #endif

    #if os(iOS)
      scrollView.contentInsetAdjustmentBehavior = .never
      scrollView.automaticallyAdjustsScrollIndicatorInsets = false
      scrollView.isScrollEnabled = false
      scrollView.showsVerticalScrollIndicator = false
      scrollView.showsHorizontalScrollIndicator = false
      scrollView.bounces = false
      scrollView.delegate = self
    #endif
  }

  #if os(macOS)
  @objc private func handleFocusWebView() {
    guard let window = self.window else { return }

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }

      // 1. Make first responder
      window.makeFirstResponder(self)

      // 2. Force display update
      self.setNeedsDisplay(self.bounds)
      self.displayIfNeeded()

      // Restore selection if available, otherwise just focus
      self.evaluateJavaScript("""
            (function() {
                      // Try to restore saved selection
                      if (window.__savedSelection) {
                          const saved = window.__savedSelection;
                          let element = null;

                          // Try to find element by ID first
                          if (saved.elementId) {
                              element = document.getElementById(saved.elementId);
                          }

                          // Try by name
                          if (!element && saved.elementName) {
                              element = document.querySelector('[name="' + saved.elementName + '"]');
                          }

                          // Try by path
                          if (!element && saved.elementPath) {
                              try {
                                  element = document.querySelector(saved.elementPath);
                              } catch(e) {
                                  console.log('Could not find element by path:', e);
                              }
                          }

                          if (element) {
                              element.focus();

                              // Restore selection for input/textarea
                              if (element.tagName === 'INPUT' || element.tagName === 'TEXTAREA') {
                                  try {
                                      element.setSelectionRange(saved.startOffset, saved.endOffset);
                                      console.log('Selection restored for input/textarea');
                                      delete window.__savedSelection;
                                      return;
                                  } catch(e) {
                                      console.log('Error restoring input selection:', e);
                                  }
                              }

                              // Restore selection for contenteditable
                              if (element.isContentEditable) {
                                  try {
                                      const range = document.createRange();
                                      const textNode = element.firstChild || element;

                                      const start = Math.min(saved.startOffset, textNode.textContent?.length || 0);
                                      const end = Math.min(saved.endOffset, textNode.textContent?.length || 0);

                                      range.setStart(textNode, start);
                                      range.setEnd(textNode, end);

                                      const selection = window.getSelection();
                                      selection.removeAllRanges();
                                      selection.addRange(range);

                                      console.log('Selection restored for contenteditable');
                                      delete window.__savedSelection;
                                      return;
                                  } catch(e) {
                                      console.log('Error restoring contenteditable selection:', e);
                                  }
                              }

                              // Clear saved selection even if restore failed
                              delete window.__savedSelection;
                              return;
                          }
                      }

                      // No saved selection or restore failed - just focus
                      let focusable = document.activeElement;
                      if (!focusable || focusable === document.body) {
                          focusable = document.querySelector('input, textarea, [contenteditable="true"]') || document.body;
                      }
                      focusable.focus();

                      if (focusable.setSelectionRange) {
                          focusable.setSelectionRange(0, 0);
                      }
                  })();
        """, completionHandler: nil)
    }
  }

  override func resignFirstResponder() -> Bool {
    print("[WebViewImpl] 🔄 resignFirstResponder called")

    // Save selection before resigning
    saveCurrentSelection()

    return super.resignFirstResponder()
  }

  private func saveCurrentSelection() {
    evaluateJavaScript("""
        (function() {
                const selection = window.getSelection();
                const activeElement = document.activeElement;

                // Handle input/textarea elements
                if (activeElement && (activeElement.tagName === 'INPUT' || activeElement.tagName === 'TEXTAREA')) {
                    window.__savedSelection = {
                        startOffset: activeElement.selectionStart || 0,
                        endOffset: activeElement.selectionEnd || 0,
                        elementTagName: activeElement.tagName,
                        elementId: activeElement.id || null,
                        elementName: activeElement.name || null,
                        elementPath: getElementPath(activeElement)
                    };
                    console.log('Selection saved:', window.__savedSelection);
                    return true;
                }

                // Handle contenteditable
                if (activeElement && activeElement.isContentEditable && selection && selection.rangeCount > 0) {
                    const range = selection.getRangeAt(0);
                    window.__savedSelection = {
                        startOffset: range.startOffset,
                        endOffset: range.endOffset,
                        elementTagName: activeElement.tagName,
                        elementId: activeElement.id || null,
                        elementName: activeElement.name || null,
                        elementPath: getElementPath(activeElement)
                    };
                    console.log('Selection saved:', window.__savedSelection);
                    return true;
                }

                // No selection to save
                delete window.__savedSelection;
                return false;

                function getElementPath(element) {
                    if (element.id) {
                        return '#' + element.id;
                    }

                    let path = [];
                    while (element && element.nodeType === Node.ELEMENT_NODE) {
                        let selector = element.nodeName.toLowerCase();
                        if (element.className) {
                            selector += '.' + element.className.trim().split(/\\s+/).join('.');
                        }

                        let sibling = element;
                        let nth = 1;
                        while (sibling.previousElementSibling) {
                            sibling = sibling.previousElementSibling;
                            if (sibling.nodeName.toLowerCase() === selector.split('.')[0]) {
                                nth++;
                            }
                        }

                        if (nth > 1) {
                            selector += ':nth-of-type(' + nth + ')';
                        }

                        path.unshift(selector);
                        element = element.parentElement;
                    }

                    return path.join(' > ');
                }
            })();
    """, completionHandler: nil)
  }
  #endif

  deinit {
    #if os(macOS)
    NotificationCenter.default.removeObserver(self)
    #endif
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func observeValue(
    forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
    context: UnsafeMutableRawPointer?
  ) {
    NSObjectImpl.handleObserveValue(
      withApi: (api as! PigeonApiWKWebView).pigeonApiNSObject, registrar: registrar,
      instance: self as NSObject,
      forKeyPath: keyPath, of: object, change: change, context: context)
  }

  override var frame: CGRect {
    get {
      return super.frame
    }
    set {
      super.frame = newValue
      #if os(iOS)
        // Prevents the contentInsets from being adjusted by iOS and gives control to Flutter.
        scrollView.contentInset = .zero

        // Adjust contentInset to compensate the adjustedContentInset so the sum will
        //  always be 0.
        if scrollView.adjustedContentInset != .zero {
          let insetToAdjust = scrollView.adjustedContentInset
          scrollView.contentInset = UIEdgeInsets(
            top: -insetToAdjust.top, left: -insetToAdjust.left, bottom: -insetToAdjust.bottom,
            right: -insetToAdjust.right)
        }
      #endif
    }
  }
}

/// ProxyApi implementation for `WKWebView`.
///
/// This class may handle instantiating native object instances that are attached to a Dart instance
/// or handle method calls on the associated native class or an instance of that class.
class WebViewProxyAPIDelegate: PigeonApiDelegateWKWebView, PigeonApiDelegateUIViewWKWebView,
  PigeonApiDelegateNSViewWKWebView
{
  func getUIViewWKWebViewAPI(_ api: PigeonApiNSViewWKWebView) -> PigeonApiUIViewWKWebView {
    return api.pigeonRegistrar.apiDelegate.pigeonApiUIViewWKWebView(api.pigeonRegistrar)
  }

  #if os(iOS)
    func scrollView(pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView) throws
      -> UIScrollView
    {
      return pigeonInstance.scrollView
    }
  #endif

  func pigeonDefaultConstructor(
    pigeonApi: PigeonApiUIViewWKWebView, initialConfiguration: WKWebViewConfiguration
  ) throws -> WKWebView {
    return WebViewImpl(
      api: pigeonApi.pigeonApiWKWebView, registrar: pigeonApi.pigeonRegistrar as! ProxyAPIRegistrar,
      frame: CGRect(), configuration: initialConfiguration)
  }

  func pigeonDefaultConstructor(
    pigeonApi: PigeonApiNSViewWKWebView, initialConfiguration: WKWebViewConfiguration
  ) throws -> WKWebView {
    return try pigeonDefaultConstructor(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), initialConfiguration: initialConfiguration)
  }

  func configuration(pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView)
    -> WKWebViewConfiguration
  {
    return pigeonInstance.configuration
  }

  func configuration(pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView) throws
    -> WKWebViewConfiguration
  {
    return configuration(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance)
  }

  func setUIDelegate(
    pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView, delegate: WKUIDelegate
  ) throws {
    pigeonInstance.uiDelegate = delegate
  }

  func setUIDelegate(
    pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView, delegate: WKUIDelegate
  ) throws {
    try setUIDelegate(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance,
      delegate: delegate)
  }

  func setNavigationDelegate(
    pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView, delegate: WKNavigationDelegate
  ) throws {
    pigeonInstance.navigationDelegate = delegate
  }

  func setNavigationDelegate(
    pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView,
    delegate: WKNavigationDelegate
  ) throws {
    try setNavigationDelegate(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance,
      delegate: delegate)
  }

  func getUrl(pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView) throws -> String? {
    return pigeonInstance.url?.absoluteString
  }

  func getUrl(pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView) throws -> String? {
    return try getUrl(pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance)
  }

  func getEstimatedProgress(pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView) throws
    -> Double
  {
    return pigeonInstance.estimatedProgress
  }

  func getEstimatedProgress(pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView) throws
    -> Double
  {
    return try getEstimatedProgress(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance)
  }

  func load(
    pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView, request: URLRequestWrapper
  ) throws {
    pigeonInstance.load(request.value)
  }

  func load(
    pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView, request: URLRequestWrapper
  ) throws {
    try load(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance, request: request)
  }

  func loadHtmlString(
    pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView, string: String, baseUrl: String?
  ) throws {
    pigeonInstance.loadHTMLString(string, baseURL: baseUrl != nil ? URL(string: baseUrl!)! : nil)
  }

  func loadHtmlString(
    pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView, string: String, baseUrl: String?
  ) throws {
    try loadHtmlString(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance, string: string,
      baseUrl: baseUrl)
  }

  func loadFileUrl(
    pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView, url: String,
    readAccessUrl: String
  ) throws {
    let fileURL = URL(fileURLWithPath: url, isDirectory: false)
    let readAccessURL = URL(fileURLWithPath: readAccessUrl, isDirectory: true)

    pigeonInstance.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
  }

  func loadFileUrl(
    pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView, url: String,
    readAccessUrl: String
  ) throws {
    try loadFileUrl(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance, url: url,
      readAccessUrl: readAccessUrl)
  }

  func loadFlutterAsset(pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView, key: String)
    throws
  {
    let registrar = pigeonApi.pigeonRegistrar as! ProxyAPIRegistrar
    let url = registrar.assetManager.urlForAsset(key)

    if let url = url {
      pigeonInstance.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else {
      let assetFilePath = registrar.assetManager.lookupKeyForAsset(key)
      throw PigeonError(
        code: "FWFURLParsingError",
        message: "Failed to find asset with filepath: `\(String(describing: assetFilePath))`.",
        details: nil)
    }
  }

  func loadFlutterAsset(pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView, key: String)
    throws
  {
    try loadFlutterAsset(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance, key: key)
  }

  func canGoBack(pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView) throws -> Bool {
    return pigeonInstance.canGoBack
  }

  func canGoBack(pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView) throws -> Bool {
    return try canGoBack(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance)
  }

  func canGoForward(pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView) throws -> Bool {
    return pigeonInstance.canGoForward
  }

  func canGoForward(pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView) throws -> Bool {
    return try canGoForward(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance)
  }

  func goBack(pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView) throws {
    pigeonInstance.goBack()
  }

  func goBack(pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView) throws {
    try goBack(pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance)
  }

  func goForward(pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView) throws {
    pigeonInstance.goForward()
  }

  func goForward(pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView) throws {
    try goForward(pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance)
  }

  func reload(pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView) throws {
    pigeonInstance.reload()
  }

  func reload(pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView) throws {
    try reload(pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance)
  }

  func getTitle(pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView) throws -> String? {
    return pigeonInstance.title
  }

  func getTitle(pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView) throws -> String? {
    return try getTitle(pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance)
  }

  func setAllowsBackForwardNavigationGestures(
    pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView, allow: Bool
  ) throws {
    pigeonInstance.allowsBackForwardNavigationGestures = allow
  }

  func setAllowsBackForwardNavigationGestures(
    pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView, allow: Bool
  ) throws {
    try setAllowsBackForwardNavigationGestures(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance, allow: allow)
  }

  func setCustomUserAgent(
    pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView, userAgent: String?
  ) throws {
    pigeonInstance.customUserAgent = userAgent
  }

  func setCustomUserAgent(
    pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView, userAgent: String?
  ) throws {
    try setCustomUserAgent(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance,
      userAgent: userAgent)
  }

  func evaluateJavaScript(
    pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView, javaScriptString: String,
    completion: @escaping (Result<Any?, Error>) -> Void
  ) {
    pigeonInstance.evaluateJavaScript(javaScriptString) { result, error in
      if error == nil {
        if let optionalResult = result as Any?? {
          switch optionalResult {
          case .none:
            completion(.success(nil))
          case .some(let value):
            if value is String || value is NSNumber {
              completion(.success(value))
            } else {
              let className = String(describing: value)
              debugPrint(
                "Return type of evaluateJavaScript is not directly supported: \(className). Returned description of value."
              )
              completion(.success((value as AnyObject).description))
            }
          }
        }
      } else {
        let error = PigeonError(
          code: "FWFEvaluateJavaScriptError", message: "Failed evaluating JavaScript.",
          details: error! as NSError)
        completion(.failure(error))
      }
    }
  }

  func evaluateJavaScript(
    pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView, javaScriptString: String,
    completion: @escaping (Result<Any?, Error>) -> Void
  ) {
    evaluateJavaScript(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance,
      javaScriptString: javaScriptString, completion: completion)
  }

  func setInspectable(
    pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView, inspectable: Bool
  ) throws {
    if #available(iOS 16.4, macOS 13.3, *) {
      pigeonInstance.isInspectable = inspectable
      if pigeonInstance.responds(to: Selector(("isInspectable:"))) {
        pigeonInstance.perform(Selector(("isInspectable:")), with: inspectable)
      }
    } else {
      throw (pigeonApi.pigeonRegistrar as! ProxyAPIRegistrar)
        .createUnsupportedVersionError(
          method: "WKWebView.inspectable",
          versionRequirements: "iOS 16.4, macOS 13.3")
    }
  }

  func setInspectable(
    pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView, inspectable: Bool
  ) throws {
    try setInspectable(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance,
      inspectable: inspectable)
  }

  func getCustomUserAgent(pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView) throws
    -> String?
  {
    return pigeonInstance.customUserAgent
  }

  func getCustomUserAgent(pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView) throws
    -> String?
  {
    return try getCustomUserAgent(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance)
  }

  func setAllowsLinkPreview(
    pigeonApi: PigeonApiUIViewWKWebView, pigeonInstance: WKWebView, allow: Bool
  ) throws {
    pigeonInstance.allowsLinkPreview = allow
  }

  func setAllowsLinkPreview(
    pigeonApi: PigeonApiNSViewWKWebView, pigeonInstance: WKWebView, allow: Bool
  ) throws {
    try setAllowsLinkPreview(
      pigeonApi: getUIViewWKWebViewAPI(pigeonApi), pigeonInstance: pigeonInstance, allow: allow)
  }
}

#if os(iOS)
extension WebViewImpl: UIScrollViewDelegate {
  // Add any UIScrollViewDelegate methods you need here
}
#endif
