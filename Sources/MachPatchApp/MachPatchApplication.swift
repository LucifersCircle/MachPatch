import SwiftUI

@main
struct MachPatchApplication: App {
    var body: some Scene {
        WindowGroup {
            MachPatchRootView()
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)
    }
}
