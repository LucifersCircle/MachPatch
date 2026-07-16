import Foundation

public struct PatchProjectValidationReport: Codable, Equatable, Sendable {
    public let isValid: Bool
    public let errors: [PatchProjectValidationIssue]
    public let warnings: [PatchProjectValidationIssue]

    public init(
        errors: [PatchProjectValidationIssue],
        warnings: [PatchProjectValidationIssue] = []
    ) {
        self.errors = errors
        self.warnings = warnings
        isValid = errors.isEmpty
    }
}

public struct PatchProjectValidationIssue: Codable, Equatable, Sendable {
    public let code: PatchProjectValidationCode
    public let message: String
    public let patchID: String?

    public init(
        code: PatchProjectValidationCode,
        message: String,
        patchID: String? = nil
    ) {
        self.code = code
        self.message = message
        self.patchID = patchID
    }
}

public enum PatchProjectValidationCode: String, Codable, Equatable, Sendable {
    case unsupportedFormatVersion
    case emptyProjectName
    case emptyExecutableName
    case invalidExecutableSHA256
    case emptySelectedImagePath
    case emptySelectedImageName
    case invalidSelectedImageSHA256
    case invalidMinimumIOSVersion
    case invalidOutputName
    case invalidRuntimeControlsID
    case missingRuntimeControlsConfiguration
    case invalidRuntimeControlTitle
    case invalidRuntimeControlOrder
    case incompatibleRuntimeControl
    case invalidPatchID
    case duplicatePatchID
    case duplicatePatchTarget
    case emptyClassName
    case invalidClassName
    case emptySelector
    case invalidSelector
    case emptyTypeEncoding
    case malformedTypeEncoding
    case invalidMethodSignature
    case unsupportedReturnType
    case unsupportedArgumentType
    case incompatibleAction
    case invalidArgumentIndex
    case duplicateArgumentReplacement
    case incompatibleArgumentReplacement
    case invalidCondition
    case invalidEffect
    case afterEffectRequiresOriginal
    case invocationCounterRequired
    case targetNotAnalyzed
    case targetHashMismatch
    case targetExecutableNameMismatch
    case targetBundleIdentifierMismatch
    case targetImagePathMismatch
    case targetImageNameMismatch
    case targetImageHashMismatch
    case targetMinimumIOSVersionMismatch
    case targetArchitectureMismatch
    case targetCPUSubtypeMismatch
    case classNotFound
    case methodNotFound
    case methodKindMismatch
    case conflictingMethodTypeEncodings
    case typeEncodingChanged
}

