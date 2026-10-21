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
static char gJCConsumedLongPressKey;
static void (*gOrigControlSendAction)(UIControl *, SEL, SEL, id, UIEvent *) = NULL;

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

// Scope the fallback guard to Jade's actual connectivity controls. All other
// SpringBoard controls retain their original action handling.
static BOOL JCIsJadeConnectivityControl(UIControl *control, UIView **moduleOut) {
    Class connectivityClass = objc_getClass("JadeConnectivityModule");
    if (!connectivityClass || !control) return NO;

    for (UIView *ancestor = control; ancestor; ancestor = ancestor.superview) {
        if (![ancestor isKindOfClass:connectivityClass]) continue;

        NSArray<NSString *> *buttonNames = @[
            @"wifiButton", @"bluetoothButton", @"airplaneModeButton",
            @"cellularButton", @"airDropButton"
        ];

        for (NSString *name in buttonNames) {
            id candidate = JCJadeButton(ancestor, name);
            if (![candidate isKindOfClass:[UIView class]]) continue;
            UIView *button = (UIView *)candidate;

            if (button == control || [control isDescendantOfView:button]) {
                if (moduleOut) *moduleOut = ancestor;
                return YES;
            }
        }
        return NO;
    }
    return NO;
}

static void JCHookedControlSendAction(UIControl *control, SEL _cmd,
                                     SEL action, id target, UIEvent *event) {
    UIView *module = nil;
    if (JCIsJadeConnectivityControl(control, &module) &&
        [objc_getAssociatedObject(module, &gJCConsumedLongPressKey) boolValue]) {
        // Jade must not dispatch a regular toggle action for a recognized hold.
        return;
    }

    if (gOrigControlSendAction) {
        gOrigControlSendAction(control, _cmd, action, target, event);
    }
}

