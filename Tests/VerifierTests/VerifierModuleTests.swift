import XCTest

@testable import MachPatchVerifier

final class VerifierModuleTests: XCTestCase {
    func testModuleIsAvailable() {
        XCTAssertNotNil(MachPatchVerifier.self)
    }
}
