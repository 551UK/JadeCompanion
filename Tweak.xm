#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>

typedef NS_ENUM(NSInteger, JCConnectivityAction) {
    JCConnectivityActionNone = 0,
    JCConnectivityActionWiFi,
    JCConnectivityActionBluetooth,
    JCConnectivityActionAirplane,
    JCConnectivityActionCellular,
    JCConnectivityActionAirDrop,
};

static void (*gOrigFullWidthHandleLongPress)(id, SEL, UILongPressGestureRecognizer *) = NULL;
static void (*gOrigStockWillTransition)(id, SEL, BOOL) = NULL;

static __weak id gStockConnectivityController = nil;
static JCConnectivityAction gPendingAction = JCConnectivityActionNone;
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

static id JCJadeButton(id module, NSString *name) {
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
        dlopen("/System/Library/PrivateFrameworks/ControlCenterUIKit.framework/ControlCenterUIKit",
               RTLD_LAZY | RTLD_GLOBAL);

        NSBundle *bundle =
            [NSBundle bundleWithPath:@"/System/Library/ControlCenter/Bundles/ConnectivityModule.bundle"];
        if (bundle && !bundle.loaded) {
            [bundle load];
        }
    });
}

#pragma mark - Jade discovery

static JCConnectivityAction JCActionAtLocation(id module, CGPoint point) {
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

    UIView *moduleView = [module isKindOfClass:[UIView class]] ? (UIView *)module : nil;
    if (!moduleView) return JCConnectivityActionNone;

    for (NSUInteger i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        UIView *button = JCJadeButton(module, entries[i].name);
        if (![button isKindOfClass:[UIView class]] || button.hidden || button.alpha < 0.01) continue;

        CGPoint p = [moduleView convertPoint:point toView:button];
        if ([button pointInside:p withEvent:nil]) {
            return entries[i].action;
        }
    }

    return JCConnectivityActionNone;
}

static UIViewController *JCFindCardInControllerTree(UIViewController *controller, UIView *module) {
    if (!controller) return nil;

    Class cardClass = objc_getClass("JadeCardViewController");
    if (cardClass && [controller isKindOfClass:cardClass]) {
        id connectivity = JCObjectIvar(controller, "_connectivityModule");
        if (!connectivity) connectivity = JCObjectIvar(controller, "connectivityModule");
        if (!connectivity || connectivity == module) {
            return controller;
        }
    }

    UIViewController *presented = controller.presentedViewController;
    UIViewController *match = JCFindCardInControllerTree(presented, module);
    if (match) return match;

    for (UIViewController *child in controller.childViewControllers) {
        match = JCFindCardInControllerTree(child, module);
        if (match) return match;
    }

    return nil;
}

static UIViewController *JCFindJadeCard(UIView *module) {
    Class cardClass = objc_getClass("JadeCardViewController");

    UIResponder *responder = module;
    while (responder) {
        if (cardClass && [responder isKindOfClass:cardClass]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }

    UIWindow *window = module.window;
    if (window.rootViewController) {
        UIViewController *match = JCFindCardInControllerTree(window.rootViewController, module);
        if (match) return match;
    }

    for (UIWindow *candidate in [UIApplication sharedApplication].windows) {
        UIViewController *match = JCFindCardInControllerTree(candidate.rootViewController, module);
        if (match) return match;
    }

    return nil;
}

#pragma mark - Test feedback

static NSString *JCActionName(JCConnectivityAction action) {
    switch (action) {
        case JCConnectivityActionWiFi: return @"Wi-Fi";
        case JCConnectivityActionBluetooth: return @"Bluetooth";
        case JCConnectivityActionAirplane: return @"Airplane";
        case JCConnectivityActionCellular: return @"Cellular";
        case JCConnectivityActionAirDrop: return @"AirDrop";
        default: return @"Unknown";
    }
}

static void JCShowFailureToast(UIView *module, JCConnectivityAction action) {
    UIWindow *window = module.window;
    if (!window) return;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = [NSString stringWithFormat:@"JadeCompanion: %@ hold detected — stock view did not open",
                  JCActionName(action)];
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    label.numberOfLines = 2;
    label.layer.cornerRadius = 12.0;
    label.clipsToBounds = YES;

    CGFloat width = MIN(CGRectGetWidth(window.bounds) - 32.0, 390.0);
    label.frame = CGRectMake((CGRectGetWidth(window.bounds) - width) / 2.0,
                             70.0,
                             width,
                             54.0);
    label.alpha = 0.0;
    [window addSubview:label];

    [UIView animateWithDuration:0.16 animations:^{
        label.alpha = 1.0;
    } completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.2
                              delay:1.4
                            options:0
                         animations:^{
            label.alpha = 0.0;
        } completion:^(__unused BOOL finished2) {
            [label removeFromSuperview];
        }];
    }];
}

