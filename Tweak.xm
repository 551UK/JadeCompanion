#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>

#pragma mark - JadeCompanion

typedef NS_ENUM(NSInteger, JCConnectivityAction) {
    JCConnectivityActionWiFi = 1,
    JCConnectivityActionBluetooth,
    JCConnectivityActionAirplane,
    JCConnectivityActionCellular,
    JCConnectivityActionAirDrop,
};

static const void *kJCActionKey = &kJCActionKey;
static const void *kJCModuleKey = &kJCModuleKey;
static const void *kJCInstalledKey = &kJCInstalledKey;

static BOOL gJCHooksInstalled = NO;
static void (*gJCOriginalDidMoveToWindow)(id, SEL) = NULL;
static void (*gJCOriginalLayoutSubviews)(id, SEL) = NULL;

static id JCObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;

    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar && name[0] != '_') {
        NSString *underscored = [@"_" stringByAppendingString:[NSString stringWithUTF8String:name]];
        ivar = class_getInstanceVariable(object_getClass(object), underscored.UTF8String);
    }

    return ivar ? object_getIvar(object, ivar) : nil;
}

static UIViewController *JCNearestViewController(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }

    UIWindow *window = view.window;
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static void JCLoadPrivateUI(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/ControlCenterUIKit.framework/ControlCenterUIKit", RTLD_LAZY | RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI", RTLD_LAZY | RTLD_GLOBAL);

        NSBundle *connectivityBundle = [NSBundle bundleWithPath:@"/System/Library/ControlCenter/Bundles/ConnectivityModule.bundle"];
        if (connectivityBundle && !connectivityBundle.loaded) {
            NSError *error = nil;
            if (![connectivityBundle loadAndReturnError:&error]) {
                NSLog(@"[JadeCompanion] Could not load ConnectivityModule.bundle: %@", error);
            }
        }
    });
}

static CGFloat JCFloatReturn(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return 0.0;
    return ((CGFloat (*)(id, SEL))objc_msgSend)(object, selector);
}

static void JCSendBool(id object, SEL selector, BOOL value) {
    if (object && [object respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    }
}

@interface JCStockMenuHostViewController : UIViewController <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIViewController *contentController;
@property (nonatomic, assign) BOOL connectivityPanel;
- (instancetype)initWithContentController:(UIViewController *)controller connectivityPanel:(BOOL)connectivityPanel;
@end

@implementation JCStockMenuHostViewController

- (instancetype)initWithContentController:(UIViewController *)controller connectivityPanel:(BOOL)connectivityPanel {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _contentController = controller;
        _connectivityPanel = connectivityPanel;
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];

    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(jc_dismissTap:)];
    dismissTap.delegate = self;
    dismissTap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:dismissTap];

    UIViewController *controller = self.contentController;
    [self addChildViewController:controller];

    UIView *contentView = controller.view;
    contentView.clipsToBounds = YES;
    contentView.layer.masksToBounds = YES;

    CGFloat radius = JCFloatReturn(controller, NSSelectorFromString(@"preferredExpandedContinuousCornerRadius"));
    if (radius <= 0.0 || radius > 80.0) radius = 22.0;
    contentView.layer.cornerRadius = radius;

    [self.view addSubview:contentView];
    [controller didMoveToParentViewController:self];

    JCSendBool(controller, NSSelectorFromString(@"contentModuleWillTransitionToExpandedContentMode:"), YES);
    JCSendBool(controller, NSSelectorFromString(@"willTransitionToExpandedContentMode:"), YES);
    JCSendBool(controller, NSSelectorFromString(@"containerWillTransitionToExpandedContentMode:"), YES);
    JCSendBool(controller, NSSelectorFromString(@"didTransitionToExpandedContentMode:"), YES);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    UIViewController *controller = self.contentController;
    CGFloat availableWidth = MAX(280.0, CGRectGetWidth(self.view.bounds) - 32.0);
    CGFloat availableHeight = MAX(220.0, CGRectGetHeight(self.view.bounds) - 80.0);

    CGFloat width = JCFloatReturn(controller, NSSelectorFromString(@"preferredExpandedContentWidth"));
    CGFloat height = JCFloatReturn(controller, NSSelectorFromString(@"preferredExpandedContentHeight"));

    if (self.connectivityPanel) {
        if (width < 250.0) width = 340.0;
        if (height < 250.0) height = 360.0;
    } else {
        if (width < 250.0) width = 340.0;
        if (height < 220.0) height = 410.0;
    }

    width = MIN(MAX(width, 280.0), MIN(390.0, availableWidth));
    height = MIN(MAX(height, 300.0), MIN(500.0, availableHeight));

    UIView *contentView = controller.view;
    contentView.bounds = CGRectMake(0.0, 0.0, width, height);
    contentView.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
}

