import XCTest

@testable import MachPatchAnalyzer

final class AnalyzerModuleTests: XCTestCase {
    func testModuleIsAvailable() {
        XCTAssertNotNil(MachPatchAnalyzer.self)
    }
}
