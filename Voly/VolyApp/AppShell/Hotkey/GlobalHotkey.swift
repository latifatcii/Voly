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
    /// Unique per instance: several hotkeys share one event target, and
    /// each handler must only answer for its own.
    private let id: UInt32
    private static var nextID: UInt32 = 1
    private let onFire: () -> Void

    /// - Returns: nil if registration fails (another app owns the combo).
    init?(
        keyCode: UInt32,
        modifiers: UInt32,
        onFire: @escaping () -> Void
    ) {
        self.onFire = onFire
        self.id = Self.nextID
        Self.nextID += 1

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
                // Not ours: let the next handler (another hotkey) have it.
                guard hotKeyID.id == me.id else { return OSStatus(eventNotHandledErr) }
                me.onFire()
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

/// A hotkey that only exists while one of the given apps is frontmost.
///
/// Used for ⌘E: next to the Simulator it shows and hides Voly, but in Xcode,
/// Finder and everything else ⌘E keeps its own meaning, because the hotkey
/// isn't registered there at all.
@MainActor
final class FrontmostAppHotkey {
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let bundleIdentifiers: Set<String>
    /// Frontmost apps that count besides the listed ones.
    private let alsoMatches: (NSRunningApplication) -> Bool
    private let onFire: () -> Void
    private var hotkey: GlobalHotkey?
    private var observer: NSObjectProtocol?

    init(
        keyCode: UInt32,
        modifiers: UInt32,
        whileFrontmost bundleIdentifiers: Set<String>,
        orWhen alsoMatches: @escaping (NSRunningApplication) -> Bool = { _ in false },
        onFire: @escaping () -> Void
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.bundleIdentifiers = bundleIdentifiers
        self.alsoMatches = alsoMatches
        self.onFire = onFire
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func update() {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmost = frontmostApp?.bundleIdentifier
        let wanted = (frontmost.map(bundleIdentifiers.contains) ?? false)
            || (frontmostApp.map(alsoMatches) ?? false)
        if wanted, hotkey == nil {
            hotkey = GlobalHotkey(keyCode: keyCode, modifiers: modifiers, onFire: onFire)
            if hotkey == nil {
                log.warning("scoped hotkey could not be registered while \(frontmost ?? "?", privacy: .public) is frontmost")
            }
        } else if !wanted {
            hotkey = nil
        }
    }
}

enum HotkeyDefaults {
    // ⌃⌥⌘V — works everywhere.
    static let keyCode: UInt32 = UInt32(kVK_ANSI_V)
    static let modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)

    // ⌘E — only while the Simulator (or Voly itself) is frontmost.
    static let simulatorKeyCode: UInt32 = UInt32(kVK_ANSI_E)
    static let simulatorModifiers: UInt32 = UInt32(cmdKey)
    static let simulatorBundleIdentifier = "com.apple.iphonesimulator"
}
