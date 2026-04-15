//////////////////////////////////////////////////////////////////////////////////
//
// B L I N K
//
// Copyright (C) 2016-2019 Blink Mobile Shell Project
//
// This file is part of Blink.
//
// Blink is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Blink is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Blink. If not, see <http://www.gnu.org/licenses/>.
//
// In addition, Blink is also subject to certain additional terms under
// GNU GPL version 3 section 7.
//
// You should have received a copy of these additional terms immediately
// following the terms and conditions of the GNU General Public License
// which accompanied the Blink Source Code. If not, see
// <http://www.github.com/blinksh/blink>.
//
////////////////////////////////////////////////////////////////////////////////

import UIKit
import Combine

class CaretHider {
  private var _cancelable: AnyCancellable? = nil
  weak var view: UIView?

  init(view: UIView) {
    self.view = view
    _applyHiddenState(isHidden: true, in: view)
    _cancelable = view.layer.publisher(for: \.sublayers).sink { [weak self] _ in
      guard let self, let view = self.view else {
        return
      }
      self._applyHiddenState(isHidden: true, in: view)
    }
  }

  func show() {
    guard let view = view else {
      return
    }

    _applyHiddenState(isHidden: false, in: view)
  }

  private func _applyHiddenState(isHidden: Bool, in view: UIView) {
    if #available(iOS 17.0, *) {
      let cursorViews = view.subviews.filter { candidate in
        candidate.classForCoder.description().hasSuffix("CursorView")
      }
      cursorViews.forEach { cursorView in
        cursorView.isHidden = isHidden
        cursorView.alpha = isHidden ? 0 : 1
        cursorView.layer.sublayers?.forEach { $0.isHidden = isHidden }
      }
    } else {
      if let caretView = view.value(forKeyPath: "caretView") as? UIView {
        caretView.isHidden = isHidden
      }

      if let floatingView = view.value(forKeyPath: "floatingCaretView") as? UIView {
        floatingView.isHidden = isHidden
      }
    }
  }
}

@objc class SmarterTermInput: KBWebView {
  
  var kbView = KBView()
  var _proxyBarButtonItem: UIBarButtonItem!
  var _barButtonItemGroup: UIBarButtonItemGroup!
  private var _lastIMECompositionText = ""
  private var _lastRawIMECompositionText = ""
  private var _pendingNoConvertCommitText: String? = nil
  private var _pendingNoConvertOriginalText: String? = nil
  private var _caretHider: CaretHider? = nil
  private var _didApplyIMEAppearance = false
  private var _internalSKKMode = "ascii"
  private let _globeKeyRawValue = 669

