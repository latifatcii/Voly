import Foundation
import XCTest
import VolyModels
import VolyProtocol
@testable import VolyHost

/// Stands in for adb: answers each command from a script and records it.
final class ScriptedAdb: AdbRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let answer: @Sendable ([String]) -> AdbOutput

    init(_ answer: @escaping @Sendable ([String]) -> AdbOutput) {
        self.answer = answer
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The device shell commands that were run, in order.
    var shellCommands: [String] {
        calls.compactMap { $0.count == 4 && $0[2] == "shell" ? $0[3] : nil }
    }

    func run(_ arguments: [String], timeout: TimeInterval) async throws -> AdbOutput {
        record(arguments)
        return answer(arguments)
    }

    private func record(_ arguments: [String]) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(arguments)
    }

    static func ok(_ text: String = "") -> AdbOutput {
        AdbOutput(exitCode: 0, stdout: Data(text.utf8))
    }

    static func fail(_ text: String, code: Int32 = 1) -> AdbOutput {
        AdbOutput(exitCode: code, stdout: Data(), stderr: Data(text.utf8))
    }
}

final class AndroidDiscoveryTests: XCTestCase {
    func test_online_serials_skip_offline_and_unauthorized_devices() {
        let text = """
            List of devices attached
            emulator-5554\tdevice
            emulator-5556\toffline
            R58M12ABCDE\tunauthorized
            192.168.1.20:5555\tdevice

            """
        XCTAssertEqual(AndroidDeviceInventory.parseOnlineSerials(text), ["emulator-5554", "192.168.1.20:5555"])
    }

    func test_device_is_described_from_its_properties() {
        let properties = AndroidDeviceInventory.parseProperties("""
            [ro.build.version.release]: [15]
            [ro.build.version.sdk]: [35]
            [ro.product.model]: [sdk_gphone64_arm64]
            [ro.product.cpu.abilist]: [arm64-v8a]
            [ro.boot.qemu.avd_name]: [Pixel_8_API_35]
            [ro.empty]: []
            """)
        let device = AndroidDeviceInventory.device(serial: "emulator-5554", properties: properties)
        XCTAssertEqual(device.name, "Pixel_8_API_35")
        XCTAssertEqual(device.displayName, "Pixel 8 API 35")
        XCTAssertEqual(device.runtimeName, "Android 15 (API 35)")
        XCTAssertEqual(device.abis, ["arm64-v8a"])
        XCTAssertTrue(device.isEmulator)
        XCTAssertTrue(device.supportsAgents)
    }

    func test_a_physical_device_is_named_by_its_model() {
        let device = AndroidDeviceInventory.device(serial: "R58M12ABCDE", properties: [
            "ro.product.model": "SM-G991B", "ro.build.version.sdk": "25", "ro.product.cpu.abilist": "arm64-v8a,armeabi-v7a",
        ])
        XCTAssertEqual(device.displayName, "SM-G991B")
        XCTAssertFalse(device.isEmulator)
        XCTAssertFalse(device.supportsAgents, "attaching an agent needs API 26")
    }

    func test_user_apps_are_main_processes_of_user_packages() {
        let ps = """
              PID  PPID NAME
                1     0 init
              356     1 zygote64
              357     1 zygote
             1201   356 com.android.systemui
             2910   356 com.example.volysample
             2950   356 com.example.volysample:remote
             3001   357 com.example.legacy32
            """
        let apps = AndroidProcessLister.userApps(
            ps: ps, userPackages: ["com.example.volysample", "com.example.legacy32", "com.example.notrunning"]
        )
        XCTAssertEqual(apps, [
            AndroidProcess(package: "com.example.legacy32", pid: 3001, is64Bit: false),
            AndroidProcess(package: "com.example.volysample", pid: 2910, is64Bit: true),
        ])
    }

    func test_packages_are_parsed_from_pm_output() {
        XCTAssertEqual(
            AndroidProcessLister.parsePackages("package:com.example.a\npackage:com.example.b\n\nWARNING: noise\n"),
            ["com.example.a", "com.example.b"]
        )
    }