public enum PatchProjectValidator {
    public static func validate(_ project: PatchProject) -> PatchProjectValidationReport {
        var errors: [PatchProjectValidationIssue] = []

        if project.formatVersion != PatchProject.currentFormatVersion {
            errors.append(
                issue(
                    .unsupportedFormatVersion,
                    "Format version \(project.formatVersion) is unsupported; expected \(PatchProject.currentFormatVersion)."
                )
            )
        }
        if isBlank(project.projectName) {
            errors.append(issue(.emptyProjectName, "Project name must not be empty."))
        }
        if isBlank(project.target.executableName) {
            errors.append(issue(.emptyExecutableName, "Target executable name must not be empty."))
        }
        if !isSHA256(project.target.executableSHA256) {
            errors.append(
                issue(
                    .invalidExecutableSHA256,
                    "Target executable SHA-256 must contain exactly 64 hexadecimal characters."
                )
            )
        }
        if isBlank(project.target.selectedImage.relativePath) {
            errors.append(
                issue(.emptySelectedImagePath, "Selected image path must not be empty.")
            )
        }
        if isBlank(project.target.selectedImage.executableName) {
            errors.append(
                issue(.emptySelectedImageName, "Selected image name must not be empty.")
            )
        }
        if !isSHA256(project.target.selectedImage.executableSHA256) {
            errors.append(
                issue(
                    .invalidSelectedImageSHA256,
                    "Selected image SHA-256 must contain exactly 64 hexadecimal characters."
                )
            )
        }
        if let version = project.target.minimumIOSVersion, !isVersion(version) {
            errors.append(
                issue(
                    .invalidMinimumIOSVersion,
                    "Target minimum iOS version '\(version)' is invalid."
                )
            )
        }
        if !isVersion(project.build.minimumIOSVersion) {
            errors.append(
                issue(
                    .invalidMinimumIOSVersion,
                    "Build minimum iOS version '\(project.build.minimumIOSVersion)' is invalid."
                )
            )
        }
        if !isOutputName(project.build.outputName) {
            errors.append(
                issue(
                    .invalidOutputName,
                    "Build output name must contain only letters, numbers, '.', '-', or '_'."
                )
            )
        }
        if let runtimeControls = project.runtimeControls,
            UUID(uuidString: runtimeControls.id) == nil
        {
            errors.append(
                issue(
                    .invalidRuntimeControlsID,
                    "Runtime controls namespace is not a UUID."
                )
            )
        }
        if project.runtimeControls == nil,
            project.patches.contains(where: { $0.runtimeControl != nil })
        {
            errors.append(
                issue(
                    .missingRuntimeControlsConfiguration,
                    "Exposed patches require a project runtime-controls configuration."
                )
            )
        }

        var identifiers: Set<String> = []
        var targets: Set<PatchTargetKey> = []
        for patch in project.patches {
            if UUID(uuidString: patch.id) == nil {
                errors.append(
                    issue(.invalidPatchID, "Patch ID is not a UUID.", patchID: patch.id)
                )
            }
            if !identifiers.insert(patch.id.lowercased()).inserted {
                errors.append(
                    issue(.duplicatePatchID, "Patch ID is duplicated.", patchID: patch.id)
                )
            }

            let targetKey = PatchTargetKey(patch)
            if !targets.insert(targetKey).inserted {
                errors.append(
                    issue(
                        .duplicatePatchTarget,
                        "More than one patch targets \(targetKey.description).",
                        patchID: patch.id
                    )
                )
            }
            errors.append(contentsOf: validate(patch))
        }

        return PatchProjectValidationReport(errors: errors)
    }

    private static func validate(_ patch: MethodPatch) -> [PatchProjectValidationIssue] {
        var errors: [PatchProjectValidationIssue] = []
        if isBlank(patch.className) {
            errors.append(
                issue(.emptyClassName, "Class name must not be empty.", patchID: patch.id)
            )
        } else if containsRuntimeNameControlCharacter(patch.className)
            || patch.className.contains(where: \.isWhitespace)
        {
            errors.append(
                issue(
                    .invalidClassName,
                    "Class name must not contain whitespace or control characters.",
                    patchID: patch.id
                )
            )
        }
        if isBlank(patch.selector) {
            errors.append(
                issue(.emptySelector, "Selector must not be empty.", patchID: patch.id)
            )
        } else if patch.selector.contains(where: \.isWhitespace)
            || containsRuntimeNameControlCharacter(patch.selector)
        {
            errors.append(
                issue(
                    .invalidSelector,
                    "Selector must not contain whitespace or control characters.",
                    patchID: patch.id
                )
            )
        }
        if isBlank(patch.expectedTypeEncoding) {
            errors.append(
                issue(
                    .emptyTypeEncoding,
                    "Expected type encoding must not be empty.",
                    patchID: patch.id
                )
            )
            return errors
        }

        let signature: ObjectiveCMethodSignature
        do {
            signature = try ObjectiveCTypeEncodingDecoder.decodeMethodSignature(
                patch.expectedTypeEncoding
            )
        } catch {
            errors.append(
                issue(
                    .malformedTypeEncoding,
                    error.localizedDescription,
                    patchID: patch.id
                )
            )
            return errors
        }

        errors.append(contentsOf: validate(signature, selector: patch.selector, patchID: patch.id))
        if let incompatibility = PatchActionCompatibility.incompatibility(
            action: patch.action,
            signature: signature
        ) {
            errors.append(
                issue(.incompatibleAction, incompatibility, patchID: patch.id)
            )
        }
        if let advanced = patch.advanced {
            errors.append(
                contentsOf: validate(
                    advanced,
                    primaryAction: patch.action,
                    signature: signature,
                    patchID: patch.id
                )
            )
        }
        if let runtimeControl = patch.runtimeControl {
            if isBlank(runtimeControl.title) || runtimeControl.title.utf8.count > 128
                || runtimeControl.title.contains(where: \.isNewline)
                || containsRuntimeNameControlCharacter(runtimeControl.title)
            {
                errors.append(
                    issue(
                        .invalidRuntimeControlTitle,
                        "Runtime control titles must contain 1 through 128 UTF-8 bytes without newlines or control characters.",
                        patchID: patch.id
                    )
                )
            }
            if runtimeControl.order < 0 {
                errors.append(
                    issue(
                        .invalidRuntimeControlOrder,
                        "Runtime control order must not be negative.",
                        patchID: patch.id
                    )
                )
            }
            if let value = runtimeControl.value,
                let message = PatchRuntimeControlCompatibility.incompatibility(
                    value: value,
                    action: patch.action,
                    signature: signature
                )
            {
                errors.append(issue(.incompatibleRuntimeControl, message, patchID: patch.id))
            }
        }
        return errors
    }

