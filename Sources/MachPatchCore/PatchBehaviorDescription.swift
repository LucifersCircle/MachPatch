public extension MethodPatch {
    var behaviorSummary: String {
        var components = [action.behaviorSummary]
        guard let advanced, !advanced.isEmpty else {
            return components[0]
        }

        if let counter = advanced.invocationCounter {
            components.append(
                counter.logEachInvocation ? "Counts and logs invocations" : "Counts invocations"
            )
        }
        if !advanced.argumentReplacements.isEmpty {
            let count = advanced.argumentReplacements.count
            components.append("Changes \(count) argument\(count == 1 ? "" : "s")")
        }
        if advanced.conditionalReturn != nil {
            components.append("Uses a conditional return")
        }
        components.append(contentsOf: advanced.beforeEffects.behaviorSummaries(position: "before"))
        components.append(contentsOf: advanced.afterEffects.behaviorSummaries(position: "after"))
        return components.joined(separator: " · ")
    }
}

private extension PatchAction {
    var behaviorSummary: String {
        switch self {
        case .returnBoolean(let value):
            "Returns \(value ? "True" : "False")"
        case .returnSignedInteger(let value):
            "Returns \(value)"
        case .returnUnsignedInteger(let value):
            "Returns \(value)"
        case .returnFloatingPoint(let value):
            "Returns \(value)"
        case .returnNil:
            "Returns nil"
        case .returnClassNamed(let className):
            "Returns class \(className)"
        case .returnSelector(let selector):
            "Returns selector \(selector)"
        case .returnString(let value):
            value.isEmpty ? "Returns an empty string" : "Returns “\(value)”"
        case .returnObject(let value):
            "Returns \(value.behaviorSummary)"
        case .logInvocation:
            "Calls original and logs the invocation"
        case .logArguments:
            "Calls original and logs its arguments"
        case .logOriginalReturnValue:
            "Calls original and logs its result"
        case .callOriginal:
            "Calls original unchanged"
        case .callOriginalAndReplace(let replacement):
            "Calls original, then returns \(replacement.behaviorSummary)"
        }
    }
}

private extension PatchObjectValue {
    var behaviorSummary: String {
        switch self {
        case .numberBoolean(let value): "NSNumber(\(value ? "True" : "False"))"
        case .numberSignedInteger(let value): "NSNumber(\(value))"
        case .numberUnsignedInteger(let value): "NSNumber(\(value))"
        case .arrayOfStrings(let values):
            "a \(values.count)-item string array"
        case .dictionaryOfStrings(let values):
            "a \(values.count)-entry string dictionary"
        case .url(let value): "URL “\(value)”"
        }
    }
}

private extension PatchReturnValue {
    var behaviorSummary: String {
        switch self {
        case .boolean(let value): value ? "True" : "False"
        case .signedInteger(let value): String(value)
        case .unsignedInteger(let value): String(value)
        case .floatingPoint(let value): String(value)
        case .nilValue: "nil"
        case .classNamed(let className): "class \(className)"
        case .selector(let selector): "selector \(selector)"
        case .string(let value): value.isEmpty ? "an empty string" : "“\(value)”"
        }
    }
}

private extension Array where Element == PatchEffect {
    func behaviorSummaries(position: String) -> [String] {
        let alertCount = count {
            if case .showAlert = $0 { return true }
            return false
        }
        let customCount = count {
            if case .customObjectiveC = $0 { return true }
            return false
        }
        var summaries: [String] = []
        if alertCount > 0 {
            summaries.append("Shows \(alertCount) alert\(alertCount == 1 ? "" : "s") \(position)")
        }
        if customCount > 0 {
            summaries.append(
                "Runs \(customCount) custom snippet\(customCount == 1 ? "" : "s") \(position)"
            )
        }
        return summaries
    }
}