  private func _debugIME(_ message: String, extra: [String: Any] = [:]) {
    if extra.isEmpty {
      NSLog("BlinkIME %@", message)
      return
    }

    if let data = try? JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
      NSLog("BlinkIME %@ %@", message, json)
    } else {
      NSLog("BlinkIME %@", message)
    }
  }
  
  lazy var _kbProxy: KBProxy = {
    KBProxy(kbView: self.kbView)
  }()
  
  private var _inputAccessoryView: UIView? = nil
  
  var isHardwareKB: Bool { kbView.traits.isHKBAttached }
  
  weak var device: TermDevice? = nil {
    didSet { reportStateReset() }
  }
  
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  
  override init(frame: CGRect, configuration: WKWebViewConfiguration) {
    
    
    super.init(frame: frame, configuration: configuration)


    _proxyBarButtonItem = UIBarButtonItem(customView: _kbProxy)
    _barButtonItemGroup = UIBarButtonItemGroup(barButtonItems: [_proxyBarButtonItem], representativeItem: nil)
    
    kbView.keyInput = self
    kbView.lang = textInputMode?.primaryLanguage ?? ""
    
    // Assume hardware kb by default, since sometimes we don't have kbframe change events
    // if shortcuts toggle in Settings.app is off.
    kbView.traits.isHKBAttached = true
    
    if traitCollection.userInterfaceIdiom == .pad {
//      _setupAssistantItem()
    } else {
      _setupAccessoryView()
    }
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
   
    if let value = self.window?.windowScene?.interfaceOrientation.isPortrait  {
      kbView.traits.isPortrait = value
    }
    kbView.setNeedsLayout()
  }
  
  func shouldUseWKCopyAndPaste() -> Bool {
    false
  }
  
  override func ready() {
    super.ready()
    reportLang()
    
//    device?.focus()
    kbView.isHidden = false
    kbView.invalidateIntrinsicContentSize()
    hideCaret()
  }
  
  func reset() {
    
  }
  
  func reportLang() {
    let lang = self.textInputMode?.primaryLanguage ?? ""
    kbView.lang = lang
    if !lang.hasPrefix("ja") {
      _lastRawIMECompositionText = ""
    }
    _didApplyIMEAppearance = false
    reportLang(lang, isHardwareKB: kbView.traits.isHKBAttached)
    _debugIME("reportLang", extra: [
      "lang": lang,
      "hardware": kbView.traits.isHKBAttached,
      "internalRaw": _lastRawIMECompositionText,
    ])
    hideCaret()
  }

  override func showCaret() {
    _caretHider?.show()
    _caretHider = nil
  }

  override func hideCaret() {
    guard let view = selectionView() else {
      return
    }

    if _caretHider?.view === view {
      return
    }

    _caretHider = CaretHider(view: view)
  }
  
  override var inputAssistantItem: UITextInputAssistantItem {
    let item = super.inputAssistantItem
    if KBTracker.shared.isHardwareKB {
      item.trailingBarButtonGroups = []
      item.leadingBarButtonGroups = []
    } else if _barButtonItemGroup != nil {
      item.leadingBarButtonGroups = []
      if item.trailingBarButtonGroups.first != _barButtonItemGroup || item.trailingBarButtonGroups.count != 1 {
        item.trailingBarButtonGroups = [_barButtonItemGroup]
        
        // Reload input views later. Fixes crash for detaching/attaching KB
        if let contentView = self.contentView() {
          DispatchQueue.main.async {
            contentView.reloadInputViews()
          }
        }
        
      }
      kbView.isHidden = false
      
    } else {
      item.trailingBarButtonGroups = []
      item.leadingBarButtonGroups = []
    }
    
    return item
  }
  
  override func becomeFirstResponder() -> Bool {
    // Don't become first responder if blocked (e.g., during Snips Input Mode)
    if device?.shouldBlockFirstResponder == true {
      return false
    }

    sync(traits: KBTracker.shared.kbTraits, device: KBTracker.shared.kbDevice, hideSmartKeysWithHKB: KBTracker.shared.hideSmartKeysWithHKB)

    let res = super.becomeFirstResponder()

    if !webViewReady {
      return res
    }

    device?.focus()
    kbView.isHidden = false
    setNeedsLayout()

    _inputAccessoryView?.isHidden = false
    hideCaret()

    return res
  }
  
  override func canBeFocused() -> Bool {
    let res = super.canBeFocused()
    if let delegate = self.window?.windowScene?.delegate as? SceneDelegate {
      if delegate.showingPaywall() {
        return false
      }
    }
    return res
    
  }
  
  var isRealFirstResponder: Bool {
    contentView()?.isFirstResponder == true
  }
  
  func reportStateReset() {
    reportStateReset(false)
    device?.view?.cleanSelection()
  }
  
  func reportStateWithSelection() {
    reportStateReset(device?.view?.hasSelection ?? false)
  }
  
  
  override func resignFirstResponder() -> Bool {
    let res = super.resignFirstResponder()
    if res {
      device?.blur()
      kbView.isHidden = true
      _inputAccessoryView?.isHidden = true
    }
    return res
  }

  func _setupAccessoryView() {
    if isHardwareKB {
      return
    }
    inputAssistantItem.leadingBarButtonGroups = []
    inputAssistantItem.trailingBarButtonGroups = []

    if let _ = _inputAccessoryView as? KBAccessoryView {
    } else {
      _inputAccessoryView = KBAccessoryView(kbView: kbView)
    }
  }

  override var inputAccessoryView: UIView? {
    return _inputAccessoryView
  }

  func sync(traits: KBTraits, device: KBDevice, hideSmartKeysWithHKB: Bool) {
    kbView.kbDevice = device
    
    defer {
      
      kbView.traits = traits
      
      if let scene = window?.windowScene {
        if traitCollection.userInterfaceIdiom == .phone {
          kbView.traits.isPortrait = scene.interfaceOrientation.isPortrait
        } else if kbView.traits.isFloatingKB {
          kbView.traits.isPortrait = true
        } else {
          kbView.traits.isPortrait = scene.interfaceOrientation.isPortrait
        }
      }
      
    }
    
    if traitCollection.userInterfaceIdiom == .phone {
      if hideSmartKeysWithHKB && traits.isHKBAttached {
        _removeSmartKeys()
        return
      }
    }
    
    if traits.isFloatingKB {
      _setupAccessoryView()
      return
    }
    
    if traitCollection.userInterfaceIdiom != .pad {
//      needToReload = (_inputAccessoryView as? KBAccessoryView) == nil
      _setupAccessoryView()
    }
    
  }
  