- (void)jc_dismissTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateEnded) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if ([touch.view isDescendantOfView:self.contentController.view]) {
        return NO;
    }
    return YES;
}

@end

static UIViewController *JCNewControllerNamed(NSString *className, BOOL expandedConnectivity) {
    JCLoadPrivateUI();

    Class cls = NSClassFromString(className);
    if (!cls) {
        NSLog(@"[JadeCompanion] Missing Apple class %@", className);
        return nil;
    }

    UIViewController *controller = nil;
    NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/ControlCenter/Bundles/ConnectivityModule.bundle"];
    SEL initWithNib = @selector(initWithNibName:bundle:);

    if ([cls instancesRespondToSelector:initWithNib]) {
        controller = ((id (*)(id, SEL, id, id))objc_msgSend)([cls alloc], initWithNib, nil, bundle);
    } else {
        controller = [[cls alloc] init];
    }

    if (!controller) return nil;

    JCSendBool(controller, NSSelectorFromString(@"setShouldProvideOwnPlatter:"), YES);

    if (expandedConnectivity) {
        (void)controller.view;
        JCSendBool(controller, NSSelectorFromString(@"willTransitionToExpandedContentMode:"), YES);
    }

    return controller;
}

static BOOL JCPresentControllerFromView(UIViewController *controller, UIView *sourceView, BOOL expandedConnectivity) {
    if (!controller || !sourceView) return NO;

    UIViewController *presenter = JCNearestViewController(sourceView);
    if (!presenter) return NO;

    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }

    JCStockMenuHostViewController *host = [[JCStockMenuHostViewController alloc] initWithContentController:controller
                                                                                         connectivityPanel:expandedConnectivity];
    [presenter presentViewController:host animated:YES completion:nil];
    return YES;
}

static BOOL JCPresentStockMenu(NSString *className, UIView *sourceView) {
    UIViewController *controller = JCNewControllerNamed(className, NO);
    return JCPresentControllerFromView(controller, sourceView, NO);
}

static BOOL JCPresentExpandedConnectivity(UIView *sourceView) {
    UIViewController *controller = JCNewControllerNamed(@"CCUIConnectivityModuleViewController", YES);
    return JCPresentControllerFromView(controller, sourceView, YES);
}

