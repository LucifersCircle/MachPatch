import Foundation
import MachPatchCore

public struct ObjectiveCSourceGenerator: Sendable {
    public init() {}

    public func generate(_ project: PatchProject) throws -> GeneratedSourceBundle {
        let report = PatchProjectValidator.validate(project)
        guard report.isValid else {
            throw ObjectiveCSourceGeneratorError.invalidProject(report.errors)
        }

        let contexts: [PatchGenerationContext] = try project.patches.enumerated().compactMap {
            index, patch in
            guard patch.enabled else { return nil }
            let signature = try ObjectiveCTypeEncodingDecoder.decodeMethodSignature(
                patch.expectedTypeEncoding
            )
            return try PatchGenerationContext(index: index, patch: patch, signature: signature)
        }
        let source = SourceRenderer(contexts: contexts).render()
        return GeneratedSourceBundle(files: [
            GeneratedSourceFile(
                relativePath: MachPatchGenerator.generatedSourceFileName,
                contents: source
            )
        ])
    }
}

public enum ObjectiveCSourceGeneratorError: Error, Equatable, LocalizedError, Sendable {
    case invalidProject([PatchProjectValidationIssue])
    case unsupportedType(ObjectiveCTypeKind)

    public var errorDescription: String? {
        switch self {
        case .invalidProject(let issues):
            "Patch project is invalid: \(issues.map(\.message).joined(separator: "; "))"
        case .unsupportedType(let kind):
            "Objective-C type '\(kind.rawValue)' cannot be generated."
        }
    }
}

private struct PatchGenerationContext {
    let index: Int
    let patch: MethodPatch
    let signature: ObjectiveCMethodSignature
    let identifier: String
    let returnType: String
    let arguments: [GeneratedArgument]

    init(
        index: Int,
        patch: MethodPatch,
        signature: ObjectiveCMethodSignature
    ) throws {
        self.index = index
        self.patch = patch
        self.signature = signature
        identifier =
            "MPPatch_\(index)_\(ObjectiveCIdentifier.sanitize(patch.className))_\(ObjectiveCIdentifier.sanitize(patch.selector))"
        returnType = try ObjectiveCTypeMapper.cType(for: signature.returnType)
        arguments = try signature.explicitArguments.enumerated().map { index, type in
            GeneratedArgument(
                name: "argument\(index)",
                cType: try ObjectiveCTypeMapper.cType(for: type),
                type: type
            )
        }
    }

    var replacementName: String { "\(identifier)_Replacement" }
    var functionTypeName: String { "\(identifier)_Function" }
    var originalName: String { "\(identifier)_Original" }
    var installName: String { "\(identifier)_Install" }
    var stateName: String { "\(identifier)_State" }
    var needsOriginalImplementation: Bool {
        switch patch.action {
        case .returnBoolean, .returnSignedInteger, .returnUnsignedInteger, .returnNil,
            .returnString:
            false
        case .logInvocation, .logArguments, .logOriginalReturnValue, .callOriginal,
            .callOriginalAndReplace:
            true
        }
    }

    var objcDescription: String {
        let marker = patch.methodKind == .instance ? "-" : "+"
        return "\(marker)[\(patch.className) \(patch.selector)]"
    }

    var originalCall: String {
        let explicit = arguments.map(\.name)
        return
            "\(originalName)(self, _cmd\(explicit.isEmpty ? "" : ", \(explicit.joined(separator: ", "))"))"
    }

    var retainedReturnFamily: Bool {
        guard signature.returnType.kind == .object else { return false }
        let selector = patch.selector.drop { $0 == "_" }
        return ["alloc", "copy", "mutableCopy", "new", "init"].contains { family in
            guard selector.hasPrefix(family) else { return false }
            let end = selector.index(selector.startIndex, offsetBy: family.count)
            guard end < selector.endIndex else { return true }
            let next = selector[end]
            return !next.isLowercase
        }
    }
}

private struct GeneratedArgument {
    let name: String
    let cType: String
    let type: ObjectiveCType
}

