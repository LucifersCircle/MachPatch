import Foundation

public enum ObjectiveCMethodPatchabilityIssueCode: String, Codable, Equatable, Hashable, Sendable {
    case missingTypeEncoding
    case invalidTypeEncoding
    case invalidImplicitArguments
    case selectorArgumentCountMismatch
    case unsupportedReturnType
    case unsupportedArgumentType
    case noCompatibleActions

    public var displayName: String {
        switch self {
        case .missingTypeEncoding:
            "Missing type encoding"
        case .invalidTypeEncoding:
            "Invalid type encoding"
        case .invalidImplicitArguments:
            "Invalid self/_cmd arguments"
        case .selectorArgumentCountMismatch:
            "Selector argument mismatch"
        case .unsupportedReturnType:
            "Unsupported return type"
        case .unsupportedArgumentType:
            "Unsupported argument type"
        case .noCompatibleActions:
            "No compatible actions"
        }
    }
}

public struct ObjectiveCMethodPatchabilityIssue: Codable, Equatable, Sendable {
    public let code: ObjectiveCMethodPatchabilityIssueCode
    public let message: String
    public let typeKind: ObjectiveCTypeKind?
    public let typeEncoding: String?
    public let argumentPosition: Int?

    public init(
        code: ObjectiveCMethodPatchabilityIssueCode,
        message: String,
        typeKind: ObjectiveCTypeKind? = nil,
        typeEncoding: String? = nil,
        argumentPosition: Int? = nil
    ) {
        self.code = code
        self.message = message
        self.typeKind = typeKind
        self.typeEncoding = typeEncoding
        self.argumentPosition = argumentPosition
    }
}

public struct ObjectiveCMethodPatchability: Codable, Equatable, Sendable {
    public let className: String
    public let categoryName: String?
    public let selector: String
    public let methodKind: ObjectiveCMethodKind
    public let typeEncoding: String?
    public let signature: ObjectiveCMethodSignature?
    public let compatibleActions: [PatchActionKind]
    public let issues: [ObjectiveCMethodPatchabilityIssue]

    public init(
        className: String,
        categoryName: String?,
        selector: String,
        methodKind: ObjectiveCMethodKind,
        typeEncoding: String?,
        signature: ObjectiveCMethodSignature?,
        compatibleActions: [PatchActionKind],
        issues: [ObjectiveCMethodPatchabilityIssue]
    ) {
        self.className = className
        self.categoryName = categoryName
        self.selector = selector
        self.methodKind = methodKind
        self.typeEncoding = typeEncoding
        self.signature = signature
        self.compatibleActions = compatibleActions
        self.issues = issues
    }

    public var isPatchable: Bool { issues.isEmpty && !compatibleActions.isEmpty }

    public var isAvailableInEditor: Bool { categoryName == nil && isPatchable }
}

public struct ObjectiveCPatchabilityIssueCount: Codable, Equatable, Sendable {
    public let code: ObjectiveCMethodPatchabilityIssueCode
    public let count: Int

    public init(code: ObjectiveCMethodPatchabilityIssueCode, count: Int) {
        self.code = code
        self.count = count
    }
}

public enum ObjectiveCUnsupportedTypeRole: String, Codable, Equatable, Hashable, Sendable {
    case returnValue
    case argument
}

public struct ObjectiveCUnsupportedTypeCount: Codable, Equatable, Sendable {
    public let role: ObjectiveCUnsupportedTypeRole
    public let typeKind: ObjectiveCTypeKind
    public let typeEncoding: String
    public let count: Int

    public init(
        role: ObjectiveCUnsupportedTypeRole,
        typeKind: ObjectiveCTypeKind,
        typeEncoding: String,
        count: Int
    ) {
        self.role = role
        self.typeKind = typeKind
        self.typeEncoding = typeEncoding
        self.count = count
    }
}

public struct ObjectiveCPatchabilitySummary: Codable, Equatable, Sendable {
    public let classCount: Int
    public let categoryCount: Int
    public let classMethodCount: Int
    public let categoryMethodCount: Int
    public let patchableClassMethodCount: Int
    public let patchableCategoryMethodCount: Int
    public let unavailableClassMethodCount: Int
    public let unavailableCategoryMethodCount: Int
    public let issueCounts: [ObjectiveCPatchabilityIssueCount]
    public let unsupportedTypeCounts: [ObjectiveCUnsupportedTypeCount]

    public init(
        classCount: Int,
        categoryCount: Int,
        classMethodCount: Int,
        categoryMethodCount: Int,
        patchableClassMethodCount: Int,
        patchableCategoryMethodCount: Int,
        unavailableClassMethodCount: Int,
        unavailableCategoryMethodCount: Int,
        issueCounts: [ObjectiveCPatchabilityIssueCount],
        unsupportedTypeCounts: [ObjectiveCUnsupportedTypeCount]
    ) {
        self.classCount = classCount
        self.categoryCount = categoryCount
        self.classMethodCount = classMethodCount
        self.categoryMethodCount = categoryMethodCount
        self.patchableClassMethodCount = patchableClassMethodCount
        self.patchableCategoryMethodCount = patchableCategoryMethodCount
        self.unavailableClassMethodCount = unavailableClassMethodCount
        self.unavailableCategoryMethodCount = unavailableCategoryMethodCount
        self.issueCounts = issueCounts
        self.unsupportedTypeCounts = unsupportedTypeCounts
    }

