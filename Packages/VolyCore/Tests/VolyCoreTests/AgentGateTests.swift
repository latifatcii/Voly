import XCTest
@testable import VolyAgent

final class AgentGateTests: XCTestCase {
    func test_sdk_gate_requires_env_var_or_flag() {
        let empty: [String: String] = [:]
        XCTAssertFalse(AgentGate.isSDKEnabled(environment: empty, args: []))

        XCTAssertTrue(
            AgentGate.isSDKEnabled(
                environment: ["VOLY_AGENT_ENABLED": "1"], args: []
            )
        )

        XCTAssertTrue(
            AgentGate.isSDKEnabled(
                environment: empty, args: ["--voly-agent-enabled"]
            )
        )
    }

    func test_injection_gate_is_on_unless_disabled() {
        XCTAssertTrue(AgentGate.isInjectionEnabled(environment: [:]))
        XCTAssertTrue(
            AgentGate.isInjectionEnabled(environment: ["FOO": "bar"])
        )
        XCTAssertFalse(
            AgentGate.isInjectionEnabled(environment: ["VOLY_DISABLE": "1"])
        )
    }
}
