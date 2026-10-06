#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>

typedef NS_ENUM(NSInteger, JCConnectivityAction) {
    JCConnectivityActionNone = 0,
    JCConnectivityActionWiFi = 1,
    JCConnectivityActionBluetooth,
    JCConnectivityActionAirplane,
    JCConnectivityActionCellular,
    JCConnectivityActionAirDrop,
};

static const void *kJCModuleLongPressKey = &kJCModuleLongPressKey;

static void (*gOrigCardViewWillAppear)(id, SEL, BOOL) = NULL;
static void (*gOrigCardViewDidLayoutSubviews)(id, SEL) = NULL;
static void (*gOrigModuleDidMoveToWindow)(id, SEL) = NULL;
static void (*gOrigModuleLayoutSubviews)(id, SEL) = NULL;
static void (*gOrigStockWillTransition)(id, SEL, BOOL) = NULL;

static BOOL gJadeHooksInstalled = NO;
static BOOL gStockHookInstalled = NO;
static __weak id gCurrentJadeCard = nil;
static __weak id gStockConnectivityController = nil;
static JCConnectivityAction gPendingAction = JCConnectivityActionNone;

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

static id JCJadeButton(id module, NSString *name) {
    if (!module || name.length == 0) return nil;

    // Jade exposes names such as wifiButton as Objective-C accessors, while the
    // backing ivars are normally underscored (_wifiButton). v0.3 only checked
    // the non-underscored ivar name, so a valid hold could be detected but then
    // discarded before the haptic/action ever ran.
    id value = JCObjectForSelector(module, name);
    if (value) return value;

    value = JCObjectIvar(module, name.UTF8String);
    if (value) return value;

    NSString *underscored = [@"_" stringByAppendingString:name];
    return JCObjectIvar(module, underscored.UTF8String);
}

static void JCLoadConnectivityBundle(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/ControlCenterUIKit.framework/ControlCenterUIKit", RTLD_LAZY | RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI", RTLD_LAZY | RTLD_GLOBAL);

        NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/ControlCenter/Bundles/ConnectivityModule.bundle"];
        if (bundle && !bundle.loaded) {
            NSError *error = nil;
            if (![bundle loadAndReturnError:&error]) {
                NSLog(@"[JadeCompanion] ConnectivityModule.bundle load failed: %@", error);
            }
        }
    });
}

static UIViewController *JCFindJadeCardController(UIView *view) {
    Class cardClass = objc_getClass("JadeCardViewController");
    UIResponder *responder = view;

    while (responder) {
        if (cardClass && [responder isKindOfClass:cardClass]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }

    id card = gCurrentJadeCard;
    if (cardClass && card && [card isKindOfClass:cardClass]) {
        return card;
    }
    return nil;
}

#pragma mark - Jade module discovery

static void JCCollectConnectivityModules(UIView *view, NSMutableArray<UIView *> *results) {
    if (!view) return;

    Class moduleClass = objc_getClass("JadeConnectivityModule");
    if (moduleClass && [view isKindOfClass:moduleClass]) {
        [results addObject:view];
    }

    for (UIView *subview in view.subviews) {
        JCCollectConnectivityModules(subview, results);
    }
}

static JCConnectivityAction JCActionAtLocation(UIView *module, CGPoint pointInModule) {
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
        if (![button isKindOfClass:[UIView class]] || button.hidden || button.alpha < 0.01) continue;

        CGPoint pointInButton = [module convertPoint:pointInModule toView:button];
        if ([button pointInside:pointInButton withEvent:nil]) {
            return entries[i].action;
        }
    }

    return JCConnectivityActionNone;
}

static void JCResetConflictingJadeGestures(UIView *module, UIGestureRecognizer *ourRecognizer) {
    UIView *view = module;
    NSUInteger depth = 0;

    while (view && depth++ < 14) {
        for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
            if (gesture == ourRecognizer) continue;

            if ([gesture isKindOfClass:[UIPanGestureRecognizer class]] ||
                [gesture isKindOfClass:[UILongPressGestureRecognizer class]]) {
                BOOL wasEnabled = gesture.enabled;
                gesture.enabled = NO;
                gesture.enabled = wasEnabled;
            }
        }
        view = view.superview;
    }
}