//  func _setupAssistantItem() {
//    let item = inputAssistantItem
//
////    let proxyItem = UIBarButtonItem(customView: _kbProxy)
////    let group = UIBarButtonItemGroup(barButtonItems: [proxyItem], presentativeItem: nil)
//
////    item.leadingBarButtonGroups = []
////    item.trailingBarButtonGroups = [group]
//
//    item.leadingBarButtonGroups = []
//    item.trailingBarButtonGroups = []
//  }
  
  func _removeSmartKeys() {
    if let _ = _inputAccessoryView as? KBAccessoryView {
      _inputAccessoryView = UIView(frame: .zero)
      self.contentView()?.reloadInputViews()      
    }
    
    guard let item = contentView()?.inputAssistantItem
      else {
        return
    }
    item.leadingBarButtonGroups = []
    item.trailingBarButtonGroups = []
    setNeedsLayout()
  }
  
  // MARK: - Legacy Keyboard Methods Removed
  // These empty override methods have been removed as keyboard tracking
  // is now handled by UIKeyboardLayoutGuide in SpaceController
  
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    super.pressesBegan(presses, with: event)
    
    guard presses.count == 1, let press = presses.first, let key = press.key,
    // left or right cmd
    key.keyCode.rawValue == 227 || key.keyCode.rawValue == 231
    else {
      commandPressTimestamp = 0
      return
    }

    if _canRunNoConvertShortcut() {
      commandPressTimestamp = 0
      return
    }
    
    if press.timestamp - commandPressTimestamp > 0.5 {
      commandPressTimestamp = press.timestamp
      return
    }
    
    UIApplication.shared.sendAction(#selector(SpaceController.toggleQuickActionsAction), to: nil, from: nil, for: nil)
    commandPressTimestamp = 0
  }
  
  var commandPressTimestamp: TimeInterval = 0
}

// - MARK: Web communication
extension SmarterTermInput {
  
  override func onOut(_ data: String) {
    defer {
      kbView.turnOffUntracked()
    }
    
    guard
      let device = device,
      let deviceView = device.view,
      let scene = deviceView.window?.windowScene,
      scene.activationState == .foregroundActive
    else {
        return
    }

    let output = _replacementOutputIfNeeded(for: data)
    _scrollPrimaryToBottomForLocalInput()

    deviceView.displayInput(output)
    
    device.write(output)
  }
  
  override func onCommand(_ command: String) {
    kbView.turnOffUntracked()
    guard
      let device = device,
      let scene = device.view.window?.windowScene,
      scene.activationState == .foregroundActive,
      let cmd = Command(rawValue: command),
      let spCtrl = spaceController
    else {
      return
    }
    
    spCtrl._onCommand(cmd)
  }
  
  var spaceController: SpaceController? {
    var n = next
    while let responder = n {
      if let spCtrl = responder as? SpaceController {
        return spCtrl
      }
      n = responder.next
    }
    return nil
  }
  
  override func onSelection(_ args: [AnyHashable : Any]) {
    if let dir = args["dir"] as? String, let gran = args["gran"] as? String {
      device?.view?.modifySelection(inDirection: dir, granularity: gran)
    } else if let op = args["command"] as? String {
      switch op {
      case "change": device?.view?.modifySideOfSelection()
      case "copy": copy(self)
      case "paste": device?.view?.pasteSelection(self)
      case "cancel": fallthrough
      default:  device?.view?.cleanSelection()
      }
    }
  }
  
  override func onMods() {
    kbView.stopRepeats()
  }
  
  override func onIME(_ event: String, data: String) {
    if event != "compositionend" {
      _applyIMEAppearance()
    }
    hideCaret()
    if event == "compositionstart" && data.isEmpty {
    } else if event == "compositionend" {
      _lastIMECompositionText = ""
      _lastRawIMECompositionText = ""
      _clearPendingNoConvertIfMatched(by: data)
      kbView.traits.isIME = false
    } else { // "compositionupdate"
      _lastIMECompositionText = data
      _clearPendingNoConvertIfCompositionMoved(to: data)
      kbView.traits.isIME = true
    }
    let hasMarkedText = (contentView() as? UITextInput)?.markedTextRange != nil
    _debugIME("onIME", extra: [
      "event": event,
      "data": data,
      "lastIME": _lastIMECompositionText,
      "lastRaw": _lastRawIMECompositionText,
      "hasMarkedText": hasMarkedText,
      "lang": kbView.lang,
    ])
  }

  @objc func noConvertComposition() {
    guard
      let device = device,
      let deviceView = device.view,
      let scene = deviceView.window?.windowScene,
      scene.activationState == .foregroundActive
    else {
      return
    }

    let originalComposition = _lastIMECompositionText
    let rawComposition = _lastRawIMECompositionText
    let fallbackASCII = Self._preferredNoConvertText(from: originalComposition)
    _debugIME("noConvert:start", extra: [
      "original": originalComposition,
      "raw": rawComposition,
      "fallback": fallbackASCII,
      "lang": kbView.lang,
    ])

    evaluateJavaScript("_blinkPreferredNoConvertText(window._kb);") { [weak self] result, error in
      guard let self = self else {
        return
      }

      let jsASCII = error == nil ? (result as? String) ?? "" : ""
      let ascii =
        !rawComposition.isEmpty ? rawComposition :
        (!jsASCII.isEmpty ? jsASCII : fallbackASCII)
      self._debugIME("noConvert:resolved", extra: [
        "js": jsASCII,
        "ascii": ascii,
        "error": error?.localizedDescription ?? "",
      ])
      guard !ascii.isEmpty else {
        return
      }

      if self._replaceMarkedTextIfPossible(with: ascii) {
        let original = !originalComposition.isEmpty ? originalComposition : self._lastIMECompositionText
        self._pendingNoConvertOriginalText = !original.isEmpty ? original : ascii
        self._pendingNoConvertCommitText = ascii
        self._armPendingNoConvertCommit(original: self._pendingNoConvertOriginalText ?? ascii, replacement: ascii)
        self._lastIMECompositionText = ascii
        self._lastRawIMECompositionText = ascii
        self.kbView.traits.isIME = true
        self._debugIME("noConvert:replaceMarkedText", extra: [
          "original": self._pendingNoConvertOriginalText ?? "",
          "replacement": ascii,
        ])
        return
      }

      self._lastIMECompositionText = ""
      self._lastRawIMECompositionText = ""
      self.kbView.traits.isIME = false
      self._debugIME("noConvert:directWrite", extra: [
        "ascii": ascii,
      ])

      deviceView.displayInput(ascii)
      device.write(ascii)
    }
  }

