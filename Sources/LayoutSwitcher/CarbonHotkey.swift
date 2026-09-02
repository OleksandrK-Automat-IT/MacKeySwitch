import Carbon
import AppKit

/// System-wide hotkey registered via Carbon's `RegisterEventHotKey`.
/// More reliable than `NSEvent.addGlobalMonitorForEvents` because Carbon
/// registers the shortcut with the window server and gets priority — the
/// event fires even when another app would normally consume the key combo
/// (e.g. Cmd+Z Undo, Ctrl+Shift+Z Redo).
final class CarbonHotkey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    var onFire: (() -> Void)?

    private static let signature: OSType = 0x4D4B5357 // 'MKSW'

    /// The registry the C event handler dispatches through.
    ///
    /// Deliberately weak: a strong map would keep every instance alive forever, which also
    /// made `deinit` — and therefore the cleanup below — unreachable. `registryLock` guards
    /// it because `deinit` can run on any thread even though everything else here is main.
    private struct WeakHotkey {
        weak var hotkey: CarbonHotkey?
    }
    private static let registryLock = NSLock()
    private static var nextID: UInt32 = 1
    private static var instances: [UInt32: WeakHotkey] = [:]
    private static var handlerInstalled = false

    private static func lookup(_ id: UInt32) -> CarbonHotkey? {
        registryLock.lock(); defer { registryLock.unlock() }
        return instances[id]?.hotkey
    }

    init() {
        CarbonHotkey.registryLock.lock()
        self.id = CarbonHotkey.nextID
        CarbonHotkey.nextID += 1
        CarbonHotkey.registryLock.unlock()

        CarbonHotkey.installHandlerIfNeeded()

        CarbonHotkey.registryLock.lock()
        CarbonHotkey.instances[id] = WeakHotkey(hotkey: self)
        CarbonHotkey.registryLock.unlock()
    }

    deinit {
        // Not `unregister()` — that is main-thread-only bookkeeping and deinit is not
        // guaranteed to run there. Releasing the Carbon ref directly is enough.
        if let ref = ref {
            UnregisterEventHotKey(ref)
        }
        CarbonHotkey.registryLock.lock()
        CarbonHotkey.instances.removeValue(forKey: id)
        CarbonHotkey.registryLock.unlock()
    }

    /// Install a single app-wide Carbon event handler that dispatches to the
    /// matching `CarbonHotkey` instance by hotkey id.
    private static func installHandlerIfNeeded() {
        registryLock.lock()
        let alreadyInstalled = handlerInstalled
        handlerInstalled = true
        registryLock.unlock()
        guard !alreadyInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, _) -> OSStatus in
                guard let eventRef = eventRef else { return noErr }
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if status == noErr, let hk = CarbonHotkey.lookup(hkID.id) {
                    DispatchQueue.main.async { hk.onFire?() }
                }
                return noErr
            },
            1, &eventType, nil, nil
        )
    }

    /// Register a hotkey with the given virtual keycode and Carbon modifier mask.
    /// Returns true on success.
    @discardableResult
    func register(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        unregister()
        guard carbonModifiers != 0 else {
            // Refuse bare keys — would eat all typing of that letter.
            print("[CarbonHotkey] Refusing to register hotkey with no modifiers.")
            return false
        }
        let hkID = EventHotKeyID(signature: CarbonHotkey.signature, id: id)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )
        if status == noErr {
            self.ref = newRef
            debugLog("[CarbonHotkey] registered id=\(id) keyCode=\(keyCode) mods=0x\(String(carbonModifiers, radix: 16))")
            return true
        }
        debugLog("[CarbonHotkey] REGISTER FAILED status=\(status) keyCode=\(keyCode) mods=0x\(String(carbonModifiers, radix: 16))")
        return false
    }

    func unregister() {
        if let ref = ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
    }

    /// Translate Cocoa modifier flags into Carbon's bitmask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
}
