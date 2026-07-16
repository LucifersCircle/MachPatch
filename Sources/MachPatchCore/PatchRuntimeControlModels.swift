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

    public init(
        title: String,
        defaultEnabled: Bool = true,
        order: Int
    ) {
        self.title = title
        self.defaultEnabled = defaultEnabled
        self.order = order
    }
}