  func commitPendingNoConvertOnReturn() -> Bool {
    guard
      let replacement = _pendingNoConvertCommitText,
      !replacement.isEmpty,
      let textInput = contentView() as? UITextInput,
      textInput.markedTextRange != nil
    else {
      return false
    }

    textInput.setMarkedText(replacement, selectedRange: NSRange(location: replacement.count, length: 0))
    textInput.unmarkText()
    _debugIME("noConvert:commitOnReturn", extra: [
      "replacement": replacement,
    ])
    _lastIMECompositionText = ""
    _lastRawIMECompositionText = ""
    _clearPendingNoConvert()
    _resetNoConvertIMEState()
    return true
  }

  func handleModifierTapNoConvert() -> Bool {
    guard _canRunNoConvertShortcut() else {
      return false
    }

    noConvertComposition()
    return true
  }

  func handleModifierTapAction(for keyCode: UIKeyboardHIDUsage) -> Bool {
    _debugIME("modifierTap", extra: [
      "keyCode": keyCode.rawValue,
      "lang": kbView.lang,
      "lastIME": _lastIMECompositionText,
      "lastRaw": _lastRawIMECompositionText,
      "mode": _internalSKKMode,
    ])

    if _canRunNoConvertShortcut(), !_lastRawIMECompositionText.isEmpty {
      _debugIME("modifierTap:noConvert", extra: [
        "keyCode": keyCode.rawValue,
        "raw": _lastRawIMECompositionText,
        "composition": _lastIMECompositionText,
      ])
      noConvertComposition()
      return true
    }

    switch keyCode.rawValue {
    case UIKeyboardHIDUsage.keyboardLeftControl.rawValue:
      _debugIME("modifierTap:setUS", extra: [
        "keyCode": keyCode.rawValue,
      ])
      _setInternalSKKMode("ascii", reason: "modifierTap-leftControl")
      return true
    case UIKeyboardHIDUsage.keyboardRightControl.rawValue:
      _debugIME("modifierTap:setJP", extra: [
        "keyCode": keyCode.rawValue,
      ])
      _setInternalSKKMode("hiragana", reason: "modifierTap-rightControl")
      return true
    case UIKeyboardHIDUsage.keyboardLeftGUI.rawValue,
         UIKeyboardHIDUsage.keyboardRightGUI.rawValue:
      return handleModifierTapNoConvert()
    default:
      return false
    }
  }

  func handleJapaneseToggleKey() -> Bool {
    _debugIME("japaneseToggleKey", extra: [
      "lang": kbView.lang,
      "lastIME": _lastIMECompositionText,
      "lastRaw": _lastRawIMECompositionText,
      "mode": _internalSKKMode,
    ])

    if _canRunNoConvertShortcut(), !_lastRawIMECompositionText.isEmpty {
      _debugIME("japaneseToggleKey:noConvert", extra: [
        "raw": _lastRawIMECompositionText,
        "composition": _lastIMECompositionText,
      ])
      noConvertComposition()
      return true
    }

    let nextMode = _internalSKKMode == "hiragana" ? "ascii" : "hiragana"
    _setInternalSKKMode(nextMode, reason: "japaneseToggleKey")
    return true
  }

  func handleNoConvertTriggerKey(reason: String) -> Bool {
    _debugIME("noConvertTriggerKey", extra: [
      "reason": reason,
      "lang": kbView.lang,
      "lastIME": _lastIMECompositionText,
      "lastRaw": _lastRawIMECompositionText,
      "mode": _internalSKKMode,
    ])

    guard _canRunNoConvertShortcut(), !_lastRawIMECompositionText.isEmpty else {
      return false
    }

    noConvertComposition()
    return true
  }

  func handleControlSpaceToggle() -> Bool {
    let nextMode = _internalSKKMode == "hiragana" ? "ascii" : "hiragana"
    _debugIME("controlSpaceToggle", extra: [
      "from": _internalSKKMode,
      "to": nextMode,
    ])
    _setInternalSKKMode(nextMode, reason: "control-space")
    return true
  }

