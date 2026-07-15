import Foundation
import MachPatchCore

struct PatchProjectDraft: Equatable {
    var projectName: String
    let target: PatchTargetIdentity
    var architectureMode: PatchArchitectureMode
    var minimumIOSVersion: String
    var outputName: String
    var enableARC: Bool
    private(set) var patches: [MethodPatch]

    init?(loadedTarget: LoadedTarget) {
        guard case .loaded(let analysis) = loadedTarget.analysisState,
            let slice = loadedTarget.inspection.slices.first(where: {
                $0.index == analysis.sliceIndex
            }),
            let targetIdentity = Self.targetIdentity(for: loadedTarget)
        else { return nil }

        let displayName =
            loadedTarget.inspection.image.displayName
            ?? loadedTarget.inspection.image.executableName
        projectName = "\(displayName) Patch"
        target = targetIdentity
        architectureMode = .automatic
        minimumIOSVersion =
            loadedTarget.target.minimumOSVersion ?? slice.minimumOSVersion ?? ""
        outputName = Self.defaultOutputName(for: loadedTarget.inspection.image.executableName)
        enableARC = true
        patches = []
    }

    init(project: PatchProject, targetOverride: PatchTargetIdentity? = nil) {
        projectName = project.projectName
        target = targetOverride ?? project.target
        architectureMode = project.build.architectureMode
        minimumIOSVersion = project.build.minimumIOSVersion
        outputName = project.build.outputName
        enableARC = project.build.enableARC
        patches = project.patches
    }

    var project: PatchProject {
        PatchProject(
            projectName: projectName,
            target: target,
            build: PatchBuildConfiguration(
                architectureMode: architectureMode,
                minimumIOSVersion: minimumIOSVersion,
                outputName: outputName,
                enableARC: enableARC
            ),
            patches: patches
        )
    }

    var validationReport: PatchProjectValidationReport {
        PatchProjectValidator.validate(project)
    }

    func patch(className: String, method: ObjectiveCMethod) -> MethodPatch? {
        patches.first {
            $0.className == className && $0.selector == method.selector
                && $0.methodKind == method.kind
        }
    }

    @discardableResult
    mutating func addPatch(
        className: String,
        method: ObjectiveCMethod,
        id: UUID = UUID()
    ) throws -> MethodPatch {
        if let existing = patch(className: className, method: method) {
            return existing
        }
        guard let typeEncoding = method.typeEncoding else {
            throw PatchDraftError.typeEncodingUnavailable
        }

        let signature: ObjectiveCMethodSignature
        do {
            signature = try ObjectiveCTypeEncodingDecoder.decodeMethodSignature(typeEncoding)
        } catch {
            throw PatchDraftError.invalidTypeEncoding(error.localizedDescription)
        }

        let allowedActions = PatchActionCompatibility.allowedActions(for: signature)
        guard let defaultKind = allowedActions.first,
            let action = PatchActionEditorPolicy.action(for: defaultKind, signature: signature)
        else {
            throw PatchDraftError.unsupportedSignature
        }

        let patch = MethodPatch(
            id: id.uuidString,
            enabled: true,
            className: className,
            selector: method.selector,
            methodKind: method.kind,
            expectedTypeEncoding: typeEncoding,
            action: action
        )
        patches.append(patch)
        return patch
    }

    mutating func updatePatch(_ patch: MethodPatch) {
        guard let index = patches.firstIndex(where: { $0.id == patch.id }) else { return }
        patches[index] = patch
    }

    mutating func removePatch(id: String) {
        patches.removeAll { $0.id == id }
    }

    static func targetIdentity(for loadedTarget: LoadedTarget) -> PatchTargetIdentity? {
        guard case .loaded(let analysis) = loadedTarget.analysisState,
            let slice = loadedTarget.inspection.slices.first(where: {
                $0.index == analysis.sliceIndex
            })
        else { return nil }

        return PatchTargetIdentity(
            bundleIdentifier: loadedTarget.target.bundleIdentifier,
            executableName: loadedTarget.target.executableName,
            executableSHA256: loadedTarget.target.sha256,
            selectedImage: PatchImageIdentity(image: loadedTarget.inspection.image),
            selectedSlice: PatchSelectedSlice(
                architecture: slice.architecture,
                cpuSubtype: slice.cpuSubtype
            ),
            minimumIOSVersion: loadedTarget.inspection.image.minimumOSVersion
                ?? loadedTarget.target.minimumOSVersion ?? slice.minimumOSVersion
        )
    }

    private static func defaultOutputName(for executableName: String) -> String {
        let base = executableName.filter {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
        }
        return "\(base.isEmpty ? "MachPatch" : base)Patch"
    }
}

enum PatchDraftError: LocalizedError, Equatable {
    case projectUnavailable
    case typeEncodingUnavailable
    case invalidTypeEncoding(String)
    case unsupportedSignature
    case conflictingTypeEncodings([String])