static void JCLoadControlCenterFrameworks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/ControlCenterUIKit.framework/ControlCenterUIKit",
               RTLD_LAZY | RTLD_GLOBAL);
        dlopen("/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI",
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
        case JCConnectivityActionAirplane:
            names = @[@"airplaneButtonViewController",
                      @"expandedAirplaneButtonViewController"];
            needle = @"airplane";
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

#pragma mark - Native Control Center platter

typedef struct {
    NSUInteger width;
    NSUInteger height;
} JCModuleLayoutSize;

@class JCNativeConnectivitySession;
static __strong JCNativeConnectivitySession *gNativeConnectivitySession = nil;

static UIViewController *JCOwningViewController(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

@interface JCNativeConnectivitySession : NSObject
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, weak) UIViewController *parentViewController;
@property (nonatomic, strong) UIViewController *containerViewController;
@property (nonatomic, strong) UIView *moduleContainerView;
@property (nonatomic, strong) id connectivityModule;
@property (nonatomic, strong) id contentModuleContext;
@property (nonatomic, strong) id presentationContext;
@property (nonatomic, strong) NSArray<UIView *> *jadeViewsToHide;
@property (nonatomic, strong) NSArray<NSNumber *> *jadeViewsOriginalHidden;
@property (nonatomic, assign) BOOL jadeViewsHidden;
- (BOOL)installForSourceView:(UIView *)sourceView;
- (void)expandWhenReady:(NSUInteger)attempt;
- (void)hideJadeBehindNativePlatter;
- (void)restoreJadeBehindNativePlatter;
- (void)cleanup;
@end

@implementation JCNativeConnectivitySession

- (BOOL)installForSourceView:(UIView *)sourceView {
    UIViewController *parent = JCOwningViewController(sourceView);
    if (!parent || !parent.view || !sourceView.window) return NO;

    Class contextClass = objc_getClass("CCUIContentModuleContext");
    Class moduleClass = objc_getClass("CCUIConnectivityModule");
    Class presentationContextClass = objc_getClass("CCUIContentModulePresentationContext");
    Class containerClass = objc_getClass("CCUIContentModuleContainerViewController");
    Class wrapperClass = objc_getClass("CCUIContentModuleContainerView");

    if (!contextClass || !moduleClass || !presentationContextClass || !containerClass) {
        return NO;
    }

    id contextAlloc = ((id (*)(id, SEL))objc_msgSend)((id)contextClass, @selector(alloc));
    SEL contextInit = NSSelectorFromString(@"initWithModuleIdentifier:");
    id context = nil;
    if ([contextAlloc respondsToSelector:contextInit]) {
        context = ((id (*)(id, SEL, id))objc_msgSend)(contextAlloc,
                                                       contextInit,
                                                       JCConnectivityIdentifier);
    }
    if (!context) return NO;

    SEL setDelegate = NSSelectorFromString(@"setDelegate:");
    if ([context respondsToSelector:setDelegate]) {
        ((void (*)(id, SEL, id))objc_msgSend)(context, setDelegate, self);
    }

    id module = JCAllocInit(moduleClass);
    if (!module) return NO;

    SEL setModuleContext = NSSelectorFromString(@"setContentModuleContext:");
    if ([module respondsToSelector:setModuleContext]) {
        ((void (*)(id, SEL, id))objc_msgSend)(module, setModuleContext, context);
    }

    SEL defaultContext = NSSelectorFromString(@"defaultControlCenterPresentationContext");
    id presentationContext = nil;
    if ([presentationContextClass respondsToSelector:defaultContext]) {
        presentationContext =
            ((id (*)(id, SEL))objc_msgSend)((id)presentationContextClass, defaultContext);
    }
    if (!presentationContext) return NO;

    id containerAlloc =
        ((id (*)(id, SEL))objc_msgSend)((id)containerClass, @selector(alloc));
    id container = nil;

    SEL classicInit =
        NSSelectorFromString(@"initWithModuleIdentifier:contentModule:presentationContext:");
    SEL uniqueInit =
        NSSelectorFromString(@"initWithModuleIdentifier:uniqueIdentifier:contentModule:presentationContext:");

    if ([containerAlloc respondsToSelector:classicInit]) {
        container =
            ((id (*)(id, SEL, id, id, id))objc_msgSend)(containerAlloc,
                                                         classicInit,
                                                         JCConnectivityIdentifier,
                                                         module,
                                                         presentationContext);
    } else if ([containerAlloc respondsToSelector:uniqueInit]) {
        container =
            ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(containerAlloc,
                                                             uniqueInit,
                                                             JCConnectivityIdentifier,
                                                             [NSUUID UUID],
                                                             module,
                                                             presentationContext);
    }
    if (![container isKindOfClass:[UIViewController class]]) return NO;

    SEL setContainerDelegate = NSSelectorFromString(@"setDelegate:");
    if ([container respondsToSelector:setContainerDelegate]) {
        ((void (*)(id, SEL, id))objc_msgSend)(container, setContainerDelegate, self);
    }

    SEL setMaterialGroupName = NSSelectorFromString(@"setMaterialGroupName:");
    if ([container respondsToSelector:setMaterialGroupName]) {
        ((void (*)(id, SEL, id))objc_msgSend)(container,
                                              setMaterialGroupName,
                                              @"CCUIContentModuleContainerViewControllerGroupName");
    }

    // Snapshot Jade's current visual subviews before adding the invisible
    // stock Connectivity module. When Apple's native platter has finished
    // opening, these are temporarily hidden so Jade cannot show through it.
    // Their original hidden states are restored before the close animation.
    NSMutableArray<UIView *> *jadeViews = [NSMutableArray array];
    NSMutableArray<NSNumber *> *jadeHiddenStates = [NSMutableArray array];
    for (UIView *view in parent.view.subviews) {
        [jadeViews addObject:view];
        [jadeHiddenStates addObject:@(view.hidden)];
    }
    self.jadeViewsToHide = jadeViews;
    self.jadeViewsOriginalHidden = jadeHiddenStates;

    UIView *wrapper = nil;
    SEL wrapperInit = NSSelectorFromString(@"initWithModuleIdentifier:options:");
    if (wrapperClass &&
        [wrapperClass instancesRespondToSelector:wrapperInit]) {
        id wrapperAlloc =
            ((id (*)(id, SEL))objc_msgSend)((id)wrapperClass, @selector(alloc));
        wrapper =
            ((id (*)(id, SEL, id, NSUInteger))objc_msgSend)(wrapperAlloc,
                                                             wrapperInit,
                                                             JCConnectivityIdentifier,
                                                             3);
    }
    if (!wrapper) wrapper = [UIView new];

    CGRect frame = [sourceView.superview convertRect:sourceView.frame toView:parent.view];
    if (CGRectIsEmpty(frame) || CGRectIsNull(frame) || CGRectIsInfinite(frame)) {
        frame = [sourceView convertRect:sourceView.bounds toView:parent.view];
    }
    wrapper.frame = frame;
    wrapper.userInteractionEnabled = NO;
    wrapper.accessibilityElementsHidden = YES;

    [parent addChildViewController:container];

    UIView *contentHost = wrapper;
    SEL containerViewSelector = NSSelectorFromString(@"containerView");
    if ([wrapper respondsToSelector:containerViewSelector]) {
        id candidate =
            ((id (*)(id, SEL))objc_msgSend)(wrapper, containerViewSelector);
        if ([candidate isKindOfClass:[UIView class]]) {
            contentHost = candidate;
        }
    }

    UIView *containerView = ((UIViewController *)container).view;
    containerView.frame = contentHost.bounds;
    containerView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [contentHost addSubview:containerView];

    // Keep the real compact Control Center module in the same window, but behind
    // Jade. Apple's own click-presentation controller can then perform the exact
    // native Haptic Touch expansion without JadeCompanion drawing a fake platter.
    [parent.view insertSubview:wrapper atIndex:0];

    [container didMoveToParentViewController:parent];
    [wrapper setNeedsLayout];
    [wrapper layoutIfNeeded];
    [containerView setNeedsLayout];
    [containerView layoutIfNeeded];

    [container beginAppearanceTransition:YES animated:NO];
    [container endAppearanceTransition];

    SEL willBecomeActive = NSSelectorFromString(@"willBecomeActive");
    if ([container respondsToSelector:willBecomeActive]) {
        ((void (*)(id, SEL))objc_msgSend)(container, willBecomeActive);
    }

    self.sourceView = sourceView;
    self.parentViewController = parent;
    self.containerViewController = container;
    self.moduleContainerView = wrapper;
    self.connectivityModule = module;
    self.contentModuleContext = context;
    self.presentationContext = presentationContext;

    [self expandWhenReady:0];
    return YES;
}

- (void)expandWhenReady:(NSUInteger)attempt {
    UIViewController *container = self.containerViewController;
    if (!container) return;

    if (container.view.window) {
        SEL expand = NSSelectorFromString(@"expandModule");
        if ([container respondsToSelector:expand]) {
            ((void (*)(id, SEL))objc_msgSend)(container, expand);
            return;
        }
        [self cleanup];
        return;
    }

    if (attempt >= 20) {
        [self cleanup];
        return;
    }

    __weak JCNativeConnectivitySession *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.03 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf expandWhenReady:attempt + 1];
    });
}

