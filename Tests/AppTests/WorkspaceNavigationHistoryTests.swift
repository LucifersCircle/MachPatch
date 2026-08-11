import XCTest

@testable import MachPatchApp

final class WorkspaceNavigationHistoryTests: XCTestCase {
    func testVisitBackForwardAndDuplicateSuppression() {
        let target = WorkspaceNavigationLocation(destination: .target)
        let classOnly = WorkspaceNavigationLocation(
            destination: .objectiveCClass("class-app")
        )
        let method = WorkspaceNavigationLocation(
            destination: .objectiveCClass("class-app"),
            methodID: "method-feature"
        )
        let build = WorkspaceNavigationLocation(destination: .build)
        var history = WorkspaceNavigationHistory()

        history.reset(to: target)
        history.visit(classOnly)
        history.visit(classOnly)
        history.visit(method)
        history.visit(build)

        XCTAssertEqual(history.backStack, [target, classOnly, method])
        XCTAssertEqual(history.current, build)
        XCTAssertFalse(history.canGoForward)

        XCTAssertEqual(history.goBack(), method)
        XCTAssertEqual(history.goBack(), classOnly)
        XCTAssertEqual(history.goForward(), method)
        XCTAssertTrue(history.canGoBack)
        XCTAssertTrue(history.canGoForward)
    }

    func testNewVisitAfterBackClearsForwardHistory() {
        let target = WorkspaceNavigationLocation(destination: .target)
        let firstClass = WorkspaceNavigationLocation(
            destination: .objectiveCClass("class-one")
        )
        let secondClass = WorkspaceNavigationLocation(
            destination: .objectiveCClass("class-two")
        )
        let build = WorkspaceNavigationLocation(destination: .build)
        var history = WorkspaceNavigationHistory()

        history.reset(to: target)
        history.visit(firstClass)
        history.visit(secondClass)
        XCTAssertEqual(history.goBack(), firstClass)

        history.visit(build)

        XCTAssertEqual(history.current, build)
        XCTAssertEqual(history.backStack, [target, firstClass])
        XCTAssertFalse(history.canGoForward)
    }

    func testNonClassLocationsDiscardMethodIdentity() {
        XCTAssertNil(
            WorkspaceNavigationLocation(destination: .target, methodID: "ignored").methodID
        )
        XCTAssertNil(
            WorkspaceNavigationLocation(destination: .build, methodID: "ignored").methodID
        )
    }
}
