import Foundation
import MachPatchCore

public enum ArchitectureResolver {
    private static let arm64eVersionedABIMask: UInt32 = 0x8000_0000
    private static let arm64ePointerAuthenticationVersionMask: UInt32 = 0x0F00_0000

    public static func resolve(
        mode: PatchArchitectureMode,
        selectedSlice: PatchSelectedSlice
    ) throws -> BuildArchitectureResolution {
        let targetABI = arm64eABI(
            architecture: selectedSlice.architecture,
            cpuSubtype: selectedSlice.cpuSubtype
        )
        try validateSelectedSlice(selectedSlice, arm64eABI: targetABI)

        switch mode {
        case .automatic:
            switch selectedSlice.architecture {
            case .arm64:
                return resolution(
                    mode: mode,
                    output: .arm64,
                    slices: [.arm64],
                    selectedSlice: selectedSlice,
                    targetABI: nil,
                    reason:
                        "Automatic selected arm64 because the recorded target slice is ordinary arm64."
                )
            case .arm64e:
                return resolution(
                    mode: mode,
                    output: .arm64e,
                    slices: [.arm64e],
                    selectedSlice: selectedSlice,
                    targetABI: targetABI,
                    reason:
                        "Automatic selected arm64e because the recorded target slice uses a versioned arm64e ABI."
                )
            case .arm64eLegacy:
                throw ArchitectureResolutionError.legacyArm64eUnsupported(
                    selectedSlice.cpuSubtype
                )
            default:
                throw ArchitectureResolutionError.unsupportedTargetArchitecture(
                    selectedSlice.architecture
                )
            }

        case .arm64:
            guard selectedSlice.architecture == .arm64 else {
                throw ArchitectureResolutionError.modeIncompatibleWithTarget(
                    mode,
                    selectedSlice.architecture
                )
            }
            return resolution(
                mode: mode,
                output: .arm64,
                slices: [.arm64],
                selectedSlice: selectedSlice,
                targetABI: nil,
                reason: "Explicit arm64 matches the recorded ordinary arm64 target slice."
            )

        case .arm64e:
            guard selectedSlice.architecture == .arm64e else {
                if selectedSlice.architecture == .arm64eLegacy {
                    throw ArchitectureResolutionError.legacyArm64eUnsupported(
                        selectedSlice.cpuSubtype
                    )
                }
                throw ArchitectureResolutionError.modeIncompatibleWithTarget(
                    mode,
                    selectedSlice.architecture
                )
            }
            return resolution(
                mode: mode,
                output: .arm64e,
                slices: [.arm64e],
                selectedSlice: selectedSlice,
                targetABI: targetABI,
                reason:
                    "Explicit arm64e matches the recorded versioned arm64e target slice."
            )

        case .universal:
            guard
                selectedSlice.architecture == .arm64
                    || selectedSlice.architecture == .arm64e
            else {
                if selectedSlice.architecture == .arm64eLegacy {
                    throw ArchitectureResolutionError.legacyArm64eUnsupported(
                        selectedSlice.cpuSubtype
                    )
                }
                throw ArchitectureResolutionError.modeIncompatibleWithTarget(
                    mode,
                    selectedSlice.architecture
                )
            }
            return resolution(
                mode: mode,
                output: .universal,
                slices: [.arm64, .arm64e],
                selectedSlice: selectedSlice,
                targetABI: targetABI,
                reason:
                    "Universal requested separate arm64 and arm64e slices; both must pass capability and output validation before merging."
            )
        }
    }

    public static func report(for slices: [MachOSlice]) -> TargetArchitectureReport {
        let assessments = slices.map(assess)
        let supportedArchitectures = Set(
            assessments.compactMap { assessment -> MachOArchitecture? in
                assessment.supportedForPatching ? assessment.architecture : nil
            }
        )
        var modes: [PatchArchitectureMode] = []
        if !supportedArchitectures.isEmpty { modes.append(.automatic) }
        if supportedArchitectures.contains(.arm64) { modes.append(.arm64) }
        if supportedArchitectures.contains(.arm64e) { modes.append(.arm64e) }
        if supportedArchitectures.contains(.arm64), supportedArchitectures.contains(.arm64e) {
            modes.append(.universal)
        }

        let recommendation: PatchArchitectureMode?
        let reason: String
        switch (supportedArchitectures.contains(.arm64), supportedArchitectures.contains(.arm64e))
        {
        case (true, false):
            recommendation = .arm64
            reason = "Automatic will select arm64 because it is the only supported device slice."
        case (false, true):
            recommendation = .arm64e
            reason =
                "Automatic will select arm64e because it is the only supported device slice and uses a versioned ABI."
        case (true, true):
            recommendation = nil
            reason =
                "The target contains arm64 and arm64e; a patch project's selected slice determines automatic mode, while universal is optional."
        case (false, false):
            recommendation = nil
            reason =
                "The target contains no supported ordinary arm64 or versioned arm64e iPhoneOS slice."
        }
        return TargetArchitectureReport(
            slices: assessments,
            availableModes: modes,
            automaticRecommendation: recommendation,
            automaticReason: reason
        )
    }

    public static func arm64eABI(
        architecture: MachOArchitecture,
        cpuSubtype: Int32
    ) -> Arm64eABI? {
        guard architecture == .arm64e || architecture == .arm64eLegacy else { return nil }
        let raw = UInt32(bitPattern: cpuSubtype)
        if raw & arm64eVersionedABIMask == 0 {
            return Arm64eABI(generation: .legacy, pointerAuthenticationVersion: nil)
        }
        let version = UInt8((raw & arm64ePointerAuthenticationVersionMask) >> 24)
        return Arm64eABI(
            generation: .versioned,
            pointerAuthenticationVersion: version
        )
    }

