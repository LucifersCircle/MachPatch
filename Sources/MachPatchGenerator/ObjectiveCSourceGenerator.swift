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
    var counterName: String { "\(identifier)_InvocationCounter" }
    var advanced: PatchAdvancedConfiguration { patch.advanced ?? PatchAdvancedConfiguration() }
    var needsOriginalImplementation: Bool {
        patch.action.callsOriginal
    }

    var needsInvocationCounter: Bool {
        advanced.invocationCounter != nil
    }

    var needsUIKit: Bool {
        (advanced.beforeEffects + advanced.afterEffects).contains { effect in
            switch effect {
            case .showAlert, .customObjectiveC: true
            }
        }
    }

    var needsAlertRuntime: Bool {
        (advanced.beforeEffects + advanced.afterEffects).contains { effect in
            if case .showAlert = effect { return true }
            return false
        }
    }

    var needsCoreGraphics: Bool {
        ([signature.returnType] + signature.explicitArguments).contains {
            $0.knownStructure?.requiresCoreGraphics == true
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
        if type.kind == .structure {
            guard let structure = type.knownStructure else {
                throw ObjectiveCSourceGeneratorError.unsupportedType(type.kind)
            }
            return structure.rawValue
        }
        return switch type.kind {
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
        case .float: "float"
        case .double: "double"
        case .object: "id"
        case .block: "id"
        case .classObject: "Class"
        case .selector: "SEL"
        case .pointer: "void *"
        default: throw ObjectiveCSourceGeneratorError.unsupportedType(type.kind)
        }
    }

    static func cTypeUnchecked(for type: ObjectiveCType) -> String {
        do {
            return try cType(for: type)
        } catch {
            preconditionFailure("Unsupported type reached source generation")
        }
    }
}

private struct SourceRenderer {
    let contexts: [PatchGenerationContext]