    private static func validate(
        _ advanced: PatchAdvancedConfiguration,
        primaryAction: PatchAction,
        signature: ObjectiveCMethodSignature,
        patchID: String
    ) -> [PatchProjectValidationIssue] {
        var errors: [PatchProjectValidationIssue] = []

        if !advanced.argumentReplacements.isEmpty, !primaryAction.callsOriginal {
            errors.append(
                issue(
                    .incompatibleArgumentReplacement,
                    "Argument replacement requires a primary action that calls the original method.",
                    patchID: patchID
                )
            )
        }

        var replacedIndices: Set<Int> = []
        for replacement in advanced.argumentReplacements {
            guard signature.explicitArguments.indices.contains(replacement.argumentIndex) else {
                errors.append(
                    issue(
                        .invalidArgumentIndex,
                        "Argument replacement index \(replacement.argumentIndex) is outside this method's \(signature.explicitArguments.count) explicit arguments.",
                        patchID: patchID
                    )
                )
                continue
            }
            if !replacedIndices.insert(replacement.argumentIndex).inserted {
                errors.append(
                    issue(
                        .duplicateArgumentReplacement,
                        "Argument \(replacement.argumentIndex + 1) has more than one replacement.",
                        patchID: patchID
                    )
                )
            }
            let argument = signature.explicitArguments[replacement.argumentIndex]
            if let message = PatchActionCompatibility.valueIncompatibility(
                replacement.value,
                type: argument,
                context: "Argument \(replacement.argumentIndex + 1) replacement"
            ) {
                errors.append(
                    issue(.incompatibleArgumentReplacement, message, patchID: patchID)
                )
            }
        }

        for effect in advanced.beforeEffects + advanced.afterEffects {
            if let message = effectValidationError(effect) {
                errors.append(issue(.invalidEffect, message, patchID: patchID))
            }
        }
        if !advanced.afterEffects.isEmpty, !primaryAction.callsOriginal {
            errors.append(
                issue(
                    .afterEffectRequiresOriginal,
                    "After-original effects require a primary action that calls the original method.",
                    patchID: patchID
                )
            )
        }

        if let conditionalReturn = advanced.conditionalReturn {
            if signature.returnType.kind == .void {
                errors.append(
                    issue(
                        .invalidCondition,
                        "Conditional return replacement requires a non-void method.",
                        patchID: patchID
                    )
                )
            } else if let message = PatchActionCompatibility.returnValueIncompatibility(
                conditionalReturn.replacement,
                kind: signature.returnType.kind
            ) {
                errors.append(issue(.invalidCondition, message, patchID: patchID))
            }

            switch conditionalReturn.condition.source {
            case .argument(let index):
                guard signature.explicitArguments.indices.contains(index) else {
                    errors.append(
                        issue(
                            .invalidArgumentIndex,
                            "Conditional source argument index \(index) is outside this method's \(signature.explicitArguments.count) explicit arguments.",
                            patchID: patchID
                        )
                    )
                    break
                }
                let argument = signature.explicitArguments[index]
                if let message = PatchActionCompatibility.conditionIncompatibility(
                    conditionalReturn.condition,
                    sourceType: argument
                ) {
                    errors.append(issue(.invalidCondition, message, patchID: patchID))
                }
            case .invocationCount:
                if advanced.invocationCounter == nil {
                    errors.append(
                        issue(
                            .invocationCounterRequired,
                            "An invocation-count condition requires the runtime invocation counter.",
                            patchID: patchID
                        )
                    )
                }
                let countType = ObjectiveCType(
                    encoding: "Q",
                    kind: .unsignedLongLong,
                    qualifiers: [],
                    annotation: nil
                )
                if let message = PatchActionCompatibility.conditionIncompatibility(
                    conditionalReturn.condition,
                    sourceType: countType
                ) {
                    errors.append(issue(.invalidCondition, message, patchID: patchID))
                }
            }
        }

        return errors
    }