  private func _replaceMarkedTextIfPossible(with text: String) -> Bool {
    guard
      !text.isEmpty,
      let textInput = contentView() as? UITextInput,
      textInput.markedTextRange != nil
    else {
      return false
    }

    textInput.setMarkedText(text, selectedRange: NSRange(location: text.count, length: 0))
    return true
  }

  private func _scrollPrimaryToBottomForLocalInput() {
    interactions
      .compactMap { $0 as? WKWebViewGesturesInteraction }
      .first?
      .scrollPrimaryToBottomForLocalInput()
  }

  private func _armPendingNoConvertCommit(original: String, replacement: String) {
    guard
      !replacement.isEmpty,
      let originalJSON = try? Self._jsonStringLiteral(original),
      let replacementJSON = try? Self._jsonStringLiteral(replacement)
    else {
      return
    }

    let js = """
    window.__blinkPendingNoConvertCommit = {
      original: \(originalJSON),
      replacement: \(replacementJSON)
    };
    """
    evaluateJavaScript(js, completionHandler: nil)
  }

  private func _replacementOutputIfNeeded(for data: String) -> String {
    guard let replacement = _pendingNoConvertCommitText else {
      return data
    }

    if data == replacement {
      _clearPendingNoConvert()
      return data
    }

    if let original = _pendingNoConvertOriginalText, !original.isEmpty, data == original {
      _clearPendingNoConvert()
      return replacement
    }

    return data
  }

  private func _clearPendingNoConvertIfMatched(by data: String) {
    guard let replacement = _pendingNoConvertCommitText else {
      return
    }

    if data == replacement || data == _pendingNoConvertOriginalText {
      _clearPendingNoConvert()
    }
  }

  private func _clearPendingNoConvertIfCompositionMoved(to data: String) {
    guard let replacement = _pendingNoConvertCommitText else {
      return
    }

    if !data.isEmpty && data != replacement {
      _clearPendingNoConvert()
    }
  }

  private func _clearPendingNoConvert() {
    _pendingNoConvertCommitText = nil
    _pendingNoConvertOriginalText = nil
  }

  func captureHardwareRawIMEKey(_ key: UIKey) {
    guard kbView.lang.hasPrefix("ja") else {
      return
    }

    if !kbView.traits.isHKBAttached {
      kbView.traits.isHKBAttached = true
      _debugIME("hardwareKeyboardDetectedFromPress", extra: [
        "keyCode": key.keyCode.rawValue,
        "lang": kbView.lang,
      ])
    }

    let flags = key.modifierFlags
    if flags.contains(.control) || flags.contains(.alternate) || flags.contains(.command) {
      return
    }

    if key.keyCode == .keyboardDeleteOrBackspace {
      if !_lastRawIMECompositionText.isEmpty {
        _lastRawIMECompositionText.removeLast()
      }
      _debugIME("rawKey", extra: [
        "keyCode": key.keyCode.rawValue,
        "characters": key.characters,
        "charactersIgnoringModifiers": key.charactersIgnoringModifiers,
        "raw": _lastRawIMECompositionText,
      ])
      return
    }

    guard let rawChar = Self._rawASCIICharacter(for: key) else {
      _debugIME("rawKey:ignored", extra: [
        "keyCode": key.keyCode.rawValue,
        "characters": key.characters,
        "charactersIgnoringModifiers": key.charactersIgnoringModifiers,
      ])
      return
    }

    _lastRawIMECompositionText.append(rawChar)
    _debugIME("rawKey", extra: [
      "keyCode": key.keyCode.rawValue,
      "characters": key.characters,
      "charactersIgnoringModifiers": key.charactersIgnoringModifiers,
      "appended": String(rawChar),
      "raw": _lastRawIMECompositionText,
    ])
  }

  func debugHardwareKeyPhase(_ phase: String, key: UIKey) {
    let shouldLog =
      kbView.lang.hasPrefix("ja") ||
      key.keyCode == .keyboardCapsLock ||
      key.keyCode == .keyboardSpacebar ||
      key.keyCode == .keyboardReturnOrEnter ||
      key.keyCode == .keyboardLeftControl ||
      key.keyCode == .keyboardRightControl ||
      key.keyCode == .keyboardLeftGUI ||
      key.keyCode == .keyboardRightGUI ||
      key.keyCode.rawValue == _globeKeyRawValue

    guard shouldLog else {
      return
    }

    _debugIME("hardwareKey:" + phase, extra: [
      "keyCode": key.keyCode.rawValue,
      "characters": key.characters,
      "charactersIgnoringModifiers": key.charactersIgnoringModifiers,
      "flags": key.modifierFlags.rawValue,
      "lang": kbView.lang,
      "raw": _lastRawIMECompositionText,
    ])

    if key.keyCode == .keyboardSpacebar {
      let flags = key.modifierFlags
      let observedShortcut =
        flags.contains(.command) || flags.contains(.control)
      if observedShortcut {
        _debugIME("spaceWithModifier:" + phase, extra: [
          "keyCode": key.keyCode.rawValue,
          "characters": key.characters,
          "charactersIgnoringModifiers": key.charactersIgnoringModifiers,
          "flags": flags.rawValue,
          "lang": kbView.lang,
          "raw": _lastRawIMECompositionText,
        ])
      }
    }
  }