    public var methodCount: Int { classMethodCount + categoryMethodCount }

    public var patchableMethodCount: Int {
        patchableClassMethodCount + patchableCategoryMethodCount
    }

    public var unavailableMethodCount: Int {
        unavailableClassMethodCount + unavailableCategoryMethodCount
    }
}

public struct ObjectiveCPatchabilityReport: Codable, Equatable, Sendable {
    public let summary: ObjectiveCPatchabilitySummary
    public let methods: [ObjectiveCMethodPatchability]

    public init(
        summary: ObjectiveCPatchabilitySummary,
        methods: [ObjectiveCMethodPatchability]
    ) {
        self.summary = summary
        self.methods = methods
    }
}

public enum ObjectiveCPatchabilityAnalyzer {
    public static func report(for metadata: ObjectiveCMetadata) -> ObjectiveCPatchabilityReport {
        var methods: [ObjectiveCMethodPatchability] = []

        for objectiveCClass in metadata.classes {
            methods.append(
                contentsOf: objectiveCClass.instanceMethods.map {
                    evaluate(className: objectiveCClass.name, categoryName: nil, method: $0)
                })
            methods.append(
                contentsOf: objectiveCClass.classMethods.map {
                    evaluate(className: objectiveCClass.name, categoryName: nil, method: $0)
                })
        }

        for category in metadata.categories {
            methods.append(
                contentsOf: category.instanceMethods.map {
                    evaluate(
                        className: category.className,
                        categoryName: category.name,
                        method: $0
                    )
                })
            methods.append(
                contentsOf: category.classMethods.map {
                    evaluate(
                        className: category.className,
                        categoryName: category.name,
                        method: $0
                    )
                })
        }

        methods.sort(by: methodOrdering)

        let classMethods = methods.filter { $0.categoryName == nil }
        let categoryMethods = methods.filter { $0.categoryName != nil }
        var issueCounts: [ObjectiveCMethodPatchabilityIssueCode: Int] = [:]
        var unsupportedTypeCounts: [UnsupportedTypeKey: Int] = [:]
        for issue in methods.flatMap(\.issues) {
            issueCounts[issue.code, default: 0] += 1
            guard let typeKind = issue.typeKind, let typeEncoding = issue.typeEncoding else {
                continue
            }
            let role: ObjectiveCUnsupportedTypeRole
            switch issue.code {
            case .unsupportedReturnType:
                role = .returnValue
            case .unsupportedArgumentType:
                role = .argument
            default:
                continue
            }
            unsupportedTypeCounts[
                UnsupportedTypeKey(
                    role: role,
                    typeKind: typeKind,
                    typeEncoding: typeEncoding
                ),
                default: 0
            ] += 1
        }

        let summary = ObjectiveCPatchabilitySummary(
            classCount: metadata.classes.count,
            categoryCount: metadata.categories.count,
            classMethodCount: classMethods.count,
            categoryMethodCount: categoryMethods.count,
            patchableClassMethodCount: classMethods.count(where: \.isPatchable),
            patchableCategoryMethodCount: categoryMethods.count(where: \.isPatchable),
            unavailableClassMethodCount: classMethods.count(where: { !$0.isPatchable }),
            unavailableCategoryMethodCount: categoryMethods.count(where: { !$0.isPatchable }),
            issueCounts: issueCounts.map {
                ObjectiveCPatchabilityIssueCount(code: $0.key, count: $0.value)
            }.sorted {
                $0.count == $1.count
                    ? $0.code.rawValue < $1.code.rawValue
                    : $0.count > $1.count
            },
            unsupportedTypeCounts: unsupportedTypeCounts.map {
                ObjectiveCUnsupportedTypeCount(
                    role: $0.key.role,
                    typeKind: $0.key.typeKind,
                    typeEncoding: $0.key.typeEncoding,
                    count: $0.value
                )
            }.sorted(by: unsupportedTypeOrdering)
        )
        return ObjectiveCPatchabilityReport(summary: summary, methods: methods)
    }

    public static func evaluate(
        className: String,
        categoryName: String? = nil,
        method: ObjectiveCMethod
    ) -> ObjectiveCMethodPatchability {
        guard let typeEncoding = method.typeEncoding,
            !typeEncoding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return ObjectiveCMethodPatchability(
                className: className,
                categoryName: categoryName,
                selector: method.selector,
                methodKind: method.kind,
                typeEncoding: method.typeEncoding,
                signature: nil,
                compatibleActions: [],
                issues: [
                    ObjectiveCMethodPatchabilityIssue(
                        code: .missingTypeEncoding,
                        message: "The method declaration does not include a type encoding."
                    )
                ]
            )
        }

