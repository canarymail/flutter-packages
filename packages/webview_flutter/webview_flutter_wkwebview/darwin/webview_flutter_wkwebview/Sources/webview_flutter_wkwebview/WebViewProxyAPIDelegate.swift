// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import WebKit

class WebViewImpl: WKWebView, WKNavigationDelegate {
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

        // Set navigation delegate
        self.navigationDelegate = self

        NotificationCenter.default.addObserver(
          self,
          selector: #selector(handleFocusWebView),
          name: Notification.Name("FocusWebView"),
          object: nil
        )

        setupSelectionTracking()
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
  private func setupSelectionTracking() {
    // Add the user script that will auto-inject on new pages
    let script = WKUserScript(
      source: getSelectionTrackerScript(),
      injectionTime: .atDocumentEnd, // Changed to End for better compatibility
      forMainFrameOnly: false
    )

    configuration.userContentController.addUserScript(script)
    print("[WebViewImpl] ✅ Selection tracking user script added to configuration")
  }

  private func injectSelectionTracker() {
    // Manually inject for immediate effect on already-loaded pages
    evaluateJavaScript(getSelectionTrackerScript(), completionHandler: { result, error in
      if let error = error {
        print("[WebViewImpl] ❌ Error injecting tracker: \(error)")
      } else {
        print("[WebViewImpl] ✅ Selection tracker injected successfully")
      }
    })
  }

  private func getSelectionTrackerScript() -> String {
    return """
    (function() {
            // Prevent double injection
            if (window.__selectionTrackerInjected) {
                console.log('[SelectionTracker] ⚠️ Already injected, skipping');
                return;
            }
            window.__selectionTrackerInjected = true;

            console.log('[SelectionTracker] 🚀 Script injected and running');

            // Save selection whenever any input loses focus
            document.addEventListener('blur', function(e) {
                console.log('[SelectionTracker] 🔔 BLUR event fired');
                console.log('[SelectionTracker] target:', e.target);
                console.log('[SelectionTracker] target.tagName:', e.target.tagName);

                const element = e.target;

                // Handle input/textarea
                if (element.tagName === 'INPUT' || element.tagName === 'TEXTAREA') {
                    console.log('[SelectionTracker] ✅ Input/Textarea detected');
                    console.log('[SelectionTracker] selectionStart:', element.selectionStart);
                    console.log('[SelectionTracker] selectionEnd:', element.selectionEnd);
                    console.log('[SelectionTracker] element.id:', element.id);
                    console.log('[SelectionTracker] element.name:', element.name);

                    window.__savedSelection = {
                        startOffset: element.selectionStart || 0,
                        endOffset: element.selectionEnd || 0,
                        elementTagName: element.tagName,
                        elementId: element.id || null,
                        elementName: element.name || null,
                        elementPath: getElementPath(element)
                    };
                    console.log('[SelectionTracker] 💾 Selection SAVED:', JSON.stringify(window.__savedSelection));
                    return;
                }

                // Handle contenteditable
                if (element.isContentEditable) {
                    console.log('[SelectionTracker] ✅ ContentEditable detected');
                    const selection = window.getSelection();
                    console.log('[SelectionTracker] selection:', selection);
                    console.log('[SelectionTracker] rangeCount:', selection?.rangeCount);

                    if (selection && selection.rangeCount > 0) {
                        const range = selection.getRangeAt(0);
                        console.log('[SelectionTracker] range.startOffset:', range.startOffset);
                        console.log('[SelectionTracker] range.endOffset:', range.endOffset);

                        window.__savedSelection = {
                            startOffset: range.startOffset,
                            endOffset: range.endOffset,
                            elementTagName: element.tagName,
                            elementId: element.id || null,
                            elementName: element.name || null,
                            elementPath: getElementPath(element)
                        };
                        console.log('[SelectionTracker] 💾 Selection SAVED:', JSON.stringify(window.__savedSelection));
                    } else {
                        console.log('[SelectionTracker] ⚠️ No selection range found');
                    }
                } else {
                    console.log('[SelectionTracker] ℹ️ Element is not input/textarea/contenteditable');
                }
            }, true); // Use capture phase

            console.log('[SelectionTracker] ✅ Blur listener registered');

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

            // Add a test function
            window.__testSelectionSave = function() {
                console.log('[SelectionTracker] 🧪 Manual test triggered');
                console.log('[SelectionTracker] activeElement:', document.activeElement);
                console.log('[SelectionTracker] activeElement.tagName:', document.activeElement?.tagName);

                const elem = document.activeElement;
                if (elem && (elem.tagName === 'INPUT' || elem.tagName === 'TEXTAREA')) {
                    console.log('[SelectionTracker] selectionStart:', elem.selectionStart);
                    console.log('[SelectionTracker] selectionEnd:', elem.selectionEnd);
                }
            };

            console.log('[SelectionTracker] 🎯 You can call window.__testSelectionSave() to test manually');
        })();
    """
  }

