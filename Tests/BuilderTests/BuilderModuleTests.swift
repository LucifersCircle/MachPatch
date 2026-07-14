import XCTest

@testable import MachPatchBuilder

final class BuilderModuleTests: XCTestCase {
    func testModuleIsAvailable() {
        XCTAssertNotNil(MachPatchBuilder.self)
    }
}
