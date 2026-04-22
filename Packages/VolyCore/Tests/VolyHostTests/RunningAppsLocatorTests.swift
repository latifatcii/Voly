import XCTest
@testable import VolyHost

final class RunningAppsLocatorTests: XCTestCase {

    func test_parse_extracts_user_apps_and_drops_apple_prefixes() {
        let output = """
        7375\t0\tUIKitApplication:com.apple.Spotlight[0ab1][rb-legacy]
        7354\t0\tUIKitApplication:com.apple.chrono.WidgetRenderer-Default[c78b][rb-legacy]
        7875\t0\tUIKitApplication:com.apple.mobilecal[8844][rb-legacy]
        9418\t0\tUIKitApplication:com.latifatci.VolySampleApp[7805][rb-legacy]
        """
        let apps = RunningAppsLocator.parse(launchctlList: output)
        XCTAssertEqual(apps, [RunningApp(pid: 9418, bundleIdentifier: "com.latifatci.VolySampleApp")])
    }

    func test_parse_skips_non_uikit_lines() {
        let output = """
        -\t0\tcom.apple.SomeDaemon
        1234\t0\tUIKitApplication:com.user.App[abcd][rb-legacy]
        """
        let apps = RunningAppsLocator.parse(launchctlList: output)
        XCTAssertEqual(apps, [RunningApp(pid: 1234, bundleIdentifier: "com.user.App")])
    }

    func test_parse_handles_empty_output() {
        XCTAssertEqual(RunningAppsLocator.parse(launchctlList: ""), [])
    }

    func test_parse_returns_multiple_user_apps() {
        let output = """
        111\t0\tUIKitApplication:com.example.A[aa][rb-legacy]
        222\t0\tUIKitApplication:com.example.B[bb][rb-legacy]
        """
        XCTAssertEqual(
            RunningAppsLocator.parse(launchctlList: output),
            [
                RunningApp(pid: 111, bundleIdentifier: "com.example.A"),
                RunningApp(pid: 222, bundleIdentifier: "com.example.B"),
            ]
        )
    }

    func test_listRunningUserApps_invokes_simctl_spawn_launchctl_list() async throws {
        final class RecordingShell: ShellExecutor {
            struct Invocation: Equatable {
                let executable: URL
                let arguments: [String]
            }
            nonisolated(unsafe) var invocations: [Invocation] = []
            func run(executable: URL, arguments: [String], environment: [String: String]?) async throws -> ShellResult {
                invocations.append(.init(executable: executable, arguments: arguments))
                let stdout = "9418\t0\tUIKitApplication:com.user.App[aa][rb-legacy]\n"
                return ShellResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data())
            }
        }
        let shell = RecordingShell()
        let locator = RunningAppsLocator(shell: shell)
        let apps = try await locator.listRunningUserApps(deviceUDID: "UDID-1")
        XCTAssertEqual(apps, [RunningApp(pid: 9418, bundleIdentifier: "com.user.App")])
        XCTAssertEqual(shell.invocations.count, 1)
        XCTAssertEqual(shell.invocations[0].executable.path, "/usr/bin/xcrun")
        XCTAssertEqual(shell.invocations[0].arguments, [
            "simctl", "spawn", "UDID-1", "launchctl", "list"
        ])
    }
}
