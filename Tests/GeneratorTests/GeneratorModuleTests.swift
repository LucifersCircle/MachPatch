import XCTest

@testable import MachPatchGenerator

final class GeneratorModuleTests: XCTestCase {
    func testModuleIsAvailable() {
        XCTAssertNotNil(MachPatchGenerator.self)
    }
}