    var errorDescription: String? {
        switch self {
        case .projectUnavailable:
            "Choose and analyze a supported target architecture before creating patches."
        case .typeEncodingUnavailable:
            "This method has no type encoding, so MachPatch cannot generate an ABI-safe patch."
        case .invalidTypeEncoding(let message):
            "This method's type encoding could not be decoded: \(message)"
        case .unsupportedSignature:
            "No version 1 patch action supports this method's complete ABI signature."
        case .conflictingTypeEncodings(let encodings):
            "Method declarations disagree on the type encoding: \(encodings.joined(separator: ", "))."
        }
    }
}

enum PatchActionEditorPolicy {
    static func action(
        for kind: PatchActionKind,
        signature: ObjectiveCMethodSignature
    ) -> PatchAction? {
        guard PatchActionCompatibility.allowedActions(for: signature).contains(kind) else {
            return nil
        }
        switch kind {
        case .returnBoolean:
            return .returnBoolean(false)
        case .returnSignedInteger:
            return .returnSignedInteger(0)
        case .returnUnsignedInteger:
            return .returnUnsignedInteger(0)
        case .returnFloatingPoint:
            return .returnFloatingPoint(0)
        case .returnNil:
            return .returnNil
        case .returnClassNamed:
            return .returnClassNamed("NSObject")
        case .returnSelector:
            return .returnSelector("description")
        case .returnString:
            return .returnString("")
        case .returnObject:
            return .returnObject(.numberBoolean(false))
        case .logInvocation:
            return .logInvocation
        case .logArguments:
            return .logArguments
        case .logOriginalReturnValue:
            return .logOriginalReturnValue
        case .callOriginal:
            return .callOriginal
        case .callOriginalAndReplace:
            guard let replacement = defaultReplacement(for: signature.returnType.kind) else {
                return nil
            }
            return .callOriginalAndReplace(replacement)
        }
    }

    static func unavailableReason(
        for kind: PatchActionKind,
        signature: ObjectiveCMethodSignature
    ) -> String? {
        if PatchActionCompatibility.allowedActions(for: signature).contains(kind) {
            return nil
        }
        if PatchActionCompatibility.allowedActions(for: signature).isEmpty {
            return "The complete method signature contains an unsupported ABI type."
        }
        let returnType = signature.returnType.kind.rawValue
        switch kind {
        case .returnBoolean:
            return "Requires a BOOL return; this method returns \(returnType)."
        case .returnSignedInteger:
            return "Requires a signed integer return; this method returns \(returnType)."
        case .returnUnsignedInteger:
            return "Requires an unsigned integer return; this method returns \(returnType)."
        case .returnFloatingPoint:
            return "Requires a float or double return; this method returns \(returnType)."
        case .returnNil:
            return "Requires an object, Class, or SEL return; this method returns \(returnType)."
        case .returnClassNamed:
            return "Requires a Class return; this method returns \(returnType)."
        case .returnSelector:
            return "Requires a SEL return; this method returns \(returnType)."
        case .returnString:
            return "Requires an Objective-C object return; this method returns \(returnType)."
        case .returnObject:
            return "Requires an Objective-C object return; this method returns \(returnType)."
        case .logOriginalReturnValue, .callOriginalAndReplace:
            return "Requires a supported non-void return; this method returns \(returnType)."
        case .logInvocation, .logArguments, .callOriginal:
            return "The complete method signature contains an unsupported ABI type."
        }
    }

    private static func defaultReplacement(
        for kind: ObjectiveCTypeKind
    ) -> PatchReturnValue? {
        switch kind {
        case .boolean:
            .boolean(false)
        case let kind where kind.isSignedInteger:
            .signedInteger(0)
        case let kind where kind.isUnsignedInteger:
            .unsignedInteger(0)
        case .float, .double:
            .floatingPoint(0)
        case .object:
            .nilValue
        case .classObject:
            .classNamed("NSObject")
        case .selector:
            .selector("description")
        default:
            nil
        }
    }
}

extension MethodPatch {
    func replacing(enabled: Bool? = nil, action: PatchAction? = nil) -> MethodPatch {
        MethodPatch(
            id: id,
            enabled: enabled ?? self.enabled,
            className: className,
            selector: selector,
            methodKind: methodKind,
            expectedTypeEncoding: expectedTypeEncoding,
            action: action ?? self.action,
            advanced: advanced
        )
    }

    func replacingAdvanced(_ advanced: PatchAdvancedConfiguration?) -> MethodPatch {
        MethodPatch(
            id: id,
            enabled: enabled,
            className: className,
            selector: selector,
            methodKind: methodKind,
            expectedTypeEncoding: expectedTypeEncoding,
            action: action,
            advanced: advanced?.isEmpty == true ? nil : advanced
        )
    }
}