    private static func effectValidationError(_ effect: PatchEffect) -> String? {
        switch effect {
        case .showAlert(let alert):
            if alert.title.utf8.count > 512 {
                return "Alert titles must not exceed 512 UTF-8 bytes."
            }
            if alert.message.utf8.count > 4_096 {
                return "Alert messages must not exceed 4096 UTF-8 bytes."
            }
            if isBlank(alert.buttonTitle) || alert.buttonTitle.utf8.count > 128 {
                return "Alert button titles must contain 1 through 128 UTF-8 bytes."
            }
            return nil
        case .customObjectiveC(let custom):
            if isBlank(custom.source) {
                return "Custom Objective-C code must not be empty."
            }
            if custom.source.utf8.count > PatchCustomObjectiveC.maximumUTF8ByteCount {
                return
                    "Custom Objective-C code exceeds the \(PatchCustomObjectiveC.maximumUTF8ByteCount)-byte limit."
            }
            if custom.source.unicodeScalars.contains(where: { $0.value == 0 }) {
                return "Custom Objective-C code must not contain NUL characters."
            }
            if custom.source.split(separator: "\n", omittingEmptySubsequences: false).contains(
                where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            ) {
                return
                    "Custom Objective-C snippets are function bodies and cannot contain preprocessor directives."
            }
            return nil
        }
    }

    private static func validate(
        _ signature: ObjectiveCMethodSignature,
        selector: String,
        patchID: String
    ) -> [PatchProjectValidationIssue] {
        ObjectiveCPatchabilityAnalyzer.signatureIssues(for: signature, selector: selector).map {
            issue(validationCode(for: $0.code), $0.message, patchID: patchID)
        }
    }

    private static func validationCode(
        for patchabilityCode: ObjectiveCMethodPatchabilityIssueCode
    ) -> PatchProjectValidationCode {
        switch patchabilityCode {
        case .invalidImplicitArguments:
            .invalidMethodSignature
        case .selectorArgumentCountMismatch:
            .invalidSelector
        case .unsupportedReturnType:
            .unsupportedReturnType
        case .unsupportedArgumentType:
            .unsupportedArgumentType
        case .noCompatibleActions:
            .incompatibleAction
        case .missingTypeEncoding:
            .emptyTypeEncoding
        case .invalidTypeEncoding:
            .malformedTypeEncoding
        }
    }

    private static func issue(
        _ code: PatchProjectValidationCode,
        _ message: String,
        patchID: String? = nil
    ) -> PatchProjectValidationIssue {
        PatchProjectValidationIssue(code: code, message: message, patchID: patchID)
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func containsRuntimeNameControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func isVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return (2...3).contains(components.count)
            && components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func isOutputName(_ value: String) -> Bool {
        !value.isEmpty
            && value.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
            }
    }
}

