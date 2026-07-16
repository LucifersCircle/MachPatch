import SwiftUI

struct PatchProjectFileCommands: Commands {
    @ObservedObject var model: WorkspaceModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Target…") {
                model.chooseTarget()
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

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

            if let completedExport = model.shareableArtifact(for: .patchProject) {
                ShareLink(item: completedExport.url) {
                    Text("Share Patch…")
                }
            }
        }

        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}
    }
}

struct PatchBuildCommands: Commands {
    @ObservedObject var model: WorkspaceModel

    var body: some Commands {
        CommandMenu("Build") {
            PatchBuildActionMenuItems(model: model, includesKeyboardShortcuts: true)
        }
    }
}

struct PatchBuildActionMenuItems: View {
    @ObservedObject var model: WorkspaceModel
    var includesKeyboardShortcuts = false

    var body: some View {
        Button(model.buildState.artifact == nil ? "Build Dylib" : "Rebuild Dylib") {
            model.buildDylib()
        }
        .keyboardShortcut(
            includesKeyboardShortcuts ? KeyboardShortcut("b", modifiers: .command) : nil
        )
        .disabled(!model.canBuild)

        Divider()

        Button("Export Dylib…") {
            model.exportDylib()
        }
        .keyboardShortcut(
            includesKeyboardShortcuts
                ? KeyboardShortcut("e", modifiers: [.command, .shift]) : nil
        )
        .disabled(!model.canExportDylib)

        if let completedExport = model.shareableArtifact(for: .dylib) {
            ShareLink(item: completedExport.url) {
                Label("Share Dylib…", systemImage: "square.and.arrow.up")
            }
        }

        Divider()

        Button("Export Source Bundle (.zip)…") {
            model.exportSourceBundle()
        }
        .disabled(!model.canExportSourceBundle)

        if let completedExport = model.shareableArtifact(for: .sourceBundle) {
            ShareLink(item: completedExport.url) {
                Label("Share Source Bundle…", systemImage: "square.and.arrow.up")
            }
        }

        Button("Export Debian Package (.deb)…") {
            model.exportDebianPackage()
        }
        .disabled(!model.canExportDebianPackage)

        if let completedExport = model.shareableArtifact(for: .debianPackage) {
            ShareLink(item: completedExport.url) {
                Label("Share Debian Package…", systemImage: "square.and.arrow.up")
            }
        }
    }
}

struct PatchProjectActionMenuItems: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        Button {
            model.requestNewPatch()
        } label: {
            Label("New Patch", systemImage: "doc.badge.plus")
        }
        .disabled(!model.canStartNewPatch)

        Divider()

        Button {
            model.savePatch()
        } label: {
            Label("Save Patch", systemImage: "tray.and.arrow.down.fill")
        }
        .disabled(model.projectDraft == nil)

        Menu {
            LoadPatchProjectMenuItems(model: model)
        } label: {
            Label("Load Patch", systemImage: "tray.full")
        }

        Menu {
            DeleteSavedPatchProjectMenuItems(model: model)
        } label: {
            Label("Delete Saved Patch", systemImage: "trash")
        }

        Divider()

        Button {
            model.importPatch()
        } label: {
            Label("Import Patch…", systemImage: "square.and.arrow.down.on.square")
        }

        Button {
            model.exportPatch()
        } label: {
            Label("Export Patch…", systemImage: "square.and.arrow.up")
        }
        .disabled(model.projectDraft == nil)

        if let completedExport = model.shareableArtifact(for: .patchProject) {
            ShareLink(item: completedExport.url) {
                Label("Share Patch…", systemImage: "square.and.arrow.up")
            }
        }

        Divider()
        PatchBuildActionMenuItems(model: model)
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
