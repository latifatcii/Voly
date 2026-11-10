import Foundation

/// The Android agent as Voly carries it (built by `AndroidAgent/build.sh`):
/// the agent's dex file, the small JVMTI library that loads it — one per
/// ABI — and a hash that names the copy on a device.
public struct AndroidAgentPayload: Sendable, Equatable {
    public static let dexName = "voly-agent.dex"
    public static let versionName = "voly-agent.version"
    public static let abis = ["arm64-v8a", "x86_64", "armeabi-v7a", "x86"]

    public static func loaderName(abi: String) -> String { "voly-agent-\(abi).elf" }

    public let dex: URL
    public let loaders: [String: URL]
    public let version: String

    public init(dex: URL, loaders: [String: URL], version: String) {
        self.dex = dex
        self.loaders = loaders
        self.version = version
    }

    public enum PayloadError: Error, Equatable, LocalizedError {
        case missing([String])

        public var errorDescription: String? {
            switch self {
            case .missing(let directories):
                return "This build of Voly doesn't contain the Android agent (looked in "
                    + directories.joined(separator: ", ") + "). Run AndroidAgent/build.sh and rebuild."
            }
        }
    }

    /// The first of `directories` that holds a complete payload.
    public static func load(from directories: [URL], fileManager: FileManager = .default) throws -> AndroidAgentPayload {
        for directory in directories {
            let dex = directory.appendingPathComponent(dexName)
            let versionFile = directory.appendingPathComponent(versionName)
            guard fileManager.fileExists(atPath: dex.path),
                  let version = try? String(contentsOf: versionFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !version.isEmpty, version.allSatisfy({ $0.isLetter || $0.isNumber })
            else { continue }
            var loaders: [String: URL] = [:]
            for abi in abis {
                let loader = directory.appendingPathComponent(loaderName(abi: abi))
                if fileManager.fileExists(atPath: loader.path) { loaders[abi] = loader }
            }
            guard !loaders.isEmpty else { continue }
            return AndroidAgentPayload(dex: dex, loaders: loaders, version: version)
        }
        throw PayloadError.missing(directories.map(\.path))
    }

    /// Where the app target's resources end up, flat or in their folder.
    public static func bundledDirectories(in bundle: Bundle = .main) -> [URL] {
        guard let resources = bundle.resourceURL else { return [] }
        return [resources, resources.appendingPathComponent("AndroidAgentPayload")]
    }
}

/// An agent that is attached to an app and listening.
public struct AndroidAgentEndpoint: Sendable, Equatable, Hashable {
    public let serial: String
    public let package: String
    public let pid: Int32
    /// The app's name as its launcher shows it.
    public let label: String
    /// Port on this Mac's loopback that adb forwards to the agent's socket.
    public let port: UInt16
    /// Session token the agent expects in the handshake.
    public let token: String

    public init(serial: String, package: String, pid: Int32, label: String, port: UInt16, token: String) {
        self.serial = serial
        self.package = package
        self.pid = pid
        self.label = label
        self.port = port
        self.token = token
    }
}

public enum AndroidAttachError: Error, Equatable, LocalizedError {
    case notDebuggable(String)
    case unsupportedABI(String)
    case processGone
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notDebuggable(let package):
            return "\(package) is not a debuggable build. Voly can only inspect debug builds on Android."
        case .unsupportedABI(let abis):
            return "Voly has no agent for this device's CPU (\(abis))."
        case .processGone:
            return "The app stopped running."
        case .failed(let detail):
            return detail
        }
    }
}

/// Gets the agent into a running app and opens the way to it.
///
/// Nothing is installed and the app is not restarted: the files go into the
/// app's own code cache (`run-as`, which only works for debuggable apps),
/// `cmd activity attach-agent` loads them into the running process, and
/// `adb forward` gives the agent's Unix socket a loopback port on the Mac.
public struct AndroidAgentInstaller: Sendable {
    private let adb: AdbRunning
    private let payload: AndroidAgentPayload
    private let pause: @Sendable (TimeInterval) async -> Void
    private let random: @Sendable () -> String

