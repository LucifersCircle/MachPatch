import XCTest

@testable import MachPatchCore

final class MachPatchVersionTests: XCTestCase {
    func testCurrentDevelopmentVersionIsExposed() {
        XCTAssertEqual(MachPatchVersion.current, "0.1.0-dev")
    }

    func testResolvedTargetRoundTripsThroughJSON() throws {
        let target = ResolvedTarget(
            sourceType: .ipa,
            sourcePath: "/tmp/Fixture.ipa",
            bundlePath: "/tmp/Payload/Fixture.app",
            bundleIdentifier: "com.example.fixture",
            displayName: "Fixture",
            minimumOSVersion: "15.0",
            supportedPlatforms: ["iPhoneOS"],
            executableName: "Fixture",
            executablePath: "/tmp/Payload/Fixture.app/Fixture",
            sha256: String(repeating: "a", count: 64)
        )

        let data = try JSONEncoder().encode(target)
        XCTAssertEqual(try JSONDecoder().decode(ResolvedTarget.self, from: data), target)
    }
}
