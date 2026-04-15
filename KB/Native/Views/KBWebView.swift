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

class BlinkCommand: UIKeyCommand {
  var bindingAction: KeyBindingAction = .none
}

class KBWebView: KBWebViewBase {
  
  private var _loaded = false
  private var _hardwareControlPressed = false
  private var _pendingModifierTapKeyCode: UIKeyboardHIDUsage? = nil
  private var _pendingModifierTapCancelled = false
  private(set) var webViewReady = false
  private(set) var blinkKeyCommands: [BlinkCommand] = []
  private(set) var allBlinkKeyCommands: [BlinkCommand] = []
  
  func configure(_ cfg: KBConfig) {
    _buildCommands(cfg)

    guard
      let data = try? JSONEncoder().encode(cfg),
      let json = String(data: data, encoding: .utf8)
    else {
      return
    }
    report("config", arg: json as NSString)
  }
  
  func _buildCommands(_ cfg: KBConfig) {
    
    self.blinkKeyCommands.removeAll()
    self.allBlinkKeyCommands.removeAll()
    
    cfg.shortcuts.forEach { shortcut in
      let cmd = BlinkCommand(
        title: "",
        image: nil,
        action: #selector(SpaceController._onBlinkCommand(_:)),
        input: shortcut.input,
        modifierFlags: shortcut.modifiers,
        propertyList: nil
      )
      cmd.bindingAction = shortcut.action
      
      allBlinkKeyCommands.append(cmd)
      
      if !shortcut.action.isCommand {
        blinkKeyCommands.append(cmd)
      }
    }
  }
  
  
  override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
    return .none
  }
  
  func matchCommand(input: String, flags: UIKeyModifierFlags) -> (UIKeyCommand, UIResponder)? {
    var result: (UIKeyCommand, UIResponder)? = nil
    
    var iterator: UIResponder? = self
    
    // try first on space controller
    let cmd = allBlinkKeyCommands.first(
      where: {
        $0.input == input && $0.modifierFlags == flags
      }
    )
    
    if let cmd = cmd {
      while let responder = iterator {
        if let _ = responder as? SpaceController,
           let action = cmd.action,
           responder.canPerformAction(action, withSender: self) {
          return (cmd, responder)
        }
        iterator = responder.next
      }
    }
    
    iterator = self
    
    while let responder = iterator {
      if let cmd = responder.keyCommands?.first(
        where: {
          $0.input == input && $0.modifierFlags == flags
        }),
         let action = cmd.action,
         responder.canPerformAction(action, withSender: self)
      {
        result = (cmd, responder)
      }
      iterator = responder.next
    }

    return result
  }

  private func _matchNoConvertCompositionCommand(
    for key: UIKey
  ) -> (UIKeyCommand, UIResponder)? {
    let flags = key.modifierFlags
    let controlLikePressed = flags.contains(.control) || _hardwareControlPressed
    let isSupportedModifier =
      (controlLikePressed || flags.contains(.command)) &&
      !flags.contains(.alternate)

    guard
      key.keyCode == .keyboardSemicolon,
      isSupportedModifier
    else {
      return nil
    }

    var iterator: UIResponder? = self

    guard let cmd = allBlinkKeyCommands.first(where: {
      if case .command(.noConvertComposition) = $0.bindingAction {
        return true
      }
      return false
    }) else {
      return nil
    }

    while let responder = iterator {
      if let action = cmd.action,
         responder is SpaceController,
         responder.canPerformAction(action, withSender: self) {
        return (cmd, responder)
      }
      iterator = responder.next
    }

    return nil
  }

  private func _updateHardwareModifierState(
    for presses: Set<UIPress>,
    pressed: Bool
  ) {
    for press in presses {
      guard let key = press.key else {
        continue
      }

      switch key.keyCode {
      case .keyboardLeftControl, .keyboardRightControl:
        _hardwareControlPressed = pressed
      default:
        break
      }
    }
  }

  private func _isNoConvertModifierKeyCode(_ keyCode: UIKeyboardHIDUsage) -> Bool {
    switch keyCode {
    case .keyboardLeftControl, .keyboardRightControl,
         .keyboardLeftGUI, .keyboardRightGUI:
      return true
    default:
      return false
    }
  }

  private func _trackModifierTapCandidate(for presses: Set<UIPress>) {
    guard let key = presses.first?.key, presses.count == 1 else {
      if _pendingModifierTapKeyCode != nil {
        _pendingModifierTapCancelled = true
      }
      return
    }

    if _isNoConvertModifierKeyCode(key.keyCode) {
      _pendingModifierTapKeyCode = key.keyCode
      _pendingModifierTapCancelled = false
      return
    }

    if _pendingModifierTapKeyCode != nil {
      _pendingModifierTapCancelled = true
    }
  }

  private func _handleModifierTapAction(
    for presses: Set<UIPress>
  ) -> Bool {
    guard
      let key = presses.first?.key,
      presses.count == 1,
      let candidate = _pendingModifierTapKeyCode,
      candidate == key.keyCode
    else {
      return false
    }

    defer {
      _pendingModifierTapKeyCode = nil
      _pendingModifierTapCancelled = false
    }

    guard
      !_pendingModifierTapCancelled,
      let smarterInput = self as? SmarterTermInput
    else {
      return false
    }

    return smarterInput.handleModifierTapAction(for: candidate)
  }
  
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    _updateHardwareModifierState(for: presses, pressed: true)
    _trackModifierTapCandidate(for: presses)

    if let key = presses.first?.key, presses.count == 1,
       let smarterInput = self as? SmarterTermInput {
      smarterInput.debugHardwareKeyPhase("began", key: key)
      smarterInput.captureHardwareRawIMEKey(key)
    }

    for press in presses {
      if let key = press.key, key.keyCode == .keyboardLeftGUI || key.keyCode == .keyboardRightGUI,
         let termView = superview as? TermView {
        termView.setCmdKeyPressed(true)
      }
    }

    if let key = presses.first?.key,
       key.keyCode == .keyboardReturnOrEnter || key.charactersIgnoringModifiers == "\r" {
      let modifierFlags = key.modifierFlags.intersection([.command, .control, .alternate, .shift])
      if modifierFlags.isEmpty,
         let smarterInput = self as? SmarterTermInput,
         smarterInput.commitPendingNoConvertOnReturn() {
        return
      }
    }

    guard
      let key = presses.first?.key,
      let (cmd, responder) = _matchNoConvertCompositionCommand(for: key)
        ?? matchCommand(input: key.charactersIgnoringModifiers, flags: key.modifierFlags),
      let action = cmd.action
    else {
      if let key = presses.first?.key,
         key.keyCode.rawValue == 55,
         key.characters == "UIKeyInputEscape"
      {
        self.reportToolbarPress(key.modifierFlags.union(.command), keyId: "190:0")
        return
      }
      super.pressesBegan(presses, with: event)
      return
    }

    responder.perform(action, with: cmd)
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    _updateHardwareModifierState(for: presses, pressed: false)

    if let key = presses.first?.key, presses.count == 1,
       let smarterInput = self as? SmarterTermInput {
      smarterInput.debugHardwareKeyPhase("ended", key: key)
    }

    for press in presses {
      if let key = press.key, key.keyCode == .keyboardLeftGUI || key.keyCode == .keyboardRightGUI,
         let termView = superview as? TermView {
        termView.setCmdKeyPressed(false)
      }
    }

    if _handleModifierTapAction(for: presses) {
      return
    }

    super.pressesEnded(presses, with: event)
  }
  
  func contentView() -> UIView? {
    scrollView.subviews.first
  }
  
  func disableTextSelectionView() {
    let subviews = scrollView.subviews
    guard
      subviews.count > 2,
      let v = subviews[1].subviews.first
    else {
      return
    }
    NotificationCenter.default.removeObserver(v)
  }
  
  override func ready() {
    webViewReady = true
    super.ready()
    configure(KBTracker.shared.loadConfig())
  }
  
  private func _loadKB() {
    let bundle = Bundle.init(for: KBWebView.self)
    guard
      let path = bundle.path(forResource: "kb", ofType: "html")
    else {
      return
    }
    let url = URL(fileURLWithPath: path)
    loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
  }
  
  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    if window != nil && !_loaded {
      _loaded = true
      _loadKB()
    }
  }
}
