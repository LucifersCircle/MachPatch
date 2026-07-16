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
        let source = SourceRenderer(
            contexts: contexts,
            runtimeControls: project.runtimeControls
        ).render()
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
    var controlEnabledName: String { "\(identifier)_ControlEnabled" }
    var advanced: PatchAdvancedConfiguration { patch.advanced ?? PatchAdvancedConfiguration() }
    var needsOriginalImplementation: Bool {
        true
    }

    var needsInvocationCounter: Bool {
        advanced.invocationCounter != nil
    }

    var needsUIKit: Bool {
        patch.runtimeControl != nil
            || (advanced.beforeEffects + advanced.afterEffects).contains { effect in
                switch effect {
                case .showAlert, .customObjectiveC: true
                }
            }
    }

    var needsAlertRuntime: Bool {
        patch.runtimeControl != nil
            || (advanced.beforeEffects + advanced.afterEffects).contains { effect in
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
    let runtimeControls: PatchRuntimeControlsConfiguration?

    func render() -> String {
        var sections: [String] = [header]
        if contexts.contains(where: \.needsAlertRuntime) {
            sections.append(alertRuntime)
        }
        sections.append(contexts.map(renderPatch).joined(separator: "\n\n"))
        if !contexts.isEmpty {
            sections.append(renderImplementationUnwrapper())
        }
        if !runtimeControlRuntime.isEmpty {
            sections.append(runtimeControlRuntime)
        }
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
        if runtimeControls != nil {
            imports += "\n#include <stdint.h>"
        }
        if contexts.contains(where: \.needsUIKit) {
            imports += "\n#import <UIKit/UIKit.h>"
        }
        if contexts.contains(where: \.needsCoreGraphics) {
            imports += "\n#import <CoreGraphics/CoreGraphics.h>"
        }
        let declarations =
            contexts.isEmpty
            ? ""
            : "\n\nstatic IMP MPBaselineImplementation(IMP implementation);"
        return imports + """


            typedef NS_ENUM(uint8_t, MPPatchState) {
                MPPatchStatePending = 0,
                MPPatchStateInstalled = 1,
                MPPatchStateFailed = 2,
            };
            """ + declarations
    }

    private var controlledContexts: [PatchGenerationContext] {
        contexts.filter { $0.patch.runtimeControl != nil }.sorted { lhs, rhs in
            let lhsOrder = lhs.patch.runtimeControl?.order ?? 0
            let rhsOrder = rhs.patch.runtimeControl?.order ?? 0
            return lhsOrder == rhsOrder ? lhs.index < rhs.index : lhsOrder < rhsOrder
        }
    }

    private var runtimeControlRuntime: String {
        guard let runtimeControls, !controlledContexts.isEmpty else { return "" }
        let entries = controlledContexts.map(runtimeControlDescriptorEntry).joined(separator: ",\n")
        return """
            typedef struct {
                __unsafe_unretained NSString *identifier;
                __unsafe_unretained NSString *title;
                __unsafe_unretained NSString *methodDescription;
                BOOL *enabledStorage;
                BOOL defaultEnabled;
                MPPatchState *patchState;
            } MPRuntimeControlDescriptor;

            static MPRuntimeControlDescriptor MPRuntimeControlDescriptors[] = {
            \(indent(entries, spaces: 4))
            };

            static NSUInteger MPRuntimeControlCount(void) {
                return sizeof(MPRuntimeControlDescriptors) / sizeof(MPRuntimeControlDescriptors[0]);
            }

            static NSString *MPRuntimeControlPersistenceKey(
                const MPRuntimeControlDescriptor *descriptor,
                NSString *suffix
            ) {
                return [NSString stringWithFormat:
                    @"com.machpatch.runtime.v2.%@.%@.%@",
                    \(ObjectiveCLiteral.string(runtimeControls.id)),
                    descriptor->identifier,
                    suffix];
            }

            static void MPLoadPersistedRuntimeControls(void) {
                NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                for (NSUInteger index = 0; index < MPRuntimeControlCount(); index += 1) {
                    MPRuntimeControlDescriptor *descriptor = &MPRuntimeControlDescriptors[index];
                    id enabled = [defaults objectForKey:
                        MPRuntimeControlPersistenceKey(descriptor, @"enabled")];
                    if ([enabled isKindOfClass:[NSNumber class]]) {
                        __atomic_store_n(
                            descriptor->enabledStorage,
                            ((NSNumber *)enabled).boolValue,
                            __ATOMIC_RELEASE
                        );
                    }
                }
            }

            \(runtimeControlOverlaySource)

            static void MPInitializeRuntimeControls(void) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[MPRuntimeControlsManager sharedManager] start];
                });
            }
            """
    }

    private var runtimeControlOverlaySource: String {
        guard let runtimeControls else { return "" }
        let classSuffix = ObjectiveCIdentifier.sanitize(runtimeControls.id)
        let showsButton = runtimeControls.activationMode != .threeFingerHold
        let installsGesture = runtimeControls.activationMode != .floatingButton
        return """
            #define MPRuntimeControlsOverlay MPControls_\(classSuffix)_Overlay
            #define MPRuntimeControlsManager MPControls_\(classSuffix)_Manager

            static const BOOL MPConfiguredShowsButton = \(showsButton ? "YES" : "NO");
            static const BOOL MPConfiguredInstallsGesture = \(installsGesture ? "YES" : "NO");
            static BOOL MPVoiceOverFallbackForSession = NO;

            static UIColor *MPPrimaryLabelColor(void) {
                if (@available(iOS 13.0, *)) { return UIColor.labelColor; }
                return UIColor.whiteColor;
            }

            static UIColor *MPSecondaryLabelColor(void) {
                if (@available(iOS 13.0, *)) { return UIColor.secondaryLabelColor; }
                return [UIColor colorWithWhite:1.0 alpha:0.7];
            }

            static UIColor *MPControlBackgroundColor(void) {
                if (@available(iOS 13.0, *)) { return UIColor.tertiarySystemFillColor; }
                return [UIColor colorWithWhite:1.0 alpha:0.12];
            }

            static UIColor *MPAccentColor(void) {
                if (@available(iOS 13.0, *)) { return UIColor.systemPurpleColor; }
                return UIColor.purpleColor;
            }

            static UIColor *MPErrorColor(void) {
                if (@available(iOS 13.0, *)) { return UIColor.systemRedColor; }
                return UIColor.redColor;
            }

            static void MPPersistRuntimeControlObject(
                const MPRuntimeControlDescriptor *descriptor,
                NSString *suffix,
                id value
            ) {
                NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                NSString *key = MPRuntimeControlPersistenceKey(descriptor, suffix);
                if (value == nil) {
                    [defaults removeObjectForKey:key];
                } else {
                    [defaults setObject:value forKey:key];
                }
            }

            static BOOL MPRuntimeControlIsEnabled(NSUInteger index) {
                return __atomic_load_n(
                    MPRuntimeControlDescriptors[index].enabledStorage,
                    __ATOMIC_ACQUIRE
                );
            }

            static void MPSetRuntimeControlEnabled(NSUInteger index, BOOL enabled) {
                MPRuntimeControlDescriptor *descriptor = &MPRuntimeControlDescriptors[index];
                __atomic_store_n(descriptor->enabledStorage, enabled, __ATOMIC_RELEASE);
                MPPersistRuntimeControlObject(
                    descriptor,
                    @"enabled",
                    [NSNumber numberWithBool:enabled]
                );
            }

            static void MPResetRuntimeControlsToDefaults(void) {
                NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                for (NSUInteger index = 0; index < MPRuntimeControlCount(); index += 1) {
                    MPRuntimeControlDescriptor *descriptor = &MPRuntimeControlDescriptors[index];
                    __atomic_store_n(
                        descriptor->enabledStorage,
                        descriptor->defaultEnabled,
                        __ATOMIC_RELEASE
                    );
                    [defaults removeObjectForKey:
                        MPRuntimeControlPersistenceKey(descriptor, @"enabled")];
                }
            }

            static UILabel *MPMakeRuntimeLabel(
                UIFont *font,
                UIColor *color,
                NSInteger numberOfLines
            ) {
                UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
                label.font = font;
                label.textColor = color;
                label.numberOfLines = numberOfLines;
                return label;
            }

            @class MPRuntimeControlsOverlay;

            @interface MPRuntimeControlsManager : NSObject
            @property(nonatomic, strong) NSMapTable<UIWindow *, MPRuntimeControlsOverlay *> *overlays;
            @property(nonatomic, assign) BOOL started;
            + (instancetype)sharedManager;
            - (void)start;
            - (void)refreshWindows;
            - (void)refreshAllControls;
            @end

            @interface MPRuntimeControlsOverlay : NSObject <UIGestureRecognizerDelegate>
            @property(nonatomic, weak) UIWindow *window;
            @property(nonatomic, strong) UIButton *button;
            @property(nonatomic, strong) UIVisualEffectView *panel;
            @property(nonatomic, strong) UIStackView *panelStack;
            @property(nonatomic, strong) UILabel *summaryLabel;
            @property(nonatomic, strong) UIButton *showButtonButton;
            @property(nonatomic, strong) UIPanGestureRecognizer *buttonPanGesture;
            @property(nonatomic, strong) UILongPressGestureRecognizer *buttonLongPressGesture;
            @property(nonatomic, strong) UILongPressGestureRecognizer *activationGesture;
            @property(nonatomic, strong) NSMutableDictionary<NSNumber *, UISwitch *> *switches;
            @property(nonatomic, strong) NSMutableDictionary<NSNumber *, UILabel *> *statusLabels;
            @property(nonatomic, assign) BOOL panelVisible;
            @property(nonatomic, assign) BOOL buttonHiddenForSession;
            @property(nonatomic, assign) BOOL hasButtonPosition;
            @property(nonatomic, assign) CGPoint buttonCenter;
            - (instancetype)initWithWindow:(UIWindow *)window;
            - (void)updateEntryPoints;
            - (void)updateButtonAppearanceAnimated:(BOOL)animated;
            - (void)layoutControls;
            - (void)refreshControls;
            - (void)invalidate;
            @end

            @implementation MPRuntimeControlsOverlay

            - (instancetype)initWithWindow:(UIWindow *)window {
                self = [super init];
                if (self != nil) {
                    _window = window;
                    _switches = [NSMutableDictionary dictionary];
                    _statusLabels = [NSMutableDictionary dictionary];
                    [self updateEntryPoints];
                }
                return self;
            }

            - (UIButton *)makeButton {
                UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
                button.frame = CGRectMake(0.0, 0.0, 52.0, 52.0);
                button.backgroundColor = MPAccentColor();
                button.tintColor = UIColor.whiteColor;
                button.layer.cornerRadius = 26.0;
                button.layer.shadowColor = UIColor.blackColor.CGColor;
                button.layer.shadowOpacity = 0.28;
                button.layer.shadowRadius = 8.0;
                button.layer.shadowOffset = CGSizeMake(0.0, 3.0);
                button.alpha = 0.28;
                if (@available(iOS 13.0, *)) {
                    UIImageSymbolConfiguration *configuration =
                        [UIImageSymbolConfiguration configurationWithPointSize:22.0
                            weight:UIImageSymbolWeightSemibold];
                    UIImage *image = [UIImage systemImageNamed:@"hammer.fill"
                        withConfiguration:configuration];
                    [button setImage:image forState:UIControlStateNormal];
                } else {
                    [button setTitle:@"M" forState:UIControlStateNormal];
                    button.titleLabel.font = [UIFont boldSystemFontOfSize:20.0];
                }
                button.accessibilityLabel = @"MachPatch controls";
                button.accessibilityHint = @"Opens patch controls. Drag to reposition.";
                [button addTarget:self
                    action:@selector(buttonTapped:)
                    forControlEvents:UIControlEventTouchUpInside];
                [button addTarget:self
                    action:@selector(buttonInteractionBegan:)
                    forControlEvents:UIControlEventTouchDown];
                [button addTarget:self
                    action:@selector(buttonInteractionEnded:)
                    forControlEvents:(UIControlEventTouchUpOutside
                        | UIControlEventTouchCancel
                        | UIControlEventTouchDragExit)];

                UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                    initWithTarget:self
                    action:@selector(buttonPanned:)];
                [button addGestureRecognizer:pan];
                self.buttonPanGesture = pan;
                UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
                    initWithTarget:self
                    action:@selector(buttonLongPressed:)];
                longPress.minimumPressDuration = 0.7;
                [button addGestureRecognizer:longPress];
                self.buttonLongPressGesture = longPress;
                return button;
            }

            - (void)updateEntryPoints {
                UIWindow *window = self.window;
                if (window == nil) { return; }
                BOOL forceAccessibleButton = MPVoiceOverFallbackForSession
                    || UIAccessibilityIsVoiceOverRunning();
                if (forceAccessibleButton) {
                    self.buttonHiddenForSession = NO;
                }
                BOOL shouldShowButton = MPConfiguredShowsButton || forceAccessibleButton;
                if (shouldShowButton && self.button == nil) {
                    self.button = [self makeButton];
                    [window addSubview:self.button];
                }
                self.button.hidden = !shouldShowButton || self.buttonHiddenForSession;
                self.buttonPanGesture.enabled = !forceAccessibleButton;
                self.buttonLongPressGesture.enabled = !forceAccessibleButton;
                [self updateButtonAppearanceAnimated:NO];

                BOOL shouldInstallGesture = MPConfiguredInstallsGesture
                    && !forceAccessibleButton;
                if (shouldInstallGesture && self.activationGesture == nil) {
                    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
                        initWithTarget:self
                        action:@selector(activationGestureRecognized:)];
                    gesture.minimumPressDuration = 3.0;
                    gesture.cancelsTouchesInView = NO;
                    gesture.delaysTouchesBegan = NO;
                    gesture.delegate = self;
                    [window addGestureRecognizer:gesture];
                    self.activationGesture = gesture;
                } else if (!shouldInstallGesture && self.activationGesture != nil) {
                    [window removeGestureRecognizer:self.activationGesture];
                    self.activationGesture = nil;
                }
                [self layoutControls];
                if (self.button != nil) { [window bringSubviewToFront:self.button]; }
                if (self.panelVisible && self.panel != nil) {
                    [window bringSubviewToFront:self.panel];
                }
            }

            - (void)updateButtonAppearanceAnimated:(BOOL)animated {
                BOOL forceAccessibleButton = MPVoiceOverFallbackForSession
                    || UIAccessibilityIsVoiceOverRunning();
                CGFloat alpha = (forceAccessibleButton || self.panelVisible) ? 1.0 : 0.28;
                void (^changes)(void) = ^{
                    self.button.alpha = alpha;
                };
                if (animated) {
                    [UIView animateWithDuration:0.16 animations:changes];
                } else {
                    changes();
                }
            }

            - (CGRect)safeRect {
                UIWindow *window = self.window;
                if (window == nil) { return CGRectZero; }
                CGRect safe = UIEdgeInsetsInsetRect(window.bounds, window.safeAreaInsets);
                safe = CGRectInset(safe, 12.0, 12.0);
                if (safe.size.width < 100.0 || safe.size.height < 100.0) {
                    safe = CGRectInset(window.bounds, 12.0, 12.0);
                }
                return safe;
            }

            - (void)layoutControls {
                UIWindow *window = self.window;
                if (window == nil) { return; }
                CGRect safe = [self safeRect];
                if (self.button != nil) {
                    BOOL forceAccessibleButton = MPVoiceOverFallbackForSession
                        || UIAccessibilityIsVoiceOverRunning();
                    CGFloat minimumX = forceAccessibleButton
                        ? CGRectGetMinX(safe) + 26.0
                        : CGRectGetMinX(window.bounds);
                    CGFloat maximumX = forceAccessibleButton
                        ? CGRectGetMaxX(safe) - 26.0
                        : CGRectGetMaxX(window.bounds);
                    if (!self.hasButtonPosition) {
                        self.buttonCenter = CGPointMake(
                            maximumX,
                            CGRectGetMidY(safe)
                        );
                        self.hasButtonPosition = YES;
                    }
                    CGFloat minimumY = CGRectGetMinY(safe) + 26.0;
                    CGFloat maximumY = CGRectGetMaxY(safe) - 26.0;
                    self.buttonCenter = CGPointMake(
                        MIN(MAX(self.buttonCenter.x, minimumX), maximumX),
                        MIN(MAX(self.buttonCenter.y, minimumY), maximumY)
                    );
                    self.button.center = self.buttonCenter;
                }
                if (self.panelVisible && self.panel != nil) {
                    CGFloat width = MIN(330.0, MAX(240.0, safe.size.width - 24.0));
                    self.panel.frame = CGRectMake(0.0, 0.0, width, 200.0);
                    [self.panel.contentView layoutIfNeeded];
                    CGFloat contentHeight = [self.panelStack
                        systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].height + 24.0;
                    CGFloat maximumHeight = MAX(180.0, safe.size.height * 0.70);
                    CGFloat height = MIN(MAX(180.0, contentHeight), maximumHeight);
                    CGFloat x = CGRectGetMidX(safe) - width / 2.0;
                    CGFloat y = CGRectGetMidY(safe) - height / 2.0;
                    if (self.button != nil && !self.button.hidden) {
                        BOOL buttonOnRight = self.buttonCenter.x >= CGRectGetMidX(safe);
                        x = buttonOnRight
                            ? CGRectGetMinX(self.button.frame) - width - 12.0
                            : CGRectGetMaxX(self.button.frame) + 12.0;
                        y = self.buttonCenter.y - height / 2.0;
                    }
                    x = MIN(MAX(x, CGRectGetMinX(safe)), CGRectGetMaxX(safe) - width);
                    y = MIN(MAX(y, CGRectGetMinY(safe)), CGRectGetMaxY(safe) - height);
                    self.panel.frame = CGRectMake(x, y, width, height);
                }
            }

            - (UIStackView *)makeHeaderRowWithTitle:(NSString *)title accessory:(UIView *)accessory {
                UILabel *label = MPMakeRuntimeLabel(
                    [UIFont preferredFontForTextStyle:UIFontTextStyleBody],
                    MPPrimaryLabelColor(),
                    2
                );
                label.text = title;
                UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:
                    accessory == nil ? @[label] : @[label, accessory]];
                row.axis = UILayoutConstraintAxisHorizontal;
                row.alignment = UIStackViewAlignmentCenter;
                row.distribution = UIStackViewDistributionFill;
                row.spacing = 10.0;
                return row;
            }

            - (void)makePanelIfNeeded {
                if (self.panel != nil) { return; }
                UIBlurEffect *effect;
                if (@available(iOS 13.0, *)) {
                    effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
                } else {
                    effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
                }
                UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:effect];
                panel.layer.cornerRadius = 18.0;
                panel.clipsToBounds = YES;
                panel.accessibilityViewIsModal = YES;
                self.panel = panel;

                UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
                scrollView.translatesAutoresizingMaskIntoConstraints = NO;
                scrollView.alwaysBounceVertical = YES;
                [panel.contentView addSubview:scrollView];
                [NSLayoutConstraint activateConstraints:@[
                    [scrollView.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor],
                    [scrollView.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor],
                    [scrollView.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor],
                    [scrollView.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor],
                ]];

                UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
                stack.translatesAutoresizingMaskIntoConstraints = NO;
                stack.axis = UILayoutConstraintAxisVertical;
                stack.spacing = 10.0;
                stack.layoutMargins = UIEdgeInsetsMake(16.0, 16.0, 16.0, 16.0);
                stack.layoutMarginsRelativeArrangement = YES;
                [scrollView addSubview:stack];
                [NSLayoutConstraint activateConstraints:@[
                    [stack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
                    [stack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
                    [stack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
                    [stack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
                    [stack.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor],
                ]];
                self.panelStack = stack;

                UILabel *title = MPMakeRuntimeLabel(
                    [UIFont boldSystemFontOfSize:20.0],
                    MPPrimaryLabelColor(),
                    1
                );
                title.text = @"MachPatch Controls";
                UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
                [closeButton setTitle:@"Done" forState:UIControlStateNormal];
                [closeButton addTarget:self
                    action:@selector(closePanel:)
                    forControlEvents:UIControlEventTouchUpInside];
                UIStackView *header = [[UIStackView alloc]
                    initWithArrangedSubviews:@[title, closeButton]];
                header.axis = UILayoutConstraintAxisHorizontal;
                header.alignment = UIStackViewAlignmentCenter;
                [stack addArrangedSubview:header];

                self.summaryLabel = MPMakeRuntimeLabel(
                    [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1],
                    MPSecondaryLabelColor(),
                    1
                );
                [stack addArrangedSubview:self.summaryLabel];

                UILabel *behaviorNote = MPMakeRuntimeLabel(
                    [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2],
                    MPSecondaryLabelColor(),
                    0
                );
                behaviorNote.text = @"Each switch chooses Patch or Original on the next method call. Returning to Original cannot undo state the target app already cached or saved.";
                [stack addArrangedSubview:behaviorNote];

                for (NSUInteger index = 0; index < MPRuntimeControlCount(); index += 1) {
                    [stack addArrangedSubview:[self makeControlRow:index]];
                }

                UIStackView *footer = [[UIStackView alloc] initWithFrame:CGRectZero];
                footer.axis = UILayoutConstraintAxisHorizontal;
                footer.distribution = UIStackViewDistributionFillEqually;
                footer.spacing = 8.0;
                UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
                [reset setTitle:@"Reset Defaults" forState:UIControlStateNormal];
                [reset addTarget:self
                    action:@selector(resetDefaults:)
                    forControlEvents:UIControlEventTouchUpInside];
                [footer addArrangedSubview:reset];
                UIButton *showButton = [UIButton buttonWithType:UIButtonTypeSystem];
                [showButton setTitle:@"Show Button" forState:UIControlStateNormal];
                [showButton addTarget:self
                    action:@selector(showButtonAgain:)
                    forControlEvents:UIControlEventTouchUpInside];
                [footer addArrangedSubview:showButton];
                self.showButtonButton = showButton;
                [stack addArrangedSubview:footer];

                panel.hidden = YES;
                [self.window addSubview:panel];
            }

            - (UIView *)makeControlRow:(NSUInteger)index {
                MPRuntimeControlDescriptor *descriptor = &MPRuntimeControlDescriptors[index];
                UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
                row.axis = UILayoutConstraintAxisVertical;
                row.spacing = 5.0;
                row.layoutMargins = UIEdgeInsetsMake(10.0, 12.0, 10.0, 12.0);
                row.layoutMarginsRelativeArrangement = YES;
                row.backgroundColor = MPControlBackgroundColor();
                row.layer.cornerRadius = 12.0;

                UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
                toggle.tag = (NSInteger)index;
                toggle.accessibilityLabel = [NSString stringWithFormat:@"%@ patch",
                    descriptor->title];
                toggle.accessibilityHint = @"Choose Patch or Original behavior.";
                [toggle addTarget:self
                    action:@selector(controlSwitchChanged:)
                    forControlEvents:UIControlEventValueChanged];
                self.switches[@(index)] = toggle;
                [row addArrangedSubview:[self makeHeaderRowWithTitle:descriptor->title
                    accessory:toggle]];

                UILabel *method = MPMakeRuntimeLabel(
                    [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1],
                    MPSecondaryLabelColor(),
                    2
                );
                method.text = [NSString stringWithFormat:@"%@ · Patch / Original",
                    descriptor->methodDescription];
                [row addArrangedSubview:method];

                UILabel *status = MPMakeRuntimeLabel(
                    [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2],
                    MPSecondaryLabelColor(),
                    1
                );
                self.statusLabels[@(index)] = status;
                [row addArrangedSubview:status];

                return row;
            }

            - (void)showPanel {
                [self makePanelIfNeeded];
                self.panelVisible = YES;
                self.panel.hidden = NO;
                self.panel.accessibilityViewIsModal = YES;
                [self refreshControls];
                [self layoutControls];
                [self updateButtonAppearanceAnimated:YES];
                [self.window bringSubviewToFront:self.panel];
                UIAccessibilityPostNotification(
                    UIAccessibilityScreenChangedNotification,
                    self.panel
                );
            }

            - (void)closePanel:(id)sender {
                (void)sender;
                [self.panel endEditing:YES];
                self.panelVisible = NO;
                self.panel.hidden = YES;
                self.panel.accessibilityViewIsModal = NO;
                [self updateButtonAppearanceAnimated:YES];
                if (self.button != nil && !self.button.hidden) {
                    UIAccessibilityPostNotification(
                        UIAccessibilityScreenChangedNotification,
                        self.button
                    );
                }
            }

            - (void)togglePanel {
                if (self.panelVisible) {
                    [self closePanel:nil];
                } else {
                    [self showPanel];
                }
            }

            - (void)buttonTapped:(UIButton *)sender {
                (void)sender;
                [self togglePanel];
            }

            - (void)buttonInteractionBegan:(UIButton *)sender {
                [UIView animateWithDuration:0.12 animations:^{
                    sender.alpha = 1.0;
                }];
            }

            - (void)buttonInteractionEnded:(UIButton *)sender {
                (void)sender;
                [self updateButtonAppearanceAnimated:YES];
            }

            - (void)buttonPanned:(UIPanGestureRecognizer *)gesture {
                UIView *view = gesture.view;
                if (view == nil) { return; }
                if (gesture.state == UIGestureRecognizerStateBegan) {
                    view.alpha = 1.0;
                }
                CGPoint translation = [gesture translationInView:self.window];
                self.buttonCenter = CGPointMake(
                    self.buttonCenter.x + translation.x,
                    self.buttonCenter.y + translation.y
                );
                [gesture setTranslation:CGPointZero inView:self.window];
                [self layoutControls];
                if (gesture.state == UIGestureRecognizerStateEnded
                    || gesture.state == UIGestureRecognizerStateCancelled) {
                    CGRect safe = [self safeRect];
                    BOOL forceAccessibleButton = MPVoiceOverFallbackForSession
                        || UIAccessibilityIsVoiceOverRunning();
                    self.buttonCenter = CGPointMake(
                        self.buttonCenter.x < CGRectGetMidX(safe)
                            ? (forceAccessibleButton
                                ? CGRectGetMinX(safe) + 26.0
                                : CGRectGetMinX(self.window.bounds))
                            : (forceAccessibleButton
                                ? CGRectGetMaxX(safe) - 26.0
                                : CGRectGetMaxX(self.window.bounds)),
                        self.buttonCenter.y
                    );
                    [UIView animateWithDuration:0.2 animations:^{
                        [self layoutControls];
                    } completion:^(__unused BOOL finished) {
                        [self updateButtonAppearanceAnimated:YES];
                    }];
                }
            }

            - (void)buttonLongPressed:(UILongPressGestureRecognizer *)gesture {
                if (gesture.state != UIGestureRecognizerStateBegan) { return; }
                self.button.alpha = 1.0;
                UIViewController *presenter = MPTopViewController(self.window.rootViewController);
                if (presenter == nil || [presenter isKindOfClass:[UIAlertController class]]) {
                    [self updateButtonAppearanceAnimated:YES];
                    return;
                }
                UIAlertController *menu = [UIAlertController
                    alertControllerWithTitle:@"MachPatch Controls"
                    message:nil
                    preferredStyle:UIAlertControllerStyleActionSheet];
                __weak typeof(self) weakSelf = self;
                [menu addAction:[UIAlertAction
                    actionWithTitle:@"Reset Position"
                    style:UIAlertActionStyleDefault
                    handler:^(__unused UIAlertAction *action) {
                        weakSelf.hasButtonPosition = NO;
                        [weakSelf layoutControls];
                    }]];
                if (!UIAccessibilityIsVoiceOverRunning()) {
                    [menu addAction:[UIAlertAction
                        actionWithTitle:@"Hide Until Next Launch"
                        style:UIAlertActionStyleDefault
                        handler:^(__unused UIAlertAction *action) {
                            weakSelf.buttonHiddenForSession = YES;
                            [weakSelf closePanel:nil];
                            [weakSelf updateEntryPoints];
                        }]];
                }
                [menu addAction:[UIAlertAction
                    actionWithTitle:@"Cancel"
                    style:UIAlertActionStyleCancel
                    handler:nil]];
                UIPopoverPresentationController *popover = menu.popoverPresentationController;
                popover.sourceView = self.button;
                popover.sourceRect = self.button.bounds;
                [presenter presentViewController:menu animated:YES completion:nil];
                [self updateButtonAppearanceAnimated:YES];
            }

            - (void)activationGestureRecognized:(UILongPressGestureRecognizer *)gesture {
                if (gesture.state != UIGestureRecognizerStateBegan) { return; }
                if (@available(iOS 10.0, *)) {
                    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc]
                        initWithStyle:UIImpactFeedbackStyleMedium];
                    [feedback impactOccurred];
                }
                [self togglePanel];
            }

            - (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
                if (gestureRecognizer == self.activationGesture) {
                    return !UIAccessibilityIsVoiceOverRunning()
                        && gestureRecognizer.numberOfTouches == 3;
                }
                return YES;
            }

            - (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
                shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
                (void)gestureRecognizer;
                (void)other;
                return YES;
            }

            - (void)controlSwitchChanged:(UISwitch *)sender {
                MPSetRuntimeControlEnabled((NSUInteger)sender.tag, sender.isOn);
                [[MPRuntimeControlsManager sharedManager] refreshAllControls];
            }

            - (void)resetDefaults:(UIButton *)sender {
                (void)sender;
                MPResetRuntimeControlsToDefaults();
                [[MPRuntimeControlsManager sharedManager] refreshAllControls];
            }

            - (void)showButtonAgain:(UIButton *)sender {
                (void)sender;
                self.buttonHiddenForSession = NO;
                [self updateEntryPoints];
                [self refreshControls];
            }

            - (void)refreshControls {
                for (NSUInteger index = 0; index < MPRuntimeControlCount(); index += 1) {
                    MPRuntimeControlDescriptor *descriptor = &MPRuntimeControlDescriptors[index];
                    BOOL enabled = MPRuntimeControlIsEnabled(index);
                    UISwitch *toggle = self.switches[@(index)];
                    if (toggle != nil) {
                        toggle.on = enabled;
                        toggle.enabled = *descriptor->patchState != MPPatchStateFailed;
                    }

                    UILabel *status = self.statusLabels[@(index)];
                    switch (*descriptor->patchState) {
                    case MPPatchStateInstalled:
                        status.text = enabled
                            ? @"Installed · Patch"
                            : @"Installed · Original";
                        if (@available(iOS 13.0, *)) {
                            status.textColor = UIColor.systemGreenColor;
                        }
                        break;
                    case MPPatchStatePending:
                        status.text = @"Waiting for class";
                        status.textColor = MPSecondaryLabelColor();
                        break;
                    case MPPatchStateFailed:
                        status.text = @"Unavailable";
                        status.textColor = MPErrorColor();
                        break;
                    }
                }
                self.summaryLabel.text = [NSString stringWithFormat:@"%lu runtime controls",
                    (unsigned long)MPRuntimeControlCount()];
                self.showButtonButton.hidden = !self.buttonHiddenForSession;
            }

            - (void)invalidate {
                [self.button removeFromSuperview];
                [self.panel removeFromSuperview];
                if (self.activationGesture != nil && self.window != nil) {
                    [self.window removeGestureRecognizer:self.activationGesture];
                }
                self.activationGesture = nil;
            }

            @end

            @implementation MPRuntimeControlsManager

            + (instancetype)sharedManager {
                static MPRuntimeControlsManager *manager;
                static dispatch_once_t onceToken;
                dispatch_once(&onceToken, ^{
                    manager = [[MPRuntimeControlsManager alloc] init];
                    manager.overlays = [NSMapTable weakToStrongObjectsMapTable];
                });
                return manager;
            }

            - (void)start {
                if (self.started) { return; }
                self.started = YES;
                if (UIAccessibilityIsVoiceOverRunning()) {
                    MPVoiceOverFallbackForSession = YES;
                }
                NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
                [center addObserver:self
                    selector:@selector(applicationStateChanged:)
                    name:UIApplicationDidBecomeActiveNotification
                    object:nil];
                [center addObserver:self
                    selector:@selector(applicationStateChanged:)
                    name:UIWindowDidBecomeKeyNotification
                    object:nil];
                [center addObserver:self
                    selector:@selector(voiceOverChanged:)
                    name:UIAccessibilityVoiceOverStatusDidChangeNotification
                    object:nil];
                if (@available(iOS 13.0, *)) {
                    [center addObserver:self
                        selector:@selector(applicationStateChanged:)
                        name:UISceneDidActivateNotification
                        object:nil];
                    [center addObserver:self
                        selector:@selector(applicationStateChanged:)
                        name:UISceneWillDeactivateNotification
                        object:nil];
                }
                [self refreshWindows];
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(),
                    ^{ [self refreshWindows]; }
                );
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(),
                    ^{ [self refreshWindows]; }
                );
            }

            - (void)applicationStateChanged:(NSNotification *)notification {
                (void)notification;
                [self refreshWindows];
            }

            - (void)voiceOverChanged:(NSNotification *)notification {
                (void)notification;
                if (UIAccessibilityIsVoiceOverRunning()) {
                    MPVoiceOverFallbackForSession = YES;
                }
                [self refreshWindows];
            }

            - (void)refreshWindows {
                UIApplication *application = UIApplication.sharedApplication;
                NSMutableSet<UIWindow *> *activeWindows = [NSMutableSet set];
                if (@available(iOS 13.0, *)) {
                    for (UIScene *scene in application.connectedScenes) {
                        if (![scene isKindOfClass:[UIWindowScene class]]
                            || scene.activationState != UISceneActivationStateForegroundActive) {
                            continue;
                        }
                        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                            if (window.isKeyWindow && !window.hidden) {
                                [activeWindows addObject:window];
                            }
                        }
                    }
                }
                if (activeWindows.count == 0) {
                    UIWindow *legacyWindow = [application valueForKey:@"keyWindow"];
                    if (legacyWindow != nil && !legacyWindow.hidden) {
                        [activeWindows addObject:legacyWindow];
                    }
                }

                NSArray<UIWindow *> *knownWindows = self.overlays.keyEnumerator.allObjects;
                for (UIWindow *window in knownWindows) {
                    if (![activeWindows containsObject:window]) {
                        MPRuntimeControlsOverlay *overlay = [self.overlays objectForKey:window];
                        [overlay invalidate];
                        [self.overlays removeObjectForKey:window];
                    }
                }
                for (UIWindow *window in activeWindows) {
                    MPRuntimeControlsOverlay *overlay = [self.overlays objectForKey:window];
                    if (overlay == nil) {
                        overlay = [[MPRuntimeControlsOverlay alloc] initWithWindow:window];
                        [self.overlays setObject:overlay forKey:window];
                    }
                    [overlay updateEntryPoints];
                    [overlay refreshControls];
                }
            }

            - (void)refreshAllControls {
                for (MPRuntimeControlsOverlay *overlay in self.overlays.objectEnumerator) {
                    [overlay refreshControls];
                }
            }

            @end
            """
    }

    private func runtimeControlDescriptorEntry(_ context: PatchGenerationContext) -> String {
        guard let control = context.patch.runtimeControl else {
            preconditionFailure("Uncontrolled patch reached runtime descriptor generation")
        }
        let fields = [
            ObjectiveCLiteral.string(context.patch.id),
            ObjectiveCLiteral.string(control.title),
            ObjectiveCLiteral.string(context.objcDescription),
            "&\(context.controlEnabledName)",
            control.defaultEnabled ? "YES" : "NO",
            "&\(context.stateName)",
        ]
        return "{ \(fields.joined(separator: ", ")) }"
    }

    private var alertRuntime: String {
        let showAlertIsUsed = contexts.contains { context in
            (context.advanced.beforeEffects + context.advanced.afterEffects).contains { effect in
                if case .showAlert = effect { return true }
                return false
            }
        }
        let unusedAttribute = showAlertIsUsed ? "" : " __attribute__((unused))"
        return """
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

            static void\(unusedAttribute) MPShowAlert(
                NSString *title,
                NSString *message,
                NSString *buttonTitle
            ) {
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
        if let control = context.patch.runtimeControl {
            parts.append(
                "static BOOL \(context.controlEnabledName) = \(control.defaultEnabled ? "YES" : "NO");"
            )
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
        if context.patch.runtimeControl != nil {
            prefix.append(contentsOf: runtimeControlPrologue(context))
        }
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

    private func runtimeControlPrologue(_ context: PatchGenerationContext) -> [String] {
        var lines = [
            "BOOL runtimeControlEnabled = __atomic_load_n(&\(context.controlEnabledName), __ATOMIC_ACQUIRE);",
            "if (!runtimeControlEnabled) {",
        ]
        lines.append(contentsOf: callOriginalUnchanged(context).map { "    \($0)" })
        lines.append("}")
        return lines
    }

    private func callOriginalUnchanged(_ context: PatchGenerationContext) -> [String] {
        context.signature.returnType.kind == .void
            ? ["\(context.originalCall);", "return;"]
            : ["return \(context.originalCall);"]
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
            let expression = valueExpression(
                replacement.value,
                target: argument.type,
                cType: argument.cType
            )
            return
                "\(argument.name) = \(expression);"
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
        lines.append(contentsOf: [
            "",
            "IMP resolvedImplementation = method_getImplementation(method);",
            "if (resolvedImplementation == NULL) {",
            "    \(context.stateName) = MPPatchStateFailed;",
            "    return NO;",
            "}",
            "IMP replacementImplementation = (IMP)\(context.replacementName);",
            "if (class_addMethod(targetClass, selector, replacementImplementation, encoding)) {",
            "    \(context.originalName) = (\(context.functionTypeName))MPBaselineImplementation(resolvedImplementation);",
            "} else {",
            "    Method directMethod = class_getInstanceMethod(targetClass, selector);",
            "    IMP directImplementation = directMethod == NULL",
            "        ? NULL",
            "        : method_getImplementation(directMethod);",
            "    if (directImplementation == NULL) {",
            "        \(context.stateName) = MPPatchStateFailed;",
            "        return NO;",
            "    }",
            "    \(context.originalName) = (\(context.functionTypeName))MPBaselineImplementation(directImplementation);",
            "    method_setImplementation(directMethod, replacementImplementation);",
            "}",
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

    private func renderImplementationUnwrapper() -> String {
        let mappings = contexts.map { context in
            """
            if (implementation == (IMP)\(context.replacementName)
                && \(context.originalName) != NULL) {
                implementation = (IMP)\(context.originalName);
            }
            """
        }.joined(separator: "\n")
        return """
            static IMP MPBaselineImplementation(IMP implementation) {
                for (NSUInteger pass = 0; pass < \(contexts.count); pass += 1) {
                    IMP previous = implementation;
            \(indent(mappings, spaces: 8))
                    if (implementation == previous) { break; }
                }
                return implementation;
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
        var lines = [
            "__attribute__((constructor))",
            "static void MachPatchInitialize(void) {",
            "    @autoreleasepool {",
        ]
        if contexts.contains(where: { $0.patch.runtimeControl != nil }) {
            lines.append("        MPLoadPersistedRuntimeControls();")
        }
        lines.append(contentsOf: [
            "        NSLog(@\"[MachPatch] Patch dylib loaded\");",
            "        if (MPInstallPendingPatches() > 0) {",
            "            MPScheduleRetry(1.0, NO);",
            "            MPScheduleRetry(3.0, NO);",
            "            MPScheduleRetry(8.0, YES);",
            "        }",
        ])
        if contexts.contains(where: { $0.patch.runtimeControl != nil }) {
            lines.append("        MPInitializeRuntimeControls();")
        }
        lines.append(contentsOf: ["    }", "}"])
        return lines.joined(separator: "\n")
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
