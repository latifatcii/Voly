import XCTest
@testable import VolyHost

final class IntegrationPreferenceTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "voly-preference-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func test_every_simulator_is_wanted_by_default() {
        let preference = IntegrationPreference(defaults: freshDefaults())
        XCTAssertTrue(preference.allSimulators)
        XCTAssertTrue(preference.wants("ANY"))
        XCTAssertTrue(preference.wants("OTHER"))
    }

    func test_one_simulator_can_be_opted_out_of_all() {
        var preference = IntegrationPreference()
        preference.set(false, for: "A")
        XCTAssertFalse(preference.wants("A"))
        XCTAssertTrue(preference.wants("B"))
        preference.set(true, for: "A")
        XCTAssertTrue(preference.wants("A"))
    }

    func test_manual_mode_wants_only_hand_picked_simulators() {
        var preference = IntegrationPreference(allSimulators: false)
        XCTAssertFalse(preference.wants("A"))
        preference.set(true, for: "A")
        XCTAssertTrue(preference.wants("A"))
        XCTAssertFalse(preference.wants("B"))
    }

    func test_turning_all_off_keeps_what_is_integrated_right_now() {
        var preference = IntegrationPreference()
        preference.set(false, for: "OPTED-OUT")
        preference.setAllSimulators(false, currentlyActive: ["A", "B"])
        XCTAssertTrue(preference.wants("A"))
        XCTAssertTrue(preference.wants("B"))
        XCTAssertFalse(preference.wants("OPTED-OUT"))
        XCTAssertFalse(preference.wants("BOOTED-LATER"))
    }

    func test_turning_all_back_on_respects_earlier_opt_outs() {
        var preference = IntegrationPreference()
        preference.set(false, for: "A")
        preference.setAllSimulators(false, currentlyActive: ["B"])
        preference.setAllSimulators(true, currentlyActive: ["B"])
        XCTAssertFalse(preference.wants("A"))
        XCTAssertTrue(preference.wants("B"))
        XCTAssertTrue(preference.wants("NEW"))
    }

    func test_round_trips_through_user_defaults() {
        let defaults = freshDefaults()
        var preference = IntegrationPreference()
        preference.set(false, for: "A")
        preference.setAllSimulators(false, currentlyActive: ["B"])
        preference.save(to: defaults)
        XCTAssertEqual(IntegrationPreference(defaults: defaults), preference)
    }

    func test_a_selection_from_before_all_was_the_default_is_not_lost() {
        // Only the hand-picked list exists on disk; "all" was never chosen.
        let defaults = freshDefaults()
        defaults.set(["A"], forKey: IntegrationPreference.enabledKey)
        let preference = IntegrationPreference(defaults: defaults)
        XCTAssertTrue(preference.wants("A"))
        XCTAssertTrue(preference.wants("B"), "the new default applies")
        XCTAssertEqual(preference.enabled, ["A"])
    }
}
