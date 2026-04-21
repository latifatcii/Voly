import AppKit
import Carbon.HIToolbox
import Foundation
import OSLog

nonisolated(unsafe) private let log = Logger(subsystem: "com.latifatci.Voly", category: "GlobalHotkey")

/// Registers a process-global hotkey via Carbon Event Manager. Stable
/// OS-shipped API; no third-party dep or entitlement needed.
@MainActor
final class GlobalHotkey {
    // Declared as optional vars (not `let`) so `self` can be used inside
    // `init?` before both Carbon resources exist. They're only ever written
    // once per instance; `init?` returns nil if either Carbon call fails and
    // the instance is torn down cleanly by `deinit`.
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let id: UInt32 = 1
    private let onFire: () -> Void

    /// - Returns: nil if registration fails (another app owns the combo).
    init?(
        keyCode: UInt32,
        modifiers: UInt32,
        onFire: @escaping () -> Void
    ) {
        self.onFire = onFire

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        var localHandler: EventHandlerRef?
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData, let eventRef else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    eventRef, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                let me = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                if hotKeyID.id == me.id { me.onFire() }
                return noErr
            },
            1, &eventType, selfPointer, &localHandler
        )
        guard status == noErr, let installedHandler = localHandler else {
            log.error("InstallEventHandler failed: \(status)")
            return nil
        }
        self.handlerRef = installedHandler

        let hotKeyID = EventHotKeyID(signature: OSType(0x766F_6C59), id: id) // 'volY'
        var localRef: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(),
            0, &localRef
        )
        guard regStatus == noErr, let registeredRef = localRef else {
            log.error("RegisterEventHotKey failed: \(regStatus) — hotkey likely already owned by another app")
            RemoveEventHandler(installedHandler)
            self.handlerRef = nil
            return nil
        }
        self.ref = registeredRef
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

enum HotkeyDefaults {
    // ⌃⌥⌘V
    static let keyCode: UInt32 = UInt32(kVK_ANSI_V)
    static let modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)
}
