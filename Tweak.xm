#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>
#import <stdlib.h>

typedef NS_ENUM(NSInteger, JCConnectivityAction) {
    JCConnectivityActionNone = 0,
    JCConnectivityActionWiFi,
    JCConnectivityActionBluetooth,
    JCConnectivityActionAirplane,
    JCConnectivityActionCellular,
    JCConnectivityActionAirDrop,
};

static NSString * const JCConnectivityIdentifier = @"com.apple.control-center.ConnectivityModule";

static void (*gOrigFullWidthHandleLongPress)(id, SEL, UILongPressGestureRecognizer *) = NULL;
static BOOL gHooksInstalled = NO;

#pragma mark - Runtime helpers

static Ivar JCIvarForObject(id object, const char *name) {
    if (!object || !name) return NULL;

    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) return ivar;
    }
    return NULL;
}

static id JCObjectIvar(id object, const char *name) {
    Ivar ivar = JCIvarForObject(object, name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

static id JCObjectForSelector(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) return nil;

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;

    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void JCVoidBool(id object, NSString *selectorName, BOOL value) {
    if (!object) return;

    SEL selector = NSSelectorFromString(selectorName);
    if ([object respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
    }
}

static id JCAllocInit(Class cls) {
    if (!cls) return nil;
    id object = ((id (*)(id, SEL))objc_msgSend)((id)cls, @selector(alloc));
    return ((id (*)(id, SEL))objc_msgSend)(object, @selector(init));
}

static id JCJadeButton(id module, NSString *name) {
    id value = JCObjectForSelector(module, name);
    if (value) return value;

    value = JCObjectIvar(module, name.UTF8String);
    if (value) return value;

    NSString *underscored = [@"_" stringByAppendingString:name];
    return JCObjectIvar(module, underscored.UTF8String);
}

static void JCLoadControlCenterFrameworks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/ControlCenterUIKit.framework/ControlCenterUIKit",
               RTLD_LAZY | RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI",
               RTLD_LAZY | RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/ControlCenterServices.framework/ControlCenterServices",
               RTLD_LAZY | RTLD_GLOBAL);

        NSBundle *bundle =
            [NSBundle bundleWithPath:@"/System/Library/ControlCenter/Bundles/ConnectivityModule.bundle"];

        if (bundle && !bundle.loaded) {
            [bundle load];
        }
    });
}

#pragma mark - Jade button mapping

static JCConnectivityAction JCActionAtLocation(id module, CGPoint point) {
    UIView *moduleView = [module isKindOfClass:[UIView class]] ? (UIView *)module : nil;
    if (!moduleView) return JCConnectivityActionNone;

    struct {
        __unsafe_unretained NSString *name;
        JCConnectivityAction action;
    } entries[] = {
        {@"wifiButton", JCConnectivityActionWiFi},
        {@"bluetoothButton", JCConnectivityActionBluetooth},
        {@"airplaneModeButton", JCConnectivityActionAirplane},
        {@"cellularButton", JCConnectivityActionCellular},
        {@"airDropButton", JCConnectivityActionAirDrop},
    };

    for (NSUInteger i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        UIView *button = JCJadeButton(module, entries[i].name);
        if (![button isKindOfClass:[UIView class]] || button.hidden || button.alpha < 0.01) {
            continue;
        }

        CGPoint pointInButton = [moduleView convertPoint:point toView:button];
        if ([button pointInside:pointInButton withEvent:nil]) {
            return entries[i].action;
        }
    }

    return JCConnectivityActionNone;
}

static NSString *JCActionName(JCConnectivityAction action) {
    switch (action) {
        case JCConnectivityActionWiFi: return @"Wi-Fi";
        case JCConnectivityActionBluetooth: return @"Bluetooth";
        case JCConnectivityActionAirplane: return @"Airplane Mode";
        case JCConnectivityActionCellular: return @"Cellular Data";
        case JCConnectivityActionAirDrop: return @"AirDrop";
        default: return @"Connectivity";
    }
}

