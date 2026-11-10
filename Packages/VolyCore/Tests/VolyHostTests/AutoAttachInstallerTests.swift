import XCTest
@testable import VolyHost

final class AutoAttachInstallerTests: XCTestCase {

    /// Records every shell invocation and returns canned output. Same pattern
    /// as RecordingShell inside SimctlLauncherTests — kept local because the
    /// stubs differ per test.
    final class RecordingShell: ShellExecutor {
        struct Invocation: Equatable {
            let executable: URL
            let arguments: [String]
        }
        nonisolated(unsafe) var invocations: [Invocation] = []
        nonisolated(unsafe) var stubbedStdout: [String: String] = [:]
        nonisolated(unsafe) var stubbedExit: Int32 = 0

        func run(
            executable: URL, arguments: [String], environment: [String: String]?
        ) async throws -> ShellResult {
            invocations.append(.init(executable: executable, arguments: arguments))
            // stub key: "getenv:NAME" returns stdout; anything else returns empty.
            let key = arguments.count >= 2 ? "\(arguments[0]):\(arguments[1])" : arguments.joined(separator: ":")
            let stdout = stubbedStdout[key] ?? ""
            return ShellResult(
                exitCode: stubbedExit,
                stdout: Data(stdout.utf8),
                stderr: Data()
            )
        }
    }

    private let ourPath = "/Applications/Voly.app/Contents/Resources/VolyAgent.dylib"

    func test_currentState_disabled_when_getenv_empty() async throws {
        let shell = RecordingShell()
        shell.stubbedStdout = ["getenv:SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": ""]
        let subject = AutoAttachInstaller(bundledDylibPath: ourPath, shell: shell)
        let state = try await subject.currentState()
        XCTAssertEqual(state, .disabled)
    }

    func test_currentState_enabled_when_getenv_matches_path() async throws {
        let shell = RecordingShell()
        shell.stubbedStdout = ["getenv:SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": "\(ourPath)\n"]
        let subject = AutoAttachInstaller(bundledDylibPath: ourPath, shell: shell)
        let state = try await subject.currentState()
        XCTAssertEqual(state, .enabled(dylibPath: ourPath))
    }

    func test_currentState_foreign_when_getenv_is_other_value() async throws {
        let shell = RecordingShell()
        shell.stubbedStdout = ["getenv:SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": "/some/other.dylib\n"]
        let subject = AutoAttachInstaller(bundledDylibPath: ourPath, shell: shell)
        let state = try await subject.currentState()
        XCTAssertEqual(state, .foreign(currentValue: "/some/other.dylib"))
    }

    func test_ensureInstalled_noop_when_already_enabled() async throws {
        let shell = RecordingShell()
        shell.stubbedStdout = ["getenv:SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": "\(ourPath)\n"]
        let subject = AutoAttachInstaller(bundledDylibPath: ourPath, shell: shell)
        try await subject.ensureInstalled()
        // Only one call: the getenv check. No setenv follow-up.
        XCTAssertEqual(shell.invocations.count, 1)
        XCTAssertEqual(shell.invocations[0].arguments[0], "getenv")
    }

    func test_ensureInstalled_runs_setenv_when_disabled() async throws {
        let shell = RecordingShell()
        shell.stubbedStdout = ["getenv:SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": ""]
        let subject = AutoAttachInstaller(bundledDylibPath: ourPath, shell: shell)
        try await subject.ensureInstalled()
        XCTAssertEqual(shell.invocations.count, 2)
        XCTAssertEqual(shell.invocations[0].arguments[0], "getenv")
        XCTAssertEqual(shell.invocations[1].arguments, [
            "setenv", "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES", ourPath
        ])
    }

    func test_ensureInstalled_overwrites_when_foreign() async throws {
        let shell = RecordingShell()
        shell.stubbedStdout = ["getenv:SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": "/some/other.dylib\n"]
        let subject = AutoAttachInstaller(bundledDylibPath: ourPath, shell: shell)
        try await subject.ensureInstalled()
        XCTAssertEqual(shell.invocations.count, 2)
        XCTAssertEqual(shell.invocations[1].arguments, [
            "setenv", "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES", ourPath
        ])
    }

    func test_uninstall_runs_unsetenv() async throws {
        let shell = RecordingShell()
        let subject = AutoAttachInstaller(bundledDylibPath: ourPath, shell: shell)
        try await subject.uninstall()
        XCTAssertEqual(shell.invocations.count, 1)
        XCTAssertEqual(shell.invocations[0].arguments, [
            "unsetenv", "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"
        ])
    }

    func test_ensureInstalled_propagates_shell_error() async throws {
        final class FailingShell: ShellExecutor {
            struct Boom: Error {}
            func run(executable: URL, arguments: [String], environment: [String: String]?) async throws -> ShellResult {
                throw Boom()
            }
        }
        let subject = AutoAttachInstaller(bundledDylibPath: ourPath, shell: FailingShell())
        do {
            try await subject.ensureInstalled()
            XCTFail("expected throw")
        } catch {
            // success
        }
    }

    // MARK: - legacy cleanup

    func test_removeLegacyInstall_unsets_a_value_this_voly_set() async throws {
        let shell = RecordingShell()
        shell.stubbedStdout = ["getenv:SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": ourPath + "\n"]
        let removed = try await AutoAttachInstaller(bundledDylibPath: ourPath, shell: shell).removeLegacyInstall()
        XCTAssertTrue(removed)
        XCTAssertEqual(shell.invocations.last?.arguments, ["unsetenv", "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"])
    }

    func test_removeLegacyInstall_unsets_a_value_from_another_voly_location() async throws {
        let shell = RecordingShell()
        shell.stubbedStdout = ["getenv:SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": "/Users/x/Old/Voly.app/Contents/Resources/VolyAgent.dylib\n"]
        let removed = try await AutoAttachInstaller(bundledDylibPath: ourPath, shell: shell).removeLegacyInstall()
        XCTAssertTrue(removed)
    }

    func test_removeLegacyInstall_leaves_other_tools_alone() async throws {
        let shell = RecordingShell()
        shell.stubbedStdout = ["getenv:SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": "/opt/other/libTool.dylib\n"]
        let removed = try await AutoAttachInstaller(bundledDylibPath: ourPath, shell: shell).removeLegacyInstall()
        XCTAssertFalse(removed)
        XCTAssertFalse(shell.invocations.contains { $0.arguments.first == "unsetenv" })
    }

    func test_removeLegacyInstall_is_a_no_op_when_nothing_is_set() async throws {
        let shell = RecordingShell()
        let removed = try await AutoAttachInstaller(bundledDylibPath: ourPath, shell: shell).removeLegacyInstall()
        XCTAssertFalse(removed)
        XCTAssertEqual(shell.invocations.map(\.arguments.first), ["getenv"])
    }
}
