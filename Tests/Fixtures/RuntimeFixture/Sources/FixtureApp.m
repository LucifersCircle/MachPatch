#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface MPFixtureController : NSObject
@property(nonatomic) BOOL recordedFlag;
@property(nonatomic, strong) id recordedObject;
- (BOOL)featureEnabled;
- (NSInteger)scoreForLevel:(NSInteger)level;
- (NSString *)greetingForName:(NSString *)name;
- (void)recordFlag:(BOOL)flag object:(id)object;
- (CGRect)insetRect:(CGRect)rect;
- (NSRange)clampedRange:(NSRange)range;
- (NSInteger)applyIntegerBlock:(NSInteger (^)(NSInteger value))block
                        toValue:(NSInteger)value;
@end

@implementation MPFixtureController

- (BOOL)featureEnabled {
    return NO;
}

- (NSInteger)scoreForLevel:(NSInteger)level {
    return level * 10;
}

- (NSString *)greetingForName:(NSString *)name {
    return [NSString stringWithFormat:@"Hello, %@", name];
}

- (void)recordFlag:(BOOL)flag object:(id)object {
    self.recordedFlag = flag;
    self.recordedObject = object;
}

- (CGRect)insetRect:(CGRect)rect {
    return CGRectInset(rect, 1, 2);
}

- (NSRange)clampedRange:(NSRange)range {
    return NSMakeRange(MIN(range.location, 100), MIN(range.length, 20));
}

- (NSInteger)applyIntegerBlock:(NSInteger (^)(NSInteger value))block
                        toValue:(NSInteger)value {
    return block == nil ? value : block(value);
}

@end

@interface MPFixtureController (MPFixtureExtras)
- (BOOL)categoryValue;
@end

@implementation MPFixtureController (MPFixtureExtras)

- (BOOL)categoryValue {
    return NO;
}

@end

@interface MPFixtureAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation MPFixtureAppDelegate {
    MPFixtureController *_fixture;
    UILabel *_statusLabel;
    void *_frameworkHandle;
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    (void)application;
    (void)launchOptions;

    _fixture = [MPFixtureController new];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *title = [UILabel new];
    title.text = @"MachPatch Runtime Fixture";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.textAlignment = NSTextAlignmentCenter;

    _statusLabel = [UILabel new];
    _statusLabel.text = @"Ready";
    _statusLabel.numberOfLines = 0;
    _statusLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        title,
        [self buttonWithTitle:@"Run Immediate Targets" action:@selector(runImmediateTargets)],
        [self buttonWithTitle:@"Load Framework Target" action:@selector(loadFrameworkTarget)],
        _statusLabel,
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [stack.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
    ]];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    return YES;
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)runImmediateTargets {
    BOOL feature = [_fixture featureEnabled];
    NSInteger score = [_fixture scoreForLevel:3];
    NSString *greeting = [_fixture greetingForName:@"Device"];
    [_fixture recordFlag:YES object:greeting];
    CGRect rect = [_fixture insetRect:CGRectMake(0, 0, 20, 30)];
    NSRange range = [_fixture clampedRange:NSMakeRange(150, 40)];
    NSInteger blockResult = [_fixture applyIntegerBlock:^NSInteger(NSInteger value) {
        return value + 5;
    } toValue:7];
    BOOL category = [_fixture categoryValue];

    _statusLabel.text = [NSString stringWithFormat:
        @"feature=%@\nscore=%ld\n%@\nflag=%@\nrect=%.0fx%.0f\nrange=%lu,%lu\nblock=%ld\ncategory=%@",
        feature ? @"YES" : @"NO",
        (long)score,
        greeting,
        _fixture.recordedFlag ? @"YES" : @"NO",
        rect.size.width,
        rect.size.height,
        (unsigned long)range.location,
        (unsigned long)range.length,
        (long)blockResult,
        category ? @"YES" : @"NO"];
}

- (void)loadFrameworkTarget {
    if (_frameworkHandle == NULL) {
        NSString *frameworkPath = [NSBundle.mainBundle.privateFrameworksPath
            stringByAppendingPathComponent:@"MPFixtureKit.framework/MPFixtureKit"];
        _frameworkHandle = dlopen(frameworkPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    }
    if (_frameworkHandle == NULL) {
        const char *error = dlerror();
        _statusLabel.text = [NSString stringWithFormat:@"dlopen failed: %s", error ?: "unknown"];
        return;
    }

    Class targetClass = NSClassFromString(@"MPFixtureLateTarget");
    if (targetClass == Nil) {
        _statusLabel.text = @"Framework loaded, but MPFixtureLateTarget is missing.";
        return;
    }

    id target = [targetClass new];
    BOOL (*sendBoolean)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    NSInteger (*sendInteger)(id, SEL) = (NSInteger (*)(id, SEL))objc_msgSend;
    BOOL value = sendBoolean(target, sel_registerName("lateValue"));
    NSInteger integer = sendInteger(target, sel_registerName("lateInteger"));
    BOOL category = sendBoolean([NSObject new], sel_registerName("mp_fixtureCategoryFlag"));
    _statusLabel.text = [NSString stringWithFormat:
        @"framework=loaded\nlateValue=%@\nlateInteger=%ld\nframeworkCategory=%@",
        value ? @"YES" : @"NO",
        (long)integer,
        category ? @"YES" : @"NO"];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(MPFixtureAppDelegate.class));
    }
}