  private func _applyIMEAppearance() {
    guard !_didApplyIMEAppearance else {
      return
    }
    contentView()?.tintColor = UIColor.systemOrange
    _didApplyIMEAppearance = true
  }

  private func _resetNoConvertIMEState() {
    let js = """
    window.__blinkPendingNoConvertCommit = null;
    if (window._kb) {
      window._kb.__blinkCompositionText = '';
      window._kb.__blinkRawCompositionText = '';
      window._kb.__blinkSkipNextCompositionEnd = false;
    }
    """
    evaluateJavaScript(js, completionHandler: nil)
    _lastRawIMECompositionText = ""

    let shouldRefocus = isFirstResponder || isRealFirstResponder
    guard shouldRefocus else {
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        return
      }
      _ = self.resignFirstResponder()
      _ = self.becomeFirstResponder()
    }
  }

  private func _setInternalSKKMode(_ mode: String, reason: String) {
    _internalSKKMode = mode
    _debugIME("setInternalSKKMode", extra: [
      "mode": mode,
      "reason": reason,
    ])
    evaluateJavaScript("term_setInternalSKKMode('\(mode)');", completionHandler: nil)
  }

  private static func _jsonStringLiteral(_ string: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: [string])
    let arrayLiteral = String(decoding: data, as: UTF8.self)
    return String(arrayLiteral.dropFirst().dropLast())
  }

  private func _canRunNoConvertShortcut() -> Bool {
    if !_lastIMECompositionText.isEmpty {
      return true
    }

    if let textInput = contentView() as? UITextInput {
      return textInput.markedTextRange != nil
    }

    return false
  }
  
  func stuckKey() -> KeyCode? {
    let mods: UIKeyModifierFlags = [.shift, .control, .alternate, .command]
    let stuck = mods.intersection(trackingModifierFlags)
    
    // Return command key first
    if stuck.contains(.command) {
      return KeyCode.commandLeft
    }

    if stuck.contains(.shift) {
      return KeyCode.shiftLeft
    }
    if stuck.contains(.control) {
      return KeyCode.controlLeft
    }
    
    if stuck.contains(.alternate) {
      return KeyCode.optionLeft
    }
    
    return nil
  }
}

private extension SmarterTermInput {
  static let _kanaDigraphToRomaji: [String: String] = [
    "きゃ": "kya", "きゅ": "kyu", "きょ": "kyo",
    "しゃ": "sha", "しゅ": "shu", "しょ": "sho",
    "ちゃ": "cha", "ちゅ": "chu", "ちょ": "cho",
    "にゃ": "nya", "にゅ": "nyu", "にょ": "nyo",
    "ひゃ": "hya", "ひゅ": "hyu", "ひょ": "hyo",
    "みゃ": "mya", "みゅ": "myu", "みょ": "myo",
    "りゃ": "rya", "りゅ": "ryu", "りょ": "ryo",
    "ぎゃ": "gya", "ぎゅ": "gyu", "ぎょ": "gyo",
    "じゃ": "ja", "じゅ": "ju", "じょ": "jo",
    "びゃ": "bya", "びゅ": "byu", "びょ": "byo",
    "ぴゃ": "pya", "ぴゅ": "pyu", "ぴょ": "pyo",
    "ゔぁ": "va", "ゔぃ": "vi", "ゔぇ": "ve", "ゔぉ": "vo",
    "てゃ": "tha", "てぃ": "thi", "てゅ": "thu", "てょ": "tho",
    "でゃ": "dha", "でぃ": "dhi", "でゅ": "dhu", "でょ": "dho",
    "とぅ": "tu", "どぅ": "du",
    "ふぁ": "fa", "ふぃ": "fi", "ふぇ": "fe", "ふぉ": "fo",
    "つぁ": "tsa", "つぃ": "tsi", "つぇ": "tse", "つぉ": "tso",
    "しぇ": "she", "ちぇ": "che", "じぇ": "je",
    "うぁ": "wa", "うぃ": "wi", "うぇ": "we", "うぉ": "wo"
  ]

  static let _kanaToRomaji: [Character: String] = [
    "あ": "a",  "い": "i",  "う": "u",  "え": "e",  "お": "o",
    "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
    "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
    "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
    "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
    "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
    "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
    "や": "ya", "ゆ": "yu", "よ": "yo",
    "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
    "わ": "wa", "を": "wo", "ん": "n",
    "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
    "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
    "だ": "da", "ぢ": "ji", "づ": "zu", "で": "de", "ど": "do",
    "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
    "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
    "ぁ": "a",  "ぃ": "i",  "ぅ": "u",  "ぇ": "e",  "ぉ": "o",
    "ゃ": "ya", "ゅ": "yu", "ょ": "yo", "ゎ": "wa",
    "ゔ": "vu"
  ]