public enum PatchActionCompatibility {
    public static func allowedActions(
        for signature: ObjectiveCMethodSignature
    ) -> [PatchActionKind] {
        guard isSupportedSignature(signature) else { return [] }
        var actions: [PatchActionKind] = [.logInvocation, .logArguments, .callOriginal]
        switch signature.returnType.kind {
        case .void:
            break
        case .boolean:
            actions.append(contentsOf: [
                .returnBoolean,
                .logOriginalReturnValue,
                .callOriginalAndReplace,
            ])
        case let kind where kind.isSignedInteger:
            actions.append(contentsOf: [
                .returnSignedInteger,
                .logOriginalReturnValue,
                .callOriginalAndReplace,
            ])
        case let kind where kind.isUnsignedInteger:
            actions.append(contentsOf: [
                .returnUnsignedInteger,
                .logOriginalReturnValue,
                .callOriginalAndReplace,
            ])
        case .float, .double:
            actions.append(contentsOf: [
                .returnFloatingPoint,
                .logOriginalReturnValue,
                .callOriginalAndReplace,
            ])
        case .object:
            actions.append(contentsOf: [
                .returnNil,
                .returnString,
                .returnObject,
                .logOriginalReturnValue,
                .callOriginalAndReplace,
            ])
        case .classObject:
            actions.append(contentsOf: [
                .returnNil,
                .returnClassNamed,
                .logOriginalReturnValue,
                .callOriginalAndReplace,
            ])
        case .selector:
            actions.append(contentsOf: [
                .returnNil,
                .returnSelector,
                .logOriginalReturnValue,
                .callOriginalAndReplace,
            ])
        case .structure where signature.returnType.knownStructure != nil:
            actions.append(.logOriginalReturnValue)
        default:
            break
        }
        if signature.explicitArguments.contains(where: { $0.kind == .pointer || $0.kind == .block })
        {
            let passThroughActions: Set<PatchActionKind> = [
                .logInvocation,
                .logArguments,
                .logOriginalReturnValue,
                .callOriginal,
                .callOriginalAndReplace,
            ]
            actions.removeAll { !passThroughActions.contains($0) }
        }
        return actions.sorted { $0.rawValue < $1.rawValue }
    }

    public static func incompatibility(
        action: PatchAction,
        signature: ObjectiveCMethodSignature
    ) -> String? {
        guard isSupportedSignature(signature) else {
            return "Action cannot be used because the complete method signature is unsupported."
        }
        guard allowedActions(for: signature).contains(action.kind) else {
            return
                "Action '\(action.kind.rawValue)' is incompatible with return type '\(signature.returnType.encoding)'."
        }

        switch action {
        case .returnSignedInteger(let value):
            return integerRangeError(value: value, kind: signature.returnType.kind)
        case .returnUnsignedInteger(let value):
            return unsignedIntegerRangeError(value: value, kind: signature.returnType.kind)
        case .returnFloatingPoint(let value):
            return floatingPointError(value: value, kind: signature.returnType.kind)
        case .returnClassNamed(let className):
            guard signature.returnType.kind == .classObject else {
                return "Named-class return requires a Class return type."
            }
            return isRuntimeName(className)
                ? nil : "Named-class return contains an invalid class name."
        case .returnSelector(let selector):
            guard signature.returnType.kind == .selector else {
                return "Named-selector return requires a SEL return type."
            }
            return isRuntimeName(selector)
                ? nil : "Named-selector return contains an invalid selector name."
        case .callOriginalAndReplace(let replacement):
            return replacementError(replacement, kind: signature.returnType.kind)
        case .returnObject(let object):
            guard signature.returnType.kind == .object else {
                return "Object construction requires an Objective-C object return type."
            }
            return objectValueError(object)
        default:
            return nil
        }
    }

    static func isSupportedReturnType(_ type: ObjectiveCType) -> Bool {
        let kind = type.kind
        return kind == .void || kind == .boolean || kind.isSignedInteger || kind.isUnsignedInteger
            || kind == .float || kind == .double || kind == .object || kind == .classObject
            || kind == .selector || type.knownStructure != nil
    }