#pragma mark - Presentation helpers

static UIViewController *JCTopViewController(UIViewController *controller) {
    if (!controller) return nil;

    UIViewController *presented = controller.presentedViewController;
    if (presented && !presented.isBeingDismissed) {
        return JCTopViewController(presented);
    }

    if ([controller isKindOfClass:[UINavigationController class]]) {
        return JCTopViewController(((UINavigationController *)controller).visibleViewController);
    }

    if ([controller isKindOfClass:[UITabBarController class]]) {
        return JCTopViewController(((UITabBarController *)controller).selectedViewController);
    }

    return controller;
}

static UIViewController *JCPresenterForView(UIView *sourceView) {
    UIWindow *window = sourceView.window;

    if (window.rootViewController) {
        return JCTopViewController(window.rootViewController);
    }

    for (UIWindow *candidate in [UIApplication sharedApplication].windows.reverseObjectEnumerator) {
        if (!candidate.hidden && candidate.alpha > 0.01 && candidate.rootViewController) {
            return JCTopViewController(candidate.rootViewController);
        }
    }

    return nil;
}

static void JCShowMessage(UIView *sourceView, NSString *message) {
    UIWindow *window = sourceView.window;
    if (!window || message.length == 0) return;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = message;
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    label.numberOfLines = 2;
    label.layer.cornerRadius = 12.0;
    label.clipsToBounds = YES;

    CGFloat width = MIN(CGRectGetWidth(window.bounds) - 32.0, 390.0);
    label.frame = CGRectMake((CGRectGetWidth(window.bounds) - width) / 2.0,
                             70.0,
                             width,
                             58.0);
    label.alpha = 0.0;

    [window addSubview:label];

    [UIView animateWithDuration:0.16 animations:^{
        label.alpha = 1.0;
    } completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.2
                              delay:1.8
                            options:0
                         animations:^{
            label.alpha = 0.0;
        } completion:^(__unused BOOL finished2) {
            [label removeFromSuperview];
        }];
    }];
}

#pragma mark - Stock Connectivity creation

static id JCNewContentModuleContext(void) {
    Class contextClass = objc_getClass("CCUIContentModuleContext");
    if (!contextClass) return nil;

    id context = ((id (*)(id, SEL))objc_msgSend)((id)contextClass, @selector(alloc));
    SEL initSelector = NSSelectorFromString(@"initWithModuleIdentifier:");

    if ([context respondsToSelector:initSelector]) {
        context = ((id (*)(id, SEL, id))objc_msgSend)(context,
                                                       initSelector,
                                                       JCConnectivityIdentifier);
    } else {
        context = ((id (*)(id, SEL))objc_msgSend)(context, @selector(init));
    }

    Class managerClass = objc_getClass("CCUIModuleInstanceManager");
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    id manager = nil;

    if (managerClass && [managerClass respondsToSelector:sharedSelector]) {
        manager = ((id (*)(id, SEL))objc_msgSend)((id)managerClass, sharedSelector);
    }

    SEL setDelegate = NSSelectorFromString(@"setDelegate:");
    if (context && manager && [context respondsToSelector:setDelegate]) {
        ((void (*)(id, SEL, id))objc_msgSend)(context, setDelegate, manager);
    }

    return context;
}

