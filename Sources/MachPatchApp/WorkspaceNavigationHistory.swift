struct WorkspaceNavigationLocation: Equatable {
    let destination: WorkspaceNavigation
    let methodID: String?

    init(destination: WorkspaceNavigation, methodID: String? = nil) {
        self.destination = destination
        if case .objectiveCClass = destination {
            self.methodID = methodID
        } else {
            self.methodID = nil
        }
    }
}

struct WorkspaceNavigationHistory: Equatable {
    private(set) var backStack: [WorkspaceNavigationLocation] = []
    private(set) var current: WorkspaceNavigationLocation?
    private(set) var forwardStack: [WorkspaceNavigationLocation] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    mutating func reset(to location: WorkspaceNavigationLocation?) {
        backStack = []
        current = location
        forwardStack = []
    }

    mutating func visit(_ location: WorkspaceNavigationLocation) {
        guard current != location else { return }
        if let current {
            backStack.append(current)
        }
        current = location
        forwardStack = []
    }

    mutating func goBack() -> WorkspaceNavigationLocation? {
        guard let destination = backStack.popLast() else { return nil }
        if let current {
            forwardStack.append(current)
        }
        current = destination
        return destination
    }

    mutating func goForward() -> WorkspaceNavigationLocation? {
        guard let destination = forwardStack.popLast() else { return nil }
        if let current {
            backStack.append(current)
        }
        current = destination
        return destination
    }
}