#pragma mark - Stock detail discovery

static BOOL JCClassNameMatchesAction(id object, JCConnectivityAction action) {
    if (!object) return NO;
    NSString *name = NSStringFromClass([object class]).lowercaseString;

    switch (action) {
        case JCConnectivityActionWiFi:
            return [name containsString:@"wifi"];
        case JCConnectivityActionBluetooth:
            return [name containsString:@"bluetooth"];
        case JCConnectivityActionAirDrop:
            return [name containsString:@"airdrop"];
        default:
            return NO;
    }
}

static id JCFindMatchingObjectInIvars(id object, JCConnectivityAction action, NSUInteger depth) {
    if (!object || depth > 2) return nil;
    if (JCClassNameMatchesAction(object, action)) return object;

    if ([object isKindOfClass:[UIViewController class]]) {
        for (UIViewController *child in [(UIViewController *)object childViewControllers]) {
            id found = JCFindMatchingObjectInIvars(child, action, depth + 1);
            if (found) return found;
        }
    }

    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);

        for (unsigned int i = 0; i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;

            id value = object_getIvar(object, ivars[i]);
            if (!value || value == object) continue;

            if (JCClassNameMatchesAction(value, action)) {
                free(ivars);
                return value;
            }
        }

        free(ivars);
    }

    return nil;
}

static id JCStockButtonController(JCConnectivityAction action) {
    id controller = gStockConnectivityController;
    if (!controller) return nil;

    NSArray<NSString *> *knownNames = nil;
    switch (action) {
        case JCConnectivityActionWiFi:
            knownNames = @[@"wifiButton", @"wifiButtonViewController",
                           @"expandedWifiButtonViewController", @"wifiModuleViewController"];
            break;
        case JCConnectivityActionBluetooth:
            knownNames = @[@"bluetoothButton", @"bluetoothButtonViewController",
                           @"expandedBluetoothButtonViewController", @"bluetoothModuleViewController"];
            break;
        case JCConnectivityActionAirDrop:
            knownNames = @[@"airDropButton", @"airDropButtonViewController",
                           @"expandedAirDropButtonViewController", @"airDropModuleViewController"];
            break;
        default:
            return nil;
    }

    for (NSString *name in knownNames) {
        id value = JCObjectForSelector(controller, name);
        if (value) return value;

        value = JCObjectIvar(controller, name.UTF8String);
        if (value) return value;

        NSString *underscored = [@"_" stringByAppendingString:name];
        value = JCObjectIvar(controller, underscored.UTF8String);
        if (value) return value;
    }

    return JCFindMatchingObjectInIvars(controller, action, 0);
}