    func test_adb_is_looked_for_where_a_gui_app_would_not_find_it_by_path() {
        let candidates = AdbLocator.candidates(
            environment: ["ANDROID_HOME": "/sdk", "PATH": "/usr/bin:/custom/bin"], home: "/Users/me", configured: "~/tools/adb"
        )
        XCTAssertEqual(candidates.first, NSString(string: "~/tools/adb").expandingTildeInPath)
        XCTAssertTrue(candidates.contains("/sdk/platform-tools/adb"))
        XCTAssertTrue(candidates.contains("/Users/me/Library/Android/sdk/platform-tools/adb"))
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/adb"))
        XCTAssertTrue(candidates.contains("/custom/bin/adb"))
        XCTAssertEqual(AdbLocator.locate(candidates: ["/a", "/b", "/c"], isExecutable: { $0 != "/a" })?.path, "/b")
        XCTAssertNil(AdbLocator.locate(candidates: ["/a"], isExecutable: { _ in false }))
    }

    func test_the_running_servers_own_adb_is_preferred() {
        // adb starts its server under the bare name, whatever path the client ran from.
        let processes = """
              1 /sbin/launchd
            412 grep adb fork-server server
            734 adb -L tcp:5037 fork-server server --reply-fd 4
            801 /Applications/Android Studio.app/Contents/MacOS/studio
            """
        let files: [Int32: String] = [
            412: "/usr/bin/grep", 734: "/Users/John Doe/Library/Android/sdk/platform-tools/adb",
        ]
        XCTAssertEqual(AdbLocator.serverProcessIDs(processList: processes), [734])
        XCTAssertEqual(
            AdbLocator.serverExecutable(
                processList: processes, executablePath: { files[$0] }, isExecutable: { _ in true }
            )?.path,
            "/Users/John Doe/Library/Android/sdk/platform-tools/adb"
        )
        XCTAssertNil(AdbLocator.serverExecutable(
            processList: processes, executablePath: { files[$0] }, isExecutable: { _ in false }
        ))
        XCTAssertNil(AdbLocator.serverExecutable(
            processList: processes, executablePath: { _ in nil }, isExecutable: { _ in true }
        ))
    }

    func test_a_server_started_by_its_full_path_is_recognised_too() {
        let processes = "  95 /Users/John Doe/sdk/platform-tools/adb -L tcp:5037 fork-server server --reply-fd 4\n"
        XCTAssertEqual(AdbLocator.serverProcessIDs(processList: processes), [95])
    }

    func test_other_adb_commands_are_not_the_server() {
        XCTAssertEqual(AdbLocator.serverProcessIDs(processList: "  12 /usr/bin/adb devices\n  13 adb logcat\n"), [])
        XCTAssertEqual(AdbLocator.serverProcessIDs(processList: "  14 notadb -L tcp:5037 fork-server server\n"), [])
    }