- (CGRect)compactModeFrameForContentModuleContainerViewController:(id)controller {
    UIView *source = self.sourceView;
    if (!source) return self.moduleContainerView.frame;

    UIView *targetView = self.parentViewController.view;
    SEL definingSelector = NSSelectorFromString(@"bs_presentationContextDefiningViewController");
    if ([controller respondsToSelector:definingSelector]) {
        id defining = ((id (*)(id, SEL))objc_msgSend)(controller, definingSelector);
        if ([defining isKindOfClass:[UIViewController class]] &&
            ((UIViewController *)defining).view) {
            targetView = ((UIViewController *)defining).view;
        }
    }

    return [source convertRect:source.bounds toView:targetView];
}

- (BOOL)contentModuleContainerViewController:(id)controller
               canBeginInteractionWithModule:(id)module {
    return YES;
}

- (void)contentModuleContainerViewController:(id)controller
               didBeginInteractionWithModule:(id)module {
    SEL ignore = NSSelectorFromString(@"setIgnoreFrameUpdates:");
    if ([self.moduleContainerView respondsToSelector:ignore]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self.moduleContainerView, ignore, YES);
    }
}

- (void)contentModuleContainerViewController:(id)controller
              didFinishInteractionWithModule:(id)module {
    SEL ignore = NSSelectorFromString(@"setIgnoreFrameUpdates:");
    if ([self.moduleContainerView respondsToSelector:ignore]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self.moduleContainerView, ignore, NO);
    }
}

- (void)contentModuleContainerViewController:(id)controller
                  willOpenExpandedModule:(id)module {
    // Stock Control Center lets the private click-presentation interaction
    // own the expanded container's appearance transition.
}

- (void)contentModuleContainerViewController:(id)controller
                   didOpenExpandedModule:(id)module {
    // Make sure Apple's expanded Airplane controller is observing the real
    // radio state. This uses its own stock methods and adds no global hook.
    id content = JCObjectForSelector(self.containerViewController,
                                     @"contentViewController");
    if ([content isKindOfClass:[UIViewController class]]) {
        id airplane = JCFindChildController((UIViewController *)content,
                                            JCConnectivityActionAirplane);
        SEL observe = NSSelectorFromString(@"startObservingStateChangesIfNecessary");
        SEL update = NSSelectorFromString(@"_updateState");
        if (airplane && [airplane respondsToSelector:observe]) {
            ((void (*)(id, SEL))objc_msgSend)(airplane, observe);
        }
        if (airplane && [airplane respondsToSelector:update]) {
            ((void (*)(id, SEL))objc_msgSend)(airplane, update);
        }
    }

    // At this point Apple's own expansion animation has completed, so the
    // compact Jade card is no longer needed as a visual source. Hide only
    // the Jade views that existed before we inserted the stock module.
    [self hideJadeBehindNativePlatter];
}