static BOOL JCPresentStockDetail(JCConnectivityAction action) {
    id buttonController = JCStockButtonController(action);
    if (!buttonController) return NO;

    id manager = JCObjectIvar(buttonController, "_clickPresentationInteractionManager");

    if (!manager) {
        SEL expandedSelector = NSSelectorFromString(@"containerWillTransitionToExpandedContentMode:");
        if ([buttonController respondsToSelector:expandedSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(buttonController, expandedSelector, YES);
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

static void JCTryPendingDetail(NSUInteger attempt) {
    JCConnectivityAction action = gPendingAction;
    if (action == JCConnectivityActionNone) return;

    id stock = gStockConnectivityController;
    UIView *view = nil;
    if (stock && [stock respondsToSelector:@selector(view)]) {
        view = ((UIView *(*)(id, SEL))objc_msgSend)(stock, @selector(view));
    }

    if (view.window && JCPresentStockDetail(action)) {
        gPendingAction = JCConnectivityActionNone;
        return;
    }

    if (attempt < 45) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            JCTryPendingDetail(attempt + 1);
        });
    } else {
        gPendingAction = JCConnectivityActionNone;
    }
}

static BOOL JCOpenStockConnectivity(UIView *module, JCConnectivityAction action) {
    UIViewController *card = JCFindJadeCard(module);
    SEL expand = NSSelectorFromString(@"expandModuleWithIdentifier:");

    if (!card || ![card respondsToSelector:expand]) {
        return NO;
    }

    gPendingAction = (action == JCConnectivityActionWiFi ||
                      action == JCConnectivityActionBluetooth ||
                      action == JCConnectivityActionAirDrop)
        ? action
        : JCConnectivityActionNone;

    ((void (*)(id, SEL, id))objc_msgSend)(card,
                                          expand,
                                          @"com.apple.control-center.ConnectivityModule");

    if (gPendingAction != JCConnectivityActionNone) {
        JCTryPendingDetail(0);
    }

    return YES;
}

#pragma mark - Exact Jade long-press hook

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

    // Do NOT call Jade's original handler for the connectivity module. Jade 1.0.5's
    // own inherited long-press handler is what leaves its presentation/blur gesture
    // state wedged after a hold. We reuse Jade's already-installed recognizer instead.
    if (recognizer.state != UIGestureRecognizerStateBegan) return;

    UIView *module = [self isKindOfClass:[UIView class]] ? (UIView *)self : nil;
    if (!module) return;

    CGPoint point = [recognizer locationInView:module];
    JCConnectivityAction action = JCActionAtLocation(self, point);
    if (action == JCConnectivityActionNone) return;

    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];

    BOOL requested = JCOpenStockConnectivity(module, action);

    // v0.5 test diagnostic: only show this if the stock connectivity view clearly
    // failed to appear. This is deliberately visual because Jade itself already
    // produces haptics, so haptic feedback cannot prove that JadeCompanion ran.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id stock = gStockConnectivityController;
        UIView *stockView = nil;
        if (stock && [stock respondsToSelector:@selector(view)]) {
            stockView = ((UIView *(*)(id, SEL))objc_msgSend)(stock, @selector(view));
        }

        if (!requested || !stockView.window) {
            JCShowFailureToast(module, action);
        }
    });
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
                JCTryPendingDetail(0);
            });
        }
    } else if (gStockConnectivityController == self) {
        gStockConnectivityController = nil;
    }
}

static void JCTryInstallHooks(NSUInteger attempt) {
    JCLoadConnectivityBundle();

    Class fullWidthClass = objc_getClass("JadeFullWidthModule");
    Class connectivityClass = objc_getClass("JadeConnectivityModule");
    Class stockClass = objc_getClass("CCUIConnectivityModuleViewController");

    if (!gHooksInstalled && fullWidthClass && connectivityClass) {
        SEL longPressSelector = NSSelectorFromString(@"handleLongPress:");
        Method longPressMethod = class_getInstanceMethod(fullWidthClass, longPressSelector);

        if (longPressMethod) {
            MSHookMessageEx(fullWidthClass,
                            longPressSelector,
                            (IMP)JCHookedFullWidthHandleLongPress,
                            (IMP *)&gOrigFullWidthHandleLongPress);

            gHooksInstalled = YES;
        }
    }

    if (!gOrigStockWillTransition && stockClass) {
        SEL transition = NSSelectorFromString(@"willTransitionToExpandedContentMode:");
        if (class_getInstanceMethod(stockClass, transition)) {
            MSHookMessageEx(stockClass,
                            transition,
                            (IMP)JCHookedStockWillTransition,
                            (IMP *)&gOrigStockWillTransition);
        }
    }

    if ((!gHooksInstalled || !gOrigStockWillTransition) && attempt < 80) {
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
