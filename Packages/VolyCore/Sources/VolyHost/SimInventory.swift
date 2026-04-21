// Packages/VolyCore/Sources/VolyHost/SimInventory.swift
import Foundation

public enum SimInventoryError: Error {
    case simctlFailed(code: Int32, stderr: String)
    case decodeFailed(String)
    case plutilFailed(code: Int32, stderr: String)
}

public struct SimDevice: Equatable, Hashable, Sendable, Identifiable {
    public let udid: String
    public let name: String
    public let state: String
    public let runtime: String
    public var id: String { udid }
    public var isBooted: Bool { state == "Booted" }
}

public struct SimApp: Equatable, Hashable, Sendable, Identifiable {
    public let bundleIdentifier: String
    public let displayName: String
    public let applicationType: String   // "User" or "System"
    public var id: String { bundleIdentifier }
}

public struct SimInventory {
    public let shell: ShellExecutor
    public let xcrunURL: URL
    public let plutilURL: URL

    public init(shell: ShellExecutor = SystemShellExecutor(),
                xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
                plutilURL: URL = URL(fileURLWithPath: "/usr/bin/plutil")) {
        self.shell = shell
        self.xcrunURL = xcrunURL
        self.plutilURL = plutilURL
    }

    public func listDevices(bootedOnly: Bool = true) async throws -> [SimDevice] {
        let args = ["simctl", "list", "devices"] + (bootedOnly ? ["booted"] : []) + ["--json"]
        let result = try await shell.run(executable: xcrunURL, arguments: args, environment: nil)
        guard result.exitCode == 0 else {
            throw SimInventoryError.simctlFailed(
                code: result.exitCode,
                stderr: String(data: result.stderr, encoding: .utf8) ?? ""
            )
        }
        return try Self.parseDevices(data: result.stdout)
    }

    public func listApps(deviceUDID: String, includeSystem: Bool = false) async throws -> [SimApp] {
        let listResult = try await shell.run(
            executable: xcrunURL,
            arguments: ["simctl", "listapps", deviceUDID],
            environment: nil
        )
        guard listResult.exitCode == 0 else {
            throw SimInventoryError.simctlFailed(
                code: listResult.exitCode,
                stderr: String(data: listResult.stderr, encoding: .utf8) ?? ""
            )
        }
        return try Self.parseApps(plistData: listResult.stdout, includeSystem: includeSystem)
    }

    public static func parseDevices(data: Data) throws -> [SimDevice] {
        struct Root: Decodable {
            let devices: [String: [RawDevice]]
        }
        struct RawDevice: Decodable {
            let udid: String
            let name: String
            let state: String
        }
        let decoder = JSONDecoder()
        let root: Root
        do { root = try decoder.decode(Root.self, from: data) }
        catch { throw SimInventoryError.decodeFailed("devices JSON: \(error)") }

        var out: [SimDevice] = []
        for (runtime, devs) in root.devices {
            for d in devs {
                out.append(SimDevice(udid: d.udid, name: d.name, state: d.state, runtime: runtime))
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    public static func parseApps(plistData: Data, includeSystem: Bool) throws -> [SimApp] {
        let xml = try convertToXMLPlist(openStep: plistData)
        var format: PropertyListSerialization.PropertyListFormat = .xml
        let obj: Any
        do {
            obj = try PropertyListSerialization.propertyList(
                from: xml, options: [], format: &format
            )
        } catch {
            throw SimInventoryError.decodeFailed("apps plist: \(error)")
        }
        guard let dict = obj as? [String: [String: Any]] else {
            throw SimInventoryError.decodeFailed("apps plist: expected top-level dictionary of dictionaries")
        }
        var out: [SimApp] = []
        for (_, info) in dict {
            let bid = info["CFBundleIdentifier"] as? String ?? ""
            let type = info["ApplicationType"] as? String ?? "User"
            if !includeSystem && type != "User" { continue }
            let display = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? bid
            out.append(SimApp(bundleIdentifier: bid, displayName: display, applicationType: type))
        }
        return out.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }

    private static func convertToXMLPlist(openStep data: Data) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        p.arguments = ["-convert", "xml1", "-o", "-", "--", "-"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        try p.run()
        try stdin.fileHandleForWriting.write(contentsOf: data)
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0 else {
            throw SimInventoryError.plutilFailed(
                code: p.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }
        return outData
    }
}