static void JCMakeJadeGesturesWaitForLongPress(UIView *module, UILongPressGestureRecognizer *longPress) {
    UIView *view = module;
    NSUInteger depth = 0;

    while (view && depth++ < 14) {
        for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
            if (gesture == longPress) continue;

            if ([gesture isKindOfClass:[UIPanGestureRecognizer class]] ||
                [gesture isKindOfClass:[UILongPressGestureRecognizer class]]) {
                [gesture requireGestureRecognizerToFail:longPress];
            }
        }
        view = view.superview;
    }
}

#pragma mark - Stock Control Center presentation

static id JCFindStockButtonController(JCConnectivityAction action) {
    id controller = gStockConnectivityController;
    if (!controller) return nil;

    NSArray<NSString *> *selectors = nil;
    NSArray<NSString *> *ivars = nil;

    switch (action) {
        case JCConnectivityActionWiFi:
            selectors = @[@"wifiButton", @"wifiButtonViewController", @"expandedWifiButtonViewController", @"wifiModuleViewController"];
            ivars = @[@"_wifiButton", @"_wifiButtonViewController", @"_expandedWifiButtonViewController", @"_wifiModuleViewController"];
            break;

        case JCConnectivityActionBluetooth:
            selectors = @[@"bluetoothButton", @"bluetoothButtonViewController", @"expandedBluetoothButtonViewController", @"bluetoothModuleViewController"];
            ivars = @[@"_bluetoothButton", @"_bluetoothButtonViewController", @"_expandedBluetoothButtonViewController", @"_bluetoothModuleViewController"];
            break;

        case JCConnectivityActionAirDrop:
            selectors = @[@"airDropButton", @"airDropButtonViewController", @"expandedAirDropButtonViewController", @"airDropModuleViewController"];
            ivars = @[@"_airDropButton", @"_airDropButtonViewController", @"_expandedAirDropButtonViewController", @"_airDropModuleViewController"];
            break;

        default:
            return nil;
    }

    for (NSString *name in selectors) {
        id value = JCObjectForSelector(controller, name);
        if (value) return value;
    }

    for (NSString *name in ivars) {
        id value = JCObjectIvar(controller, name.UTF8String);
        if (value) return value;
    }

    return nil;
}

static BOOL JCPresentStockDetail(JCConnectivityAction action) {
    id buttonController = JCFindStockButtonController(action);
    if (!buttonController) return NO;

    // Older connectivity button controllers create this manager when their parent
    // switches to expanded mode. If needed, force that transition on the child.
    id manager = JCObjectIvar(buttonController, "_clickPresentationInteractionManager");
    if (!manager) {
        SEL transition = NSSelectorFromString(@"containerWillTransitionToExpandedContentMode:");
        if ([buttonController respondsToSelector:transition]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(buttonController, transition, YES);
        }
        manager = JCObjectIvar(buttonController, "_clickPresentationInteractionManager");
    }

    if (!manager) return NO;

    id interaction = JCObjectIvar(manager, "_clickPresentationInteraction");
    SEL presentSelector = NSSelectorFromString(@"present");
    if (interaction && [interaction respondsToSelector:presentSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(interaction, presentSelector);
        return YES;
    }

    return NO;
}

static void JCTryPresentPendingDetail(NSUInteger attempt) {
    JCConnectivityAction action = gPendingAction;
    if (action == JCConnectivityActionNone) return;

    id stockController = gStockConnectivityController;
    UIView *stockView = nil;
    if (stockController && [stockController respondsToSelector:@selector(view)]) {
        stockView = ((UIView *(*)(id, SEL))objc_msgSend)(stockController, @selector(view));
    }

    if (stockView.window && JCPresentStockDetail(action)) {
        gPendingAction = JCConnectivityActionNone;
        return;
    }

    if (attempt < 50) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            JCTryPresentPendingDetail(attempt + 1);
        });
    } else {
        // The real expanded connectivity module is still useful if a particular
        // iOS build changes the private second-level controller layout.
        gPendingAction = JCConnectivityActionNone;
    }
}