  @objc private func handleFocusWebView() {
    print("[WebViewImpl] 🔔 handleFocusWebView called")

    guard let window = self.window else {
      print("[WebViewImpl] ❌ window is nil")
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }

      print("[WebViewImpl] ▶️ DispatchQueue.main - making first responder")
      window.makeFirstResponder(self)

      // Force display update
      self.setNeedsDisplay(self.bounds)
      self.displayIfNeeded()
      print("[WebViewImpl] 🎨 Display updated")

      // Small delay then restore selection
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        print("[WebViewImpl] ⏰ 0.05s delay passed - attempting restore")

        self.evaluateJavaScript("""
                (function() {
                            console.log('[SelectionRestore] 🔄 Restore function called');
                            console.log('[SelectionRestore] window.__savedSelection:', window.__savedSelection);

                            // Try to restore saved selection
                            if (window.__savedSelection) {
                                console.log('[SelectionRestore] ✅ Saved selection found:', JSON.stringify(window.__savedSelection));
                                const saved = window.__savedSelection;
                                let element = null;

                                // Try to find element by ID first
                                if (saved.elementId) {
                                    console.log('[SelectionRestore] 🔍 Searching by ID:', saved.elementId);
                                    element = document.getElementById(saved.elementId);
                                    console.log('[SelectionRestore] Found by ID?', !!element);
                                }

                                // Try by name
                                if (!element && saved.elementName) {
                                    console.log('[SelectionRestore] 🔍 Searching by name:', saved.elementName);
                                    element = document.querySelector('[name="' + saved.elementName + '"]');
                                    console.log('[SelectionRestore] Found by name?', !!element);
                                }

                                // Try by path
                                if (!element && saved.elementPath) {
                                    console.log('[SelectionRestore] 🔍 Searching by path:', saved.elementPath);
                                    try {
                                        element = document.querySelector(saved.elementPath);
                                        console.log('[SelectionRestore] Found by path?', !!element);
                                    } catch(e) {
                                        console.log('[SelectionRestore] ❌ Error finding by path:', e);
                                    }
                                }

                                if (element) {
                                    console.log('[SelectionRestore] ✅ Element found:', element);
                                    console.log('[SelectionRestore] Element tagName:', element.tagName);

                                    element.focus();
                                    console.log('[SelectionRestore] 🎯 Element focused');

                                    // Restore selection for input/textarea
                                    if (element.tagName === 'INPUT' || element.tagName === 'TEXTAREA') {
                                        console.log('[SelectionRestore] 📝 Restoring input/textarea selection');
                                        console.log('[SelectionRestore] startOffset:', saved.startOffset);
                                        console.log('[SelectionRestore] endOffset:', saved.endOffset);

                                        try {
                                            element.setSelectionRange(saved.startOffset, saved.endOffset);
                                            console.log('[SelectionRestore] ✅ Selection restored for input/textarea');
                                            delete window.__savedSelection;
                                            console.log('[SelectionRestore] 🗑️ Saved selection cleared');
                                            return;
                                        } catch(e) {
                                            console.log('[SelectionRestore] ❌ Error restoring input selection:', e);
                                        }
                                    }

                                    // Restore selection for contenteditable
                                    if (element.isContentEditable) {
                                        console.log('[SelectionRestore] 📝 Restoring contenteditable selection');
                                        try {
                                            // Find all text nodes in the element
                                            function getTextNodes(node) {
                                                const textNodes = [];

                                                function walk(n) {
                                                    if (n.nodeType === Node.TEXT_NODE) {
                                                        textNodes.push(n);
                                                    } else {
                                                        for (let child of n.childNodes) {
                                                            walk(child);
                                                        }
                                                    }
                                                }

                                                walk(node);
                                                return textNodes;
                                            }

                                            const textNodes = getTextNodes(element);
                                            console.log('[SelectionRestore] Found text nodes:', textNodes.length);

                                            if (textNodes.length === 0) {
                                                console.log('[SelectionRestore] ⚠️ No text nodes found');
                                                delete window.__savedSelection;
                                                return;
                                            }

                                            // Calculate cumulative position to find correct text node
                                            let startNode = null, endNode = null;
                                            let startNodeOffset = 0, endNodeOffset = 0;
                                            let cumulativeLength = 0;

                                            for (let i = 0; i < textNodes.length; i++) {
                                                const node = textNodes[i];
                                                const nodeLength = node.textContent.length;

                                                // Find start position
                                                if (startNode === null && cumulativeLength + nodeLength >= saved.startOffset) {
                                                    startNode = node;
                                                    startNodeOffset = saved.startOffset - cumulativeLength;
                                                    console.log('[SelectionRestore] Start node found at index', i, 'offset:', startNodeOffset);
                                                }

                                                // Find end position
                                                if (endNode === null && cumulativeLength + nodeLength >= saved.endOffset) {
                                                    endNode = node;
                                                    endNodeOffset = saved.endOffset - cumulativeLength;
                                                    console.log('[SelectionRestore] End node found at index', i, 'offset:', endNodeOffset);
                                                }

                                                if (startNode && endNode) break;

                                                cumulativeLength += nodeLength;
                                            }

                                            // Fallback to last text node if not found
                                            if (!startNode) {
                                                startNode = textNodes[textNodes.length - 1];
                                                startNodeOffset = startNode.textContent.length;
                                            }
                                            if (!endNode) {
                                                endNode = textNodes[textNodes.length - 1];
                                                endNodeOffset = endNode.textContent.length;
                                            }

                                            console.log('[SelectionRestore] Final start offset:', startNodeOffset);
                                            console.log('[SelectionRestore] Final end offset:', endNodeOffset);

                                            const range = document.createRange();
                                            range.setStart(startNode, startNodeOffset);
                                            range.setEnd(endNode, endNodeOffset);

                                            const selection = window.getSelection();
                                            selection.removeAllRanges();
                                            selection.addRange(range);

                                            console.log('[SelectionRestore] ✅ Selection restored for contenteditable');
                                            delete window.__savedSelection;
                                            console.log('[SelectionRestore] 🗑️ Saved selection cleared');
                                            return;
                                        } catch(e) {
                                            console.log('[SelectionRestore] ❌ Error restoring contenteditable selection:', e);
                                        }
                                    }

                                    // Clear saved selection even if restore failed
                                    delete window.__savedSelection;
                                    console.log('[SelectionRestore] 🗑️ Saved selection cleared (restore failed)');
                                    return;
                                } else {
                                    console.log('[SelectionRestore] ❌ Could not find element to restore');
                                }
                            } else {
                                console.log('[SelectionRestore] ℹ️ No saved selection found');
                            }

                            // No saved selection or restore failed - just focus
                            console.log('[SelectionRestore] 🎯 Falling back to default focus');
                            let focusable = document.activeElement;
                            console.log('[SelectionRestore] Current activeElement:', focusable);

                            if (!focusable || focusable === document.body) {
                                focusable = document.querySelector('input, textarea, [contenteditable="true"]') || document.body;
                                console.log('[SelectionRestore] Found focusable element:', focusable);
                            }

                            focusable.focus();
                            console.log('[SelectionRestore] Element focused');

                            if (focusable.setSelectionRange) {
                                focusable.setSelectionRange(0, 0);
                                console.log('[SelectionRestore] Cursor set to position 0');
                            }
                        })();
            """, completionHandler: { result, error in
          if let error = error {
            print("[WebViewImpl] ❌ JS execution error: \(error)")
          } else {
            print("[WebViewImpl] ✅ JS executed successfully")
          }
        })
      }
    }
  }

  // MARK: - WKNavigationDelegate

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    print("[WebViewImpl] 🌐 Page loaded - re-injecting selection tracker")

    // Re-inject the selection tracking script after page load
    injectSelectionTracker()
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    print("[WebViewImpl] 🔄 Navigation committed")
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
