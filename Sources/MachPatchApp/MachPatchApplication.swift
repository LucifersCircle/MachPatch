import SwiftUI

@main
struct MachPatchApplication: App {
    @StateObject private var model = WorkspaceModel()

    var body: some Scene {
        WindowGroup {
            MachPatchRootView(model: model)
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            PatchProjectFileCommands(model: model)
        }
    }
}
