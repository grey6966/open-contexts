@preconcurrency import ApplicationServices
import AppKit
import Combine

struct KeyboardShortcut: Codable, Equatable {
    static let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
    static let allWindows = KeyboardShortcut(keyCode: 48, modifiers: .maskCommand, keyLabel: "Tab")
    static let currentApp = KeyboardShortcut(keyCode: 50, modifiers: .maskCommand, keyLabel: "`")

    let keyCode: UInt16
    let modifierRawValue: UInt64
    let keyLabel: String

    init(keyCode: UInt16, modifiers: CGEventFlags, keyLabel: String) {
        self.keyCode = keyCode
        modifierRawValue = modifiers.rawValue
        self.keyLabel = keyLabel
    }

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifierRawValue) }
    var isValid: Bool {
        keyCode < 128 && keyCode != 53 && !(54...63).contains(keyCode)
            && !modifiers.isEmpty && modifiers.subtracting(Self.modifierMask).isEmpty
            && !keyLabel.isEmpty && keyLabel.count <= 20
    }
    var display: String {
        (modifiers.contains(.maskControl) ? "⌃" : "")
            + (modifiers.contains(.maskAlternate) ? "⌥" : "")
            + (modifiers.contains(.maskCommand) ? "⌘" : "") + keyLabel
    }

    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        self.keyCode == keyCode && flags.intersection(Self.modifierMask) == modifiers
    }

    func conflicts(with other: KeyboardShortcut) -> Bool {
        keyCode == other.keyCode && modifierRawValue == other.modifierRawValue
    }

    init?(event: NSEvent) {
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        guard !flags.contains(.maskShift) else { return nil }
        let names: [UInt16: String] = [
            36: "↩", 48: "Tab", 49: "Space", 51: "⌫", 76: "⌤", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟"
        ]
        let functionKeys: [UInt16: Int] = [
            122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9,
            109: 10, 103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20
        ]
        let label = names[event.keyCode] ?? functionKeys[event.keyCode].map { "F\($0)" }
            ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        self.init(keyCode: event.keyCode, modifiers: flags.intersection(Self.modifierMask), keyLabel: label)
        guard isValid else { return nil }
    }
}

enum SwitcherAction: Equatable {
    case begin(currentAppOnly: Bool)
    case step(Int)
    case commit
    case cancel
}

private struct ShortcutState {
    private(set) var isSwitching = false
    private(set) var heldModifiers: CGEventFlags = []
    private var shiftIsDown = false

    var isShiftDown: Bool { shiftIsDown }

    mutating func begin(currentAppOnly: Bool, allowed: Bool,
                        modifiers: CGEventFlags = .maskCommand,
                        shiftHeld: Bool = false) -> SwitcherAction? {
        guard !isSwitching, allowed else { return nil }
        isSwitching = true
        heldModifiers = modifiers
        // Shift already held when the switcher opens belongs to the opening shortcut, not a fresh press.
        shiftIsDown = shiftHeld
        return .begin(currentAppOnly: currentAppOnly)
    }

    mutating func step(_ amount: Int) -> SwitcherAction? {
        isSwitching ? .step(amount) : nil
    }

    /// Pressing Shift on its own while switching immediately steps back one window.
    mutating func shiftFlagsChanged(_ flags: CGEventFlags) -> SwitcherAction? {
        guard isSwitching else { return nil }
        guard flags.contains(.maskShift) else {
            shiftIsDown = false
            return nil
        }
        guard !shiftIsDown else { return nil }
        shiftIsDown = true
        return .step(-1)
    }

    mutating func finish(commit: Bool) -> SwitcherAction? {
        guard isSwitching else { return nil }
        isSwitching = false
        heldModifiers = []
        shiftIsDown = false
        return commit ? .commit : .cancel
    }
}

