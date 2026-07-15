import SwiftUI
import UniformTypeIdentifiers

struct MachPatchRootView: View {
    @StateObject private var model = WorkspaceModel()

    var body: some View {
        NavigationSplitView {
            TargetSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            WorkspaceDetail(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.chooseTarget()
                } label: {
                    Label("Open Target", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let inputURL = urls.first {
                model.openTarget(at: inputURL)
            }
        }
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
                if let objectiveCClass = model.selectedClass {
                    ClassBrowserView(objectiveCClass: objectiveCClass)
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
