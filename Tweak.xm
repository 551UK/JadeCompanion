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

static const void *kJCLongPressKey = &kJCLongPressKey;
static const void *kJCActionKey = &kJCActionKey;

static void (*gOrigButtonDidMoveToSuperview)(id, SEL) = NULL;
static void (*gOrigButtonSetAction)(id, SEL, SEL) = NULL;
static void (*gOrigConnectivityWillTransition)(id, SEL, BOOL) = NULL;

static BOOL gButtonHooksInstalled = NO;
static BOOL gStockHookInstalled = NO;
static id gStockConnectivityController = nil;
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

static UIViewController *JCFindJadeCardController(UIView *view) {
    Class cardClass = objc_getClass("JadeCardViewController");
    if (!cardClass || !view) return nil;

    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:cardClass]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }

    return nil;
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
                NSLog(@"[JadeCompanion] Failed to load ConnectivityModule.bundle: %@", error);
            }
        }
    });
}

#pragma mark - Action mapping

static JCConnectivityAction JCActionForSelector(SEL action) {
    if (!action) return JCConnectivityActionNone;

    NSString *name = NSStringFromSelector(action);
    if ([name isEqualToString:@"onWiFiTap:"]) return JCConnectivityActionWiFi;
    if ([name isEqualToString:@"onBluetoothTap:"]) return JCConnectivityActionBluetooth;
    if ([name isEqualToString:@"onAirplaneModeTap:"]) return JCConnectivityActionAirplane;
    if ([name isEqualToString:@"onCellularTap:"]) return JCConnectivityActionCellular;
    if ([name isEqualToString:@"onAirDropTap:"]) return JCConnectivityActionAirDrop;
    return JCConnectivityActionNone;
}

static SEL JCButtonAction(id button) {
    SEL getter = NSSelectorFromString(@"action");
    if (!button || ![button respondsToSelector:getter]) return NULL;
    return ((SEL (*)(id, SEL))objc_msgSend)(button, getter);
}

#pragma mark - Stock connectivity detail presentation