    /// - Parameters:
    ///   - pause: waits between polls; replaced in tests.
    ///   - random: 16 random hex digits; replaced in tests.
    public init(
        adb: AdbRunning,
        payload: AndroidAgentPayload,
        pause: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        random: @escaping @Sendable () -> String = {
            String(UInt64.random(in: UInt64.min...UInt64.max), radix: 16)
        }
    ) {
        self.adb = adb
        self.payload = payload
        self.pause = pause
        self.random = random
    }

    private var stagingDirectory: String { "/data/local/tmp/voly-\(payload.version)" }

    /// The loader for a process: the device's first ABI of the process's bitness.
    static func abi(for process: AndroidProcess, deviceABIs: [String], available: Set<String>) -> String? {
        let matching = deviceABIs.filter { $0.contains("64") == process.is64Bit }
        return (matching + deviceABIs).first(where: available.contains)
    }

    /// Whether a name can go into a device shell command unquoted. Package
    /// names and everything Voly generates qualify; anything else is refused
    /// rather than quoted.
    static func isShellSafe(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Copy the agent's files to the device's shared temp directory, once per device and version.
    public func stage(serial: String, abi: String) async throws {
        guard let loader = payload.loaders[abi] else { throw AndroidAttachError.unsupportedABI(abi) }
        let directory = stagingDirectory
        let remoteLoader = "\(directory)/libvolyagent-\(abi).so"
        let present = try await adb.shell(serial, "ls \(directory)/\(AndroidAgentPayload.dexName) \(remoteLoader)")
        if present.succeeded { return }
        let made = try await adb.shell(serial, "mkdir -p \(directory)")
        guard made.succeeded else { throw AndroidAttachError.failed("Could not create \(directory): \(made.errorText)") }
        for (local, remote) in [(payload.dex, "\(directory)/\(AndroidAgentPayload.dexName)"), (loader, remoteLoader)] {
            let pushed = try await adb.run(["-s", serial, "push", local.path, remote], timeout: 30)
            guard pushed.succeeded else {
                throw AndroidAttachError.failed("Could not copy the agent to the device: \(pushed.errorText)")
            }
        }
    }

    /// Attach the agent to `process` and wait until it listens.
    public func attach(serial: String, device: AndroidDevice, process: AndroidProcess) async throws -> AndroidAgentEndpoint {
        let package = process.package
        guard Self.isShellSafe(package) else { throw AndroidAttachError.failed("Unexpected package name \(package).") }
        guard let abi = Self.abi(for: process, deviceABIs: device.abis, available: Set(payload.loaders.keys)) else {
            throw AndroidAttachError.unsupportedABI(device.abis.joined(separator: ", "))
        }
        try await stage(serial: serial, abi: abi)

        // Into the app's own code cache: the runtime only loads an agent
        // library from where the app itself could load code.
        let cache = "code_cache/voly-\(payload.version)"
        let dex = AndroidAgentPayload.dexName, loader = "libvolyagent-\(abi).so"
        let staged = stagingDirectory
        let copy = "d=\(cache); { [ -f $d/\(dex) ] && [ -f $d/\(loader) ]; } || "
            + "{ mkdir -p $d && cp \(staged)/\(dex) \(staged)/\(loader) $d/ && chmod 700 $d && chmod 600 $d/\(dex) && chmod 700 $d/\(loader); }; pwd"
        var copied = try await adb.shell(serial, "run-as \(package) sh -c '\(copy)'", timeout: 15)
        if !copied.succeeded, !Self.saysNotDebuggable(copied) {
            // Some system images don't let the app read the shell's temp
            // directory; hand the files over through a pipe instead.
            let piped = "run-as \(package) mkdir -p \(cache) && "
                + "cat \(staged)/\(dex) | run-as \(package) sh -c 'cat > \(cache)/\(dex)' && "
                + "cat \(staged)/\(loader) | run-as \(package) sh -c 'cat > \(cache)/\(loader)' && "
                + "run-as \(package) sh -c 'chmod 700 \(cache) \(cache)/\(loader) && chmod 600 \(cache)/\(dex) && pwd'"
            copied = try await adb.shell(serial, piped, timeout: 20)
        }
        guard copied.succeeded else {
            if Self.saysNotDebuggable(copied) { throw AndroidAttachError.notDebuggable(package) }
            throw AndroidAttachError.failed("Could not copy the agent into \(package): \(Self.detail(copied))")
        }
        guard let dataDirectory = copied.text.split(whereSeparator: \.isNewline).last
            .map({ $0.trimmingCharacters(in: .whitespaces) }), dataDirectory.hasPrefix("/")
        else {
            throw AndroidAttachError.failed("Could not find \(package)'s data directory.")
        }

        let nonce = random()
        let token = random() + random()
        let socket = "voly-agent-\(process.pid)-\(nonce)"
        let info = "voly-agent-\(nonce).json"
        guard Self.isShellSafe(nonce), Self.isShellSafe(token) else {
            throw AndroidAttachError.failed("Could not generate a session token.")
        }
        let directory = "\(dataDirectory)/\(cache)"
        let options = "dex=\(directory)/\(dex),socket=\(socket),token=\(token),info=\(info)"
        let attached = try await adb.shell(
            serial, "cmd activity attach-agent \(process.pid) \(directory)/\(loader)=\(options)", timeout: 15
        )
        let complaint = (attached.text + " " + attached.errorText).lowercased()
        guard attached.succeeded, !complaint.contains("exception"), !complaint.contains("error") else {
            if complaint.contains("unknown process") || complaint.contains("no process") { throw AndroidAttachError.processGone }
            throw AndroidAttachError.failed("The system refused to attach the agent: \(Self.detail(attached))")
        }

        // The agent writes this file once its socket is listening.
        var label = package
        var listening = false
        for _ in 0..<25 {
            let read = try await adb.shell(serial, "run-as \(package) cat cache/\(info)", timeout: 8)
            if read.succeeded, let written = Self.parseInfo(read.stdout), written.pid == process.pid {
                label = written.label ?? package
                listening = true
                break
            }
            await pause(0.3)
        }
        guard listening else {
            throw AndroidAttachError.failed(
                "The agent did not start in \(package). `adb logcat -s VolyAgent` on the device says why."
            )
        }

        let forwarded = try await adb.run(["-s", serial, "forward", "tcp:0", "localabstract:\(socket)"], timeout: 8)
        guard forwarded.succeeded,
              let port = UInt16(forwarded.text.trimmingCharacters(in: .whitespacesAndNewlines)), port != 0
        else {
            throw AndroidAttachError.failed("adb could not forward a port to the agent: \(Self.detail(forwarded))")
        }
        return AndroidAgentEndpoint(serial: serial, package: package, pid: process.pid, label: label, port: port, token: token)
    }

    /// Give back the port `attach` took.
    public func release(_ endpoint: AndroidAgentEndpoint) async {
        _ = try? await adb.run(["-s", endpoint.serial, "forward", "--remove", "tcp:\(endpoint.port)"], timeout: 5)
    }

    struct Info: Equatable {
        let pid: Int32
        let label: String?
    }

    static func parseInfo(_ data: Data) -> Info? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int
        else { return nil }
        return Info(pid: Int32(pid), label: object["label"] as? String)
    }

    private static func saysNotDebuggable(_ output: AdbOutput) -> Bool {
        let text = (output.text + " " + output.errorText).lowercased()
        return text.contains("not debuggable") || text.contains("is not an application")
            || text.contains("unknown package")
    }

    private static func detail(_ output: AdbOutput) -> String {
        if output.timedOut { return "the device did not answer in time" }
        let text = output.errorText.isEmpty
            ? output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            : output.errorText
        return text.isEmpty ? "exit code \(output.exitCode)" : String(text.prefix(300))
    }
}
