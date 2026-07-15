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
    case invalidMinimumIOSVersion
    case invalidOutputName
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
    case targetNotAnalyzed
    case targetHashMismatch
    case targetExecutableNameMismatch
    case targetBundleIdentifierMismatch
    case targetMinimumIOSVersionMismatch
    case targetArchitectureMismatch
    case targetCPUSubtypeMismatch
    case classNotFound
    case methodNotFound
    case methodKindMismatch
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
        return errors
    }

    private static func validate(
        _ signature: ObjectiveCMethodSignature,
        selector: String,
        patchID: String
    ) -> [PatchProjectValidationIssue] {
        var errors: [PatchProjectValidationIssue] = []
        guard signature.arguments.count >= 2 else {
            return [
                issue(
                    .invalidMethodSignature,
                    "Method encoding must contain the implicit self and selector arguments.",
                    patchID: patchID
                )
            ]
        }
        if signature.arguments[0].kind != .object
            || signature.arguments[1].kind != .selector
        {
            errors.append(
                issue(
                    .invalidMethodSignature,
                    "Method encoding must begin with the implicit object and selector arguments ('@:').",
                    patchID: patchID
                )
            )
        }

        let selectorArgumentCount = selector.filter { $0 == ":" }.count
        if selectorArgumentCount != signature.explicitArguments.count {
            errors.append(
                issue(
                    .invalidSelector,
                    "Selector has \(selectorArgumentCount) parameter markers, but its encoding has \(signature.explicitArguments.count) explicit arguments.",
                    patchID: patchID
                )
            )
        }
        if !PatchActionCompatibility.isSupportedReturnType(signature.returnType.kind) {
            errors.append(
                issue(
                    .unsupportedReturnType,
                    "Return type '\(signature.returnType.encoding)' is unsupported for MVP patches.",
                    patchID: patchID
                )
            )
        }
        for (index, argument) in signature.explicitArguments.enumerated()
        where !PatchActionCompatibility.isSupportedArgumentType(argument.kind) {
            errors.append(
                issue(
                    .unsupportedArgumentType,
                    "Argument \(index + 1) type '\(argument.encoding)' is unsupported for MVP patches.",
                    patchID: patchID
                )
            )
        }
        return errors
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
        case .object:
            actions.append(contentsOf: [
                .returnNil,
                .returnString,
                .logOriginalReturnValue,
                .callOriginalAndReplace,
            ])
        case .classObject:
            actions.append(contentsOf: [
                .returnNil,
                .logOriginalReturnValue,
                .callOriginalAndReplace,
            ])
        default:
            break
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
        case .callOriginalAndReplace(let replacement):
            return replacementError(replacement, kind: signature.returnType.kind)
        default:
            return nil
        }
    }

    static func isSupportedReturnType(_ kind: ObjectiveCTypeKind) -> Bool {
        kind == .void || kind == .boolean || kind.isSignedInteger || kind.isUnsignedInteger
            || kind == .object || kind == .classObject
    }

    static func isSupportedArgumentType(_ kind: ObjectiveCTypeKind) -> Bool {
        kind == .boolean || kind.isSignedInteger || kind.isUnsignedInteger || kind == .object
            || kind == .classObject || kind == .selector
    }

    private static func isSupportedSignature(_ signature: ObjectiveCMethodSignature) -> Bool {
        signature.arguments.count >= 2
            && signature.arguments[0].kind == .object
            && signature.arguments[1].kind == .selector
            && isSupportedReturnType(signature.returnType.kind)
            && signature.explicitArguments.allSatisfy { isSupportedArgumentType($0.kind) }
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
        case .nilValue:
            return kind == .object || kind == .classObject
                ? nil : replacementMismatch(replacement, kind: kind)
        case .string:
            return kind == .object ? nil : replacementMismatch(replacement, kind: kind)
        }
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