    private static func validateSelectedSlice(
        _ selectedSlice: PatchSelectedSlice,
        arm64eABI: Arm64eABI?
    ) throws {
        let raw = UInt32(bitPattern: selectedSlice.cpuSubtype)
        let subtypeBase = raw & 0x00FF_FFFF
        switch selectedSlice.architecture {
        case .arm64:
            guard (subtypeBase == 0 || subtypeBase == 1), raw & 0xFF00_0000 == 0 else {
                throw ArchitectureResolutionError.inconsistentSelectedSlice(
                    selectedSlice.architecture,
                    selectedSlice.cpuSubtype
                )
            }
        case .arm64e:
            guard subtypeBase == 2 else {
                throw ArchitectureResolutionError.inconsistentSelectedSlice(
                    selectedSlice.architecture,
                    selectedSlice.cpuSubtype
                )
            }
            guard arm64eABI?.generation == .versioned else {
                throw ArchitectureResolutionError.legacyArm64eUnsupported(
                    selectedSlice.cpuSubtype
                )
            }
        case .arm64eLegacy:
            guard subtypeBase == 2, arm64eABI?.generation == .legacy else {
                throw ArchitectureResolutionError.inconsistentSelectedSlice(
                    selectedSlice.architecture,
                    selectedSlice.cpuSubtype
                )
            }
        default:
            break
        }
    }

    private static func assess(_ slice: MachOSlice) -> TargetArchitectureSliceAssessment {
        let abi = arm64eABI(
            architecture: slice.architecture,
            cpuSubtype: slice.cpuSubtype
        )
        let supported: Bool
        let diagnostic: String
        if slice.platform != .iPhoneOS {
            supported = false
            diagnostic =
                "Unsupported platform '\(slice.platform.rawValue)'; patch dylibs must target iPhoneOS."
        } else {
            switch slice.architecture {
            case .arm64 where slice.cpuSubtypeCapabilities == 0:
                supported = true
                diagnostic = "Supported ordinary arm64 iPhoneOS slice."
            case .arm64:
                supported = false
                diagnostic =
                    "arm64 CPU subtype contains unsupported capability bits 0x\(String(slice.cpuSubtypeCapabilities, radix: 16))."
            case .arm64e where abi?.generation == .versioned:
                supported = true
                diagnostic =
                    "Supported versioned arm64e iPhoneOS slice (pointer-auth ABI version \(abi?.pointerAuthenticationVersion ?? 0))."
            case .arm64eLegacy:
                supported = false
                diagnostic =
                    "Legacy unversioned arm64e ABI cannot be produced safely by the selected modern toolchain."
            case .arm64e:
                supported = false
                diagnostic = "arm64e CPU subtype metadata is unknown or inconsistent."
            default:
                supported = false
                diagnostic =
                    "Architecture '\(slice.architecture.rawValue)' is not buildable for iPhoneOS patches."
            }
        }
        return TargetArchitectureSliceAssessment(
            index: slice.index,
            architecture: slice.architecture,
            cpuSubtype: slice.cpuSubtype,
            cpuSubtypeBase: slice.cpuSubtypeBase,
            cpuSubtypeCapabilities: slice.cpuSubtypeCapabilities,
            platform: slice.platform,
            arm64eABI: abi,
            supportedForPatching: supported,
            diagnostic: diagnostic
        )
    }

    private static func resolution(
        mode: PatchArchitectureMode,
        output: PatchBuildOutputArchitecture,
        slices: [BuildSliceArchitecture],
        selectedSlice: PatchSelectedSlice,
        targetABI: Arm64eABI?,
        reason: String
    ) -> BuildArchitectureResolution {
        BuildArchitectureResolution(
            requestedMode: mode,
            outputArchitecture: output,
            slices: slices,
            targetArchitecture: selectedSlice.architecture,
            targetCPUSubtype: selectedSlice.cpuSubtype,
            targetArm64eABI: targetABI,
            reason: reason
        )
    }
}

public enum ArchitectureResolutionError: Error, Equatable, LocalizedError, Sendable {
    case inconsistentSelectedSlice(MachOArchitecture, Int32)
    case unsupportedTargetArchitecture(MachOArchitecture)
    case legacyArm64eUnsupported(Int32)
    case modeIncompatibleWithTarget(PatchArchitectureMode, MachOArchitecture)

    public var errorDescription: String? {
        switch self {
        case .inconsistentSelectedSlice(let architecture, let cpuSubtype):
            "Selected architecture '\(architecture.rawValue)' is inconsistent with raw CPU subtype \(cpuSubtype)."
        case .unsupportedTargetArchitecture(let architecture):
            "Target architecture '\(architecture.rawValue)' is unsupported for iPhoneOS patch dylibs."
        case .legacyArm64eUnsupported(let cpuSubtype):
            "The target uses legacy unversioned arm64e CPU subtype \(cpuSubtype), which the selected modern Xcode toolchain cannot reproduce safely."
        case .modeIncompatibleWithTarget(let mode, let architecture):
            "Architecture mode '\(mode.rawValue)' is incompatible with the selected '\(architecture.rawValue)' target slice."
        }
    }
}