@MainActor
final class ShortcutController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var recordingCurrentAppOnly: Bool?
    @Published private(set) var recordingErrorKey: String?
    var onAction: ((SwitcherAction) -> Void)?
    var canBegin: ((Bool) -> Bool)?
    private(set) var allWindowsShortcut = KeyboardShortcut.allWindows
    private(set) var currentAppShortcut = KeyboardShortcut.currentApp

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var state = ShortcutState()
    private var shiftRepeatTimer: Timer?
    private var recordingMonitor: Any?
    private var saveRecording: ((KeyboardShortcut) -> Bool)?

    func configure(allWindows: KeyboardShortcut, currentApp: KeyboardShortcut) {
        guard allWindows.isValid, currentApp.isValid, !allWindows.conflicts(with: currentApp),
              allWindows != allWindowsShortcut || currentApp != currentAppShortcut else { return }
        stopShiftRepeat()
        if let action = state.finish(commit: false) { onAction?(action) }
        allWindowsShortcut = allWindows
        currentAppShortcut = currentApp
    }

    func beginRecording(currentAppOnly: Bool, onSave: @escaping (KeyboardShortcut) -> Bool) {
        cancelRecording()
        stopShiftRepeat()
        if let action = state.finish(commit: false) { onAction?(action) }
        recordingCurrentAppOnly = currentAppOnly
        saveRecording = onSave
        // Also records in Settings before Accessibility permission is granted.
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let captured = MainActor.assumeIsolated {
                guard let self, self.recordingCurrentAppOnly != nil else { return false }
                self.record(event)
                return true
            }
            return captured ? nil : event
        }
    }

    func cancelRecording() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        saveRecording = nil
        recordingCurrentAppOnly = nil
        recordingErrorKey = nil
    }

    private func record(_ event: NSEvent) {
        guard recordingCurrentAppOnly != nil, !event.isARepeat else { return }
        if event.keyCode == 53 {
            cancelRecording()
        } else if let shortcut = KeyboardShortcut(event: event) {
            if saveRecording?(shortcut) == true {
                cancelRecording()
            } else {
                recordingErrorKey = "The two shortcuts must be different."
            }
        } else {
            recordingErrorKey = "Use Command, Option or Control with a key; Shift is reserved for reverse switching."
        }
    }

    func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        if let eventTap {
            // The tap survives transient trust loss or session switches; re-enable it instead of no-op.
            CGEvent.tapEnable(tap: eventTap, enable: true)
            isRunning = true
            return true
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: shortcutEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        observeSessionChanges()
        return true
    }

    func stop() {
        cancelRecording()
        stopShiftRepeat()
        if let action = state.finish(commit: false) { onAction?(action) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        runLoopSource = nil
        eventTap = nil
        isRunning = false
    }

    func resetState() {
        stopShiftRepeat()
        _ = state.finish(commit: false)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stopShiftRepeat()
            if let action = state.finish(commit: false) { emit(action, deferred: true) }
            if AXIsProcessTrusted(), let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard AXIsProcessTrusted() else {
            stopShiftRepeat()
            if let action = state.finish(commit: false) { emit(action, deferred: true) }
            isRunning = false
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        if type == .flagsChanged {
            if let action = modifierAction(flags: flags) { emit(action, deferred: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        if recordingCurrentAppOnly != nil {
            // Defer AppKit/UI work until after the event tap returns, and swallow even ⌘Tab.
            if let keyEvent = NSEvent(cgEvent: event) {
                DispatchQueue.main.async { [weak self] in self?.record(keyEvent) }
            }
            return nil
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard onAction != nil, let action = keyAction(keyCode: keyCode, flags: flags) else {
            return Unmanaged.passUnretained(event)
        }
        onAction?(action)
        return nil
    }

    private func modifierAction(flags: CGEventFlags) -> SwitcherAction? {
        guard state.isSwitching else {
            stopShiftRepeat()
            return nil
        }
        guard flags.contains(state.heldModifiers) else {
            stopShiftRepeat()
            return state.finish(commit: true)
        }
        let action = state.shiftFlagsChanged(flags)
        if action == .step(-1) {
            // A fresh Shift press steps back immediately and arms hold-to-repeat.
            startShiftRepeat()
        } else if !state.isShiftDown {
            // Shift released while the switcher stays open: stop repeating but keep switching.
            stopShiftRepeat()
        }
        return action
    }

    private func keyAction(keyCode: UInt16, flags: CGEventFlags) -> SwitcherAction? {
        if state.isSwitching {
            if allWindowsShortcut.matches(keyCode: keyCode, flags: flags)
                || currentAppShortcut.matches(keyCode: keyCode, flags: flags) {
                return state.step(1)
            }
            switch keyCode {
            case 48, 50:
                return state.step(1)
            case 126:
                return state.step(-1)
            case 125:
                return state.step(1)
            case 53:
                stopShiftRepeat()
                return state.finish(commit: false)
            default:
                return nil
            }
        }

        let currentAppOnly: Bool
        let shortcut: KeyboardShortcut
        if allWindowsShortcut.matches(keyCode: keyCode, flags: flags) {
            currentAppOnly = false
            shortcut = allWindowsShortcut
        } else if currentAppShortcut.matches(keyCode: keyCode, flags: flags) {
            currentAppOnly = true
            shortcut = currentAppShortcut
        } else {
            return nil
        }

        stopShiftRepeat()
        return state.begin(
            currentAppOnly: currentAppOnly,
            allowed: canBegin?(currentAppOnly) ?? true,
            modifiers: shortcut.modifiers,
            shiftHeld: flags.contains(.maskShift)
        )
    }

    /// Holding Shift keeps stepping back one window at a time, mirroring how a held Tab
    /// auto-repeats forward. The system key-repeat delay and interval keep both directions
    /// feeling identical.
    private func startShiftRepeat() {
        stopShiftRepeat()
        guard state.isSwitching else { return }
        let timer = Timer(timeInterval: max(0.05, NSEvent.keyRepeatDelay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.isSwitching, self.state.isShiftDown else {
                    self?.stopShiftRepeat()
                    return
                }
                self.onAction?(.step(-1))
                self.repeatShiftSteps()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shiftRepeatTimer = timer
    }

    private func repeatShiftSteps() {
        stopShiftRepeat()
        guard state.isSwitching, state.isShiftDown else { return }
        let timer = Timer(timeInterval: max(0.01, NSEvent.keyRepeatInterval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.isSwitching, self.state.isShiftDown else {
                    self?.stopShiftRepeat()
                    return
                }
                self.onAction?(.step(-1))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shiftRepeatTimer = timer
    }

    private func stopShiftRepeat() {
        shiftRepeatTimer?.invalidate()
        shiftRepeatTimer = nil
    }

    private func emit(_ action: SwitcherAction, deferred: Bool) {
        guard deferred else {
            onAction?(action)
            return
        }
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
    }

    private func observeSessionChanges() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.cancelRecording()
                    self.stopShiftRepeat()
                    if let action = self.state.finish(commit: false) { self.onAction?(action) }
                    if let eventTap = self.eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
                    self.isRunning = false
                }
            },
            center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    guard AXIsProcessTrusted(), let eventTap = self?.eventTap else { return }
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                    self?.isRunning = true
                }
            }
        ]
    }

    static func selfCheck() -> Bool {
        var state = ShortcutState()
        guard KeyboardShortcut.allWindows.display == "⌘Tab",
              KeyboardShortcut.currentApp.display == "⌘`",
              state.begin(currentAppOnly: false, allowed: false) == nil,
              state.begin(currentAppOnly: false, allowed: true) == .begin(currentAppOnly: false),
              state.step(1) == .step(1),
              state.finish(commit: false) == .cancel,
              state.begin(currentAppOnly: true, allowed: true,
                          shiftHeld: true) == .begin(currentAppOnly: true),
              state.finish(commit: true) == .commit,
              state.finish(commit: true) == nil else { return false }

        let controller = ShortcutController()
        // ⌘Tab opens the switcher; ⌘⇧Tab no longer reverses and behaves like ⌘Tab.
        guard controller.keyAction(keyCode: 48, flags: []) == nil,
              controller.keyAction(keyCode: 48, flags: [.maskCommand, .maskControl]) == nil,
              controller.keyAction(keyCode: 48, flags: .maskCommand) == .begin(currentAppOnly: false),
              // Pressing Shift on its own immediately steps back one window and arms hold-to-repeat.
              controller.modifierAction(flags: [.maskCommand, .maskShift]) == .step(-1),
              controller.shiftRepeatTimer != nil,
              // Holding Shift keeps the repeat armed without stepping again on its own.
              controller.modifierAction(flags: [.maskCommand, .maskShift]) == nil,
              controller.shiftRepeatTimer != nil,
              // Releasing Shift stops repeating but leaves the switcher open.
              controller.modifierAction(flags: .maskCommand) == nil,
              controller.shiftRepeatTimer == nil,
              // Tapping Shift again steps back once more and re-arms the repeat timer.
              controller.modifierAction(flags: [.maskCommand, .maskShift]) == .step(-1),
              controller.shiftRepeatTimer != nil,
              // ⇧Tab no longer reverses; Tab always advances.
              controller.keyAction(keyCode: 48, flags: [.maskCommand, .maskShift]) == .step(1),
              controller.keyAction(keyCode: 50, flags: .maskCommand) == .step(1),
              controller.modifierAction(flags: .maskCommand) == nil,
              controller.modifierAction(flags: []) == .commit else { return false }

        // Shift held from the opening shortcut is never mistaken for a fresh press, and can still
        // step back once it is released and tapped again.
        let shiftHeldFromStart = ShortcutController()
        guard shiftHeldFromStart.keyAction(keyCode: 48, flags: [.maskCommand, .maskShift])
                == .begin(currentAppOnly: false),
              shiftHeldFromStart.modifierAction(flags: [.maskCommand, .maskShift]) == nil,
              // ⇧Tab no longer reverses while the switcher is open.
              shiftHeldFromStart.keyAction(keyCode: 48, flags: [.maskCommand, .maskShift]) == .step(1),
              shiftHeldFromStart.modifierAction(flags: .maskCommand) == nil,
              shiftHeldFromStart.modifierAction(flags: [.maskCommand, .maskShift]) == .step(-1),
              shiftHeldFromStart.shiftRepeatTimer != nil,
              // Escape cancels the switcher and tears the repeat timer down with it.
              shiftHeldFromStart.keyAction(keyCode: 53, flags: .maskCommand) == .cancel,
              shiftHeldFromStart.shiftRepeatTimer == nil else { return false }

        let custom = KeyboardShortcut(keyCode: 16, modifiers: [.maskControl, .maskAlternate], keyLabel: "Y")
        let sameKey = KeyboardShortcut(keyCode: 16, modifiers: .maskCommand, keyLabel: "Y")
        guard custom.isValid, custom.display == "⌃⌥Y", !custom.conflicts(with: sameKey),
              !KeyboardShortcut(keyCode: 16, modifiers: [], keyLabel: "Y").isValid,
              !KeyboardShortcut(keyCode: 16, modifiers: [.maskCommand, .maskShift], keyLabel: "Y").isValid,
              !KeyboardShortcut(keyCode: 53, modifiers: .maskCommand, keyLabel: "Esc").isValid else { return false }
        controller.configure(allWindows: custom, currentApp: sameKey)
        guard controller.keyAction(keyCode: 48, flags: .maskCommand) == nil,
              controller.keyAction(keyCode: 50, flags: .maskCommand) == nil,
              controller.keyAction(keyCode: 16, flags: .maskControl) == nil,
              controller.keyAction(keyCode: 16, flags: [.maskControl, .maskAlternate, .maskShift])
                == .begin(currentAppOnly: false),
              controller.keyAction(keyCode: 16, flags: custom.modifiers) == .step(1),
              controller.keyAction(keyCode: 48, flags: [.maskControl, .maskAlternate, .maskShift]) == .step(1),
              controller.keyAction(keyCode: 126, flags: custom.modifiers) == .step(-1),
              controller.keyAction(keyCode: 125, flags: custom.modifiers) == .step(1),
              controller.keyAction(keyCode: 0, flags: custom.modifiers) == nil,
              controller.modifierAction(flags: [.maskControl, .maskAlternate, .maskShift]) == nil,
              controller.modifierAction(flags: .maskControl) == .commit,
              controller.keyAction(keyCode: 16, flags: .maskCommand)
                == .begin(currentAppOnly: true),
              controller.modifierAction(flags: []) == .commit else { return false }
        controller.canBegin = { _ in false }
        guard controller.keyAction(keyCode: 16, flags: custom.modifiers) == nil else { return false }
        controller.canBegin = nil
        guard controller.keyAction(keyCode: 16, flags: custom.modifiers) != nil else { return false }
        var cancelled = false
        controller.onAction = { cancelled = $0 == .cancel }
        controller.configure(allWindows: .allWindows, currentApp: .currentApp)
        guard cancelled, controller.modifierAction(flags: []) == nil else { return false }
        controller.configure(allWindows: .allWindows, currentApp: .allWindows)
        guard controller.currentAppShortcut == .currentApp else { return false }

        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                          modifierFlags: [.control, .option], timestamp: 0,
                                          windowNumber: 0, context: nil, characters: "y",
                                          charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16),
              let recorded = KeyboardShortcut(event: event),
              recorded.matches(keyCode: 16, flags: custom.modifiers), recorded.keyLabel == "Y" else { return false }

        var acceptRecording = false
        var saved: KeyboardShortcut?
        controller.beginRecording(currentAppOnly: false) { shortcut in
            guard acceptRecording else { return false }
            saved = shortcut
            return true
        }
        defer { controller.cancelRecording() }
        controller.record(event)
        guard controller.recordingCurrentAppOnly == false,
              controller.recordingErrorKey == "The two shortcuts must be different.", saved == nil else { return false }
        acceptRecording = true
        controller.record(event)
        guard saved == recorded, controller.recordingCurrentAppOnly == nil,
              controller.recordingMonitor == nil, controller.recordingErrorKey == nil else { return false }
        controller.beginRecording(currentAppOnly: true) { _ in false }
        guard let invalid = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, characters: "y",
                                            charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16),
              let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, characters: "\u{1b}",
                                           charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { return false }
        controller.record(invalid)
        guard controller.recordingCurrentAppOnly == true, controller.recordingErrorKey != nil else { return false }
        controller.record(escape)
        guard controller.recordingCurrentAppOnly == nil, controller.recordingMonitor == nil,
              controller.recordingErrorKey == nil else { return false }
        return true
    }
}

private let shortcutEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<ShortcutController>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated { controller.handle(type: type, event: event) }
}