static id JCStockButtonControllerForAction(JCConnectivityAction action) {
    id controller = gStockConnectivityController;
    if (!controller) return nil;

    NSArray<NSString *> *selectors = nil;
    NSArray<NSString *> *ivars = nil;

    switch (action) {
        case JCConnectivityActionWiFi:
            selectors = @[@"wifiButton", @"wifiButtonViewController"];
            ivars = @[@"_wifiButton", @"_wifiButtonViewController"];
            break;
        case JCConnectivityActionBluetooth:
            selectors = @[@"bluetoothButton", @"bluetoothButtonViewController"];
            ivars = @[@"_bluetoothButton", @"_bluetoothButtonViewController"];
            break;
        case JCConnectivityActionAirDrop:
            selectors = @[@"airDropButton", @"airDropButtonViewController"];
            ivars = @[@"_airDropButton", @"_airDropButtonViewController"];
            break;
        case JCConnectivityActionCellular:
            selectors = @[@"cellularDataButton", @"cellularDataButtonViewController"];
            ivars = @[@"_cellularDataButton", @"_cellularDataButtonViewController"];
            break;
        case JCConnectivityActionAirplane:
            selectors = @[@"airplaneButton", @"airplaneButtonViewController"];
            ivars = @[@"_airplaneButton", @"_airplaneButtonViewController"];
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

static BOOL JCPresentDetailForAction(JCConnectivityAction action) {
    if (action != JCConnectivityActionWiFi &&
        action != JCConnectivityActionBluetooth &&
        action != JCConnectivityActionAirDrop) {
        return NO;
    }

    id buttonController = JCStockButtonControllerForAction(action);
    if (!buttonController) {
        NSLog(@"[JadeCompanion] Stock button controller not found for action %ld", (long)action);
        return NO;
    }

    // Force the stock button into expanded mode if Jade has not already done it.
    id manager = JCObjectIvar(buttonController, "_clickPresentationInteractionManager");
    if (!manager) {
        SEL transition = NSSelectorFromString(@"containerWillTransitionToExpandedContentMode:");
        if ([buttonController respondsToSelector:transition]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(buttonController, transition, YES);
        }
        manager = JCObjectIvar(buttonController, "_clickPresentationInteractionManager");
    }

    if (!manager) {
        NSLog(@"[JadeCompanion] Detail interaction manager is missing for %@", NSStringFromClass([buttonController class]));
        return NO;
    }

    id interaction = JCObjectIvar(manager, "_clickPresentationInteraction");
    SEL presentSelector = NSSelectorFromString(@"present");
    if (interaction && [interaction respondsToSelector:presentSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(interaction, presentSelector);
        NSLog(@"[JadeCompanion] Presented stock detail for action %ld using _UIClickPresentationInteraction", (long)action);
        return YES;
    }

    // Fallback for builds where the manager exposes a direct presentation helper.
    SEL managerPresent = NSSelectorFromString(@"presentViewController");
    if ([manager respondsToSelector:managerPresent]) {
        ((void (*)(id, SEL))objc_msgSend)(manager, managerPresent);
        NSLog(@"[JadeCompanion] Presented stock detail for action %ld using manager fallback", (long)action);
        return YES;
    }

    NSLog(@"[JadeCompanion] No supported stock detail presentation path for action %ld", (long)action);
    return NO;
}

static void JCTryPresentPendingDetail(NSUInteger attempt) {
    if (gPendingAction == JCConnectivityActionNone) return;

    JCConnectivityAction action = gPendingAction;

    if (gStockConnectivityController) {
        UIView *view = nil;
        if ([gStockConnectivityController respondsToSelector:@selector(view)]) {
            view = ((UIView *(*)(id, SEL))objc_msgSend)(gStockConnectivityController, @selector(view));
        }

        if (view.window && JCPresentDetailForAction(action)) {
            gPendingAction = JCConnectivityActionNone;
            return;
        }
    }

    if (attempt < 30) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JCTryPresentPendingDetail(attempt + 1);
        });
    } else {
        NSLog(@"[JadeCompanion] Timed out waiting for expanded stock connectivity module");
        gPendingAction = JCConnectivityActionNone;
    }
}

static void JCExpandStockConnectivityFromButton(UIView *button, JCConnectivityAction action) {
    UIViewController *card = JCFindJadeCardController(button);
    SEL expandSelector = NSSelectorFromString(@"expandModuleWithIdentifier:");

    if (!card || ![card respondsToSelector:expandSelector]) {
        NSLog(@"[JadeCompanion] Could not find JadeCardViewController from connectivity button");
        return;
    }

    // Airplane Mode and Cellular have no useful second-level browser on the iOS 16
    // connectivity tile, so their hold action stops at the real expanded stock module.
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

#pragma mark - Long press gesture

@interface JCGestureHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer;
@end

@implementation JCGestureHandler

+ (instancetype)shared {
    static JCGestureHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handler = [JCGestureHandler new];
    });
    return handler;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;

    JCConnectivityAction action = (JCConnectivityAction)[objc_getAssociatedObject(recognizer, kJCActionKey) integerValue];
    UIView *button = recognizer.view;
    if (!button || action == JCConnectivityActionNone) return;

    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];

    JCExpandStockConnectivityFromButton(button, action);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

@end

static void JCProtectLongPressFromAncestorPans(UIView *button, UILongPressGestureRecognizer *longPress) {
    UIView *ancestor = button.superview;
    NSUInteger depth = 0;

    while (ancestor && depth++ < 12) {
        for (UIGestureRecognizer *gesture in ancestor.gestureRecognizers) {
            if (gesture == longPress) continue;

            if ([gesture isKindOfClass:[UIPanGestureRecognizer class]] ||
                [gesture isKindOfClass:[UILongPressGestureRecognizer class]]) {
                // This fixes Jade's pre-existing "hold, then next swipe only blurs" state:
                // a real hold wins first; a normal swipe quickly makes our recognizer fail
                // due to movement and Jade's pan proceeds normally.
                [gesture requireGestureRecognizerToFail:longPress];
            }
        }
        ancestor = ancestor.superview;
    }
}