    func test_the_file_a_process_runs_is_read_from_the_system() throws {
        // Started under another name, as adb's server is: the name in the
        // command line is not where the file is.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sh")
        sleeper.arguments = ["-c", "exec -a adb /bin/sleep 30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        var path: String?
        for _ in 0..<50 where path != "/bin/sleep" {
            path = AdbLocator.executablePath(ofProcess: sleeper.processIdentifier)
            usleep(20_000)
        }
        XCTAssertEqual(path, "/bin/sleep")
        XCTAssertNil(AdbLocator.executablePath(ofProcess: 0x7FFF_FFF0))
    }

    func test_a_process_that_only_quotes_the_servers_command_line_is_passed_over() {
        // A shell that started the server by hand is listed too, and first.
        let processes = """
            77 /bin/zsh -c exec x/adb -L tcp:5037 fork-server server
            78 adb -L tcp:5037 fork-server server --reply-fd 4
            """
        let files: [Int32: String] = [77: "/bin/zsh", 78: "/sdk/platform-tools/adb"]
        XCTAssertEqual(
            AdbLocator.serverExecutable(
                processList: processes, executablePath: { files[$0] }, isExecutable: { _ in true }
            )?.path,
            "/sdk/platform-tools/adb"
        )
        XCTAssertNil(AdbLocator.serverExecutable(
            processList: "77 /bin/zsh -c exec x/adb -L tcp:5037 fork-server server\n",
            executablePath: { files[$0] }, isExecutable: { _ in true }
        ))
    }

    func test_running_a_command_collects_output_larger_than_a_pipe() async throws {
        let shell = AdbClient(executable: URL(fileURLWithPath: "/bin/sh"))
        let output = try await shell.run(["-c", "seq 1 60000; echo done >&2"], timeout: 20)
        XCTAssertTrue(output.succeeded)
        XCTAssertEqual(output.text.split(separator: "\n").count, 60000)
        XCTAssertEqual(output.errorText, "done")
    }

    func test_an_executable_that_is_gone_is_an_error_not_a_hang() async {
        let missing = AdbClient(executable: URL(fileURLWithPath: "/nonexistent/platform-tools/adb"))
        do {
            _ = try await missing.run(["devices"], timeout: 5)
            XCTFail("expected an error")
        } catch {}
    }

    func test_emulators_are_inspected_unless_switched_off_and_devices_only_once_switched_on() {
        var policy = AndroidDevicePolicy()
        XCTAssertTrue(policy.wants("emulator-5554"))
        XCTAssertFalse(policy.wants("R58M12ABCDE"))
        // An emulator reached over the network has no name that says what it is.
        XCTAssertFalse(policy.wants("192.168.56.101:5555"))

        policy.set(true, for: "R58M12ABCDE")
        policy.set(false, for: "emulator-5554")
        XCTAssertTrue(policy.wants("R58M12ABCDE"))
        XCTAssertFalse(policy.wants("emulator-5554"))
        XCTAssertEqual(policy, AndroidDevicePolicy(enabled: ["R58M12ABCDE"], disabled: ["emulator-5554"]))

        policy.set(false, for: "R58M12ABCDE")
        policy.set(true, for: "emulator-5554")
        XCTAssertFalse(policy.wants("R58M12ABCDE"))
        XCTAssertTrue(policy.wants("emulator-5554"))
    }

    #if canImport(AppKit)
    func test_only_the_android_sdks_own_qemu_counts_as_the_emulator() {
        let sdk = "/Users/me/Library/Android/sdk/emulator/qemu/darwin-aarch64"
        XCTAssertTrue(AndroidEmulatorApp.isEmulator(executablePath: "\(sdk)/qemu-system-aarch64"))
        XCTAssertTrue(AndroidEmulatorApp.isEmulator(executablePath: "\(sdk)/qemu-system-aarch64-headless"))
        // Somebody's Linux machine in QEMU from Homebrew.
        XCTAssertFalse(AndroidEmulatorApp.isEmulator(executablePath: "/opt/homebrew/bin/qemu-system-aarch64"))
        XCTAssertFalse(AndroidEmulatorApp.isEmulator(executablePath: "/Users/me/Library/Android/sdk/emulator/emulator"))
    }
    #endif

    func test_png_size_is_read_from_the_header() {
        XCTAssertEqual(PNGSize.read(AndroidFixtures.onePixelPNG)?.width, 1)
        XCTAssertEqual(PNGSize.read(AndroidFixtures.onePixelPNG)?.height, 1)
        XCTAssertNil(PNGSize.read(Data("not a png at all, just text".utf8)))
    }
}

enum AndroidFixtures {
    /// A valid 1×1 PNG.
    static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    )!

    static let payload = AndroidAgentPayload(
        dex: URL(fileURLWithPath: "/voly/voly-agent.dex"),
        loaders: [
            "arm64-v8a": URL(fileURLWithPath: "/voly/voly-agent-arm64-v8a.elf"),
            "x86_64": URL(fileURLWithPath: "/voly/voly-agent-x86_64.elf"),
            "armeabi-v7a": URL(fileURLWithPath: "/voly/voly-agent-armeabi-v7a.elf"),
        ],
        version: "abc123"
    )

    static let pixel = AndroidDevice(
        serial: "emulator-5554", name: "Pixel_8_API_35", model: "sdk_gphone64_arm64",
        androidVersion: "15", apiLevel: 35, abis: ["arm64-v8a"], isEmulator: true
    )

    static let getprop = """
        [ro.build.version.release]: [15]
        [ro.build.version.sdk]: [35]
        [ro.product.model]: [sdk_gphone64_arm64]
        [ro.product.cpu.abilist]: [arm64-v8a]
        [ro.boot.qemu.avd_name]: [Pixel_8_API_35]
        """