    static func isSupportedArgumentType(_ type: ObjectiveCType) -> Bool {
        let kind = type.kind
        return kind == .boolean || kind.isSignedInteger || kind.isUnsignedInteger || kind == .object
            || kind == .float || kind == .double || kind == .classObject || kind == .selector
            || kind == .pointer || kind == .block || type.knownStructure != nil
    }

    private static func isSupportedSignature(_ signature: ObjectiveCMethodSignature) -> Bool {
        signature.arguments.count >= 2
            && signature.arguments[0].kind == .object
            && signature.arguments[1].kind == .selector
            && isSupportedReturnType(signature.returnType)
            && signature.explicitArguments.allSatisfy(isSupportedArgumentType)
    }

    public static func supportsArgumentReplacement(for type: ObjectiveCType) -> Bool {
        let kind = type.kind
        return kind == .boolean || kind.isSignedInteger || kind.isUnsignedInteger
            || kind == .float || kind == .double || kind == .object || kind == .classObject
            || kind == .selector || kind == .pointer || kind == .block
    }

    public static func supportsCondition(for type: ObjectiveCType) -> Bool {
        supportsArgumentReplacement(for: type)
    }

    public static func supportsConditionalReturn(for type: ObjectiveCType) -> Bool {
        let kind = type.kind
        return kind == .boolean || kind.isSignedInteger || kind.isUnsignedInteger
            || kind == .float || kind == .double || kind == .object || kind == .classObject
            || kind == .selector
    }

    static func returnValueIncompatibility(
        _ replacement: PatchReturnValue,
        kind: ObjectiveCTypeKind
    ) -> String? {
        replacementError(replacement, kind: kind)
    }

    static func valueIncompatibility(
        _ value: PatchValue,
        type: ObjectiveCType,
        context: String
    ) -> String? {
        let kind = type.kind
        switch value {
        case .boolean:
            return kind == .boolean ? nil : "\(context) requires a BOOL value."
        case .signedInteger(let value):
            guard kind.isSignedInteger else { return "\(context) requires a signed integer value." }
            return integerRangeError(value: value, kind: kind)
        case .unsignedInteger(let value):
            guard kind.isUnsignedInteger else {
                return "\(context) requires an unsigned integer value."
            }
            return unsignedIntegerRangeError(value: value, kind: kind)
        case .floatingPoint(let value):
            guard kind == .float || kind == .double else {
                return "\(context) requires a floating-point value."
            }
            return floatingPointError(value: value, kind: kind)
        case .nilValue:
            return kind == .object || kind == .classObject || kind == .selector
                || kind == .pointer || kind == .block
                ? nil
                : "\(context) can use nil/NULL only for object, Class, SEL, block, or pointer values."
        case .string:
            return kind == .object ? nil : "\(context) can use a string only for object values."
        case .selector(let selector):
            guard kind == .selector else { return "\(context) requires a selector value." }
            return isRuntimeName(selector) ? nil : "\(context) contains an invalid selector name."
        case .classNamed(let className):
            guard kind == .classObject else { return "\(context) requires a Class value." }
            return isRuntimeName(className) ? nil : "\(context) contains an invalid class name."
        }
    }

    static func conditionIncompatibility(
        _ condition: PatchCondition,
        sourceType: ObjectiveCType
    ) -> String? {
        if let message = valueIncompatibility(
            condition.value,
            type: sourceType,
            context: "Conditional comparison"
        ) {
            return message
        }
        let supportsOrdering =
            sourceType.kind.isSignedInteger || sourceType.kind.isUnsignedInteger
            || sourceType.kind == .float || sourceType.kind == .double
        switch condition.comparison {
        case .equal, .notEqual:
            return nil
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            return supportsOrdering
                ? nil : "Ordered comparisons require an integer or floating-point source."
        }
    }