  static func _preferredNoConvertText(from composition: String) -> String {
    let romanized = _romanizeComposition(composition)
    if romanized.isEmpty {
      return ""
    }
    return romanized
  }

  static func _romanizeComposition(_ composition: String) -> String {
    let source = _katakanaToHiragana(composition)
    var result = ""
    var pendingSokuon = false
    let chars = Array(source)
    var index = 0

    while index < chars.count {
      let ch = chars[index]

      if ch.isASCII {
        result.append(ch)
        pendingSokuon = false
        index += 1
        continue
      }

      if ch == "っ" {
        pendingSokuon = true
        index += 1
        continue
      }

      if ch == "ー" {
        if let last = result.last, "aeiou".contains(last) {
          result.append(last)
        } else {
          result.append("-")
        }
        pendingSokuon = false
        index += 1
        continue
      }

      var roman: String? = nil
      if index + 1 < chars.count {
        let pair = String(chars[index...index + 1])
        roman = _kanaDigraphToRomaji[pair]
        if roman != nil {
          index += 1
        }
      }

      roman = roman ?? _kanaToRomaji[ch]

      guard let roman else {
        result.append(ch)
        pendingSokuon = false
        index += 1
        continue
      }

      if pendingSokuon, let first = roman.first, first.isLetter {
        result.append(first)
      }
      pendingSokuon = false
      result += roman
      index += 1
    }

    return result
  }

  static func _katakanaToHiragana(_ text: String) -> String {
    String(text.map { ch in
      guard let scalar = ch.unicodeScalars.first,
            scalar.value >= 0x30A1,
            scalar.value <= 0x30F6,
            let converted = UnicodeScalar(scalar.value - 0x60) else {
        return ch
      }
      return Character(converted)
    })
  }

  static func _rawASCIICharacter(for key: UIKey) -> Character? {
    let flags = key.modifierFlags
    let shift = flags.contains(.shift)
    let caps = flags.contains(.alphaShift)
    let uppercasedLetter = shift != caps

    switch key.keyCode {
    case .keyboardA: return uppercasedLetter ? "A" : "a"
    case .keyboardB: return uppercasedLetter ? "B" : "b"
    case .keyboardC: return uppercasedLetter ? "C" : "c"
    case .keyboardD: return uppercasedLetter ? "D" : "d"
    case .keyboardE: return uppercasedLetter ? "E" : "e"
    case .keyboardF: return uppercasedLetter ? "F" : "f"
    case .keyboardG: return uppercasedLetter ? "G" : "g"
    case .keyboardH: return uppercasedLetter ? "H" : "h"
    case .keyboardI: return uppercasedLetter ? "I" : "i"
    case .keyboardJ: return uppercasedLetter ? "J" : "j"
    case .keyboardK: return uppercasedLetter ? "K" : "k"
    case .keyboardL: return uppercasedLetter ? "L" : "l"
    case .keyboardM: return uppercasedLetter ? "M" : "m"
    case .keyboardN: return uppercasedLetter ? "N" : "n"
    case .keyboardO: return uppercasedLetter ? "O" : "o"
    case .keyboardP: return uppercasedLetter ? "P" : "p"
    case .keyboardQ: return uppercasedLetter ? "Q" : "q"
    case .keyboardR: return uppercasedLetter ? "R" : "r"
    case .keyboardS: return uppercasedLetter ? "S" : "s"
    case .keyboardT: return uppercasedLetter ? "T" : "t"
    case .keyboardU: return uppercasedLetter ? "U" : "u"
    case .keyboardV: return uppercasedLetter ? "V" : "v"
    case .keyboardW: return uppercasedLetter ? "W" : "w"
    case .keyboardX: return uppercasedLetter ? "X" : "x"
    case .keyboardY: return uppercasedLetter ? "Y" : "y"
    case .keyboardZ: return uppercasedLetter ? "Z" : "z"
    case .keyboard1: return shift ? "!" : "1"
    case .keyboard2: return shift ? "@" : "2"
    case .keyboard3: return shift ? "#" : "3"
    case .keyboard4: return shift ? "$" : "4"
    case .keyboard5: return shift ? "%" : "5"
    case .keyboard6: return shift ? "^" : "6"
    case .keyboard7: return shift ? "&" : "7"
    case .keyboard8: return shift ? "*" : "8"
    case .keyboard9: return shift ? "(" : "9"
    case .keyboard0: return shift ? ")" : "0"
    case .keyboardHyphen: return shift ? "_" : "-"
    case .keyboardEqualSign: return shift ? "+" : "="
    case .keyboardOpenBracket: return shift ? "{" : "["
    case .keyboardCloseBracket: return shift ? "}" : "]"
    case .keyboardBackslash: return shift ? "|" : "\\"
    case .keyboardSemicolon: return shift ? ":" : ";"
    case .keyboardQuote: return shift ? "\"" : "'"
    case .keyboardComma: return shift ? "<" : ","
    case .keyboardPeriod: return shift ? ">" : "."
    case .keyboardSlash: return shift ? "?" : "/"
    case .keyboardGraveAccentAndTilde: return shift ? "~" : "`"
    case .keyboardSpacebar: return " "
    default:
      return nil
    }
  }
}
// - MARK: Config