    /// An adb that behaves like a device with the given running user apps,
    /// all debuggable unless listed in `releaseBuilds`.
    static func device(
        running: @escaping @Sendable () -> [(package: String, pid: Int32)],
        releaseBuilds: Set<String> = [],
        attachFails: Bool = false,
        forwardsLost: Bool = false
    ) -> ScriptedAdb {
        ScriptedAdb { arguments in
            if arguments == ["devices"] { return ScriptedAdb.ok("List of devices attached\nemulator-5554\tdevice\n") }
            if arguments.contains("forward") {
                if arguments.contains("--list") {
                    return ScriptedAdb.ok(forwardsLost ? "" : "emulator-5554 tcp:40123 localabstract:voly-agent\n")
                }
                return arguments.contains("--remove") ? ScriptedAdb.ok() : ScriptedAdb.ok("40123\n")
            }
            if arguments.contains("push") { return ScriptedAdb.ok("1 file pushed") }
            guard arguments.count == 4, arguments[2] == "shell" else { return ScriptedAdb.fail("unexpected \(arguments)") }
            let command = arguments[3]
            if command == "getprop" { return ScriptedAdb.ok(getprop) }
            if command.hasPrefix("pm list packages") {
                return ScriptedAdb.ok(running().map { "package:\($0.package)" }.joined(separator: "\n"))
            }
            if command.hasPrefix("ps ") {
                let rows = running().map { "\($0.pid) 356 \($0.package)" }
                return ScriptedAdb.ok((["PID PPID NAME", "356 1 zygote64"] + rows).joined(separator: "\n"))
            }
            if command.hasPrefix("ls ") { return ScriptedAdb.fail("No such file or directory") }
            if command.hasPrefix("mkdir ") { return ScriptedAdb.ok() }
            if command.hasPrefix("run-as ") {
                let package = command.split(separator: " ")[1]
                if releaseBuilds.contains(String(package)) {
                    return ScriptedAdb.fail("run-as: package not debuggable: \(package)")
                }
                if command.contains(" cat cache/voly-agent-") {
                    guard let pid = running().first(where: { $0.package == package })?.pid else {
                        return ScriptedAdb.fail("No such file")
                    }
                    return ScriptedAdb.ok("{\"pid\":\(pid),\"label\":\"Sample App\",\"socket\":\"s\"}")
                }
                return ScriptedAdb.ok("/data/user/0/\(package)\n")
            }
            if command.hasPrefix("cmd activity attach-agent") {
                return attachFails ? ScriptedAdb.ok("Exception occurred while executing 'attach-agent'") : ScriptedAdb.ok()
            }
            if command.hasPrefix("am force-stop") { return ScriptedAdb.ok() }
            if command.hasPrefix("monkey ") { return ScriptedAdb.ok("Events injected: 1") }
            return ScriptedAdb.fail("unexpected shell command: \(command)")
        }
    }

    static func installer(_ adb: AdbRunning) -> AndroidAgentInstaller {
        AndroidAgentInstaller(adb: adb, payload: payload, pause: { _ in }, random: { "0123456789abcdef" })
    }
}

final class AndroidAgentInstallerTests: XCTestCase {
    private let process = AndroidProcess(package: "com.example.app", pid: 4242, is64Bit: true)