- (void)contentModuleContainerViewController:(id)controller
                 willCloseExpandedModule:(id)module {
    // Restore Jade before Apple's stock collapse animation starts. Do not
    // manually drive the expanded container's appearance lifecycle here.
    [self restoreJadeBehindNativePlatter];
}

- (void)contentModuleContainerViewController:(id)controller
                  didCloseExpandedModule:(id)module {
    // Apple's click-presentation dismissal is not completely torn down when
    // this callback first arrives. Detaching our embedded module immediately
    // can crash SpringBoard. Keep everything alive briefly, then clean up after
    // UIKit has finished the close transition.
    __weak JCNativeConnectivitySession *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.75 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf cleanup];
    });
}

- (void)contentModuleContainerViewController:(id)controller
                   willPresentViewController:(UIViewController *)viewController {
    // Stock collection controller adjusts sibling modules here, not this
    // container. JadeCompanion has no sibling stock modules to update.
}

- (void)contentModuleContainerViewController:(id)controller
                   willDismissViewController:(UIViewController *)viewController {
    // UIKit/ControlCenterUI already owns this presentation transition.
}

- (void)contentModuleContainerViewControllerDismissPresentedContent:(id)controller {
    SEL dismiss = NSSelectorFromString(@"dismissPresentedContentAnimated:");
    if ([controller respondsToSelector:dismiss]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, dismiss, YES);
    }
}

- (void)contentModuleContext:(id)context enqueueStatusUpdate:(id)status {
}

- (void)requestExpandModuleForContentModuleContext:(id)context {
    [self expandWhenReady:0];
}

- (void)dismissExpandedViewForContentModuleContext:(id)context {
    SEL dismiss = NSSelectorFromString(@"dismissPresentedContentAnimated:");
    if ([self.containerViewController respondsToSelector:dismiss]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self.containerViewController,
                                                dismiss,
                                                YES);
    }
}

- (void)dismissControlCenterForContentModuleContext:(id)context {
    [self dismissExpandedViewForContentModuleContext:context];
}

- (void)requestModuleLayoutSizeUpdateForContentModuleContext:(id)context {
}

- (JCModuleLayoutSize)moduleLayoutSizeForContentModuleContext:(id)context
                                              forOrientation:(NSInteger)orientation {
    JCModuleLayoutSize size = {2, 2};
    return size;
}

- (void)hideJadeBehindNativePlatter {
    if (self.jadeViewsHidden) return;

    NSUInteger count = MIN(self.jadeViewsToHide.count,
                           self.jadeViewsOriginalHidden.count);
    for (NSUInteger index = 0; index < count; index++) {
        UIView *view = self.jadeViewsToHide[index];
        // Do not touch Apple's stock module if the hierarchy changed.
        if (view == self.moduleContainerView ||
            [view isDescendantOfView:self.moduleContainerView]) {
            continue;
        }
        view.hidden = YES;
    }
    self.jadeViewsHidden = YES;
}

- (void)restoreJadeBehindNativePlatter {
    if (!self.jadeViewsHidden) return;

    NSUInteger count = MIN(self.jadeViewsToHide.count,
                           self.jadeViewsOriginalHidden.count);
    for (NSUInteger index = 0; index < count; index++) {
        UIView *view = self.jadeViewsToHide[index];
        view.hidden = self.jadeViewsOriginalHidden[index].boolValue;
    }
    self.jadeViewsHidden = NO;
}

- (void)cleanup {
    // Covers cancellation/interruption paths where Control Center does not
    // deliver the normal willClose callback.
    [self restoreJadeBehindNativePlatter];

    UIViewController *container = self.containerViewController;
    if (container) {
        SEL willResignActive = NSSelectorFromString(@"willResignActive");
        if ([container respondsToSelector:willResignActive]) {
            ((void (*)(id, SEL))objc_msgSend)(container, willResignActive);
        }

        [container willMoveToParentViewController:nil];
        [container.view removeFromSuperview];
        [container removeFromParentViewController];

        SEL setDelegate = NSSelectorFromString(@"setDelegate:");
        if ([container respondsToSelector:setDelegate]) {
            ((void (*)(id, SEL, id))objc_msgSend)(container, setDelegate, nil);
        }
    }

    [self.moduleContainerView removeFromSuperview];

    self.containerViewController = nil;
    self.moduleContainerView = nil;
    self.connectivityModule = nil;
    self.contentModuleContext = nil;
    self.presentationContext = nil;
    self.jadeViewsToHide = nil;
    self.jadeViewsOriginalHidden = nil;

    if (gNativeConnectivitySession == self) {
        gNativeConnectivitySession = nil;
    }
}

