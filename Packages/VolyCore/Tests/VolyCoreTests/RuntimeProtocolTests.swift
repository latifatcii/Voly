import XCTest
@testable import VolyModels
@testable import VolyProtocol

final class RuntimeProtocolTests: XCTestCase {
    private func roundTrip(_ command: Command) throws -> Command {
        let envelope = try Framing.encodeCommand(command, id: 7)
        return try Framing.decodeCommand(try Framing.decodeEnvelope(try Framing.encodeEnvelope(envelope)))
    }

    private func roundTrip(_ response: Response) throws -> Response {
        let envelope = try Framing.encodeResponse(response, id: 7)
        return try Framing.decodeResponse(try Framing.decodeEnvelope(try Framing.encodeEnvelope(envelope)))
    }

    func test_handshake_carries_the_session_token() throws {
        let request = HandshakeRequest(clientName: "Voly.app", clientVersion: "0.1.0", authToken: "abc123")
        guard case .handshake(let decoded) = try roundTrip(.handshake(request)) else { return XCTFail() }
        XCTAssertEqual(decoded.authToken, "abc123")
    }

    func test_handshake_from_a_client_without_auth_still_decodes() throws {
        let legacy = #"{"clientName":"Voly.app","clientVersion":"0.1.0","protocolVersion":1}"#
        let request = try Framing.decoder.decode(HandshakeRequest.self, from: Data(legacy.utf8))
        XCTAssertNil(request.authToken)
    }

    func test_handshake_reply_from_an_older_agent_still_decodes() throws {
        let legacy = #"{"protocolVersion":1,"sessionID":"5E87EE9E-7EFC-4CAA-AFC7-DFA050460E44","agentName":"VolyAgent","agentVersion":"0.1.0","bundleIdentifier":"com.x","processName":"X"}"#
        let accepted = try Framing.decoder.decode(HandshakeAccepted.self, from: Data(legacy.utf8))
        XCTAssertNil(accepted.pid)
        XCTAssertNil(accepted.simulatorUDID)
        XCTAssertNil(accepted.capabilities)
    }

    func test_handshake_reply_identifies_the_process_and_its_capabilities() throws {
        let capabilities = AgentCapabilities(
            injectionMode: .injected, previewHost: false, localization: true,
            screenshots: true, navigation: true, sourceSymbols: true
        )
        let accepted = HandshakeAccepted(
            protocolVersion: 1, sessionID: UUID(), agentName: "VolyAgent", agentVersion: "0.1.0",
            bundleIdentifier: "com.x", processName: "X", pid: 4242, simulatorUDID: "SIM", capabilities: capabilities
        )
        guard case .handshakeAccepted(let decoded) = try roundTrip(.handshakeAccepted(accepted)) else { return XCTFail() }
        XCTAssertEqual(decoded.pid, 4242)
        XCTAssertEqual(decoded.simulatorUDID, "SIM")
        XCTAssertEqual(decoded.capabilities, capabilities)
    }

    func test_localization_commands_round_trip() throws {
        let request = LocalizationOverrideRequest(language: "ar", layoutDirectionMode: .leftToRight, refreshUI: true)
        guard case .setLocalizationOverride(let decoded) = try roundTrip(.setLocalizationOverride(request)) else { return XCTFail() }
        XCTAssertEqual(decoded, request)

        let reset = LocalizationOverrideRequest(language: nil, layoutDirectionMode: .system, refreshUI: false)
        guard case .setLocalizationOverride(let decodedReset) = try roundTrip(.setLocalizationOverride(reset)) else { return XCTFail() }
        XCTAssertNil(decodedReset.language)

        let state = LocalizationState(
            available: [.init(code: "ar", displayName: "Arabic", isRightToLeft: true)],
            developmentLanguage: "en", systemLanguage: "en", activeOverride: "ar",
            layoutDirectionMode: .followLanguage, isLayoutRightToLeft: true,
            interceptedLookups: ["localizedStringForKey:value:table:"],
            lastRefresh: .init(updated: 3, unresolved: 2, ambiguous: 1, notes: ["n"])
        )
        guard case .localization(let decodedState) = try roundTrip(.localization(state)) else { return XCTFail() }
        XCTAssertEqual(decodedState, state)
    }

    func test_screenshot_payload_survives_the_envelope_byte_for_byte() throws {
        let png = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let image = ScreenshotImage(png: png, pixelWidth: 1179, pixelHeight: 2556, scale: 3, orientation: .landscapeLeft)
        guard case .screenshot(let decoded) = try roundTrip(.screenshot(image)) else { return XCTFail() }
        XCTAssertEqual(decoded, image)
        guard case .captureScreenshot(.view(let id)) = try roundTrip(.captureScreenshot(.view(99))) else { return XCTFail() }
        XCTAssertEqual(id, 99)
        guard case .captureScreenshot(.application) = try roundTrip(.captureScreenshot(.application)) else { return XCTFail() }
    }

    func test_navigation_round_trip_and_availability() throws {
        for action in NavigationAction.allCases {
            guard case .navigate(let decoded) = try roundTrip(.navigate(action)) else { return XCTFail() }
            XCTAssertEqual(decoded, action)
        }
        let state = NavigationState(
            canDismiss: true, canPop: false, canPopToRoot: false,
            unavailableReasons: ["pop": "Already at the root screen."],
            topViewController: "HomeVC", navigationStackDepth: 1, isTransitioning: false
        )
        XCTAssertTrue(state.isAvailable(.dismiss))
        XCTAssertFalse(state.isAvailable(.pop))
        XCTAssertFalse(state.isAvailable(.popToRoot))
        let result = NavigationResult(action: .pop, performed: false, message: "Already at the root screen.", state: state)
        guard case .navigationResult(let decoded) = try roundTrip(.navigationResult(result)) else { return XCTFail() }
        XCTAssertEqual(decoded, result)
        XCTAssertFalse(NavigationAction.allCases.contains { NavigationState.unavailable.isAvailable($0) })
    }

    func test_source_info_carries_candidates_and_tolerates_their_absence() throws {
        let candidate = SourceCandidate(
            role: .viewController, className: "HomeVC", moduleName: "App", runtimeName: "App.HomeVC",
            imagePath: "/sim/App.debug.dylib", imageUUID: "6DB5",
            probes: [.init(selector: "viewDidLoad", imageOffset: 0x3c1c8)]
        )
        let info = SourceInfo(className: "UILabel", moduleName: nil, dsymUUID: nil, guessedRelativePath: nil, candidates: [candidate])
        guard case .sourceInfo(let decoded) = try roundTrip(.sourceInfo(info)) else { return XCTFail() }
        XCTAssertEqual(decoded.candidates, [candidate])

        let legacy = #"{"className":"UILabel"}"#
        XCTAssertNil(try Framing.decoder.decode(SourceInfo.self, from: Data(legacy.utf8)).candidates)
    }

    func test_new_errors_round_trip_with_readable_text() throws {
        for error in [InspectorError.unauthorized, .unavailable("The selected view has no size to capture.")] {
            guard case .error(let decoded) = try roundTrip(.error(error)) else { return XCTFail() }
            XCTAssertEqual(decoded, error)
            XCTAssertFalse(decoded.humanDescription.isEmpty)
        }
    }
}