    private static func replacementError(
        _ replacement: PatchReturnValue,
        kind: ObjectiveCTypeKind
    ) -> String? {
        switch replacement {
        case .boolean:
            return kind == .boolean ? nil : replacementMismatch(replacement, kind: kind)
        case .signedInteger(let value):
            guard kind.isSignedInteger else { return replacementMismatch(replacement, kind: kind) }
            return integerRangeError(value: value, kind: kind)
        case .unsignedInteger(let value):
            guard kind.isUnsignedInteger else {
                return replacementMismatch(replacement, kind: kind)
            }
            return unsignedIntegerRangeError(value: value, kind: kind)
        case .floatingPoint(let value):
            guard kind == .float || kind == .double else {
                return replacementMismatch(replacement, kind: kind)
            }
            return floatingPointError(value: value, kind: kind)
        case .nilValue:
            return kind == .object || kind == .classObject || kind == .selector
                ? nil : replacementMismatch(replacement, kind: kind)
        case .classNamed(let className):
            guard kind == .classObject else { return replacementMismatch(replacement, kind: kind) }
            return isRuntimeName(className) ? nil : "Replacement contains an invalid class name."
        case .selector(let selector):
            guard kind == .selector else { return replacementMismatch(replacement, kind: kind) }
            return isRuntimeName(selector) ? nil : "Replacement contains an invalid selector name."
        case .string:
            return kind == .object ? nil : replacementMismatch(replacement, kind: kind)
        }
    }

    private static func objectValueError(_ value: PatchObjectValue) -> String? {
        switch value {
        case .url(let value):
            return value.isEmpty || URL(string: value) == nil
                ? "URL object construction requires a valid, non-empty URL string." : nil
        case .numberBoolean, .numberSignedInteger, .numberUnsignedInteger, .arrayOfStrings,
            .dictionaryOfStrings:
            return nil
        }
    }

    private static func isRuntimeName(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(where: \.isWhitespace)
            && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func replacementMismatch(
        _ replacement: PatchReturnValue,
        kind: ObjectiveCTypeKind
    ) -> String {
        "Replacement value '\(replacement.kind.rawValue)' is incompatible with return type '\(kind.rawValue)'."
    }

    private static func integerRangeError(
        value: Int64,
        kind: ObjectiveCTypeKind
    ) -> String? {
        let range: ClosedRange<Int64>
        switch kind {
        case .signedChar: range = Int64(Int8.min)...Int64(Int8.max)
        case .signedShort: range = Int64(Int16.min)...Int64(Int16.max)
        case .signedInt: range = Int64(Int32.min)...Int64(Int32.max)
        case .signedLong, .signedLongLong: range = Int64.min...Int64.max
        default: return "Signed integer action requires a signed integer return type."
        }
        return range.contains(value)
            ? nil : "Signed value \(value) does not fit return type '\(kind.rawValue)'."
    }

    private static func unsignedIntegerRangeError(
        value: UInt64,
        kind: ObjectiveCTypeKind
    ) -> String? {
        let maximum: UInt64
        switch kind {
        case .unsignedChar: maximum = UInt64(UInt8.max)
        case .unsignedShort: maximum = UInt64(UInt16.max)
        case .unsignedInt: maximum = UInt64(UInt32.max)
        case .unsignedLong, .unsignedLongLong: maximum = UInt64.max
        default: return "Unsigned integer action requires an unsigned integer return type."
        }
        return value <= maximum
            ? nil : "Unsigned value \(value) does not fit return type '\(kind.rawValue)'."
    }

    private static func floatingPointError(
        value: Double,
        kind: ObjectiveCTypeKind
    ) -> String? {
        guard kind == .float || kind == .double else {
            return "Floating-point action requires a float or double type."
        }
        guard value.isFinite else {
            return "Floating-point values must be finite; NaN and infinity are not supported."
        }
        if kind == .float {
            let converted = Float(value)
            if !converted.isFinite || (value != 0 && converted == 0) {
                return "Floating-point value \(value) does not fit return type 'float'."
            }
        }
        return nil
    }
}

private struct PatchTargetKey: Hashable {
    let className: String
    let selector: String
    let methodKind: ObjectiveCMethodKind

    init(_ patch: MethodPatch) {
        className = patch.className
        selector = patch.selector
        methodKind = patch.methodKind
    }

    var description: String {
        let marker = methodKind == .instance ? "-" : "+"
        return "\(marker)[\(className) \(selector)]"
    }
}