@end

static BOOL JCPresentNativeConnectivityPlatter(UIView *sourceView) {
    if (!sourceView) return NO;

    if (gNativeConnectivitySession) {
        [gNativeConnectivitySession cleanup];
    }

    JCNativeConnectivitySession *session = [JCNativeConnectivitySession new];
    gNativeConnectivitySession = session;

    if (![session installForSourceView:sourceView]) {
        [session cleanup];
        return NO;
    }

    return YES;
}

#pragma mark - Overlay host

@interface JCConnectivityHostViewController : UIViewController
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIViewController *connectivityController;
@property (nonatomic, strong) UIViewController *detailController;
@property (nonatomic, strong) id contentModuleContext;
@property (nonatomic, strong) id connectivityModule;
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

static __weak JCConnectivityHostViewController *gCurrentHost = nil;

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
        NSLog(@"[JadeCompanion] Apple's Connectivity controller could not be created");
        return;
    }

    (void)connectivityController.view;

    JCVoidBool(connectivityController,
               @"willTransitionToExpandedContentMode:",
               YES);

    UIViewController *presenter = JCPresenterForView(sourceView);
    if (!presenter) {
        NSLog(@"[JadeCompanion] No presentation controller was available");
        return;
    }

    JCConnectivityHostViewController *host = [JCConnectivityHostViewController new];
    host.modalPresentationStyle = UIModalPresentationOverFullScreen;
    host.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    host.contentModuleContext = context;
    host.connectivityModule = module;
    host.connectivityController = connectivityController;

    gCurrentHost = host;

    [presenter presentViewController:host animated:YES completion:^{
        [host showController:connectivityController];

        // Wi-Fi, Cellular Data and Airplane Mode intentionally stay on
        // Apple's expanded six-button Connectivity panel. Only Bluetooth and
        // AirDrop drill into their existing native detail menus.
        if (action == JCConnectivityActionBluetooth ||
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
                    NSLog(@"[JadeCompanion] %@ detail unavailable; showing stock Connectivity instead",
                          JCActionName(action));
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

    // Ensure a recognized hold cancels the button touch, rather than delivering
    // a normal toggle as well. A quick tap never recognizes this gesture.
    recognizer.cancelsTouchesInView = YES;

    // Keep the guard through the release event. Clear on the next main-queue
    // turn so any release-generated button action is also discarded.
    if (recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed) {
        id module = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(module, &gJCConsumedLongPressKey,
                                     nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
        return;
    }

    // Jade's stock long-press path leaves an orphaned blur/expanded state
    // because its replacement Connectivity module cannot expand normally.
    if (recognizer.state != UIGestureRecognizerStateBegan) return;

    UIView *moduleView = [self isKindOfClass:[UIView class]] ? (UIView *)self : nil;
    if (!moduleView) return;

    CGPoint point = [recognizer locationInView:moduleView];
    JCConnectivityAction action = JCActionAtLocation(self, point);
    if (action == JCConnectivityActionNone) return;

    // Do not let a hold trigger the same button's usual on/off action.
    objc_setAssociatedObject(self, &gJCConsumedLongPressKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback prepare];
    [feedback impactOccurred];

    // Wi-Fi, Cellular Data, Airplane Mode and Bluetooth all use Apple's
    // own CCUIContentModuleContainerViewController expansion. This is the same
    // native Haptic Touch / 3D Touch presentation path used by Control Center.
    // AirDrop is intentionally left on the existing dedicated menu path.
    if (action == JCConnectivityActionAirDrop) {
        JCPresentStockConnectivity(moduleView, action);
    } else {
        if (!JCPresentNativeConnectivityPlatter(moduleView)) {
            NSLog(@"[JadeCompanion] Native Connectivity platter could not be started");
        }
    }
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

        // Defensive guard against Jade forwarding a UIControl action even
        // after the long press has been recognized. Does not alter normal taps.
        MSHookMessageEx(objc_getClass("UIControl"),
                        @selector(sendAction:to:forEvent:),
                        (IMP)JCHookedControlSendAction,
                        (IMP *)&gOrigControlSendAction);

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