static UIViewController *JCNewConnectivityViewController(id context, id *moduleOut) {
    Class moduleClass = objc_getClass("CCUIConnectivityModule");
    id module = JCAllocInit(moduleClass);

    SEL setContext = NSSelectorFromString(@"setContentModuleContext:");
    if (module && context && [module respondsToSelector:setContext]) {
        ((void (*)(id, SEL, id))objc_msgSend)(module, setContext, context);
    }

    UIViewController *controller = nil;

    SEL controllerForContext = NSSelectorFromString(@"contentViewControllerForContext:");
    if (module && [module respondsToSelector:controllerForContext]) {
        controller = ((id (*)(id, SEL, id))objc_msgSend)(module,
                                                          controllerForContext,
                                                          context);
    }

    if (!controller) {
        SEL contentViewController = NSSelectorFromString(@"contentViewController");
        if (module && [module respondsToSelector:contentViewController]) {
            controller = ((id (*)(id, SEL))objc_msgSend)(module, contentViewController);
        }
    }

    if (!controller) {
        Class controllerClass = objc_getClass("CCUIConnectivityModuleViewController");
        if (controllerClass) {
            id allocated = ((id (*)(id, SEL))objc_msgSend)((id)controllerClass, @selector(alloc));
            SEL initWithContext = NSSelectorFromString(@"initWithContentModuleContext:");

            if ([allocated respondsToSelector:initWithContext]) {
                controller = ((id (*)(id, SEL, id))objc_msgSend)(allocated,
                                                                  initWithContext,
                                                                  context);
            } else {
                controller = ((id (*)(id, SEL))objc_msgSend)(allocated, @selector(init));

                if (context && [controller respondsToSelector:setContext]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(controller,
                                                          setContext,
                                                          context);
                }
            }
        }
    }

    if (moduleOut) *moduleOut = module;
    return controller;
}

static id JCObjectForPossibleNames(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        id value = JCObjectForSelector(object, name);
        if (value) return value;

        value = JCObjectIvar(object, name.UTF8String);
        if (value) return value;

        NSString *underscored = [@"_" stringByAppendingString:name];
        value = JCObjectIvar(object, underscored.UTF8String);
        if (value) return value;
    }

    return nil;
}

static BOOL JCClassNameContains(id object, NSString *needle) {
    if (!object) return NO;
    return [NSStringFromClass([object class]).lowercaseString containsString:needle.lowercaseString];
}

static id JCFindChildController(UIViewController *parent, JCConnectivityAction action) {
    NSArray<NSString *> *names = nil;
    NSString *needle = nil;

    switch (action) {
        case JCConnectivityActionWiFi:
            names = @[@"wifiButton", @"wifiButtonViewController",
                      @"expandedWifiButtonViewController", @"wifiModuleViewController"];
            needle = @"wifi";
            break;

        case JCConnectivityActionBluetooth:
            names = @[@"bluetoothButton", @"bluetoothButtonViewController",
                      @"expandedBluetoothButtonViewController", @"bluetoothModuleViewController"];
            needle = @"bluetooth";
            break;

        case JCConnectivityActionAirDrop:
            names = @[@"airDropButton", @"airDropButtonViewController",
                      @"expandedAirDropButtonViewController", @"airDropModuleViewController"];
            needle = @"airdrop";
            break;

        default:
            return nil;
    }

    id known = JCObjectForPossibleNames(parent, names);
    if (known) return known;

    for (UIViewController *child in parent.childViewControllers) {
        if (JCClassNameContains(child, needle)) {
            return child;
        }
    }

    for (Class cls = object_getClass(parent); cls; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);

        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            if (!type || type[0] != '@') continue;

            id value = object_getIvar(parent, ivars[index]);
            if (JCClassNameContains(value, needle)) {
                free(ivars);
                return value;
            }
        }

        free(ivars);
    }

    return nil;
}

static UIViewController *JCDetailControllerForAction(UIViewController *connectivityController,
                                                     JCConnectivityAction action) {
    id child = JCFindChildController(connectivityController, action);
    if (!child) return nil;

    JCVoidBool(child, @"containerWillTransitionToExpandedContentMode:", YES);

    SEL detailSelector =
        NSSelectorFromString(@"presentedViewControllerForContentModuleDetailClickPresentationInteractionController:");

    if ([child respondsToSelector:detailSelector]) {
        id detail = ((id (*)(id, SEL, id))objc_msgSend)(child, detailSelector, nil);
        if ([detail isKindOfClass:[UIViewController class]]) {
            return detail;
        }
    }

    if (action == JCConnectivityActionAirDrop) {
        SEL airDropSelector = NSSelectorFromString(@"_newAirDropMenuViewController");
        if ([child respondsToSelector:airDropSelector]) {
            id detail = ((id (*)(id, SEL))objc_msgSend)(child, airDropSelector);
            if ([detail isKindOfClass:[UIViewController class]]) {
                return detail;
            }
        }
    }

    return nil;
}