    func test_attach_copies_the_agent_into_the_app_then_attaches_and_forwards() async throws {
        let adb = AndroidFixtures.device(running: { [("com.example.app", 4242)] })
        let endpoint = try await AndroidFixtures.installer(adb).attach(
            serial: "emulator-5554", device: AndroidFixtures.pixel, process: process
        )

        XCTAssertEqual(endpoint, AndroidAgentEndpoint(
            serial: "emulator-5554", package: "com.example.app", pid: 4242, label: "Sample App",
            port: 40123, token: "0123456789abcdef0123456789abcdef"
        ))
        // Staged once into the shell's temp directory, under the payload's version.
        let pushes = adb.calls.filter { $0.contains("push") }
        XCTAssertEqual(pushes.map { $0.last }, [
            "/data/local/tmp/voly-abc123/voly-agent.dex",
            "/data/local/tmp/voly-abc123/libvolyagent-arm64-v8a.so",
        ])
        XCTAssertEqual(pushes.map { $0[3] }, ["/voly/voly-agent.dex", "/voly/voly-agent-arm64-v8a.elf"])

        let shell = adb.shellCommands
        let copy = try XCTUnwrap(shell.first { $0.hasPrefix("run-as com.example.app sh -c") })
        XCTAssertTrue(copy.contains("code_cache/voly-abc123"))
        let attach = try XCTUnwrap(shell.first { $0.hasPrefix("cmd activity attach-agent") })
        XCTAssertEqual(attach, "cmd activity attach-agent 4242 "
            + "/data/user/0/com.example.app/code_cache/voly-abc123/libvolyagent-arm64-v8a.so="
            + "dex=/data/user/0/com.example.app/code_cache/voly-abc123/voly-agent.dex,"
            + "socket=voly-agent-4242-0123456789abcdef,"
            + "token=0123456789abcdef0123456789abcdef,"
            + "info=voly-agent-0123456789abcdef.json")
        XCTAssertEqual(adb.calls.last, [
            "-s", "emulator-5554", "forward", "tcp:0", "localabstract:voly-agent-4242-0123456789abcdef",
        ])
        // The copy comes before the attach, the attach before the forward.
        let order = [copy, attach].map { shell.firstIndex(of: $0)! }
        XCTAssertLessThan(order[0], order[1])
    }

    func test_a_release_build_is_reported_as_not_debuggable() async {
        let adb = AndroidFixtures.device(running: { [("com.example.app", 4242)] }, releaseBuilds: ["com.example.app"])
        do {
            _ = try await AndroidFixtures.installer(adb).attach(
                serial: "emulator-5554", device: AndroidFixtures.pixel, process: process
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AndroidAttachError, .notDebuggable("com.example.app"))
        }
        XCTAssertFalse(adb.shellCommands.contains { $0.hasPrefix("cmd activity attach-agent") })
    }

    func test_a_refused_attach_is_an_error_not_a_silent_success() async {
        let adb = AndroidFixtures.device(running: { [("com.example.app", 4242)] }, attachFails: true)
        do {
            _ = try await AndroidFixtures.installer(adb).attach(
                serial: "emulator-5554", device: AndroidFixtures.pixel, process: process
            )
            XCTFail("expected an error")
        } catch {
            guard case .failed(let message)? = error as? AndroidAttachError else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("refused to attach"))
        }
        XCTAssertFalse(adb.calls.contains { $0.contains("forward") })
    }

    func test_the_loader_matches_the_process_not_just_the_device() {
        let available: Set<String> = ["arm64-v8a", "armeabi-v7a", "x86_64"]
        let both = ["arm64-v8a", "armeabi-v7a"]
        XCTAssertEqual(AndroidAgentInstaller.abi(
            for: AndroidProcess(package: "a", pid: 1, is64Bit: true), deviceABIs: both, available: available
        ), "arm64-v8a")
        XCTAssertEqual(AndroidAgentInstaller.abi(
            for: AndroidProcess(package: "a", pid: 1, is64Bit: false), deviceABIs: both, available: available
        ), "armeabi-v7a")
        XCTAssertNil(AndroidAgentInstaller.abi(
            for: AndroidProcess(package: "a", pid: 1, is64Bit: true), deviceABIs: ["riscv64"], available: available
        ))
    }

    func test_names_that_would_need_shell_quoting_are_refused() async {
        XCTAssertTrue(AndroidAgentInstaller.isShellSafe("com.example.my_app-debug"))
        XCTAssertFalse(AndroidAgentInstaller.isShellSafe("com.example; rm -rf /"))
        XCTAssertFalse(AndroidAgentInstaller.isShellSafe("a b"))
        XCTAssertFalse(AndroidAgentInstaller.isShellSafe(""))
        let adb = AndroidFixtures.device(running: { [] })
        do {
            _ = try await AndroidFixtures.installer(adb).attach(
                serial: "emulator-5554", device: AndroidFixtures.pixel,
                process: AndroidProcess(package: "bad;name", pid: 1, is64Bit: true)
            )
            XCTFail("expected an error")
        } catch {}
        XCTAssertTrue(adb.calls.isEmpty, "nothing is sent to the device for a name like that")
    }

    func test_payload_is_loaded_from_the_first_complete_directory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voly-payload-\(UUID().uuidString)")
        let empty = root.appendingPathComponent("empty"), full = root.appendingPathComponent("full")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try AndroidAgentPayload.load(from: [empty, full]))

        try Data("dex".utf8).write(to: full.appendingPathComponent("voly-agent.dex"))
        try Data("elf".utf8).write(to: full.appendingPathComponent("voly-agent-arm64-v8a.elf"))
        try Data("6cde1f0b210c9285\n".utf8).write(to: full.appendingPathComponent("voly-agent.version"))
        let payload = try AndroidAgentPayload.load(from: [empty, full])
        XCTAssertEqual(payload.version, "6cde1f0b210c9285")
        XCTAssertEqual(Array(payload.loaders.keys), ["arm64-v8a"])
    }

    func test_the_payload_checked_into_the_repository_is_complete() throws {
        // Voly/AndroidAgentPayload, four levels up from this file's package.
        let repository = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let payload = try AndroidAgentPayload.load(from: [repository.appendingPathComponent("Voly/AndroidAgentPayload")])
        XCTAssertEqual(Set(payload.loaders.keys), Set(AndroidAgentPayload.abis))
        // A dex file starts with "dex\n", an ELF file with 0x7F "ELF".
        XCTAssertEqual(try Data(contentsOf: payload.dex).prefix(4), Data("dex\n".utf8))
        for loader in payload.loaders.values {
            XCTAssertEqual(try Data(contentsOf: loader).prefix(4), Data([0x7F, 0x45, 0x4C, 0x46]))
        }
    }
}

