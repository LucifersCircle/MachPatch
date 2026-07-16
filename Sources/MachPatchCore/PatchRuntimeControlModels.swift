public struct PatchRuntimeControlsConfiguration: Codable, Equatable, Sendable {
    public let id: String
    public let hideFloatingButtonAtStart: Bool

    public init(
        id: String,
        hideFloatingButtonAtStart: Bool = false
    ) {
        self.id = id
        self.hideFloatingButtonAtStart = hideFloatingButtonAtStart
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case hideFloatingButtonAtStart
        case recoveryGestureEnabled
        case activationMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        if let hidden = try container.decodeIfPresent(
            Bool.self,
            forKey: .hideFloatingButtonAtStart
        ) {
            hideFloatingButtonAtStart = hidden
        } else if try container.decodeIfPresent(
            Bool.self,
            forKey: .recoveryGestureEnabled
        ) != nil {
            hideFloatingButtonAtStart = false
        } else {
            let legacyMode = try container.decodeIfPresent(String.self, forKey: .activationMode)
            hideFloatingButtonAtStart = legacyMode == "threeFingerHold"
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(hideFloatingButtonAtStart, forKey: .hideFloatingButtonAtStart)
    }
}

public struct PatchRuntimeControlConfiguration: Codable, Equatable, Sendable {
    public let title: String
    public let defaultEnabled: Bool
    public let showsTargetSubtitle: Bool
    public let order: Int

    public init(
        title: String,
        defaultEnabled: Bool = true,
        showsTargetSubtitle: Bool = true,
        order: Int
    ) {
        self.title = title
        self.defaultEnabled = defaultEnabled
        self.showsTargetSubtitle = showsTargetSubtitle
        self.order = order
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case defaultEnabled
        case showsTargetSubtitle
        case order
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        defaultEnabled = try container.decode(Bool.self, forKey: .defaultEnabled)
        showsTargetSubtitle =
            try container.decodeIfPresent(Bool.self, forKey: .showsTargetSubtitle) ?? true
        order = try container.decode(Int.self, forKey: .order)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(defaultEnabled, forKey: .defaultEnabled)
        try container.encode(showsTargetSubtitle, forKey: .showsTargetSubtitle)
        try container.encode(order, forKey: .order)
    }
}