private enum ObjectiveCTypeMapper {
    static func cType(for type: ObjectiveCType) throws -> String {
        switch type.kind {
        case .void: "void"
        case .boolean: "BOOL"
        case .signedChar: "signed char"
        case .unsignedChar: "unsigned char"
        case .signedShort: "short"
        case .unsignedShort: "unsigned short"
        case .signedInt: "int"
        case .unsignedInt: "unsigned int"
        case .signedLong: "long"
        case .unsignedLong: "unsigned long"
        case .signedLongLong: "long long"
        case .unsignedLongLong: "unsigned long long"
        case .object: "id"
        case .classObject: "Class"
        case .selector: "SEL"
        default: throw ObjectiveCSourceGeneratorError.unsupportedType(type.kind)
        }
    }
}

private struct SourceRenderer {
    let contexts: [PatchGenerationContext]

    func render() -> String {
        var sections: [String] = [header]
        sections.append(contexts.map(renderPatch).joined(separator: "\n\n"))
        sections.append(renderInstallationCoordinator())
        sections.append(renderConstructor())
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    private var header: String {
        """
        // Generated by MachPatch. Do not edit.

        #import <Foundation/Foundation.h>
        #import <dispatch/dispatch.h>
        #import <objc/runtime.h>
        #include <string.h>

        typedef NS_ENUM(uint8_t, MPPatchState) {
            MPPatchStatePending = 0,
            MPPatchStateInstalled = 1,
            MPPatchStateFailed = 2,
        };
        """
    }

    private func renderPatch(_ context: PatchGenerationContext) -> String {
        var parts: [String] = [
            "static MPPatchState \(context.stateName) = MPPatchStatePending;"
        ]
        if context.needsOriginalImplementation {
            let functionArguments = (["id", "SEL"] + context.arguments.map(\.cType))
                .joined(separator: ", ")
            let attribute =
                context.retainedReturnFamily
                ? " __attribute__((ns_returns_retained))" : ""
            parts.append(
                "typedef \(context.returnType) (*\(context.functionTypeName))(\(functionArguments))\(attribute);"
            )
            parts.append(
                "static \(context.functionTypeName) \(context.originalName) = NULL;"
            )
        }
        if context.retainedReturnFamily {
            parts.append(
                "\(functionHeader(context)) __attribute__((ns_returns_retained));"
            )
        }
        parts.append(renderReplacement(context))
        parts.append(renderInstaller(context))
        return parts.joined(separator: "\n\n")
    }

    private func functionHeader(_ context: PatchGenerationContext) -> String {
        let parameters =
            (["id self", "SEL _cmd"]
            + context.arguments.map { "\($0.cType) \($0.name)" })
            .joined(separator: ",\n    ")
        return "static \(context.returnType) \(context.replacementName)(\n    \(parameters)\n)"
    }

    private func renderReplacement(_ context: PatchGenerationContext) -> String {
        let body = replacementBody(context).map { "    \($0)" }.joined(separator: "\n")
        return """
            \(functionHeader(context)) {
            \(body)
            }
            """
    }

    private func replacementBody(_ context: PatchGenerationContext) -> [String] {
        switch context.patch.action {
        case .returnBoolean(let value):
            return unusedParameterLines(context) + ["return \(value ? "YES" : "NO");"]
        case .returnSignedInteger(let value):
            return unusedParameterLines(context)
                + ["return (\(context.returnType))\(signedLiteral(value));"]
        case .returnUnsignedInteger(let value):
            return unusedParameterLines(context)
                + ["return (\(context.returnType))\(value)ULL;"]
        case .returnNil:
            return unusedParameterLines(context) + [
                context.signature.returnType.kind == .classObject ? "return Nil;" : "return nil;"
            ]
        case .returnString(let value):
            return unusedParameterLines(context)
                + ["return \(ObjectiveCLiteral.string(value));"]
        case .logInvocation:
            return logInvocation(context) + callOriginalAndReturn(context)
        case .logArguments:
            return logInvocation(context)
                + context.arguments.enumerated().map { index, argument in
                    logArgument(context, argument: argument, index: index)
                } + callOriginalAndReturn(context)
        case .logOriginalReturnValue:
            return logOriginalReturnValue(context)
        case .callOriginal:
            return callOriginalAndReturn(context)
        case .callOriginalAndReplace(let replacement):
            return ["\(context.originalCall);"]
                + ["return \(replacementExpression(replacement, context: context));"]
        }
    }

    private func unusedParameterLines(_ context: PatchGenerationContext) -> [String] {
        (["self", "_cmd"] + context.arguments.map(\.name)).map { "(void)\($0);" }
    }

    private func callOriginalAndReturn(_ context: PatchGenerationContext) -> [String] {
        context.signature.returnType.kind == .void
            ? ["\(context.originalCall);", "return;"]
            : ["return \(context.originalCall);"]
    }

    private func logInvocation(_ context: PatchGenerationContext) -> [String] {
        [
            "NSLog(@\"[MachPatch] Invoked %@\", \(ObjectiveCLiteral.string(context.objcDescription)));"
        ]
    }

    private func logArgument(
        _ context: PatchGenerationContext,
        argument: GeneratedArgument,
        index: Int
    ) -> String {
        let description = ObjectiveCLiteral.string(context.objcDescription)
        switch argument.type.kind {
        case .boolean:
            return
                "NSLog(@\"[MachPatch] %@ argument \(index + 1) = %d\", \(description), (int)\(argument.name));"
        case let kind where kind.isSignedInteger:
            return
                "NSLog(@\"[MachPatch] %@ argument \(index + 1) = %lld\", \(description), (long long)\(argument.name));"
        case let kind where kind.isUnsignedInteger:
            return
                "NSLog(@\"[MachPatch] %@ argument \(index + 1) = %llu\", \(description), (unsigned long long)\(argument.name));"
        case .object, .classObject:
            return
                "NSLog(@\"[MachPatch] %@ argument \(index + 1) = %@\", \(description), \(argument.name));"
        case .selector:
            return
                "NSLog(@\"[MachPatch] %@ argument \(index + 1) = %@\", \(description), NSStringFromSelector(\(argument.name)));"
        default:
            preconditionFailure("Unsupported argument reached source generation")
        }
    }

    private func logOriginalReturnValue(_ context: PatchGenerationContext) -> [String] {
        let result = "originalResult"
        var lines = ["\(context.returnType) \(result) = \(context.originalCall);"]
        let description = ObjectiveCLiteral.string(context.objcDescription)
        switch context.signature.returnType.kind {
        case .boolean:
            lines.append(
                "NSLog(@\"[MachPatch] %@ returned %d\", \(description), (int)\(result));"
            )
        case let kind where kind.isSignedInteger:
            lines.append(
                "NSLog(@\"[MachPatch] %@ returned %lld\", \(description), (long long)\(result));"
            )
        case let kind where kind.isUnsignedInteger:
            lines.append(
                "NSLog(@\"[MachPatch] %@ returned %llu\", \(description), (unsigned long long)\(result));"
            )
        case .object, .classObject:
            lines.append("NSLog(@\"[MachPatch] %@ returned %@\", \(description), \(result));")
        default:
            preconditionFailure("Unsupported return reached source generation")
        }
        lines.append("return \(result);")
        return lines
    }

    private func replacementExpression(
        _ replacement: PatchReturnValue,
        context: PatchGenerationContext
    ) -> String {
        switch replacement {
        case .boolean(let value): value ? "YES" : "NO"
        case .signedInteger(let value): "(\(context.returnType))\(signedLiteral(value))"
        case .unsignedInteger(let value): "(\(context.returnType))\(value)ULL"
        case .nilValue: context.signature.returnType.kind == .classObject ? "Nil" : "nil"
        case .string(let value): ObjectiveCLiteral.string(value)
        }
    }

    private func signedLiteral(_ value: Int64) -> String {
        value == Int64.min ? "(-9223372036854775807LL - 1LL)" : "\(value)LL"
    }

    private func renderInstaller(_ context: PatchGenerationContext) -> String {
        let description = ObjectiveCLiteral.string(context.objcDescription)
        let className = CLiteral.string(context.patch.className)
        let selector = CLiteral.string(context.patch.selector)
        let expectedEncoding = CLiteral.string(context.patch.expectedTypeEncoding)
        var lines = [
            "if (\(context.stateName) == MPPatchStateInstalled) { return YES; }",
            "if (\(context.stateName) == MPPatchStateFailed) { return NO; }",
            "",
            "Class cls = objc_getClass(\(className));",
            "if (cls == Nil) { return NO; }",
        ]
        if context.patch.methodKind == .class {
            lines.append("Class targetClass = object_getClass((id)cls);")
            lines.append("if (targetClass == Nil) { return NO; }")
        } else {
            lines.append("Class targetClass = cls;")
        }
        lines.append(contentsOf: [
            "SEL selector = sel_registerName(\(selector));",
            "Method method = class_getInstanceMethod(targetClass, selector);",
            "if (method == NULL) { return NO; }",
            "",
            "const char *encoding = method_getTypeEncoding(method);",
            "if (encoding == NULL || strcmp(encoding, \(expectedEncoding)) != 0) {",
            "    NSLog(@\"[MachPatch] Unexpected encoding for %@: %s\", \(description), encoding ?: \"(null)\");",
            "    \(context.stateName) = MPPatchStateFailed;",
            "    return NO;",
            "}",
        ])
        if context.needsOriginalImplementation {
            lines.append(contentsOf: [
                "",
                "IMP originalImplementation = method_getImplementation(method);",
                "if (originalImplementation == NULL) {",
                "    \(context.stateName) = MPPatchStateFailed;",
                "    return NO;",
                "}",
                "\(context.originalName) = (\(context.functionTypeName))originalImplementation;",
            ])
        }
        lines.append(contentsOf: [
            "method_setImplementation(method, (IMP)\(context.replacementName));",
            "\(context.stateName) = MPPatchStateInstalled;",
            "NSLog(@\"[MachPatch] Installed %@\", \(description));",
            "return YES;",
        ])

        return """
            static BOOL \(context.installName)(void) {
            \(lines.map { $0.isEmpty ? "" : "    \($0)" }.joined(separator: "\n"))
            }
            """
    }

    private func renderInstallationCoordinator() -> String {
        let pendingChecks = contexts.map { context in
            """
            if (\(context.stateName) == MPPatchStatePending) {
                \(context.installName)();
                if (\(context.stateName) == MPPatchStatePending) { pending += 1; }
            }
            """
        }
        let failureChecks = contexts.map { context in
            """
            if (\(context.stateName) == MPPatchStatePending) {
                NSLog(@"[MachPatch] Giving up on %@", \(ObjectiveCLiteral.string(context.objcDescription)));
                \(context.stateName) = MPPatchStateFailed;
            }
            """
        }
        return """
            static NSUInteger MPInstallPendingPatches(void) {
                NSUInteger pending = 0;
            \(pendingChecks.map { indent($0, spaces: 4) }.joined(separator: "\n"))
                return pending;
            }

            static void MPMarkPendingPatchesFailed(void) {
            \(failureChecks.map { indent($0, spaces: 4) }.joined(separator: "\n"))
            }

            static void MPScheduleRetry(NSTimeInterval delay, BOOL finalAttempt) {
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                    dispatch_get_main_queue(),
                    ^{
                        @autoreleasepool {
                            NSUInteger pending = MPInstallPendingPatches();
                            if (finalAttempt && pending > 0) {
                                MPMarkPendingPatchesFailed();
                            }
                        }
                    }
                );
            }
            """
    }

    private func renderConstructor() -> String {
        """
        __attribute__((constructor))
        static void MachPatchInitialize(void) {
            @autoreleasepool {
                NSLog(@"[MachPatch] Patch dylib loaded");
                if (MPInstallPendingPatches() > 0) {
                    MPScheduleRetry(1.0, NO);
                    MPScheduleRetry(3.0, NO);
                    MPScheduleRetry(8.0, YES);
                }
            }
        }
        """
    }

    private func indent(_ value: String, spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
    }
}

private enum CLiteral {
    static func string(_ value: String) -> String {
        "\"\(escapedBytes(value))\""
    }

    fileprivate static func escapedBytes(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 0x22: "\\\""
            case 0x5C: "\\\\"
            case 0x0A: "\\n"
            case 0x0D: "\\r"
            case 0x09: "\\t"
            case 0x20...0x7E: String(UnicodeScalar(byte))
            default: String(format: "\\%03o", byte)
            }
        }.joined()
    }
}

private enum ObjectiveCLiteral {
    static func string(_ value: String) -> String {
        "@\"\(CLiteral.escapedBytes(value))\""
    }
}