static void JCOpenStockConnectivity(UIView *module, JCConnectivityAction action) {
    UIViewController *card = JCFindJadeCardController(module);
    SEL expandSelector = NSSelectorFromString(@"expandModuleWithIdentifier:");

    if (!card || ![card respondsToSelector:expandSelector]) {
        NSLog(@"[JadeCompanion] JadeCardViewController / expandModuleWithIdentifier: not available");
        return;
    }

    if (action == JCConnectivityActionWiFi ||
        action == JCConnectivityActionBluetooth ||
        action == JCConnectivityActionAirDrop) {
        gPendingAction = action;
    } else {
        gPendingAction = JCConnectivityActionNone;
    }

    ((void (*)(id, SEL, id))objc_msgSend)(card,
                                          expandSelector,
                                          @"com.apple.control-center.ConnectivityModule");

    if (gPendingAction != JCConnectivityActionNone) {
        JCTryPresentPendingDetail(0);
    }
}

#pragma mark - Long press recognizer

@interface JCModuleGestureHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleConnectivityLongPress:(UILongPressGestureRecognizer *)recognizer;
@end

@implementation JCModuleGestureHandler

+ (instancetype)shared {
    static JCModuleGestureHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handler = [JCModuleGestureHandler new];
    });
    return handler;
}

- (void)handleConnectivityLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;

    UIView *module = recognizer.view;
    if (!module) return;

    CGPoint point = [recognizer locationInView:module];
    JCConnectivityAction action = JCActionAtLocation(module, point);
    if (action == JCConnectivityActionNone) return;

    // Cancel Jade's pre-existing stuck gesture state. This is only done once a
    // stationary hold has actually won; normal swipes are left alone.
    JCResetConflictingJadeGestures(module, recognizer);

    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];

    JCOpenStockConnectivity(module, action);
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    UIView *module = gestureRecognizer.view;
    if (!module) return NO;

    CGPoint point = [gestureRecognizer locationInView:module];
    return JCActionAtLocation(module, point) != JCConnectivityActionNone;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

@end

static void JCConfigureConnectivityModule(UIView *module) {
    if (!module) return;

    UILongPressGestureRecognizer *longPress =
        objc_getAssociatedObject(module, kJCModuleLongPressKey);

    if (!longPress) {
        longPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:[JCModuleGestureHandler shared]
                    action:@selector(handleConnectivityLongPress:)];

        longPress.minimumPressDuration = 0.38;
        longPress.allowableMovement = 12.0;
        longPress.cancelsTouchesInView = YES;
        longPress.delaysTouchesBegan = NO;
        longPress.delegate = [JCModuleGestureHandler shared];

        module.userInteractionEnabled = YES;
        [module addGestureRecognizer:longPress];

        objc_setAssociatedObject(module,
                                 kJCModuleLongPressKey,
                                 longPress,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    JCMakeJadeGesturesWaitForLongPress(module, longPress);
}

static void JCConfigureCard(id card) {
    if (![card isKindOfClass:[UIViewController class]]) return;

    gCurrentJadeCard = card;

    UIView *rootView = ((UIViewController *)card).view;
    if (!rootView) return;

    NSMutableArray<UIView *> *modules = [NSMutableArray array];
    JCCollectConnectivityModules(rootView, modules);

    for (UIView *module in modules) {
        JCConfigureConnectivityModule(module);
    }
}

#pragma mark - Hooks

static void JCHookedCardViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigCardViewWillAppear) {
        gOrigCardViewWillAppear(self, _cmd, animated);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        JCConfigureCard(self);
    });
}

static void JCHookedCardViewDidLayoutSubviews(id self, SEL _cmd) {
    if (gOrigCardViewDidLayoutSubviews) {
        gOrigCardViewDidLayoutSubviews(self, _cmd);
    }
    JCConfigureCard(self);
}

