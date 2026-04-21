import Foundation

/// Thin wrapper around `xcrun simctl` for Simulator-specific polish features.
/// None of these are on the critical path — they degrade to no-op when not running
/// next to a simulator.
enum SimctlClient {
    struct Device: Codable, Hashable, Identifiable {
        let udid: String
        let name: String
        let state: String
        var id: String { udid }
    }

    static func listBootedDevices() async -> [Device] {
        let output = await run(["list", "devices", "booted", "--json"])
        guard let data = output.data(using: .utf8) else { return [] }
        struct Root: Decodable { let devices: [String: [Device]] }
        let decoded = try? JSONDecoder().decode(Root.self, from: data)
        return (decoded?.devices.values.flatMap { $0 }) ?? []
    }

    static func setAppearance(_ appearance: String, udid: String) async {
        _ = await run(["ui", udid, "appearance", appearance])
    }

    static func openURL(_ url: URL, udid: String) async {
        _ = await run(["openurl", udid, url.absoluteString])
    }

    private static func run(_ args: [String]) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = ["simctl"] + args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    cont.resume(returning: "")
                }
            }
        }
    }
}
