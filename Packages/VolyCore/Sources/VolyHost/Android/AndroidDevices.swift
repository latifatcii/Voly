import Foundation

/// An Android emulator or device adb can reach.
public struct AndroidDevice: Sendable, Equatable, Hashable, Identifiable {
    /// adb's name for it: `emulator-5554`, or a device's serial number.
    public let serial: String
    /// The AVD's name for an emulator (`Pixel_8_API_35`), else the model.
    public let name: String
    public let model: String?
    /// `15`
    public let androidVersion: String?
    /// `35`
    public let apiLevel: Int?
    /// ABIs the device runs, 64-bit first: `["arm64-v8a"]`.
    public let abis: [String]
    public let isEmulator: Bool

    public var id: String { serial }

    public init(
        serial: String, name: String, model: String? = nil, androidVersion: String? = nil,
        apiLevel: Int? = nil, abis: [String] = [], isEmulator: Bool
    ) {
        self.serial = serial
        self.name = name
        self.model = model
        self.androidVersion = androidVersion
        self.apiLevel = apiLevel
        self.abis = abis
        self.isEmulator = isEmulator
    }

    /// `Android 15 (API 35)`
    public var runtimeName: String {
        switch (androidVersion, apiLevel) {
        case (let version?, let api?): return "Android \(version) (API \(api))"
        case (let version?, nil): return "Android \(version)"
        case (nil, let api?): return "Android (API \(api))"
        default: return "Android"
        }
    }

    /// `Pixel 8 API 35`: AVD names use underscores where people would use spaces.
    public var displayName: String {
        isEmulator ? name.replacingOccurrences(of: "_", with: " ") : name
    }

    /// Attaching an agent to a running app needs Android 8.
    public var supportsAgents: Bool { (apiLevel ?? 26) >= 26 }
}

/// Lists the devices adb sees and reads what Voly shows about each.
public struct AndroidDeviceInventory: Sendable {
    private let adb: AdbRunning

    public init(adb: AdbRunning) {
        self.adb = adb
    }

    /// Serials of the devices that are online (booted and authorized).
    public func onlineSerials() async throws -> [String] {
        let output = try await adb.run(["devices"], timeout: 8)
        guard output.succeeded else { throw AdbError.failed(command: "devices", detail: output.errorText) }
        return Self.parseOnlineSerials(output.text)
    }

    /// `adb devices` prints a header and one `serial<TAB>state` line each.
    public static func parseOnlineSerials(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            return String(fields[0])
        }
    }

    public func describe(serial: String) async throws -> AndroidDevice {
        let output = try await adb.shell(serial, "getprop", timeout: 8)
        guard output.succeeded else { throw AdbError.failed(command: "shell getprop", detail: output.errorText) }
        return Self.device(serial: serial, properties: Self.parseProperties(output.text))
    }

    /// `[ro.build.version.sdk]: [35]` lines.
    public static func parseProperties(_ text: String) -> [String: String] {
        var properties: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("["), let separator = line.range(of: "]: [") else { continue }
            let key = line[line.index(after: line.startIndex)..<separator.lowerBound]
            var value = line[separator.upperBound...]
            if value.hasSuffix("]") { value = value.dropLast() }
            properties[String(key)] = String(value)
        }
        return properties
    }

    public static func device(serial: String, properties: [String: String]) -> AndroidDevice {
        func value(_ key: String) -> String? {
            properties[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        let isEmulator = serial.hasPrefix("emulator-") || value("ro.kernel.qemu") == "1"
            || value("ro.boot.qemu") == "1"
        let model = value("ro.product.model")
        let avd = value("ro.boot.qemu.avd_name") ?? value("ro.kernel.qemu.avd_name")
        let abis = (value("ro.product.cpu.abilist") ?? value("ro.product.cpu.abi") ?? "")
            .split(separator: ",").map(String.init)
        return AndroidDevice(
            serial: serial,
            name: (isEmulator ? avd : nil) ?? model ?? serial,
            model: model,
            androidVersion: value("ro.build.version.release"),
            apiLevel: value("ro.build.version.sdk").flatMap(Int.init),
            abis: abis,
            isEmulator: isEmulator
        )
    }
}

/// A running app process on a device.
public struct AndroidProcess: Sendable, Equatable, Hashable {
    public let package: String
    public let pid: Int32
    /// The app can have an agent attached: it is a debuggable build (or the
    /// device is a debug image, where every app is).
    public let isDebuggable: Bool
    public let is64Bit: Bool

    public init(package: String, pid: Int32, isDebuggable: Bool, is64Bit: Bool) {
        self.package = package
        self.pid = pid
        self.isDebuggable = isDebuggable
        self.is64Bit = is64Bit
    }
}

/// Finds the user's apps that are running on a device.
public struct AndroidProcessLister: Sendable {
    private let adb: AdbRunning

    public init(adb: AdbRunning) {
        self.adb = adb
    }

    /// Main processes of user-installed apps, with whether each can take
    /// an agent.
    public func runningUserApps(serial: String, userPackages: Set<String>) async throws -> [AndroidProcess] {
        let ps = try await adb.shell(serial, "ps -A -o PID,PPID,NAME", timeout: 8)
        guard ps.succeeded else { throw AdbError.failed(command: "shell ps", detail: ps.errorText) }
        // `adb jdwp` lists the pids a debugger (and so an agent) may attach
        // to. It doesn't exit on its own on every adb version, hence the
        // short limit; what it printed until then is the answer.
        let jdwp = try await adb.run(["-s", serial, "jdwp"], timeout: 2)
        return Self.userApps(ps: ps.text, debuggablePIDs: Self.parsePIDs(jdwp.text), userPackages: userPackages)
    }

    /// Packages the user installed (`pm list packages -3`).
    public func userPackages(serial: String) async throws -> Set<String> {
        let output = try await adb.shell(serial, "pm list packages -3", timeout: 15)
        guard output.succeeded else { throw AdbError.failed(command: "shell pm list packages", detail: output.errorText) }
        return Self.parsePackages(output.text)
    }

    public static func parsePackages(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("package:") else { return nil }
            return String(trimmed.dropFirst("package:".count))
        })
    }

    public static func parsePIDs(_ text: String) -> Set<Int32> {
        Set(text.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
    }

    public static func userApps(ps: String, debuggablePIDs: Set<Int32>, userPackages: Set<String>) -> [AndroidProcess] {
        struct Row { let pid: Int32, parent: Int32, name: String }
        let rows = ps.split(whereSeparator: \.isNewline).compactMap { line -> Row? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return Row(pid: pid, parent: parent, name: String(fields[2]))
        }
        let names = Dictionary(rows.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })
        return rows
            // An app's main process is named exactly like its package;
            // `package:service` processes have no UI of their own.
            .filter { userPackages.contains($0.name) }
            .map { row in
                // Apps are forked from zygote64 or, for 32-bit apps, zygote.
                let parent = names[row.parent] ?? ""
                return AndroidProcess(
                    package: row.name, pid: row.pid,
                    isDebuggable: debuggablePIDs.contains(row.pid),
                    is64Bit: parent.isEmpty || parent.contains("64")
                )
            }
            .sorted { $0.package < $1.package }
    }
}
