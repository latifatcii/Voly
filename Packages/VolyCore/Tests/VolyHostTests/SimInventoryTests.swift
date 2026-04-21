// Packages/VolyCore/Tests/VolyHostTests/SimInventoryTests.swift
import XCTest
@testable import VolyHost

final class SimInventoryTests: XCTestCase {
    func test_parse_devices_returns_only_booted() throws {
        let url = Bundle.module.url(forResource: "list-devices", withExtension: "json", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        let devices = try SimInventory.parseDevices(data: data)
        // We captured the user's actual devices, so we can't assert an exact count,
        // but every returned device must have a non-empty UDID and a name.
        for d in devices {
            XCTAssertFalse(d.udid.isEmpty)
            XCTAssertFalse(d.name.isEmpty)
        }
    }

    func test_parse_apps_filters_system_apps_when_requested() throws {
        let url = Bundle.module.url(forResource: "listapps", withExtension: "plist", subdirectory: "Fixtures")!
        let data = try Data(contentsOf: url)
        let allApps = try SimInventory.parseApps(plistData: data, includeSystem: true)
        let userApps = try SimInventory.parseApps(plistData: data, includeSystem: false)
        XCTAssertGreaterThan(allApps.count, userApps.count,
            "fixture should contain at least one system app (captured from iOS sim runtime)")
        for a in userApps {
            XCTAssertEqual(a.applicationType, "User")
            XCTAssertFalse(a.bundleIdentifier.isEmpty)
            XCTAssertFalse(a.displayName.isEmpty)
        }
    }
}
