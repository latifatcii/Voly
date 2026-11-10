import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// What one `adb` invocation produced.
public struct AdbOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    /// The command was stopped because it ran past its time limit. Whatever
    /// it had printed until then is still in `stdout`.
    public let timedOut: Bool

    public init(exitCode: Int32, stdout: Data, stderr: Data = Data(), timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public var text: String { String(decoding: stdout, as: UTF8.self) }
    public var errorText: String {
        String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs `adb`. The one seam between Voly and Android tooling: everything
/// above it is tested against a scripted stand-in.
public protocol AdbRunning: Sendable {
    /// - Parameter timeout: seconds after which the command is stopped.
    func run(_ arguments: [String], timeout: TimeInterval) async throws -> AdbOutput
}

public extension AdbRunning {
    /// `adb -s <serial> shell <command>`. The command is one string, run by
    /// the device's shell.
    func shell(_ serial: String, _ command: String, timeout: TimeInterval = 10) async throws -> AdbOutput {
        try await run(["-s", serial, "shell", command], timeout: timeout)
    }
}

public enum AdbError: Error, Equatable, LocalizedError {
    case notFound
    case failed(command: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "adb was not found. Install the Android SDK platform-tools, or point Voly at adb with: "
                + "defaults write com.latifatci.Voly voly.android.adbPath /path/to/adb"
        case .failed(let command, let detail):
            return detail.isEmpty ? "adb \(command) failed." : "adb \(command) failed: \(detail)"
        }
    }
}

/// Finds the `adb` executable. A menu-bar app doesn't inherit a shell's
/// PATH or ANDROID_HOME, so the usual install locations are checked too.
public enum AdbLocator {
    public static let defaultsKey = "voly.android.adbPath"

    public static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        configured: String? = UserDefaults.standard.string(forKey: AdbLocator.defaultsKey)
    ) -> [String] {
        var paths: [String] = []
        if let configured, !configured.isEmpty { paths.append((configured as NSString).expandingTildeInPath) }
        if let explicit = environment["VOLY_ADB"], !explicit.isEmpty { paths.append(explicit) }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = environment[key], !sdk.isEmpty { paths.append(sdk + "/platform-tools/adb") }
        }
        paths.append(home + "/Library/Android/sdk/platform-tools/adb")
        paths.append(home + "/Android/Sdk/platform-tools/adb")
        paths += ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            paths.append(String(directory) + "/adb")
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    public static func locate(
        candidates: [String] = AdbLocator.candidates(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}

/// Whether an adb server is already running on this Mac.
///
/// Voly only talks to adb while one is: running `adb` starts a server as a
/// side effect, and somebody who never uses Android shouldn't get a daemon
/// from Voly. Android Studio and the emulator both start the server
/// themselves, so one is there whenever there is something to inspect.
public enum AdbServerProbe {
    public static func port(environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt16 {
        environment["ANDROID_ADB_SERVER_PORT"].flatMap(UInt16.init) ?? 5037
    }

    public static func isRunning(port: UInt16 = AdbServerProbe.port()) -> Bool {
        #if os(Linux)
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        // A refused connection on loopback fails at once; no timeout is needed.
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

/// `AdbRunning` on the real executable.
public struct AdbClient: AdbRunning {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public func run(_ arguments: [String], timeout: TimeInterval) async throws -> AdbOutput {
        let executable = self.executable
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try Self.runBlocking(executable, arguments, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Both pipes are drained while the process runs: a screenshot is far
    /// larger than a pipe's buffer, and a process blocked on a full pipe
    /// never exits.
    private static func runBlocking(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> AdbOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collected = Collected()
        let readers = DispatchGroup()
        for (pipe, isError) in [(out, false), (err, true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.set(data, isError: isError)
                readers.leave()
            }
        }

        try process.run()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        // A grandchild that inherited the pipes could keep them open; don't wait forever.
        _ = readers.wait(timeout: .now() + 2)
        return AdbOutput(
            exitCode: process.terminationStatus, stdout: collected.stdout, stderr: collected.stderr, timedOut: timedOut
        )
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()

        func set(_ data: Data, isError: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isError { err = data } else { out = data }
        }

        var stdout: Data {
            lock.lock()
            defer { lock.unlock() }
            return out
        }

        var stderr: Data {
            lock.lock()
            defer { lock.unlock() }
            return err
        }
    }
}