extension SmarterTermInput {
  
  @objc private func _updateSettings() {
//    let hideSmartKeysWithHKB = !BKUserConfigurationManager.userSettingsValue(forKey: BKUserConfigShowSmartKeysWithXKeyBoard)
//    
//    if hideSmartKeysWithHKB != hideSmartKeysWithHKB {
//      _hideSmartKeysWithHKB = hideSmartKeysWithHKB
//      if traitCollection.userInterfaceIdiom == .pad {
//        _setupAssistantItem()
//      } else {
//        _setupAccessoryView()
//      }
//      _refreshInputViews()
//    }
  }
}


// - MARK: Commands

extension SmarterTermInput {
  
  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    switch action {
    case #selector(UIResponder.paste(_:)):
      // do not touch UIPasteboard before actual paste to skip exta notification.
      return true// UIPasteboard.general.string != nil
    case
      #selector(UIResponder.copy(_:)),
      #selector(Self.copyRaw(_:)),
      #selector(UIResponder.cut(_:)):
      // When the action is requested from the keyboard, the sender will be nil.
      // In that case we let it go through to the WKWebView.
      // Otherwise, we check if there is a selection.
      return (sender == nil) || (sender != nil && device?.view?.hasSelection == true)
    case
         #selector(TermView.pasteSelection(_:)),
         #selector(Self.soSelection(_:)),
         #selector(Self.googleSelection(_:)),
         #selector(Self.shareSelection(_:)):
      return sender != nil && device?.view?.hasSelection == true
    case #selector(Self.copyLink(_:)),
         #selector(Self.openLink(_:)):
      return sender != nil && device?.view?.detectedLink != nil
    default:
//      if #available(iOS 15.0, *) {
//        switch action {
//          case #selector(UIResponder.pasteAndMatchStyle(_:)),
//               #selector(UIResponder.pasteAndSearch(_:)),
//               #selector(UIResponder.pasteAndGo(_:)): return false
//          case _: break
//        }
//      }
      return super.canPerformAction(action, withSender: sender)
    }
  }
  
  override func copy(_ sender: Any?) {
    if shouldUseWKCopyAndPaste() {
      super.copy(sender)
    } else {
      device?.view?.copy(sender)
    }
  }

  @objc func copyRaw(_ sender: Any?) {
    device?.view?.copyRaw(sender)
  }

  override func paste(_ sender: Any?) {
    if shouldUseWKCopyAndPaste() {
      super.paste(sender)
    } else {
      device?.view?.paste(sender)
    }
  }

  @objc func copyLink(_ sender: Any) {
    guard
      let deviceView = device?.view
      else {
        return
    }
    let url = deviceView.detectedLink
    UIPasteboard.general.url = url
    deviceView.cleanSelection()
  }
  
  @objc func openLink(_ sender: Any) {
    guard
      let deviceView = device?.view
      else {
        return
    }
    let url = deviceView.detectedLink
    deviceView.cleanSelection()
    
    blink_openurl(url)
  }
  
  @objc func pasteSelection(_ sender: Any) {
    device?.view?.pasteSelection(sender)
  }
  
  @objc func googleSelection(_ sender: Any) {
    guard
      let deviceView = device?.view,
      let query = deviceView.selectedText.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
      let url = URL(string: "https://google.com/search?q=\(query)")
    else {
        return
    }
    
    blink_openurl(url)
  }
  
  @objc func soSelection(_ sender: Any) {
    guard
      let deviceView = device?.view,
      let query = deviceView.selectedText.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
      let url = URL(string: "https://stackoverflow.com/search?q=\(query)")
    else {
        return
    }
    
    blink_openurl(url)
  }
  
  @objc func shareSelection(_ sender: Any) {
    guard
      let vc = device?.delegate?.viewController(),
      let deviceView = device?.view
    else {
        return
    }
    let text = deviceView.selectedText
    
    let ctrl = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    ctrl.popoverPresentationController?.sourceView = deviceView
    ctrl.popoverPresentationController?.sourceRect = deviceView.selectionRect
    vc.present(ctrl, animated: true, completion: nil)
  }
}


extension SmarterTermInput: TermInput {
  var secureTextEntry: Bool {
    get {
      false
    }
    set(secureTextEntry) {
      
    }
  }
  
}

class VSCodeInput: SmarterTermInput {
  override func shouldUseWKCopyAndPaste() -> Bool {
    true
  }
  
  override func canBeFocused() -> Bool {
    let res = super.canBeFocused()
   
    if res == false {
      return KBTracker.shared.input == self
    }
    
    return res
  }
}
