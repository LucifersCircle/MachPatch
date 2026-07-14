import XCTest

@testable import MachPatchAnalyzer

final class ZipArchiveValidatorTests: XCTestCase {
    func testAcceptsNormalIPAEntryPaths() {
        XCTAssertNoThrow(
            try ZipArchiveValidator.validateEntryPath("Payload/Fixture.app/Fixture")
        )
        XCTAssertNoThrow(
            try ZipArchiveValidator.validateEntryPath("Payload/Fixture.app/Frameworks/")
        )
    }

    func testRejectsTraversalAbsoluteAndBackslashPaths() {
        for path in [
            "../escape",
            "Payload/../escape",
            "/absolute/path",
            "C:/drive/path",
            "Payload\\escape",
            "Payload//escape",
        ] {
            XCTAssertThrowsError(try ZipArchiveValidator.validateEntryPath(path), path)
        }
    }
}