        let signature: ObjectiveCMethodSignature
        do {
            signature = try ObjectiveCTypeEncodingDecoder.decodeMethodSignature(typeEncoding)
        } catch {
            return ObjectiveCMethodPatchability(
                className: className,
                categoryName: categoryName,
                selector: method.selector,
                methodKind: method.kind,
                typeEncoding: typeEncoding,
                signature: nil,
                compatibleActions: [],
                issues: [
                    ObjectiveCMethodPatchabilityIssue(
                        code: .invalidTypeEncoding,
                        message: error.localizedDescription
                    )
                ]
            )
        }

        let issues = signatureIssues(for: signature, selector: method.selector)
        let compatibleActions =
            issues.isEmpty
            ? PatchActionCompatibility.allowedActions(for: signature)
            : []

        return ObjectiveCMethodPatchability(
            className: className,
            categoryName: categoryName,
            selector: method.selector,
            methodKind: method.kind,
            typeEncoding: typeEncoding,
            signature: signature,
            compatibleActions: compatibleActions,
            issues: issues
        )
    }

    static func signatureIssues(
        for signature: ObjectiveCMethodSignature,
        selector: String
    ) -> [ObjectiveCMethodPatchabilityIssue] {
        var issues: [ObjectiveCMethodPatchabilityIssue] = []
        if signature.arguments.count < 2
            || signature.arguments[0].kind != .object
            || signature.arguments[1].kind != .selector
        {
            issues.append(
                ObjectiveCMethodPatchabilityIssue(
                    code: .invalidImplicitArguments,
                    message:
                        "The encoding must begin with the implicit object and selector arguments ('@:')."
                )
            )
        }

        let selectorArgumentCount = selector.count(where: { $0 == ":" })
        if selectorArgumentCount != signature.explicitArguments.count {
            issues.append(
                ObjectiveCMethodPatchabilityIssue(
                    code: .selectorArgumentCountMismatch,
                    message:
                        "The selector has \(selectorArgumentCount) parameter markers, but the encoding has \(signature.explicitArguments.count) explicit arguments."
                )
            )
        }

        if !PatchActionCompatibility.isSupportedReturnType(signature.returnType.kind) {
            issues.append(
                ObjectiveCMethodPatchabilityIssue(
                    code: .unsupportedReturnType,
                    message:
                        "Return type '\(signature.returnType.encoding)' is not supported by the patch editor.",
                    typeKind: signature.returnType.kind,
                    typeEncoding: signature.returnType.encoding
                )
            )
        }

        for (index, argument) in signature.explicitArguments.enumerated()
        where !PatchActionCompatibility.isSupportedArgumentType(argument.kind) {
            issues.append(
                ObjectiveCMethodPatchabilityIssue(
                    code: .unsupportedArgumentType,
                    message:
                        "Argument \(index + 1) type '\(argument.encoding)' is not supported by the patch editor.",
                    typeKind: argument.kind,
                    typeEncoding: argument.encoding,
                    argumentPosition: index + 1
                )
            )
        }

        if issues.isEmpty && PatchActionCompatibility.allowedActions(for: signature).isEmpty {
            issues.append(
                ObjectiveCMethodPatchabilityIssue(
                    code: .noCompatibleActions,
                    message: "The signature has no compatible patch actions."
                )
            )
        }
        return issues
    }

    private static func methodOrdering(
        _ lhs: ObjectiveCMethodPatchability,
        _ rhs: ObjectiveCMethodPatchability
    ) -> Bool {
        if lhs.className != rhs.className { return lhs.className < rhs.className }
        switch (lhs.categoryName, rhs.categoryName) {
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case (.some(let lhsName), .some(let rhsName)) where lhsName != rhsName:
            return lhsName < rhsName
        default:
            break
        }
        if lhs.methodKind != rhs.methodKind {
            return lhs.methodKind.rawValue < rhs.methodKind.rawValue
        }
        if lhs.selector != rhs.selector { return lhs.selector < rhs.selector }
        return (lhs.typeEncoding ?? "") < (rhs.typeEncoding ?? "")
    }

    private static func unsupportedTypeOrdering(
        _ lhs: ObjectiveCUnsupportedTypeCount,
        _ rhs: ObjectiveCUnsupportedTypeCount
    ) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        if lhs.role != rhs.role { return lhs.role.rawValue < rhs.role.rawValue }
        if lhs.typeKind != rhs.typeKind { return lhs.typeKind.rawValue < rhs.typeKind.rawValue }
        return lhs.typeEncoding < rhs.typeEncoding
    }

    private struct UnsupportedTypeKey: Hashable {
        let role: ObjectiveCUnsupportedTypeRole
        let typeKind: ObjectiveCTypeKind
        let typeEncoding: String
    }
}