    func render() -> String {
        var sections: [String] = [header]
        if contexts.contains(where: \.needsAlertRuntime) {
            sections.append(alertRuntime)
        }
        sections.append(contexts.map(renderPatch).joined(separator: "\n\n"))
        sections.append(renderInstallationCoordinator())
        sections.append(renderConstructor())
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    private var header: String {
        var imports = """
            // Generated by MachPatch. Do not edit.
            // Logging destination: target-process NSLog, default severity, [MachPatch] prefix.

            #import <Foundation/Foundation.h>
            #import <dispatch/dispatch.h>
            #import <objc/runtime.h>
            #include <string.h>
            """
        if contexts.contains(where: \.needsUIKit) {
            imports += "\n#import <UIKit/UIKit.h>"
        }
        if contexts.contains(where: \.needsCoreGraphics) {
            imports += "\n#import <CoreGraphics/CoreGraphics.h>"
        }
        return imports + """


            typedef NS_ENUM(uint8_t, MPPatchState) {
                MPPatchStatePending = 0,
                MPPatchStateInstalled = 1,
                MPPatchStateFailed = 2,
            };
            """
    }

    private var alertRuntime: String {
        """
        static UIViewController *MPTopViewController(UIViewController *controller) {
            if (controller == nil) { return nil; }
            if (controller.presentedViewController != nil) {
                return MPTopViewController(controller.presentedViewController);
            }
            if ([controller isKindOfClass:[UINavigationController class]]) {
                return MPTopViewController(((UINavigationController *)controller).visibleViewController);
            }
            if ([controller isKindOfClass:[UITabBarController class]]) {
                return MPTopViewController(((UITabBarController *)controller).selectedViewController);
            }
            return controller;
        }

        static void MPShowAlert(NSString *title, NSString *message, NSString *buttonTitle) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIApplication *application = UIApplication.sharedApplication;
                UIWindow *window = nil;
                if (@available(iOS 13.0, *)) {
                    for (UIScene *scene in application.connectedScenes) {
                        if (scene.activationState != UISceneActivationStateForegroundActive ||
                            ![scene isKindOfClass:[UIWindowScene class]]) {
                            continue;
                        }
                        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                            if (candidate.isKeyWindow) {
                                window = candidate;
                                break;
                            }
                        }
                        if (window != nil) { break; }
                    }
                }
                if (window == nil) {
                    window = [application valueForKey:@"keyWindow"];
                }
                UIViewController *presenter = MPTopViewController(window.rootViewController);
                if (presenter == nil) {
                    NSLog(@"[MachPatch] Could not present alert because no active view controller was found.");
                    return;
                }
                if ([presenter isKindOfClass:[UIAlertController class]]) {
                    NSLog(@"[MachPatch] Suppressed alert because another alert is already visible.");
                    return;
                }
                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:title
                    message:message
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction
                    actionWithTitle:buttonTitle
                    style:UIAlertActionStyleDefault
                    handler:nil]];
                [presenter presentViewController:alert animated:YES completion:nil];
            });
        }
        """
    }

    private func renderPatch(_ context: PatchGenerationContext) -> String {
        var parts: [String] = [
            "static MPPatchState \(context.stateName) = MPPatchStatePending;"
        ]
        if context.needsInvocationCounter {
            parts.append("static uint64_t \(context.counterName) = 0;")
        }
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
        var prefix: [String] = []
        if let counter = context.advanced.invocationCounter {
            prefix.append(
                "uint64_t invocationCount = __atomic_add_fetch(&\(context.counterName), 1, __ATOMIC_RELAXED);"
            )
            if counter.logEachInvocation {
                prefix.append(
                    "NSLog(@\"[MachPatch] %@ invocation count = %llu\", \(ObjectiveCLiteral.string(context.objcDescription)), (unsigned long long)invocationCount);"
                )
            } else if context.advanced.conditionalReturn?.condition.source != .invocationCount {
                prefix.append("(void)invocationCount;")
            }
        }
        prefix.append(
            contentsOf: renderEffects(context.advanced.beforeEffects, phase: "before-original")
        )
        if let conditionalReturn = context.advanced.conditionalReturn {
            prefix.append(
                "if (\(conditionExpression(conditionalReturn.condition, context: context))) {"
            )
            prefix.append(
                "    return \(replacementExpression(conditionalReturn.replacement, context: context));"
            )
            prefix.append("}")
        }
        prefix.append(contentsOf: argumentReplacementLines(context))

        let primary: [String]
        switch context.patch.action {
        case .returnBoolean(let value):
            primary = unusedParameterLines(context) + ["return \(value ? "YES" : "NO");"]
        case .returnSignedInteger(let value):
            primary =
                unusedParameterLines(context)
                + ["return (\(context.returnType))\(signedLiteral(value));"]
        case .returnUnsignedInteger(let value):
            primary =
                unusedParameterLines(context)
                + ["return (\(context.returnType))\(value)ULL;"]
        case .returnFloatingPoint(let value):
            primary =
                unusedParameterLines(context)
                + ["return \(floatingLiteral(value, kind: context.signature.returnType.kind));"]
        case .returnNil:
            primary =
                unusedParameterLines(context)
                + ["return \(nullLiteral(for: context.signature.returnType.kind));"]
        case .returnClassNamed(let className):
            primary =
                unusedParameterLines(context)
                + ["return objc_getClass(\(CLiteral.string(className)));"]
        case .returnSelector(let selector):
            primary =
                unusedParameterLines(context)
                + ["return sel_registerName(\(CLiteral.string(selector)));"]
        case .returnString(let value):
            primary =
                unusedParameterLines(context)
                + ["return \(ObjectiveCLiteral.string(value));"]
        case .returnObject(let value):
            primary = unusedParameterLines(context) + ["return \(objectExpression(value));"]
        case .logInvocation:
            primary = logInvocation(context) + callOriginalAndReturn(context)
        case .logArguments:
            primary =
                logInvocation(context)
                + context.arguments.enumerated().map { index, argument in
                    logArgument(context, argument: argument, index: index)
                } + callOriginalAndReturn(context)
        case .logOriginalReturnValue:
            primary = logOriginalReturnValue(context)
        case .callOriginal:
            primary = callOriginalAndReturn(context)
        case .callOriginalAndReplace(let replacement):
            primary =
                callOriginalForEffects(context)
                + renderEffects(context.advanced.afterEffects, phase: "after-original")
                + (context.signature.returnType.kind == .void ? [] : ["(void)originalResult;"])
                + ["return \(replacementExpression(replacement, context: context));"]
        }
        return prefix + primary
    }

    private func unusedParameterLines(_ context: PatchGenerationContext) -> [String] {
        (["self", "_cmd"] + context.arguments.map(\.name)).map { "(void)\($0);" }
    }

    private func callOriginalAndReturn(_ context: PatchGenerationContext) -> [String] {
        callOriginalForEffects(context)
            + renderEffects(context.advanced.afterEffects, phase: "after-original")
            + (context.signature.returnType.kind == .void
                ? ["return;"] : ["return originalResult;"])
    }

    private func callOriginalForEffects(_ context: PatchGenerationContext) -> [String] {
        context.signature.returnType.kind == .void
            ? ["\(context.originalCall);"]
            : ["\(context.returnType) originalResult = \(context.originalCall);"]
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
        case .float:
            return
                "NSLog(@\"[MachPatch] %@ argument \(index + 1) = %.9g\", \(description), (double)\(argument.name));"
        case .double:
            return
                "NSLog(@\"[MachPatch] %@ argument \(index + 1) = %.17g\", \(description), \(argument.name));"
        case .object, .classObject:
            return
                "NSLog(@\"[MachPatch] %@ argument \(index + 1) = %@\", \(description), \(argument.name));"
        case .selector:
            return
                "NSLog(@\"[MachPatch] %@ argument \(index + 1) = %@\", \(description), NSStringFromSelector(\(argument.name)));"
        case .block:
            return
                "NSLog(@\"[MachPatch] %@ argument \(index + 1) block address = %p\", \(description), (__bridge void *)\(argument.name));"
        case .pointer:
            return
                "NSLog(@\"[MachPatch] %@ argument \(index + 1) pointer = %p\", \(description), (void *)\(argument.name));"
        case .structure:
            return logStructure(
                argument.type,
                expression: argument.name,
                prefix: "[MachPatch] %@ argument \(index + 1)",
                description: description
            )
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
        case .float:
            lines.append(
                "NSLog(@\"[MachPatch] %@ returned %.9g\", \(description), (double)\(result));"
            )
        case .double:
            lines.append(
                "NSLog(@\"[MachPatch] %@ returned %.17g\", \(description), \(result));"
            )
        case .object, .classObject:
            lines.append("NSLog(@\"[MachPatch] %@ returned %@\", \(description), \(result));")
        case .selector:
            lines.append(
                "NSLog(@\"[MachPatch] %@ returned %@\", \(description), \(result) == NULL ? @\"(null)\" : NSStringFromSelector(\(result)));"
            )
        case .structure:
            lines.append(
                logStructure(
                    context.signature.returnType,
                    expression: result,
                    prefix: "[MachPatch] %@ returned",
                    description: description
                )
            )
        default:
            preconditionFailure("Unsupported return reached source generation")
        }
        return lines + renderEffects(context.advanced.afterEffects, phase: "after-original")
            + ["return \(result);"]
    }

