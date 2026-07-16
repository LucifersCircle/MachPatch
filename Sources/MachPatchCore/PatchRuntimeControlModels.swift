public struct PatchRuntimeControlsConfiguration: Codable, Equatable, Sendable {
    public let id: String
    public let activationMode: PatchRuntimeControlActivationMode

    public init(
        id: String,
        activationMode: PatchRuntimeControlActivationMode = .floatingButton
    ) {
        self.id = id
        self.activationMode = activationMode
    }
}

public enum PatchRuntimeControlActivationMode: String, Codable, CaseIterable, Equatable, Sendable {
    case floatingButton
    case threeFingerHold
    case both
}

public struct PatchRuntimeControlConfiguration: Codable, Equatable, Sendable {
    public let title: String
    public let defaultEnabled: Bool
    public let order: Int
    public let value: PatchRuntimeControlValue?

    public init(
        title: String,
        defaultEnabled: Bool = true,
        order: Int,
        value: PatchRuntimeControlValue? = nil
    ) {
        self.title = title
        self.defaultEnabled = defaultEnabled
        self.order = order
        self.value = value
    }
}

public enum PatchRuntimeControlValue: Equatable, Sendable {
    case boolean(Bool)
    case signedInteger(PatchRuntimeSignedIntegerConfiguration)
    case unsignedInteger(PatchRuntimeUnsignedIntegerConfiguration)

    public var kind: PatchRuntimeControlValueKind {
        switch self {
        case .boolean: .boolean
        case .signedInteger: .signedInteger
        case .unsignedInteger: .unsignedInteger
        }
    }
}

public enum PatchRuntimeControlValueKind: String, Codable, CaseIterable, Equatable, Sendable {
    case boolean
    case signedInteger
    case unsignedInteger
}

public struct PatchRuntimeSignedIntegerConfiguration: Codable, Equatable, Sendable {
    public let defaultValue: Int64
    public let minimumValue: Int64?
    public let maximumValue: Int64?
    public let step: Int64

    public init(
        defaultValue: Int64,
        minimumValue: Int64? = nil,
        maximumValue: Int64? = nil,
        step: Int64 = 1
    ) {
        self.defaultValue = defaultValue
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.step = step
    }
}

public struct PatchRuntimeUnsignedIntegerConfiguration: Codable, Equatable, Sendable {
    public let defaultValue: UInt64
    public let minimumValue: UInt64?
    public let maximumValue: UInt64?
    public let step: UInt64

    public init(
        defaultValue: UInt64,
        minimumValue: UInt64? = nil,
        maximumValue: UInt64? = nil,
        step: UInt64 = 1
    ) {
        self.defaultValue = defaultValue
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.step = step
    }
}

extension PatchRuntimeControlValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case boolean
        case signedInteger
        case unsignedInteger
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(PatchRuntimeControlValueKind.self, forKey: .kind) {
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .boolean))
        case .signedInteger:
            self = .signedInteger(
                try container.decode(
                    PatchRuntimeSignedIntegerConfiguration.self,
                    forKey: .signedInteger
                )
            )
        case .unsignedInteger:
            self = .unsignedInteger(
                try container.decode(
                    PatchRuntimeUnsignedIntegerConfiguration.self,
                    forKey: .unsignedInteger
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .boolean(let value):
            try container.encode(value, forKey: .boolean)
        case .signedInteger(let configuration):
            try container.encode(configuration, forKey: .signedInteger)
        case .unsignedInteger(let configuration):
            try container.encode(configuration, forKey: .unsignedInteger)
        }
    }
}

public enum PatchRuntimeControlCompatibility {
    public static func defaultEditableValue(for action: PatchAction) -> PatchRuntimeControlValue? {
        switch action {
        case .returnBoolean(let value):
            .boolean(value)
        case .returnSignedInteger(let value):
            .signedInteger(PatchRuntimeSignedIntegerConfiguration(defaultValue: value))
        case .returnUnsignedInteger(let value):
            .unsignedInteger(PatchRuntimeUnsignedIntegerConfiguration(defaultValue: value))
        case .callOriginalAndReplace(.boolean(let value)):
            .boolean(value)
        case .callOriginalAndReplace(.signedInteger(let value)):
            .signedInteger(PatchRuntimeSignedIntegerConfiguration(defaultValue: value))
        case .callOriginalAndReplace(.unsignedInteger(let value)):
            .unsignedInteger(PatchRuntimeUnsignedIntegerConfiguration(defaultValue: value))
        default:
            nil
        }
    }

    static func incompatibility(
        value: PatchRuntimeControlValue,
        action: PatchAction,
        signature: ObjectiveCMethodSignature
    ) -> String? {
        guard value.kind == defaultEditableValue(for: action)?.kind else {
            return "The runtime control value does not match the patch's primary action."
        }

        switch value {
        case .boolean:
            return PatchActionCompatibility.valueIncompatibility(
                .boolean(false),
                type: signature.returnType,
                context: "Runtime boolean control"
            )
        case .signedInteger(let configuration):
            if configuration.step <= 0 {
                return "Runtime signed-integer step must be greater than zero."
            }
            if let minimum = configuration.minimumValue,
                let maximum = configuration.maximumValue,
                minimum > maximum
            {
                return "Runtime signed-integer minimum must not exceed its maximum."
            }
            if let minimum = configuration.minimumValue,
                configuration.defaultValue < minimum
            {
                return "Runtime signed-integer default must not be less than its minimum."
            }
            if let maximum = configuration.maximumValue,
                configuration.defaultValue > maximum
            {
                return "Runtime signed-integer default must not exceed its maximum."
            }
            for value in [
                configuration.defaultValue,
                configuration.minimumValue,
                configuration.maximumValue,
            ].compactMap({ $0 }) {
                if let message = PatchActionCompatibility.valueIncompatibility(
                    .signedInteger(value),
                    type: signature.returnType,
                    context: "Runtime signed-integer control"
                ) {
                    return message
                }
            }
            return nil
        case .unsignedInteger(let configuration):
            if configuration.step == 0 {
                return "Runtime unsigned-integer step must be greater than zero."
            }
            if let minimum = configuration.minimumValue,
                let maximum = configuration.maximumValue,
                minimum > maximum
            {
                return "Runtime unsigned-integer minimum must not exceed its maximum."
            }
            if let minimum = configuration.minimumValue,
                configuration.defaultValue < minimum
            {
                return "Runtime unsigned-integer default must not be less than its minimum."
            }
            if let maximum = configuration.maximumValue,
                configuration.defaultValue > maximum
            {
                return "Runtime unsigned-integer default must not exceed its maximum."
            }
            for value in [
                configuration.defaultValue,
                configuration.minimumValue,
                configuration.maximumValue,
            ].compactMap({ $0 }) {
                if let message = PatchActionCompatibility.valueIncompatibility(
                    .unsignedInteger(value),
                    type: signature.returnType,
                    context: "Runtime unsigned-integer control"
                ) {
                    return message
                }
            }
            return nil
        }
    }
}
