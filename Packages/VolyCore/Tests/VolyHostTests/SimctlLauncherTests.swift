import XCTest
@testable import VolyHost

final class SimctlLauncherTests: XCTestCase {
    final class RecordingShell: ShellExecutor {
        struct Invocation {
            let executable: URL
            let arguments: [String]
            let environment: [String: String]?
        }
        nonisolated(unsafe) var invocations: [Invocation] = []
        nonisolated(unsafe) var stubbedExit: Int32 = 0
        nonisolated(unsafe) var stubbedStdout: String = "com.test.App: 12345\n"
        nonisolated(unsafe) var stubbedStderr: String = ""

        func run(executable: URL, arguments: [String], environment: [String: String]?) async throws -> ShellResult {
            invocations.append(.init(executable: executable, arguments: arguments, environment: environment))
            return ShellResult(
                exitCode: stubbedExit,
                stdout: Data(stubbedStdout.utf8),
                stderr: Data(stubbedStderr.utf8)
            )
        }
    }

    func test_launch_sets_SIMCTL_CHILD_DYLD_INSERT_LIBRARIES_in_environment() async throws {
        let shell = RecordingShell()
        let launcher = SimctlLauncher(shell: shell)
        _ = try await launcher.launch(
            deviceUDID: "UDID-1",
            bundleIdentifier: "com.test.App",
            dylibPath: URL(fileURLWithPath: "/a/b/VolyAgent.dylib")
        )

        XCTAssertEqual(shell.invocations.count, 1)
        let inv = shell.invocations[0]
        XCTAssertEqual(inv.executable.path, "/usr/bin/xcrun")
        XCTAssertEqual(inv.arguments, [
            "simctl", "launch", "--terminate-running-process", "UDID-1", "com.test.App"
        ])
        XCTAssertEqual(inv.environment?["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"], "/a/b/VolyAgent.dylib")
    }

    func test_launch_parses_pid_from_stdout() async throws {
        let shell = RecordingShell()
        shell.stubbedStdout = "com.test.App: 77777\n"
        let launcher = SimctlLauncher(shell: shell)
        let result = try await launcher.launch(
            deviceUDID: "UDID-1",
            bundleIdentifier: "com.test.App",
            dylibPath: URL(fileURLWithPath: "/a/b/VolyAgent.dylib")
        )
        XCTAssertEqual(result.pid, 77777)
        XCTAssertEqual(result.bundleIdentifier, "com.test.App")
    }

    func test_launch_throws_on_nonzero_exit() async throws {
        let shell = RecordingShell()
        shell.stubbedExit = 1
        shell.stubbedStderr = "nope"
        let launcher = SimctlLauncher(shell: shell)
        do {
            _ = try await launcher.launch(
                deviceUDID: "U", bundleIdentifier: "b",
                dylibPath: URL(fileURLWithPath: "/d")
            )
            XCTFail("expected throw")
        } catch SimctlLauncher.LauncherError.launchFailed(let code, let err) {
            XCTAssertEqual(code, 1)
            XCTAssertEqual(err, "nope")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