    private func logStructure(
        _ type: ObjectiveCType,
        expression: String,
        prefix: String,
        description: String
    ) -> String {
        switch type.knownStructure {
        case .cgPoint:
            return
                "NSLog(@\"\(prefix) CGPoint { x = %.17g, y = %.17g }\", \(description), (double)\(expression).x, (double)\(expression).y);"
        case .cgSize:
            return
                "NSLog(@\"\(prefix) CGSize { width = %.17g, height = %.17g }\", \(description), (double)\(expression).width, (double)\(expression).height);"
        case .cgRect:
            return
                "NSLog(@\"\(prefix) CGRect { x = %.17g, y = %.17g, width = %.17g, height = %.17g }\", \(description), (double)\(expression).origin.x, (double)\(expression).origin.y, (double)\(expression).size.width, (double)\(expression).size.height);"
        case .nsRange:
            return
                "NSLog(@\"\(prefix) NSRange { location = %llu, length = %llu }\", \(description), (unsigned long long)\(expression).location, (unsigned long long)\(expression).length);"
        case nil:
            preconditionFailure("Unsupported structure reached source generation")
        }
    }

    private func argumentReplacementLines(_ context: PatchGenerationContext) -> [String] {
        context.advanced.argumentReplacements.sorted { $0.argumentIndex < $1.argumentIndex }.map {
            replacement in
            let argument = context.arguments[replacement.argumentIndex]
            return
                "\(argument.name) = \(valueExpression(replacement.value, target: argument.type, cType: argument.cType));"
        }
    }

