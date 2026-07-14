import XCTest

@testable import MachPatchCore

final class MachPatchVersionTests: XCTestCase {
    func testCurrentDevelopmentVersionIsExposed() {
        XCTAssertEqual(MachPatchVersion.current, "0.1.0-dev")
    }
}
