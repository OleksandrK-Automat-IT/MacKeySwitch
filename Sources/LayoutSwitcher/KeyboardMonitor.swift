import Cocoa
import Foundation

final class KeyboardMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Buffer of (keycode, isShifted) for current word
    private var keyBuffer: [(UInt16, Bool)] = []

    // Track how many characters we've typed in current word (for backspace counting)
    private var charCount: Int = 0

    var isEnabled: Bool = true

    // Prevent re-entrant correction
    private var isCorrecting: Bool = false

    func start() {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passRetained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handleEvent(proxy: proxy, type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            print("ERROR: Failed to create event tap.")
            print("Please grant Accessibility permission in System Settings > Privacy & Security > Accessibility")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("Keyboard monitor started. Listening for EN/UA mismatches...")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        keyBuffer.removeAll()
        charCount = 0
    }

    private func handleEvent(
        proxy: CGEventTapProxy, type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Re-enable tap if it gets disabled by the system
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown, isEnabled, !isCorrecting else {
            return Unmanaged.passRetained(event)
        }

        // Only monitor if current layout is EN or UA
        guard let currentLang = InputSourceManager.currentLanguage() else {
            keyBuffer.removeAll()
            charCount = 0
            return Unmanaged.passRetained(event)
        }

        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isShifted = flags.contains(.maskShift)

        // Handle backspace — shrink buffer
        if keycode == KeyMapping.backspaceKeycode {
            if !keyBuffer.isEmpty {
                keyBuffer.removeLast()
                charCount = max(0, charCount - 1)
            }
            return Unmanaged.passRetained(event)
        }

        // Word boundary — analyze and possibly correct
        if KeyMapping.wordBoundaryKeycodes.contains(keycode) {
            if keyBuffer.count >= 2 {
                analyzeAndCorrect(currentLayout: currentLang)
            }
            keyBuffer.removeAll()
            charCount = 0
            return Unmanaged.passRetained(event)
        }

        // Only buffer letter keys
        if KeyMapping.isLetterKey(keycode) {
            keyBuffer.append((keycode, isShifted))
            charCount += 1
        }

        return Unmanaged.passRetained(event)
    }

    private func analyzeAndCorrect(currentLayout: Language) {
        guard !keyBuffer.isEmpty else { return }

        // Detect if the user intended a different language
        guard let intended = LanguageDetector.detectIntended(
            keycodes: keyBuffer,
            currentLayout: currentLayout
        ) else {
            return
        }

        // Intended language differs from current — correct!
        let correctText = KeyMapping.reconstruct(keycodes: keyBuffer, language: intended)

        isCorrecting = true

        // Delete the mistyped word
        for _ in 0..<charCount {
            simulateKey(keycode: KeyMapping.backspaceKeycode, flags: [])
        }

        // Small delay to let backspaces process
        usleep(30_000) // 30ms

        // Switch input source
        InputSourceManager.switchTo(intended)

        // Small delay for layout switch
        usleep(50_000) // 50ms

        // Retype the correct text
        typeString(correctText)

        isCorrecting = false
    }

    private func simulateKey(keycode: UInt16, flags: CGEventFlags) {
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
        usleep(5_000) // 5ms between keystrokes
    }

    private func typeString(_ text: String) {
        // Use CGEvent to type the string character by character
        for char in text {
            let str = String(char) as CFString
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                continue
            }
            let unichar = Array(str as String).first!
            let utf16 = Array(String(unichar).utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event.post(tap: .cgAnnotatedSessionEventTap)

            let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            upEvent?.post(tap: .cgAnnotatedSessionEventTap)
            usleep(5_000)
        }
    }
}
