import SwiftUI
import UniformTypeIdentifiers

struct MachPatchRootView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        NavigationSplitView {
            TargetSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            WorkspaceDetail(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 620)
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let inputURL = urls.first {
                model.openTarget(at: inputURL)
            }
        }
        .fileImporter(
            isPresented: $model.isProjectImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let projectURL = urls.first {
                model.openProject(at: projectURL)
            }
        }
        .fileExporter(
            isPresented: $model.isProjectExporterPresented,
            document: model.projectDocument,
            contentType: .json,
            defaultFilename: model.defaultProjectFilename,
            onCompletion: model.handleProjectExport
        )
        .fileExporter(
            isPresented: $model.isDylibExporterPresented,
            document: model.dylibExportDocument,
            contentType: .machPatchDynamicLibrary,
            defaultFilename: model.defaultDylibFilename,
            onCompletion: model.handleDylibExport
        )
        .fileExporter(
            isPresented: $model.isSourceBundleExporterPresented,
            document: model.sourceBundleExportDocument,
            contentType: .zip,
            defaultFilename: model.defaultSourceBundleFilename,
            onCompletion: model.handleSourceBundleExport
        )
        .fileExporter(
            isPresented: $model.isDebianPackageExporterPresented,
            document: model.debianPackageExportDocument,
            contentType: .machPatchDebianPackage,
            defaultFilename: model.defaultDebianPackageFilename,
            onCompletion: model.handleDebianPackageExport
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let inputURL = urls.first else { return false }
            model.openTarget(at: inputURL)
            return true
        } isTargeted: { isTargeted in
            model.setDropTargeted(isTargeted)
        }
        .overlay {
            if model.isDropTargeted {
                DropTargetOverlay()
                    .allowsHitTesting(false)
            }
        }
        .alert(item: $model.workspaceAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .modifier(DeleteSavedPatchConfirmation(model: model))
        .modifier(DeletePatchConfirmation(model: model))
        .modifier(UnsavedChangesConfirmation(model: model))
        .modifier(TargetChangedConfirmation(model: model))
    }

}

private struct DeletePatchConfirmation: ViewModifier {
    @ObservedObject var model: WorkspaceModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete Patch?",
            isPresented: Binding(
                get: { model.pendingPatchDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        model.cancelDeletePatch()
                    }
                }
            ),
            presenting: model.pendingPatchDeletion
        ) { patch in
            Button("Delete Patch", role: .destructive) {
                model.confirmDeletePatch()
            }
            Button("Cancel", role: .cancel) {
                model.cancelDeletePatch()
            }
        } message: { patch in
            let marker = patch.methodKind == .instance ? "−" : "+"
            Text(
                "This permanently removes \(marker)[\(patch.className) \(patch.selector)] from the current project."
            )
        }
    }
}

private struct UnsavedChangesConfirmation: ViewModifier {
    @ObservedObject var model: WorkspaceModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            model.pendingWorkspaceTransitionHasUnsavedChanges
                ? "Save Changes Before Continuing?"
                : "Replace Current Patch Project?",
            isPresented: Binding(
                get: { model.pendingWorkspaceTransition != nil },
                set: { isPresented in
                    if !isPresented {
                        model.cancelPendingWorkspaceTransition()
                    }
                }
            ),
            presenting: model.pendingWorkspaceTransition
        ) { transition in
            if model.pendingWorkspaceTransitionHasUnsavedChanges {
                Button("Save and Continue") {
                    model.saveAndPerformPendingWorkspaceTransition()
                }
            }
            Button(
                model.pendingWorkspaceTransitionHasUnsavedChanges
                    ? "Discard Changes"
                    : transition.continueActionTitle,
                role: .destructive
            ) {
                model.discardAndPerformPendingWorkspaceTransition()
            }
            Button("Cancel", role: .cancel) {
                model.cancelPendingWorkspaceTransition()
            }
        } message: { transition in
            if model.pendingWorkspaceTransitionHasUnsavedChanges {
                Text(
                    "The current project has unsaved changes. \(transition.confirmationMessage)"
                )
            } else {
                Text(
                    "\(transition.confirmationMessage) The saved project can be loaded again later."
                )
            }
        }
    }
}

private struct DeleteSavedPatchConfirmation: ViewModifier {
    @ObservedObject var model: WorkspaceModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete Saved Patch?",
            isPresented: Binding(
                get: { model.pendingSavedPatchDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        model.cancelDeleteSavedPatch()
                    }
                }
            ),
            presenting: model.pendingSavedPatchDeletion
        ) { savedProject in
            Button("Delete \(savedProject.projectName)", role: .destructive) {
                model.confirmDeleteSavedPatch()
            }
            Button("Cancel", role: .cancel) {
                model.cancelDeleteSavedPatch()
            }
        } message: { savedProject in
            Text(
                "This permanently removes the saved project for \(savedProject.targetExecutableName), executable \(savedProject.target.executableSHA256.prefix(8)), from MachPatch’s private library."
            )
        }
    }
}

private struct TargetChangedConfirmation: ViewModifier {
    @ObservedObject var model: WorkspaceModel

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "The Target Has Changed",
            isPresented: Binding(
                get: { model.pendingProjectImport != nil },
                set: { isPresented in
                    if !isPresented {
                        model.cancelPendingProjectImport()
                    }
                }
            ),
            presenting: model.pendingProjectImport
        ) { _ in
            Button("Continue Without Updating Identity") {
                model.resolvePendingProjectImport(retarget: false)
            }
            Button("Retarget Project to This Executable") {
                model.resolvePendingProjectImport(retarget: true)
            }
            Button("Cancel", role: .cancel) {
                model.cancelPendingProjectImport()
            }
        } message: { pending in
            Text(pending.warnings.map(\.message).joined(separator: "\n"))
        }
    }
}

private struct WorkspaceDetail: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        Group {
            switch model.phase {
            case .empty:
                EmptyWorkspaceView(openTarget: model.chooseTarget)
            case .loading(let inputURL):
                LoadingTargetView(inputURL: inputURL)
            case .loaded(let loadedTarget):
                if model.navigation == .build {
                    BuildWorkspaceView(model: model)
                } else if let objectiveCClass = model.selectedClass {
                    ClassBrowserView(
                        objectiveCClass: objectiveCClass,
                        model: model,
                        initialMethodSearch: model.initialMethodSearch(for: objectiveCClass)
                    )
                    .id(objectiveCClass.id)
                } else {
                    TargetSummaryView(loadedTarget: loadedTarget)
                }
            case .failed(let failure):
                FailedTargetView(failure: failure, openTarget: model.chooseTarget)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyWorkspaceView: View {
    let openTarget: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Open an iOS Target", systemImage: "shippingbox")
        } description: {
            Text(
                "Choose or drop a decrypted IPA, an extracted .app bundle, or a Mach-O executable.")
        } actions: {
            Button("Open Target…", action: openTarget)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

private struct LoadingTargetView: View {
    let inputURL: URL

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Inspecting \(inputURL.lastPathComponent)")
                .font(.headline)
            Text("Resolving the executable and auditing its Mach-O slices…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct FailedTargetView: View {
    let failure: WorkspaceFailure
    let openTarget: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Open Target", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                Text(failure.inputURL.lastPathComponent)
                    .font(.headline)
                Text(failure.message)
            }
        } actions: {
            Button("Choose Another Target…", action: openTarget)
        }
    }
}

private struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(.tint.opacity(0.12))
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [9, 7]))
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 42))
                Text("Drop Target to Inspect")
                    .font(.title2.weight(.semibold))
            }
            .foregroundStyle(.tint)
        }
        .padding(18)
    }
}
