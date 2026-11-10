import Foundation
import OSLog

private let log = Logger(subsystem: "com.latifatci.Voly", category: "AndroidIntegration")

/// One running app on a device, and what Voly could do about it.
public struct AndroidAppStatus: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        /// The agent is attached and listening.
        case inspectable
        /// Not a debuggable build: nothing can be attached.
        case notDebuggable
        /// Left alone because the user excluded it.
        case excluded
        /// Attaching was tried and didn't work.
        case failed(String)
    }

    public let package: String
    public let pid: Int32
    public let state: State

    public var id: String { "\(package):\(pid)" }

    public init(package: String, pid: Int32, state: State) {
        self.package = package
        self.pid = pid
        self.state = state
    }
}

public struct AndroidDeviceStatus: Sendable, Equatable, Identifiable {
    public let device: AndroidDevice
    /// Whether Voly attaches to apps on this device.
    public let isIntegrationEnabled: Bool
    public let apps: [AndroidAppStatus]
    public let error: String?

    public var id: String { device.serial }

    public init(device: AndroidDevice, isIntegrationEnabled: Bool, apps: [AndroidAppStatus], error: String?) {
        self.device = device
        self.isIntegrationEnabled = isIntegrationEnabled
        self.apps = apps
        self.error = error
    }
}

public struct AndroidSnapshot: Sendable, Equatable {
    public let devices: [AndroidDeviceStatus]
    /// Every agent Voly can connect to right now.
    public let agents: [AndroidAgentEndpoint]
    /// Set when devices couldn't be listed at all.
    public let error: String?

    public init(devices: [AndroidDeviceStatus] = [], agents: [AndroidAgentEndpoint] = [], error: String? = nil) {
        self.devices = devices
        self.agents = agents
        self.error = error
    }

    public static let empty = AndroidSnapshot()
}