static void JCOpenSettingsFallback(JCConnectivityAction action) {
    NSString *urlString = nil;
    switch (action) {
        case JCConnectivityActionWiFi:
            urlString = @"App-prefs:root=WIFI";
            break;
        case JCConnectivityActionBluetooth:
            urlString = @"App-prefs:root=Bluetooth";
            break;
        case JCConnectivityActionCellular:
            urlString = @"App-prefs:root=MOBILE_DATA_SETTINGS_ID";
            break;
        case JCConnectivityActionAirDrop:
            urlString = @"App-prefs:root=General&path=AIRDROP_LINK";
            break;
        case JCConnectivityActionAirplane:
        default:
            urlString = @"App-prefs:";
            break;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;

    UIApplication *application = [UIApplication sharedApplication];
    if ([application respondsToSelector:@selector(openURL:options:completionHandler:)]) {
        [application openURL:url options:@{} completionHandler:nil];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [application openURL:url];
#pragma clang diagnostic pop
    }
}

@interface JCConnectivityGestureHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedHandler;
- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer;
@end

@implementation JCConnectivityGestureHandler

+ (instancetype)sharedHandler {
    static JCConnectivityGestureHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handler = [JCConnectivityGestureHandler new];
    });
    return handler;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;

    UIView *sourceView = recognizer.view;
    JCConnectivityAction action = (JCConnectivityAction)[objc_getAssociatedObject(recognizer, kJCActionKey) integerValue];

    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];

    BOOL presented = NO;
    switch (action) {
        case JCConnectivityActionWiFi:
            presented = JCPresentStockMenu(@"CCUIWiFiMenuModuleViewController", sourceView);
            break;
        case JCConnectivityActionBluetooth:
            presented = JCPresentStockMenu(@"CCUIBluetoothMenuModuleViewController", sourceView);
            break;
        case JCConnectivityActionAirDrop:
            presented = JCPresentStockMenu(@"CCUIAirDropMenuModuleViewController", sourceView);
            break;
        case JCConnectivityActionAirplane:
        case JCConnectivityActionCellular:
            presented = JCPresentExpandedConnectivity(sourceView);
            break;
    }

    if (!presented) {
        NSLog(@"[JadeCompanion] Stock presentation failed for action %ld; opening Settings fallback", (long)action);
        JCOpenSettingsFallback(action);
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

@end

static void JCInstallLongPress(UIView *button, id module, JCConnectivityAction action) {
    if (!button || ![button isKindOfClass:[UIView class]]) return;

    NSNumber *installedAction = objc_getAssociatedObject(button, kJCInstalledKey);
    if (installedAction && installedAction.integerValue == action) return;

    button.userInteractionEnabled = YES;

    UILongPressGestureRecognizer *recognizer = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[JCConnectivityGestureHandler sharedHandler]
                action:@selector(handleLongPress:)];
    recognizer.minimumPressDuration = 0.45;
    recognizer.allowableMovement = 18.0;
    recognizer.cancelsTouchesInView = YES;
    recognizer.delaysTouchesBegan = NO;
    recognizer.delegate = [JCConnectivityGestureHandler sharedHandler];

    objc_setAssociatedObject(recognizer, kJCActionKey, @(action), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(recognizer, kJCModuleKey, module, OBJC_ASSOCIATION_ASSIGN);
    [button addGestureRecognizer:recognizer];
    objc_setAssociatedObject(button, kJCInstalledKey, @(action), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if ([module isKindOfClass:[UIView class]]) {
        for (UIGestureRecognizer *other in [(UIView *)module gestureRecognizers]) {
            if (other != recognizer && [other isKindOfClass:[UILongPressGestureRecognizer class]]) {
                [other requireGestureRecognizerToFail:recognizer];
            }
        }
    }
}

static void JCInstallGesturesOnConnectivityModule(id module) {
    if (!module) return;

    UIView *wifi = JCObjectIvar(module, "wifiButton");
    UIView *bluetooth = JCObjectIvar(module, "bluetoothButton");
    UIView *airplane = JCObjectIvar(module, "airplaneModeButton");
    UIView *cellular = JCObjectIvar(module, "cellularButton");
    UIView *airDrop = JCObjectIvar(module, "airDropButton");

    JCInstallLongPress(wifi, module, JCConnectivityActionWiFi);
    JCInstallLongPress(bluetooth, module, JCConnectivityActionBluetooth);
    JCInstallLongPress(airplane, module, JCConnectivityActionAirplane);
    JCInstallLongPress(cellular, module, JCConnectivityActionCellular);
    JCInstallLongPress(airDrop, module, JCConnectivityActionAirDrop);
}

static void JCHookedDidMoveToWindow(id self, SEL _cmd) {
    if (gJCOriginalDidMoveToWindow) {
        gJCOriginalDidMoveToWindow(self, _cmd);
    }
    JCInstallGesturesOnConnectivityModule(self);
}

static void JCHookedLayoutSubviews(id self, SEL _cmd) {
    if (gJCOriginalLayoutSubviews) {
        gJCOriginalLayoutSubviews(self, _cmd);
    }
    JCInstallGesturesOnConnectivityModule(self);
}

static void JCTryInstallHooks(NSUInteger attempt) {
    if (gJCHooksInstalled) return;

    Class jadeConnectivityClass = objc_getClass("JadeConnectivityModule");
    if (!jadeConnectivityClass) {
        if (attempt < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                JCTryInstallHooks(attempt + 1);
            });
        } else {
            NSLog(@"[JadeCompanion] JadeConnectivityModule never appeared; hooks not installed");
        }
        return;
    }

    Method didMoveMethod = class_getInstanceMethod(jadeConnectivityClass, @selector(didMoveToWindow));
    Method layoutMethod = class_getInstanceMethod(jadeConnectivityClass, @selector(layoutSubviews));

    if (!didMoveMethod || !layoutMethod) {
        NSLog(@"[JadeCompanion] JadeConnectivityModule lifecycle methods are missing; unsupported Jade build");
        return;
    }

    MSHookMessageEx(jadeConnectivityClass,
                    @selector(didMoveToWindow),
                    (IMP)JCHookedDidMoveToWindow,
                    (IMP *)&gJCOriginalDidMoveToWindow);

    MSHookMessageEx(jadeConnectivityClass,
                    @selector(layoutSubviews),
                    (IMP)JCHookedLayoutSubviews,
                    (IMP *)&gJCOriginalLayoutSubviews);

    gJCHooksInstalled = YES;
    NSLog(@"[JadeCompanion] Hooks installed for JadeConnectivityModule");
}

__attribute__((constructor)) static void JadeCompanionInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            JCTryInstallHooks(0);
        });
    }
}