static void JCHookedModuleDidMoveToWindow(id self, SEL _cmd) {
    if (gOrigModuleDidMoveToWindow) {
        gOrigModuleDidMoveToWindow(self, _cmd);
    }

    if ([self isKindOfClass:[UIView class]] && ((UIView *)self).window) {
        JCConfigureConnectivityModule((UIView *)self);
    }
}

static void JCHookedModuleLayoutSubviews(id self, SEL _cmd) {
    if (gOrigModuleLayoutSubviews) {
        gOrigModuleLayoutSubviews(self, _cmd);
    }

    if ([self isKindOfClass:[UIView class]]) {
        JCConfigureConnectivityModule((UIView *)self);
    }
}

static void JCHookedStockWillTransition(id self, SEL _cmd, BOOL expanded) {
    if (gOrigStockWillTransition) {
        gOrigStockWillTransition(self, _cmd, expanded);
    }

    if (expanded) {
        gStockConnectivityController = self;

        if (gPendingAction != JCConnectivityActionNone) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                JCTryPresentPendingDetail(0);
            });
        }
    } else if (gStockConnectivityController == self) {
        gStockConnectivityController = nil;
    }
}

static void JCTryInstallHooks(NSUInteger attempt) {
    JCLoadConnectivityBundle();

    if (!gJadeHooksInstalled) {
        Class cardClass = objc_getClass("JadeCardViewController");
        Class moduleClass = objc_getClass("JadeConnectivityModule");

        Method cardWillAppear = cardClass ? class_getInstanceMethod(cardClass, @selector(viewWillAppear:)) : NULL;
        Method cardDidLayout = cardClass ? class_getInstanceMethod(cardClass, @selector(viewDidLayoutSubviews)) : NULL;
        Method moduleDidMove = moduleClass ? class_getInstanceMethod(moduleClass, @selector(didMoveToWindow)) : NULL;
        Method moduleLayout = moduleClass ? class_getInstanceMethod(moduleClass, @selector(layoutSubviews)) : NULL;

        if (cardClass && moduleClass && cardWillAppear && cardDidLayout && moduleDidMove && moduleLayout) {
            MSHookMessageEx(cardClass,
                            @selector(viewWillAppear:),
                            (IMP)JCHookedCardViewWillAppear,
                            (IMP *)&gOrigCardViewWillAppear);

            MSHookMessageEx(cardClass,
                            @selector(viewDidLayoutSubviews),
                            (IMP)JCHookedCardViewDidLayoutSubviews,
                            (IMP *)&gOrigCardViewDidLayoutSubviews);

            MSHookMessageEx(moduleClass,
                            @selector(didMoveToWindow),
                            (IMP)JCHookedModuleDidMoveToWindow,
                            (IMP *)&gOrigModuleDidMoveToWindow);

            MSHookMessageEx(moduleClass,
                            @selector(layoutSubviews),
                            (IMP)JCHookedModuleLayoutSubviews,
                            (IMP *)&gOrigModuleLayoutSubviews);

            gJadeHooksInstalled = YES;
            NSLog(@"[JadeCompanion] Jade 1.0.5 card/module hooks installed");
        }
    }

    if (!gStockHookInstalled) {
        Class stockClass = objc_getClass("CCUIConnectivityModuleViewController");
        SEL transitionSelector = NSSelectorFromString(@"willTransitionToExpandedContentMode:");

        if (stockClass && class_getInstanceMethod(stockClass, transitionSelector)) {
            MSHookMessageEx(stockClass,
                            transitionSelector,
                            (IMP)JCHookedStockWillTransition,
                            (IMP *)&gOrigStockWillTransition);

            gStockHookInstalled = YES;
            NSLog(@"[JadeCompanion] Stock connectivity hook installed");
        }
    }

    if ((!gJadeHooksInstalled || !gStockHookInstalled) && attempt < 80) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
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
