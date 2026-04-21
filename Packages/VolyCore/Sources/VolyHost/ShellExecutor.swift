// Packages/VolyCore/Sources/VolyHost/ShellExecutor.swift
import Foundation

public struct ShellResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
}

public protocol ShellExecutor: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String]?) async throws -> ShellResult
}

public struct SystemShellExecutor: ShellExecutor {
    public init() {}
    public func run(
        executable: URL, arguments: [String], environment: [String: String]? = nil
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = executable
                p.arguments = arguments
                if let env = environment {
                    // Inherit current environment, then override.
                    var merged = ProcessInfo.processInfo.environment
                    for (k, v) in env { merged[k] = v }
                    p.environment = merged
                }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                    p.waitUntilExit()
                    let outData = out.fileHandleForReading.readDataToEndOfFile()
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    cont.resume(returning: ShellResult(exitCode: p.terminationStatus, stdout: outData, stderr: errData))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