static void JCConfigureButton(id object) {
    if (![object isKindOfClass:[UIView class]]) return;

    UIView *button = (UIView *)object;
    JCConnectivityAction action = JCActionForSelector(JCButtonAction(object));

    UILongPressGestureRecognizer *existing = objc_getAssociatedObject(button, kJCLongPressKey);

    if (action == JCConnectivityActionNone) {
        if (existing) {
            [button removeGestureRecognizer:existing];
            objc_setAssociatedObject(button, kJCLongPressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    if (!existing) {
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:[JCGestureHandler shared]
                    action:@selector(handleLongPress:)];

        longPress.minimumPressDuration = 0.38;
        longPress.allowableMovement = 12.0;
        longPress.cancelsTouchesInView = YES;
        longPress.delaysTouchesBegan = NO;
        longPress.delegate = [JCGestureHandler shared];

        [button addGestureRecognizer:longPress];
        objc_setAssociatedObject(button, kJCLongPressKey, longPress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        existing = longPress;
    }

    objc_setAssociatedObject(existing, kJCActionKey, @(action), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    dispatch_async(dispatch_get_main_queue(), ^{
        JCProtectLongPressFromAncestorPans(button, existing);
    });
}

#pragma mark - Hooks

static void JCHookedButtonDidMoveToSuperview(id self, SEL _cmd) {
    if (gOrigButtonDidMoveToSuperview) {
        gOrigButtonDidMoveToSuperview(self, _cmd);
    }
    JCConfigureButton(self);
}

static void JCHookedButtonSetAction(id self, SEL _cmd, SEL action) {
    if (gOrigButtonSetAction) {
        gOrigButtonSetAction(self, _cmd, action);
    }
    JCConfigureButton(self);
}

static void JCHookedConnectivityWillTransition(id self, SEL _cmd, BOOL expanded) {
    if (gOrigConnectivityWillTransition) {
        gOrigConnectivityWillTransition(self, _cmd, expanded);
    }

    if (expanded) {
        gStockConnectivityController = self;
        if (gPendingAction != JCConnectivityActionNone) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                JCTryPresentPendingDetail(0);
            });
        }
    } else if (gStockConnectivityController == self) {
        gStockConnectivityController = nil;
    }
}

static void JCTryInstallHooks(NSUInteger attempt) {
    JCLoadConnectivityBundle();

    if (!gButtonHooksInstalled) {
        Class buttonClass = objc_getClass("JadeConnectivityButton");
        if (buttonClass) {
            MSHookMessageEx(buttonClass,
                            NSSelectorFromString(@"didMoveToSuperview"),
                            (IMP)JCHookedButtonDidMoveToSuperview,
                            (IMP *)&gOrigButtonDidMoveToSuperview);

            MSHookMessageEx(buttonClass,
                            NSSelectorFromString(@"setAction:"),
                            (IMP)JCHookedButtonSetAction,
                            (IMP *)&gOrigButtonSetAction);

            gButtonHooksInstalled = YES;
            NSLog(@"[JadeCompanion] JadeConnectivityButton hooks installed");
        }
    }

    if (!gStockHookInstalled) {
        Class stockClass = objc_getClass("CCUIConnectivityModuleViewController");
        SEL transition = NSSelectorFromString(@"willTransitionToExpandedContentMode:");

        if (stockClass && class_getInstanceMethod(stockClass, transition)) {
            MSHookMessageEx(stockClass,
                            transition,
                            (IMP)JCHookedConnectivityWillTransition,
                            (IMP *)&gOrigConnectivityWillTransition);
            gStockHookInstalled = YES;
            NSLog(@"[JadeCompanion] Stock connectivity transition hook installed");
        }
    }

    if ((!gButtonHooksInstalled || !gStockHookInstalled) && attempt < 40) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
