import SwiftUI

struct PatchProjectFileCommands: Commands {
    @ObservedObject var model: WorkspaceModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Patch") {
                model.requestNewPatch()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!model.canStartNewPatch)

            Divider()

            Button("Save Patch") {
                model.savePatch()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.projectDraft == nil)

            Menu("Load Patch") {
                LoadPatchProjectMenuItems(model: model)
            }

            Menu("Delete Saved Patch") {
                DeleteSavedPatchProjectMenuItems(model: model)
            }

            Divider()

            Button("Import Patch…") {
                model.importPatch()
            }

            Button("Export Patch…") {
                model.exportPatch()
            }
            .disabled(model.projectDraft == nil)
        }

        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}
    }
}

struct LoadPatchProjectMenuItems: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        if model.currentTargetIdentity == nil {
            Text("Analyze a Target First")
        } else if model.loadableSavedPatchProjects.isEmpty {
            Text("No Saved Patches for This Target")
        } else {
            ForEach(model.loadableSavedPatchProjects) { savedProject in
                Button {
                    model.loadPatch(savedProject)
                } label: {
                    Label(
                        savedPatchLabel(savedProject),
                        systemImage: savedPatchLoadSystemImage(savedProject)
                    )
                }
                .help(savedPatchLoadHelp(savedProject))
            }
        }
    }

    private func savedPatchLabel(_ savedProject: SavedPatchProject) -> String {
        let suffix = savedProject.patchCount == 1 ? "patch" : "patches"
        return "\(savedProject.projectName) · \(savedProject.patchCount) \(suffix)"
    }

    private func savedPatchLoadSystemImage(_ savedProject: SavedPatchProject) -> String {
        guard let target = model.currentTargetIdentity else { return "hammer" }
        return savedProject.isExactExecutableMatch(to: target)
            ? "checkmark.circle" : "arrow.triangle.2.circlepath"
    }

    private func savedPatchLoadHelp(_ savedProject: SavedPatchProject) -> String {
        guard let target = model.currentTargetIdentity else {
            return savedProject.targetExecutableName
        }
        let match =
            savedProject.isExactExecutableMatch(to: target)
            ? "Exact executable match"
            : "Same app, different executable build; compatibility will be checked"
        return
            "\(match) · \(savedProject.targetExecutableName) · \(savedProject.patchCount) patch\(savedProject.patchCount == 1 ? "" : "es")"
    }
}

struct DeleteSavedPatchProjectMenuItems: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        if model.savedPatchProjects.isEmpty {
            Text("No Saved Patches")
        } else {
            ForEach(model.savedPatchProjects) { savedProject in
                Button {
                    model.requestDeleteSavedPatch(savedProject)
                } label: {
                    Label(deleteSavedPatchLabel(savedProject), systemImage: "trash")
                }
                .help(
                    "Delete the saved patch for \(savedProject.targetExecutableName), executable \(savedProject.target.executableSHA256.prefix(8))."
                )
            }
        }
    }

    private func deleteSavedPatchLabel(_ savedProject: SavedPatchProject) -> String {
        let suffix = savedProject.patchCount == 1 ? "patch" : "patches"
        return
            "\(savedProject.projectName) · \(savedProject.targetExecutableName) · \(savedProject.patchCount) \(suffix)"
    }
}