    private func renderEffects(_ effects: [PatchEffect], phase: String) -> [String] {
        effects.flatMap { effect in
            switch effect {
            case .showAlert(let alert):
                return [
                    "MPShowAlert(\(ObjectiveCLiteral.string(alert.title)), \(ObjectiveCLiteral.string(alert.message)), \(ObjectiveCLiteral.string(alert.buttonTitle)));"
                ]
            case .customObjectiveC(let custom):
                let sourceLines = custom.source.split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                ).map(String.init)
                return ["{", "    // MachPatch custom \(phase) code"]
                    + sourceLines.map { "    \($0)" } + ["}"]
            }
        }
    }

    private func conditionExpression(
        _ condition: PatchCondition,
        context: PatchGenerationContext
    ) -> String {
        let source: String
        let type: ObjectiveCType
        switch condition.source {
        case .argument(let index):
            source = context.arguments[index].name
            type = context.arguments[index].type
        case .invocationCount:
            source = "invocationCount"
            type = ObjectiveCType(encoding: "Q", kind: .unsignedLongLong)
        }

        switch type.kind {
        case .object:
            let equality: String
            switch condition.value {
            case .nilValue:
                equality = "\(source) == nil"
            case .string(let value):
                equality = "[\(source) isEqual:\(ObjectiveCLiteral.string(value))]"
            default:
                preconditionFailure("Invalid object condition reached source generation")
            }
            return condition.comparison == .notEqual ? "!(\(equality))" : equality
        case .classObject:
            let equality: String
            switch condition.value {
            case .nilValue:
                equality = "\(source) == Nil"
            case .classNamed(let value):
                equality = "\(source) == objc_getClass(\(CLiteral.string(value)))"
            default:
                preconditionFailure("Invalid Class condition reached source generation")
            }
            return condition.comparison == .notEqual ? "!(\(equality))" : equality
        case .selector:
            let equality: String
            switch condition.value {
            case .nilValue:
                equality = "\(source) == NULL"
            case .selector(let value):
                equality =
                    "sel_isEqual(\(source), sel_registerName(\(CLiteral.string(value))))"
            default:
                preconditionFailure("Invalid selector condition reached source generation")
            }
            return condition.comparison == .notEqual ? "!(\(equality))" : equality
        default:
            let cType = ObjectiveCTypeMapper.cTypeUnchecked(for: type)
            return
                "\(source) \(comparisonOperator(condition.comparison)) \(valueExpression(condition.value, target: type, cType: cType))"
        }
    }

    private func comparisonOperator(_ comparison: PatchComparison) -> String {
        switch comparison {
        case .equal: "=="
        case .notEqual: "!="
        case .lessThan: "<"
        case .lessThanOrEqual: "<="
        case .greaterThan: ">"
        case .greaterThanOrEqual: ">="
        }
    }

    private func valueExpression(
        _ value: PatchValue,
        target: ObjectiveCType,
        cType: String
    ) -> String {
        switch value {
        case .boolean(let value): value ? "YES" : "NO"
        case .signedInteger(let value): "(\(cType))\(signedLiteral(value))"
        case .unsignedInteger(let value): "(\(cType))\(value)ULL"
        case .floatingPoint(let value): floatingLiteral(value, kind: target.kind)
        case .nilValue: nullLiteral(for: target.kind)
        case .string(let value): ObjectiveCLiteral.string(value)
        case .selector(let value): "sel_registerName(\(CLiteral.string(value)))"
        case .classNamed(let value): "objc_getClass(\(CLiteral.string(value)))"
        }
    }

    private func objectExpression(_ value: PatchObjectValue) -> String {
        switch value {
        case .numberBoolean(let value):
            return "[NSNumber numberWithBool:\(value ? "YES" : "NO")]"
        case .numberSignedInteger(let value):
            return "[NSNumber numberWithLongLong:\(signedLiteral(value))]"
        case .numberUnsignedInteger(let value):
            return "[NSNumber numberWithUnsignedLongLong:\(value)ULL]"
        case .arrayOfStrings(let values):
            return "@[\(values.map(ObjectiveCLiteral.string).joined(separator: ", "))]"
        case .dictionaryOfStrings(let values):
            let entries = values.keys.sorted().map { key in
                "\(ObjectiveCLiteral.string(key)): \(ObjectiveCLiteral.string(values[key] ?? ""))"
            }
            return "@{\(entries.joined(separator: ", "))}"
        case .url(let value):
            return "[NSURL URLWithString:\(ObjectiveCLiteral.string(value))]"
        }
    }

    private func replacementExpression(
        _ replacement: PatchReturnValue,
        context: PatchGenerationContext
    ) -> String {
        switch replacement {
        case .boolean(let value): value ? "YES" : "NO"
        case .signedInteger(let value): "(\(context.returnType))\(signedLiteral(value))"
        case .unsignedInteger(let value): "(\(context.returnType))\(value)ULL"
        case .floatingPoint(let value):
            floatingLiteral(value, kind: context.signature.returnType.kind)
        case .nilValue: nullLiteral(for: context.signature.returnType.kind)
        case .classNamed(let className): "objc_getClass(\(CLiteral.string(className)))"
        case .selector(let selector): "sel_registerName(\(CLiteral.string(selector)))"
        case .string(let value): ObjectiveCLiteral.string(value)
        }
    }

    private func floatingLiteral(_ value: Double, kind: ObjectiveCTypeKind) -> String {
        if kind == .float {
            return "\(hexadecimalFloatingLiteral(Double(Float(value))))f"
        }
        return hexadecimalFloatingLiteral(value)
    }

    private func hexadecimalFloatingLiteral(_ value: Double) -> String {
        String(
            format: "%a",
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: [value]
        )
    }

    private func nullLiteral(for kind: ObjectiveCTypeKind) -> String {
        switch kind {
        case .classObject: "Nil"
        case .selector, .pointer: "NULL"
        default: "nil"
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
