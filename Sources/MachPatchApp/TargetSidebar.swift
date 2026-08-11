import AppKit
import MachPatchCore
import SwiftUI

struct TargetSidebar: View {
    @ObservedObject var model: WorkspaceModel
    @State private var isBuildWorkspaceHovered = false
    @State private var isClassBrowserControlsPinned = false
    @State private var sidebarViewportHeight: CGFloat = 800
    @State private var hoveredClassID: String?
    @State private var highlightedSearchResultID: String?
    @FocusState private var isClassSearchFocused: Bool

    private static let classSearchControlsAnchor = "TargetSidebarClassSearchControlsAnchor"
    private static let classResultsAnchor = "TargetSidebarClassResultsAnchor"
    private static let pinnedControlsHeight: CGFloat = 116
    private static let scrollBarGutter: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(selection: $model.navigation) {
                    sidebarListContent
                }
                .listStyle(.sidebar)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SidebarViewportHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
                .overlay(alignment: .top) {
                    HStack(alignment: .top, spacing: 0) {
                        pinnedClassBrowserControls {
                            unpinClassBrowser()
                        }
                        Color.clear
                            .frame(width: Self.scrollBarGutter)
                            .allowsHitTesting(false)
                    }
                    .animation(.easeOut(duration: 0.18), value: isClassBrowserControlsPinned)
                }
                .onPreferenceChange(SidebarViewportHeightKey.self) { height in
                    sidebarViewportHeight = height
                }
                .onChange(of: model.classSearch) { _, _ in
                    handleClassQueryChange(with: proxy)
                }
                .onChange(of: model.classFilter) { _, _ in
                    handleClassQueryChange(with: proxy)
                }
                .onChange(of: isClassBrowserControlsPinned) { _, isPinned in
                    proxy.scrollTo(
                        isPinned ? Self.classResultsAnchor : Self.classSearchControlsAnchor,
                        anchor: .top
                    )
                }
                .onChange(of: model.navigation) { _, navigation in
                    if let navigation, case .objectiveCClass = navigation {
                        highlightedSearchResultID = nil
                    }
                }
            }

            if let projectDraft = model.projectDraft {
                Divider()
                buildWorkspaceControl(projectDraft)
            }
        }
        .navigationTitle("MachPatch")
    }

    @ViewBuilder
    private var sidebarListContent: some View {
        if !isClassBrowserControlsPinned {
            Section {
                Button {
                    model.chooseTarget()
                } label: {
                    Label("Open Target…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }

        if case .loaded(let loadedTarget) = model.phase {
            if !isClassBrowserControlsPinned {
                targetSection(loadedTarget)
                architectureSection(loadedTarget)
                imagesSection(loadedTarget)
            }
            analysisNavigation(loadedTarget)

            if pinnedTrailingScrollSpace > 0 {
                Color.clear
                    .frame(height: pinnedTrailingScrollSpace)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .accessibilityHidden(true)
            }
        }
    }

    private func targetSection(_ loadedTarget: LoadedTarget) -> some View {
        Section("Target") {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: loadedTarget))
                        .lineLimit(1)
                    Text(loadedTarget.target.sourceType.rawValue.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                TargetIconView(iconData: loadedTarget.iconData, size: 24)
            }
            .tag(WorkspaceNavigation.target)
        }
    }

    private func architectureSection(_ loadedTarget: LoadedTarget) -> some View {
        Section("Architectures") {
            ForEach(loadedTarget.architectureReport.slices, id: \.index) { slice in
                Button {
                    model.selectArchitecture(sliceIndex: slice.index)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(slice.architecture.rawValue)
                            Text(slice.platform.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        architectureIcon(
                            sliceIndex: slice.index,
                            supported: slice.supportedForPatching
                        )
                    }
                }
                .buttonStyle(.plain)
                .disabled(!slice.supportedForPatching)
            }
        }
    }

    private func imagesSection(_ loadedTarget: LoadedTarget) -> some View {
        Section("Images") {
            ForEach(loadedTarget.images) { image in
                Button {
                    model.selectImage(id: image.id)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(imageDisplayName(image.image))
                                .lineLimit(1)
                            Text(imageSubtitle(image))
                                .font(.caption)
                                .foregroundStyle(imageSubtitleColor(image))
                                .lineLimit(1)
                        }
                    } icon: {
                        imageStatusIcon(image, loadedTarget: loadedTarget)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help(imageHelp(image))
            }

            ForEach(
                Array(loadedTarget.target.imageDiscoveryIssues.enumerated()),
                id: \.offset
            ) { _, issue in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.relativeBundlePath)
                            .lineLimit(1)
                        Text(issue.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .help(issue.message)
            }
        }
    }

    private func handleClassQueryChange(with proxy: ScrollViewProxy) {
        let query = model.classSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        hoveredClassID = nil
        highlightedSearchResultID = query.isEmpty ? nil : firstDisplayedClassResult?.id

        if !query.isEmpty, !isClassBrowserControlsPinned {
            pinClassBrowser()
            return
        }
        guard isClassBrowserControlsPinned else { return }
        proxy.scrollTo(Self.classResultsAnchor, anchor: .top)
    }

    private func pinClassBrowser() {
        withAnimation(.easeOut(duration: 0.16)) {
            isClassBrowserControlsPinned = true
        }
        isClassSearchFocused = true
    }

    private func unpinClassBrowser() {
        isClassSearchFocused = false
        withAnimation(.easeOut(duration: 0.16)) {
            isClassBrowserControlsPinned = false
        }
    }

    private var pinnedTrailingScrollSpace: CGFloat {
        guard isClassBrowserControlsPinned else { return 0 }
        let estimatedRowsHeight = model.filteredClasses.reduce(CGFloat.zero) { height, target in
            height + (model.methodSearchMatches(for: target).isEmpty ? 44 : 62)
        }
        let estimatedResultsHeight = estimatedRowsHeight + 54
        return max(sidebarViewportHeight - estimatedResultsHeight, 0)
    }

    private var firstDisplayedClassResult: ObjectiveCClassBrowserTarget? {
        model.filteredClasses.first(where: { !$0.isCategoryOnly })
            ?? model.filteredClasses.first
    }

    private func buildWorkspaceControl(_ projectDraft: PatchProjectDraft) -> some View {
        let isSelected = model.navigation == .build
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        return HStack(spacing: 4) {
            Button {
                model.navigation = .build
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "hammer.fill")
                        .font(.title3)
                        .foregroundStyle(isSelected ? selectedText : .accentColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Build Workspace")
                            .font(.body.weight(.semibold))
                        Text(
                            "\(projectDraft.patches.count) patch\(projectDraft.patches.count == 1 ? "" : "es")"
                        )
                        .font(.caption)
                        .foregroundStyle(isSelected ? selectedText.opacity(0.82) : .secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the always-available build, verification, and export workspace.")
            .accessibilityLabel("Build Workspace, \(projectDraft.patches.count) patches")

            Menu {
                PatchProjectActionMenuItems(model: model)
            } label: {
                ZStack {
                    Rectangle()
                        .fill(Color.primary.opacity(0.001))
                    Circle()
                        .fill(
                            isSelected
                                ? selectedText.opacity(0.22) : Color.accentColor.opacity(0.16)
                        )
                        .frame(width: 28, height: 28)
                    Circle()
                        .stroke(
                            isSelected
                                ? selectedText.opacity(0.9) : Color.accentColor.opacity(0.8),
                            lineWidth: 1.5
                        )
                        .frame(width: 28, height: 28)
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isSelected ? selectedText : Color.accentColor)
                }
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 34, height: 34)
            .help("Patch project actions")
            .accessibilityLabel("Patch project actions")
        }
        .foregroundStyle(isSelected ? selectedText : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .background(
            isSelected
                ? Color.accentColor
                : Color.accentColor.opacity(isBuildWorkspaceHovered ? 0.16 : 0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    Color.accentColor.opacity(
                        isSelected ? 0 : isBuildWorkspaceHovered ? 0.55 : 0.28
                    ),
                    lineWidth: 1
                )
        }
        .padding(8)
        .onHover { isBuildWorkspaceHovered = $0 }
    }

    private func displayName(for loadedTarget: LoadedTarget) -> String {
        loadedTarget.target.displayName ?? loadedTarget.target.executableName
    }

    private func imageDisplayName(_ image: ResolvedImage) -> String {
        image.displayName ?? image.executableName
    }

    private func imageSubtitle(_ loadedImage: LoadedTargetImage) -> String {
        switch loadedImage.inspectionState {
        case .available(let slices, _):
            let architectures = Array(Set(slices.map(\.architecture.rawValue))).sorted()
            let architectureSummary =
                architectures.isEmpty ? "No Mach-O slices" : architectures.joined(separator: ", ")
            return slices.contains(where: \.encrypted)
                ? "\(architectureSummary) · Encrypted"
                : architectureSummary
        case .failed:
            return "Inspection failed"
        }
    }

    private func imageSubtitleColor(_ loadedImage: LoadedTargetImage) -> Color {
        switch loadedImage.inspectionState {
        case .available(let slices, _):
            slices.contains(where: \.encrypted) ? .orange : .secondary
        case .failed:
            .red
        }
    }

    @ViewBuilder
    private func pinnedClassBrowserControls(onUnpin: @escaping () -> Void) -> some View {
        if isClassBrowserControlsPinned,
            let counts = classBrowserCounts
        {
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    Text("Class Search")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(action: onUnpin) {
                        Label("Unpin", systemImage: "pin.slash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Unpin search and show target details")
                }
                classBrowserControls(
                    filteredCount: counts.filtered,
                    totalCount: counts.total,
                    pinsOnEditing: false
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 5)
            .background(.bar)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: 1)
                    .allowsHitTesting(false)
            }
            .transition(.opacity)
        }
    }

    private var classBrowserCounts: (filtered: Int, total: Int)? {
        guard case .loaded(let loadedTarget) = model.phase,
            case .loaded(let analysis) = loadedTarget.analysisState
        else {
            return nil
        }
        return (
            model.filteredClasses.count(where: { !$0.isCategoryOnly }),
            analysis.metadata.classes.count
        )
    }

    @ViewBuilder
    private func imageStatusIcon(
        _ image: LoadedTargetImage,
        loadedTarget: LoadedTarget
    ) -> some View {
        if case .failed = image.inspectionState {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        } else if loadedTarget.inspection.image.id == image.id {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: imageSymbol(image.image.kind))
                .foregroundStyle(Color.accentColor)
        }
    }

    private func imageSymbol(_ kind: ResolvedImageKind) -> String {
        switch kind {
        case .mainExecutable: "app.fill"
        case .dynamicFramework, .standaloneFramework: "shippingbox.fill"
        case .appExtension: "puzzlepiece.extension.fill"
        case .standaloneMachO: "terminal.fill"
        }
    }

    private func imageHelp(_ loadedImage: LoadedTargetImage) -> String {
        switch loadedImage.inspectionState {
        case .available(let slices, _):
            let architectures = Array(Set(slices.map(\.architecture.rawValue))).sorted()
            let architectureSummary =
                architectures.isEmpty ? "Unavailable" : architectures.joined(separator: ", ")
            let encryption = slices.contains(where: \.encrypted) ? "Encrypted" : "Not encrypted"
            let metadata = loadedImage.image.hasBundleMetadata ? "Available" : "Not available"
            return """
                \(imageKindName(loadedImage.image.kind))
                \(loadedImage.image.relativePath)
                Architectures: \(architectureSummary)
                Encryption: \(encryption)
                Bundle metadata: \(metadata)
                """
        case .failed(let message):
            return "\(loadedImage.image.relativePath)\n\(message)"
        }
    }

    private func imageKindName(_ kind: ResolvedImageKind) -> String {
        switch kind {
        case .mainExecutable: "Main executable"
        case .dynamicFramework: "Dynamic framework"
        case .appExtension: "App extension"
        case .standaloneFramework: "Standalone framework"
        case .standaloneMachO: "Standalone Mach-O"
        }
    }

    @ViewBuilder
    private func architectureIcon(sliceIndex: Int, supported: Bool) -> some View {
        if case .loaded(let loadedTarget) = model.phase,
            case .loading(let loadingIndex) = loadedTarget.analysisState,
            loadingIndex == sliceIndex
        {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(supported ? .green : .red)
        }
    }

    @ViewBuilder
    private func analysisNavigation(_ loadedTarget: LoadedTarget) -> some View {
        switch loadedTarget.analysisState {
        case .loaded(let analysis):
            let filteredClasses = model.filteredClasses.filter { !$0.isCategoryOnly }
            let filteredCategoryTargets = model.filteredClasses.filter(\.isCategoryOnly)
            let categoryTargetCount = loadedTarget.classBrowserTargets.count(
                where: \.isCategoryOnly)
            if !isClassBrowserControlsPinned {
                Section {
                    classBrowserControls(
                        filteredCount: filteredClasses.count,
                        totalCount: analysis.metadata.classes.count,
                        pinsOnEditing: true
                    )
                    .id(Self.classSearchControlsAnchor)
                }
            }

            Section(
                "Classes · \(filteredClasses.count) of \(analysis.metadata.classes.count)"
            ) {
                Color.clear
                    .frame(
                        height: isClassBrowserControlsPinned ? Self.pinnedControlsHeight : 0
                    )
                    .id(Self.classResultsAnchor)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .accessibilityHidden(true)

                ForEach(filteredClasses) { objectiveCClass in
                    classRow(objectiveCClass)
                }
            }

            if categoryTargetCount > 0 {
                Section(
                    "Category Targets · \(filteredCategoryTargets.count) of \(categoryTargetCount)"
                ) {
                    ForEach(filteredCategoryTargets) { objectiveCClass in
                        classRow(objectiveCClass)
                    }
                }
            }
        case .requiresSliceSelection:
            Section("Classes") {
                Label(
                    "Choose a supported architecture to analyze Objective-C metadata.",
                    systemImage: "cursorarrow.click"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .loading:
            Section("Classes") {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing Objective-C metadata…")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let sliceIndex, let message):
            Section("Analysis Failed") {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry Slice \(sliceIndex)") {
                    model.selectArchitecture(sliceIndex: sliceIndex)
                }
            }
        case .unavailable(let reason):
            Section("Classes Unavailable") {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func classBrowserControls(
        filteredCount: Int,
        totalCount: Int,
        pinsOnEditing: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if pinsOnEditing {
                TextField(
                    "Search classes or methods",
                    text: $model.classSearch,
                    onEditingChanged: { isEditing in
                        if isEditing {
                            pinClassBrowser()
                        }
                    }
                )
                .textFieldStyle(.roundedBorder)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        pinClassBrowser()
                    }
                )
            } else {
                TextField("Search classes or methods", text: $model.classSearch)
                    .textFieldStyle(.roundedBorder)
                    .focused($isClassSearchFocused)
            }
            Picker("Class Filter", selection: $model.classFilter) {
                ForEach(ObjectiveCClassFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                        .help(filter.helpText)
                }
            }
            .labelsHidden()
            .help(model.classFilter.helpText)
            Text("Classes · \(filteredCount) of \(totalCount)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
    }

    private func classRow(_ objectiveCClass: ObjectiveCClassBrowserTarget) -> some View {
        let searchMatch = model.classSearchMatch(for: objectiveCClass)
        let isSelected = model.navigation == .objectiveCClass(objectiveCClass.id)
        let isEmphasized =
            !isSelected
            && (hoveredClassID == objectiveCClass.id
                || (hoveredClassID == nil
                    && highlightedSearchResultID == objectiveCClass.id))
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(objectiveCClass.name)
                    .lineLimit(1)
                classRowSubtitle(objectiveCClass, searchMatch: searchMatch)
            }
        } icon: {
            Image(systemName: classIcon(objectiveCClass))
                .foregroundStyle(classIconColor(objectiveCClass))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(classRowHelp(objectiveCClass, searchMatch: searchMatch))
        .tag(WorkspaceNavigation.objectiveCClass(objectiveCClass.id))
        .simultaneousGesture(
            TapGesture().onEnded {
                model.selectClassSearchResult(objectiveCClass)
            }
        )
        .listRowBackground(
            isEmphasized ? Color.accentColor.opacity(0.14) : Color.clear
        )
        .animation(.easeOut(duration: 0.12), value: isEmphasized)
        .onHover { isHovered in
            if isHovered {
                highlightedSearchResultID = nil
                hoveredClassID = objectiveCClass.id
            } else if hoveredClassID == objectiveCClass.id {
                hoveredClassID = nil
            }
        }
    }

    @ViewBuilder
    private func classRowSubtitle(
        _ objectiveCClass: ObjectiveCClassBrowserTarget,
        searchMatch: ObjectiveCClassSearchMatch?
    ) -> some View {
        if let searchMatch, let firstMethod = searchMatch.methods.first {
            Text(
                "\(searchMatch.methods.count) matching method\(searchMatch.methods.count == 1 ? "" : "s")"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Text(methodDescription(firstMethod))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let searchMatch, !searchMatch.matchesClassName {
            if let categoryName = searchMatch.categoryNames.first {
                Text(
                    searchReasonSummary(
                        "Category", value: categoryName, total: searchMatch.categoryNames.count)
                )
                .font(.caption)
                .foregroundStyle(.purple)
                .lineLimit(1)
            } else if let superclass = searchMatch.superclassName {
                Text("Superclass · \(superclass)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let imageName = searchMatch.imageName {
                Text("Image · \(imageName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if let superclass = objectiveCClass.superclassName {
            Text("Subclass of \(superclass)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let categoryName = objectiveCClass.categoryNames.first {
            Text(
                objectiveCClass.categoryNames.count == 1
                    ? "Category target · \(categoryName)"
                    : "Category target · \(categoryName) + \(objectiveCClass.categoryNames.count - 1) more"
            )
            .font(.caption)
            .foregroundStyle(.purple)
            .lineLimit(1)
        }
    }

    private func classIcon(_ objectiveCClass: ObjectiveCClassBrowserTarget) -> String {
        if objectiveCClass.isCategoryOnly {
            "square.stack.3d.up"
        } else if objectiveCClass.isObjectiveCVisibleSwift {
            "swift"
        } else if objectiveCClass.isLikelyAppDefined {
            "cube.fill"
        } else {
            "cube"
        }
    }

    private func classIconColor(_ objectiveCClass: ObjectiveCClassBrowserTarget) -> Color {
        if model.navigation == .objectiveCClass(objectiveCClass.id) {
            return Color(nsColor: .alternateSelectedControlTextColor)
        }
        if objectiveCClass.isObjectiveCVisibleSwift {
            return .orange
        }
        if objectiveCClass.isCategoryOnly {
            return .purple
        }
        return objectiveCClass.isLikelyAppDefined ? .accentColor : .secondary
    }

    private func methodDescription(_ method: ObjectiveCCanonicalMethod) -> String {
        let marker = method.kind == .instance ? "−" : "+"
        return "\(marker)\(method.selector)"
    }

    private func searchReasonSummary(_ label: String, value: String, total: Int) -> String {
        let remainder = total > 1 ? " + \(total - 1) more" : ""
        return "\(label) · \(value)\(remainder)"
    }

    private func classRowHelp(
        _ objectiveCClass: ObjectiveCClassBrowserTarget,
        searchMatch: ObjectiveCClassSearchMatch?
    ) -> String {
        guard let searchMatch else {
            return "\(objectiveCClass.name)\nImage: \(objectiveCClass.imageName)"
        }

        var reasons: [String] = []
        if searchMatch.matchesClassName {
            reasons.append("Class name: \(objectiveCClass.name)")
        }
        if let superclass = searchMatch.superclassName {
            reasons.append("Superclass: \(superclass)")
        }
        if let imageName = searchMatch.imageName {
            reasons.append("Image: \(imageName)")
        }
        reasons.append(contentsOf: searchMatch.categoryNames.map { "Category: \($0)" })
        if !searchMatch.methods.isEmpty {
            reasons.append("Matched methods:")
            reasons.append(contentsOf: searchMatch.methods.map(methodDescription))
        }
        return reasons.joined(separator: "\n")
    }
}

private struct SidebarViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