/// Keeps the Android side in step with what is running: every call to
/// `refresh` lists the devices adb sees and the user's apps running on
/// them, attaches the agent to debuggable apps that don't have it yet, and
/// forgets the ones that went away.
///
/// Unlike on iOS nothing is hooked into the system and no app is ever
/// relaunched: an agent can be attached to an app that is already running,
/// so "integration" is just this loop.
public actor AndroidIntegration {
    private struct Key: Hashable {
        let serial: String
        let pid: Int32
    }

    private let adb: AdbRunning
    private let inventory: AndroidDeviceInventory
    private let processes: AndroidProcessLister
    private let installer: AndroidAgentInstaller
    private let now: @Sendable () -> Date

    private var devices: [String: AndroidDevice] = [:]
    private var userPackages: [String: (packages: Set<String>, readAt: Date)] = [:]
    private var agents: [Key: AndroidAgentEndpoint] = [:]
    private var failures: [Key: (attempts: Int, message: String)] = [:]
    private var notDebuggable: Set<Key> = []

    private static let maxAttachAttempts = 2
    private static let packageListLifetime: TimeInterval = 20

    public init(
        adb: AdbRunning,
        payload: AndroidAgentPayload,
        installer: AndroidAgentInstaller? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.adb = adb
        self.inventory = AndroidDeviceInventory(adb: adb)
        self.processes = AndroidProcessLister(adb: adb)
        self.installer = installer ?? AndroidAgentInstaller(adb: adb, payload: payload)
        self.now = now
    }

    /// - Parameters:
    ///   - wantsDevice: whether Voly should attach to apps on this device.
    ///   - allowsApp: whether this package may get the agent.
    ///   - only: when set, other devices are ignored altogether (scripted runs).
    public func refresh(
        wantsDevice: @Sendable (String) -> Bool,
        allowsApp: @Sendable (String) -> Bool,
        only: Set<String>? = nil
    ) async -> AndroidSnapshot {
        var serials: [String]
        do {
            serials = try await inventory.onlineSerials()
        } catch {
            return AndroidSnapshot(devices: [], agents: Array(agents.values), error: error.localizedDescription)
        }
        if let only { serials = serials.filter(only.contains) }

        // A device that is gone took its apps, agents and forwards with it.
        let online = Set(serials)
        devices = devices.filter { online.contains($0.key) }
        userPackages = userPackages.filter { online.contains($0.key) }
        agents = agents.filter { online.contains($0.key.serial) }
        failures = failures.filter { online.contains($0.key.serial) }
        notDebuggable = notDebuggable.filter { online.contains($0.serial) }

        var statuses: [AndroidDeviceStatus] = []
        for serial in serials {
            statuses.append(await refresh(serial: serial, enabled: wantsDevice(serial), allowsApp: allowsApp))
        }
        return AndroidSnapshot(
            devices: statuses.sorted { $0.device.displayName < $1.device.displayName },
            agents: agents.values.sorted { ($0.serial, $0.package, $0.pid) < ($1.serial, $1.package, $1.pid) },
            error: nil
        )
    }

    private func refresh(serial: String, enabled: Bool, allowsApp: @Sendable (String) -> Bool) async -> AndroidDeviceStatus {
        let device: AndroidDevice
        if let known = devices[serial] {
            device = known
        } else {
            do {
                device = try await inventory.describe(serial: serial)
                devices[serial] = device
            } catch {
                let placeholder = AndroidDevice(serial: serial, name: serial, isEmulator: serial.hasPrefix("emulator-"))
                return AndroidDeviceStatus(
                    device: placeholder, isIntegrationEnabled: enabled, apps: [], error: error.localizedDescription
                )
            }
        }
        guard device.supportsAgents else {
            return AndroidDeviceStatus(
                device: device, isIntegrationEnabled: enabled, apps: [],
                error: "Voly needs Android 8 (API 26) or later to inspect apps."
            )
        }
        guard enabled else {
            // Switched off: let go of what was attached here and look no further.
            for (key, endpoint) in agents where key.serial == serial {
                await installer.release(endpoint)
                agents[key] = nil
            }
            return AndroidDeviceStatus(device: device, isIntegrationEnabled: false, apps: [], error: nil)
        }

        let running: [AndroidProcess]
        do {
            running = try await processes.runningUserApps(serial: serial, userPackages: try await packages(on: serial))
        } catch {
            return AndroidDeviceStatus(device: device, isIntegrationEnabled: true, apps: [], error: error.localizedDescription)
        }

        // Processes that ended: free their forwarded ports.
        let alive = Set(running.map { Key(serial: serial, pid: $0.pid) })
        for (key, endpoint) in agents where key.serial == serial && !alive.contains(key) {
            await installer.release(endpoint)
            agents[key] = nil
        }
        failures = failures.filter { $0.key.serial != serial || alive.contains($0.key) }
        notDebuggable = notDebuggable.filter { $0.serial != serial || alive.contains($0) }

        var apps: [AndroidAppStatus] = []
        for process in running {
            let key = Key(serial: serial, pid: process.pid)
            let state: AndroidAppStatus.State
            if !allowsApp(process.package) {
                if let endpoint = agents.removeValue(forKey: key) { await installer.release(endpoint) }
                state = .excluded
            } else if agents[key] != nil {
                state = .inspectable
            } else if notDebuggable.contains(key) {
                state = .notDebuggable
            } else if let failure = failures[key], failure.attempts >= Self.maxAttachAttempts {
                state = .failed(failure.message)
            } else {
                state = await attach(process, key: key, device: device)
            }
            apps.append(AndroidAppStatus(package: process.package, pid: process.pid, state: state))
        }
        return AndroidDeviceStatus(device: device, isIntegrationEnabled: true, apps: apps, error: nil)
    }

    private func attach(_ process: AndroidProcess, key: Key, device: AndroidDevice) async -> AndroidAppStatus.State {
        do {
            let endpoint = try await installer.attach(serial: key.serial, device: device, process: process)
            agents[key] = endpoint
            failures[key] = nil
            log.notice("attached to \(process.package, privacy: .public) pid \(process.pid) on \(key.serial, privacy: .public), port \(endpoint.port)")
            return .inspectable
        } catch AndroidAttachError.notDebuggable {
            notDebuggable.insert(key)
            return .notDebuggable
        } catch AndroidAttachError.processGone {
            return .failed("The app stopped running.")
        } catch {
            let message = error.localizedDescription
            failures[key] = (attempts: (failures[key]?.attempts ?? 0) + 1, message: message)
            log.error("attaching to \(process.package, privacy: .public) on \(key.serial, privacy: .public) failed: \(message, privacy: .public)")
            return .failed(message)
        }
    }

    private func packages(on serial: String) async throws -> Set<String> {
        if let cached = userPackages[serial], now().timeIntervalSince(cached.readAt) < Self.packageListLifetime {
            return cached.packages
        }
        let packages = try await processes.userPackages(serial: serial)
        userPackages[serial] = (packages, now())
        return packages
    }

    /// Try again for apps where attaching failed (the user asked).
    public func retryFailures(serial: String) {
        failures = failures.filter { $0.key.serial != serial }
        userPackages[serial] = nil
    }

    /// Give back every forwarded port. The agents stay in their apps, idle.
    public func releaseAll() async {
        for endpoint in agents.values { await installer.release(endpoint) }
        agents.removeAll()
    }

    // MARK: - Things done to a device on request

    /// Stop the app and start it again from its launcher activity.
    public func relaunch(serial: String, package: String) async throws {
        guard AndroidAgentInstaller.isShellSafe(package) else {
            throw AdbError.failed(command: "relaunch", detail: "unexpected package name \(package)")
        }
        let stopped = try await adb.shell(serial, "am force-stop \(package)", timeout: 10)
        guard stopped.succeeded else { throw AdbError.failed(command: "shell am force-stop", detail: stopped.errorText) }
        let started = try await adb.shell(
            serial, "monkey -p \(package) -c android.intent.category.LAUNCHER 1", timeout: 15
        )
        let text = started.text + started.errorText
        guard started.succeeded, !text.contains("No activities found") else {
            throw AdbError.failed(command: "launch", detail: "\(package) has no launcher activity, or is not installed")
        }
        // The new process is a different pid; forget what failed for the old one.
        userPackages[serial] = nil
    }

    /// PNG of the whole display, system UI included, as it is shown (already upright).
    public func screenshot(serial: String) async throws -> Data {
        let output = try await adb.run(["-s", serial, "exec-out", "screencap", "-p"], timeout: 20)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        guard output.succeeded, output.stdout.starts(with: png) else {
            throw AdbError.failed(command: "exec-out screencap", detail: output.timedOut ? "timed out" : output.errorText)
        }
        return output.stdout
    }
}