#pragma mark - Overlay host

@interface JCConnectivityHostViewController : UIViewController
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIViewController *connectivityController;
@property (nonatomic, strong) UIViewController *detailController;
@property (nonatomic, strong) id contentModuleContext;
@property (nonatomic, strong) id connectivityModule;
@property (nonatomic, assign) JCConnectivityAction action;
- (void)showController:(UIViewController *)controller;
@end

@implementation JCConnectivityHostViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.24];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];

    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 28.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.clipsToBounds = YES;

    [self.view addSubview:panel];
    self.panelView = panel;

    UIView *content = panel.contentView;
    self.contentView = content;

    CGFloat width = MIN(UIScreen.mainScreen.bounds.size.width - 28.0, 390.0);
    CGFloat height = MIN(MAX(UIScreen.mainScreen.bounds.size.height * 0.42, 320.0), 470.0);

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:10.0],
        [panel.widthAnchor constraintEqualToConstant:width],
        [panel.heightAnchor constraintEqualToConstant:height],
    ]];

    UITapGestureRecognizer *dismissTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(outsideTap:)];

    dismissTap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:dismissTap];
}

- (void)outsideTap:(UITapGestureRecognizer *)recognizer {
    CGPoint point = [recognizer locationInView:self.view];

    if (!CGRectContainsPoint(self.panelView.frame, point)) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)showController:(UIViewController *)controller {
    if (!controller || !self.contentView) return;

    UIViewController *old = nil;
    for (UIViewController *child in self.childViewControllers) {
        if (child != controller) {
            old = child;
            break;
        }
    }

    BOOL hostVisible = self.view.window != nil;

    if (old && old.parentViewController == self) {
        if (hostVisible) {
            [old beginAppearanceTransition:NO animated:NO];
        }

        [old willMoveToParentViewController:nil];
        [old.view removeFromSuperview];
        [old removeFromParentViewController];

        if (hostVisible) {
            [old endAppearanceTransition];
        }
    }

    if (controller.parentViewController != self) {
        if (hostVisible) {
            [controller beginAppearanceTransition:YES animated:NO];
        }

        [self addChildViewController:controller];

        UIView *view = controller.view;
        view.translatesAutoresizingMaskIntoConstraints = NO;
        view.backgroundColor = UIColor.clearColor;

        [self.contentView addSubview:view];

        [NSLayoutConstraint activateConstraints:@[
            [view.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [view.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [view.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [view.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        ]];

        [controller didMoveToParentViewController:self];

        if (hostVisible) {
            [controller endAppearanceTransition];
        }
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];

    JCVoidBool(self.connectivityController,
               @"willTransitionToExpandedContentMode:",
               NO);

    id child = self.detailController;
    JCVoidBool(child,
               @"containerWillTransitionToExpandedContentMode:",
               NO);
}

@end

static __strong JCConnectivityHostViewController *gCurrentHost = nil;

static void JCPresentStockConnectivity(UIView *sourceView, JCConnectivityAction action) {
    if (gCurrentHost.presentingViewController) {
        [gCurrentHost dismissViewControllerAnimated:NO completion:nil];
        gCurrentHost = nil;
    }

    id context = JCNewContentModuleContext();
    id module = nil;
    UIViewController *connectivityController =
        JCNewConnectivityViewController(context, &module);

    if (!connectivityController) {
        JCShowMessage(sourceView,
                      @"JadeCompanion: Apple's Connectivity controller could not be created");
        return;
    }

    (void)connectivityController.view;

    JCVoidBool(connectivityController,
               @"willTransitionToExpandedContentMode:",
               YES);

    UIViewController *presenter = JCPresenterForView(sourceView);
    if (!presenter) {
        JCShowMessage(sourceView,
                      @"JadeCompanion: no presentation controller was available");
        return;
    }

    JCConnectivityHostViewController *host = [JCConnectivityHostViewController new];
    host.modalPresentationStyle = UIModalPresentationOverFullScreen;
    host.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    host.contentModuleContext = context;
    host.connectivityModule = module;
    host.connectivityController = connectivityController;
    host.action = action;

    gCurrentHost = host;

    [presenter presentViewController:host animated:YES completion:^{
        [host showController:connectivityController];

        if (action == JCConnectivityActionWiFi ||
            action == JCConnectivityActionBluetooth ||
            action == JCConnectivityActionAirDrop) {

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.18 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *detail =
                    JCDetailControllerForAction(connectivityController, action);

                if (detail) {
                    host.detailController = detail;

                    SEL platter = NSSelectorFromString(@"setShouldProvideOwnPlatter:");
                    if ([detail respondsToSelector:platter]) {
                        ((void (*)(id, SEL, BOOL))objc_msgSend)(detail, platter, YES);
                    }

                    // These Apple detail controllers normally receive a complete
                    // Control Center appearance lifecycle. Our host swaps them in
                    // after presentation, so explicitly drive that lifecycle in
                    // showController:. Bluetooth in particular refreshes its device
                    // list from viewWillAppear:.
                    [host showController:detail];
                } else {
                    JCShowMessage(sourceView,
                                  [NSString stringWithFormat:
                                      @"JadeCompanion: %@ detail unavailable — showing stock Connectivity",
                                      JCActionName(action)]);
                }
            });
        }
    }];
}

#pragma mark - Jade's existing long press

static void JCHookedFullWidthHandleLongPress(id self,
                                             SEL _cmd,
                                             UILongPressGestureRecognizer *recognizer) {
    Class connectivityClass = objc_getClass("JadeConnectivityModule");

    if (!connectivityClass || ![self isKindOfClass:connectivityClass]) {
        if (gOrigFullWidthHandleLongPress) {
            gOrigFullWidthHandleLongPress(self, _cmd, recognizer);
        }
        return;
    }

    // Jade 1.0.5 already installs this recognizer. Its stock handler sets Jade's
    // moduleExpanded/blur state and asks the stock CC collection to expand a
    // Connectivity module that Jade has replaced. Suppress that path completely.
    if (recognizer.state != UIGestureRecognizerStateBegan) return;

    UIView *moduleView = [self isKindOfClass:[UIView class]] ? (UIView *)self : nil;
    if (!moduleView) return;

    CGPoint point = [recognizer locationInView:moduleView];
    JCConnectivityAction action = JCActionAtLocation(self, point);
    if (action == JCConnectivityActionNone) return;

    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];

    JCPresentStockConnectivity(moduleView, action);
}

static void JCTryInstallHooks(NSUInteger attempt) {
    JCLoadControlCenterFrameworks();

    Class fullWidthClass = objc_getClass("JadeFullWidthModule");
    Class connectivityClass = objc_getClass("JadeConnectivityModule");
    SEL longPressSelector = NSSelectorFromString(@"handleLongPress:");

    if (!gHooksInstalled &&
        fullWidthClass &&
        connectivityClass &&
        class_getInstanceMethod(fullWidthClass, longPressSelector)) {

        MSHookMessageEx(fullWidthClass,
                        longPressSelector,
                        (IMP)JCHookedFullWidthHandleLongPress,
                        (IMP *)&gOrigFullWidthHandleLongPress);

        gHooksInstalled = YES;
    }

    if (!gHooksInstalled && attempt < 80) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            JCTryInstallHooks(attempt + 1);
        });
    }
}

__attribute__((constructor)) static void JadeCompanionInit(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            JCTryInstallHooks(0);
        });
    }
}