final class AndroidIntegrationTests: XCTestCase {
    /// What is running on the fake device; tests change it between refreshes.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var apps: [(package: String, pid: Int32)]
        init(_ apps: [(package: String, pid: Int32)]) { self.apps = apps }
        var value: [(package: String, pid: Int32)] {
            get { lock.lock(); defer { lock.unlock() }; return apps }
            set { lock.lock(); apps = newValue; lock.unlock() }
        }
    }

    private func integration(_ adb: ScriptedAdb) -> AndroidIntegration {
        AndroidIntegration(adb: adb, payload: AndroidFixtures.payload, installer: AndroidFixtures.installer(adb))
    }

    private func refresh(
        _ integration: AndroidIntegration, device: Bool = true, excluding: Set<String> = []
    ) async -> AndroidSnapshot {
        await integration.refresh(wantsDevice: { _ in device }, allowsApp: { !excluding.contains($0) })
    }

    func test_running_debug_builds_get_the_agent_once() async {
        let running = Running([("com.example.app", 4242), ("com.example.store", 5000)])
        let adb = AndroidFixtures.device(running: { running.value }, releaseBuilds: ["com.example.store"])
        let integration = integration(adb)

        let first = await refresh(integration)
        XCTAssertEqual(first.devices.map(\.device.displayName), ["Pixel 8 API 35"])
        XCTAssertEqual(first.devices.first?.apps, [
            AndroidAppStatus(package: "com.example.app", pid: 4242, state: .inspectable),
            AndroidAppStatus(package: "com.example.store", pid: 5000, state: .notDebuggable),
        ])
        XCTAssertEqual(first.agents.map(\.package), ["com.example.app"])

        // Nothing is attached twice, and a release build isn't tried again.
        let attachesBefore = adb.shellCommands.filter { $0.hasPrefix("cmd activity attach-agent") }.count
        let runAsBefore = adb.shellCommands.filter { $0.hasPrefix("run-as com.example.store") }.count
        let second = await refresh(integration)
        XCTAssertEqual(second, first)
        XCTAssertEqual(adb.shellCommands.filter { $0.hasPrefix("cmd activity attach-agent") }.count, attachesBefore)
        XCTAssertEqual(adb.shellCommands.filter { $0.hasPrefix("run-as com.example.store") }.count, runAsBefore)
        XCTAssertEqual(attachesBefore, 1)
    }

    func test_a_relaunched_app_is_a_new_agent_and_the_old_port_is_given_back() async {
        let running = Running([("com.example.app", 4242)])
        let adb = AndroidFixtures.device(running: { running.value })
        let integration = integration(adb)
        _ = await refresh(integration)

        running.value = [("com.example.app", 4300)]
        let after = await refresh(integration)
        XCTAssertEqual(after.agents.map(\.pid), [4300])
        XCTAssertTrue(adb.calls.contains(["-s", "emulator-5554", "forward", "--remove", "tcp:40123"]))

        running.value = []
        let gone = await refresh(integration)
        XCTAssertTrue(gone.agents.isEmpty)
        XCTAssertEqual(gone.devices.first?.apps, [])
    }

    func test_an_agent_whose_forwarded_port_is_gone_is_attached_again() async {
        // As after `adb kill-server`: the app still runs, the way to it doesn't.
        let running = Running([("com.example.app", 4242)])
        let adb = AndroidFixtures.device(running: { running.value }, forwardsLost: true)
        let integration = integration(adb)
        _ = await refresh(integration)
        let again = await refresh(integration)
        XCTAssertEqual(again.agents.map(\.pid), [4242])
        XCTAssertEqual(adb.shellCommands.filter { $0.hasPrefix("cmd activity attach-agent") }.count, 2)
    }

    func test_a_device_that_is_switched_off_is_left_alone() async {
        let running = Running([("com.example.app", 4242)])
        let adb = AndroidFixtures.device(running: { running.value })
        let integration = integration(adb)

        let off = await refresh(integration, device: false)
        XCTAssertEqual(off.devices.first?.isIntegrationEnabled, false)
        XCTAssertTrue(off.agents.isEmpty)
        XCTAssertFalse(adb.shellCommands.contains { $0.hasPrefix("ps ") || $0.hasPrefix("run-as") })

        // Switching it off later lets go of what was attached.
        _ = await refresh(integration)
        let offAgain = await refresh(integration, device: false)
        XCTAssertTrue(offAgain.agents.isEmpty)
        XCTAssertTrue(adb.calls.contains { $0.contains("--remove") })
    }

    func test_an_excluded_app_is_not_touched() async {
        let running = Running([("com.example.app", 4242)])
        let adb = AndroidFixtures.device(running: { running.value })
        let snapshot = await refresh(integration(adb), excluding: ["com.example.app"])
        XCTAssertEqual(snapshot.devices.first?.apps.map(\.state), [.excluded])
        XCTAssertFalse(adb.shellCommands.contains { $0.hasPrefix("run-as") })
    }

    func test_a_failing_attach_is_not_retried_forever() async {
        let running = Running([("com.example.app", 4242)])
        let adb = AndroidFixtures.device(running: { running.value }, attachFails: true)
        let integration = integration(adb)
        for _ in 0..<5 { _ = await refresh(integration) }
        XCTAssertEqual(adb.shellCommands.filter { $0.hasPrefix("cmd activity attach-agent") }.count, 2)
        let snapshot = await refresh(integration)
        guard case .failed? = snapshot.devices.first?.apps.first?.state else { return XCTFail("expected failed") }

        // …until the user asks.
        await integration.retryFailures(serial: "emulator-5554")
        _ = await refresh(integration)
        XCTAssertEqual(adb.shellCommands.filter { $0.hasPrefix("cmd activity attach-agent") }.count, 3)
    }

    func test_no_adb_means_an_error_not_a_crash() async {
        let adb = ScriptedAdb { _ in ScriptedAdb.fail("cannot connect to daemon") }
        let snapshot = await refresh(integration(adb))
        XCTAssertTrue(snapshot.devices.isEmpty)
        XCTAssertNotNil(snapshot.error)
    }

    func test_relaunch_stops_and_starts_the_app() async throws {
        let adb = AndroidFixtures.device(running: { [] })
        try await integration(adb).relaunch(serial: "emulator-5554", package: "com.example.app")
        XCTAssertEqual(adb.shellCommands, [
            "am force-stop com.example.app",
            "monkey -p com.example.app -c android.intent.category.LAUNCHER 1",
        ])
    }

    func test_screenshot_is_the_png_adb_returns() async throws {
        let adb = ScriptedAdb { arguments in
            arguments.contains("screencap")
                ? AdbOutput(exitCode: 0, stdout: AndroidFixtures.onePixelPNG)
                : ScriptedAdb.fail("unexpected")
        }
        let png = try await integration(adb).screenshot(serial: "emulator-5554")
        XCTAssertEqual(png, AndroidFixtures.onePixelPNG)
        XCTAssertEqual(adb.calls, [["-s", "emulator-5554", "exec-out", "screencap", "-p"]])
    }
}
