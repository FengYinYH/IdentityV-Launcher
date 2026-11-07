/* IDV native protocol candidate; keep ae1c independent and frozen.
 * Real WineConfinement handler start/stop; never patch its active BOOL.
 * Full-client confinement only:
 * OEM recenter/input processing stays intact; this is not a high-Hz fix.
 * Reuse the frozen known-hash foreground gate's validation/loader primitives.
 */
#define IDV_GATE_TEST 1
#include "foreground_warp_compat.m"
#include <math.h>
#include <strings.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stddef.h>
#include <mach-o/dyld.h>

static int camera_requested, background_requested, camera_ready, entry_blocked;
static Ivar hidden_ivar, dragging_ivar, capture_ivar, handler_ivar;
static ptrdiff_t hidden_offset, capture_offset, handler_offset;
static BOOL dragging_cached;
static IMP original_unhide, original_capture, original_start_clip, original_stop_clip, original_drag;
static SEL capture_selector, clipping_selector, parent_selector, native_get, native_set;
static SEL frame_selector, client_selector, convert_selector, flip_selector;
static id notification_observer;
static Class native_handler_class;
static Ivar native_owner_ivar;
static IMP original_front, original_retina;
static SEL front_selector, flip_rect_selector, update_windows_selector;
static int protocol_transition;
static id transition_controller, transition_owner;
static struct { id owner; CGRect screen, local; CGPoint target; } geometry;
static struct { id owner, capture, controller, handler, prior_handler; CGRect native_rect; int active; } lease;
static unsigned trace_count, last_context = ~0u;

static int rect_empty(CGRect r) { return r.size.width <= 0 || r.size.height <= 0; }
static int rect_equal(CGRect a, CGRect b)
{
    return a.origin.x == b.origin.x && a.origin.y == b.origin.y &&
           a.size.width == b.size.width && a.size.height == b.size.height;
}
static CGRect rect_get(id object, SEL selector)
{
    CGRect r;
    ((void (*)(CGRect *, id, SEL))objc_msgSend_stret)(&r, object, selector);
    return r;
}
static CGRect rect_convert(id object, SEL selector, CGRect argument)
{
    CGRect r;
    ((void (*)(CGRect *, id, SEL, CGRect))objc_msgSend_stret)(&r, object, selector, argument);
    return r;
}
static void set_rect(id object, CGRect rect)
{
    ((void (*)(id, SEL, CGRect))objc_msgSend)(object, native_set, rect);
}
static id object_get(id object, SEL selector) { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
static BOOL boolean_get(id object, SEL selector) { return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector); }
/* Known-hash, checked object-ivar layouts; all access is on Cocoa's main thread. */
static id raw_object(id object, ptrdiff_t offset) { return *(id *)((char *)object + offset); }
static BOOL hidden_request(id object) { return *(BOOL *)((char *)object + hidden_offset); }
static BOOL windows_clipping(id object)
{
    id handler = raw_object(object, handler_offset);
    if (handler && handler == lease.handler) return NO; /* adapter-owned, not a Windows request */
    return handler && boolean_get(handler, clipping_selector);
}
static void retain_object(id object) { if (object) object_get(object, sel_registerName("retain")); }
static void release_object(id object) { if (object) ((void (*)(id, SEL))objc_msgSend)(object, sel_registerName("release")); }

static void camera_trace(const char *reason, unsigned context, int force)
{
    if (!audit_enabled || trace_count >= 32 || (!force && context == last_context)) return;
    last_context = context; ++trace_count;
    char line[384];
    int known = !strcmp(reason, "predicate") || !strcmp(reason, "lease-enter") || !strncmp(reason, "native-", 7);
    int length = snprintf(line, sizeof(line), "IDV_NATIVE_CAMERA reason=%s contextKnown=%d active=%u wineKey=%u hiddenRequest=%u ownedCapture=%u capturePresent=%u captureAllowed=%u centerEvaluated=%u centerTarget=%u windowsClip=%u dragging=%u lease=%d budget=32\n",
                          reason, known, !!(context & 1), !!(context & 2), !!(context & 4), !!(context & 8),
                          !!(context & 256), !!(context & 512), !!(context & 128), !!(context & 16), !!(context & 32), !!(context & 64), lease.active);
    if (length > 0 && length < sizeof(line)) (void)write(STDERR_FILENO, line, length);
}

static void invalidate_geometry(void)
{
    id owner = geometry.owner;
    geometry.owner = nil;
    release_object(owner);
}
static void release_lease(const char *reason)
{
    if (!lease.active) return;
    id owner=lease.owner,capture=lease.capture,controller=lease.controller;
    id handler=lease.handler,prior=lease.prior_handler;
    CGRect ours=lease.native_rect;
    lease.active=0;lease.owner=lease.capture=lease.controller=lease.handler=lease.prior_handler=nil;
    BOOL owns_slot=raw_object(controller,handler_offset)==handler;
    protocol_transition=1;transition_controller=controller;transition_owner=nil;
    if (owns_slot)
    {
        if (rect_equal(rect_get(owner,native_get),ours))
        {
            BOOL stopped=((BOOL(*)(id,SEL))original_stop_clip)(controller,sel_registerName("stopClippingCursor"));
            /* The pinned native implementation normally cannot fail. Preserve
             * free mode even if a future failed stop left our exact rect live. */
            if (!stopped && rect_equal(rect_get(owner,native_get),ours)) set_rect(owner,(CGRect){{0,0},{0,0}});
        }
        /* Return the prior inactive slot's +1 ownership; no native BOOL writes.
         * If another writer changed native state, don't call its stop/clear. */
        *(id*)((char*)controller+handler_offset)=prior;
        release_object(handler); /* slot's +1 */
        ((void(*)(id,SEL))objc_msgSend)(controller,update_windows_selector);
    }
    else release_object(prior); /* the detached +1 cannot replace a foreign slot */
    protocol_transition=0;transition_controller=transition_owner=nil;
    release_object(handler); /* adapter's +1; foreign slot owners handle theirs */
    release_object(controller);release_object(capture);release_object(owner);
    camera_trace(reason,0,1);
}
static id protocol_front(id self, SEL command)
{
    if(protocol_transition && self==transition_controller && transition_owner) return transition_owner;
    return ((id(*)(id,SEL))original_front)(self,command);
}
static void protocol_retina(id self, SEL command, BOOL mode)
{
    release_lease("release-retina");invalidate_geometry();entry_blocked=0;
    protocol_transition=1;transition_controller=self;transition_owner=nil;
    ((void(*)(id,SEL,BOOL))original_retina)(self,command,mode);
    protocol_transition=0;transition_controller=transition_owner=nil;
    invalidate_geometry();
}
static id root_window(id window)
{
    for (unsigned i = 0; window && i < 16; ++i)
    {
        id parent = object_get(window, parent_selector);
        if (!parent) return window;
        window = parent;
    }
    return nil;
}
static BOOL capture_belongs_to_key(id capture, id key)
{
    if (!capture) return NO;
    if (capture == key) return YES;
    if (!((BOOL (*)(id, SEL, Class))objc_msgSend)(capture, kind_selector, wine_window_class)) return NO;
    id root = root_window(capture);
    return root && root == root_window(key);
}
static int refresh_geometry(id self, id owner)
{
    if (geometry.owner == owner) return !rect_empty(geometry.screen) && !rect_empty(geometry.local);
    invalidate_geometry();
    entry_blocked = 0;
    CGRect frame = rect_get(owner, frame_selector);
    CGRect screen = rect_convert(owner, client_selector, frame);
    CGRect local = rect_convert(owner, convert_selector, screen);
    if (rect_empty(screen) || rect_empty(local)) return 0;
    CGPoint center = {screen.origin.x + screen.size.width / 2, screen.origin.y + screen.size.height / 2};
    geometry.target = ((CGPoint (*)(id, SEL, CGPoint))objc_msgSend)(self, flip_selector, center);
    retain_object(owner); geometry.owner = owner; geometry.screen = screen; geometry.local = local;
    return 1;
}

static BOOL camera_warp(id self, SEL command, CGPoint position)
{
    if (protocol_transition) return eligible_warp(self,command,position);
    id app = application_slot ? *application_slot : nil;
    BOOL active = app && boolean_get(app, active_selector);
    id key = active ? object_get(app, key_selector) : nil;
    BOOL wine_key = key && ((BOOL (*)(id, SEL, Class))objc_msgSend)(key, kind_selector, wine_window_class);
    if (!active || !wine_key)
    {
        release_lease("release-focus"); entry_blocked = 0;
        camera_trace("ineligible-focus", active, 0);
        return NO;
    }
    BOOL hidden = hidden_request(self);
    id capture = raw_object(self, capture_offset);
    BOOL owned = capture_belongs_to_key(capture, key);
    /* SetCapture is button-message routing here, not camera ownership. The
     * real 737 session disproved requiring it: nil is neutral, foreign is not. */
    BOOL capture_allowed = !capture || owned;
    BOOL drag = dragging_cached;
    BOOL windows_clip = windows_clipping(self);
    BOOL center = NO;
    BOOL center_evaluated = hidden && refresh_geometry(self, key);
    if (center_evaluated)
        center = fabs(position.x - geometry.target.x) <= 1.0 && fabs(position.y - geometry.target.y) <= 1.0;
    unsigned context = 1 | 2 | (!!hidden << 2) | (!!owned << 3) | (!!center << 4) |
                       (!!windows_clip << 5) | (!!drag << 6) | (!!center_evaluated << 7) |
                       (!!capture << 8) | (!!capture_allowed << 9);
    BOOL qualified = hidden && capture_allowed && center && !windows_clip && !drag;
    if (!qualified)
    {
        release_lease("release-predicate"); entry_blocked = 0;
        if (center_evaluated && !center) invalidate_geometry();
    }
    else if (lease.active && lease.owner != key) release_lease("release-owner");
    camera_trace("predicate", context, 0);
    /* Always delegate eligible native positioning to OEM, including failures.
     * Acquiring after a successful original warp avoids claiming relocation. */
    BOOL result = original_warp(self, command, position);
    if (!result) { release_lease("release-warp-failure"); return result; }
    if (qualified && !entry_blocked && !lease.active &&
        boolean_get(app, active_selector) && object_get(app, key_selector) == key &&
        !windows_clipping(self))
    {
        if (!rect_empty(rect_get(key, native_get)))
        {
            entry_blocked = 1;
            camera_trace("native-already-owned", context, 1);
            return result;
        }
        if (((id(*)(id,SEL))original_front)(self,front_selector)!=key ||
            !boolean_get((id)native_handler_class,sel_registerName("isAvailable")))
        {
            entry_blocked=1;camera_trace("native-protocol-unavailable-or-owner",context,1);return result;
        }
        CGRect expected=geometry.local,screen=geometry.screen;
        ((void(*)(id,SEL,CGRect*))objc_msgSend)(self,flip_rect_selector,&screen);
        id prior=raw_object(self,handler_offset);
        if(prior && boolean_get(prior,clipping_selector)) return result;
        id handler=object_get((id)native_handler_class,sel_registerName("new"));
        if(!handler) {entry_blocked=1;return result;}
        retain_object(handler);retain_object(self);retain_object(key);retain_object(capture);
        /* Transfer the old slot's +1 to the lease; new's +1 goes to the slot. */
        lease.owner=key;lease.capture=capture;lease.controller=self;lease.handler=handler;
        lease.prior_handler=prior;lease.native_rect=expected;lease.active=1;
        *(id*)((char*)self+handler_offset)=handler;
        protocol_transition=1;transition_controller=self;transition_owner=key;
        BOOL started=((BOOL(*)(id,SEL,CGRect))original_start_clip)(self,sel_registerName("startClippingCursor:"),screen);
        protocol_transition=0;transition_controller=transition_owner=nil;
        long bound=*(long*)((char*)handler+ivar_getOffset(native_owner_ivar));
        long wanted=((long(*)(id,SEL))objc_msgSend)(key,sel_registerName("windowNumber"));
        CGRect readback=rect_get(key,native_get);
        BOOL stable_geometry=refresh_geometry(self,key);
        CGRect current_screen=geometry.screen;
        if(stable_geometry)((void(*)(id,SEL,CGRect*))objc_msgSend)(self,flip_rect_selector,&current_screen);
        stable_geometry=stable_geometry && rect_equal(geometry.local,expected) && rect_equal(current_screen,screen);
        if(started && stable_geometry && raw_object(self,handler_offset)==handler && boolean_get(handler,clipping_selector) &&
           bound==wanted && rect_equal(readback,expected) && boolean_get(app,active_selector) && object_get(app,key_selector)==key)
        {
            lease.native_rect=readback;camera_trace("lease-enter",context,1);
        }
        else
        {
            release_lease("release-protocol-start-failed");entry_blocked=1;
            camera_trace("native-protocol-start-rejected",context,1);
        }
    }
    return result;
}
static void camera_unhide(id self, SEL command)
{
    release_lease("release-unhide"); entry_blocked = 0;
    ((void (*)(id, SEL))original_unhide)(self, command);
}
static void camera_capture(id self, SEL command, id capture)
{
    if (capture != raw_object(self, capture_offset)) entry_blocked = 0;
    ((void (*)(id, SEL, id))original_capture)(self, command, capture);
    if (!lease.active) return;
    id app = application_slot ? *application_slot : nil;
    id key = app && boolean_get(app, active_selector) ? object_get(app, key_selector) : nil;
    if (key != lease.owner || !hidden_request(self) || dragging_cached || windows_clipping(self) ||
        (capture && !capture_belongs_to_key(capture, key)))
    {
        release_lease("release-capture-ineligible"); return;
    }
    /* nil/owned routing transitions keep a lease justified by the last center
     * warp. Unhide, non-center, foreign capture and focus still revoke it. */
    if (lease.capture != capture)
    {
        retain_object(capture); id previous = lease.capture; lease.capture = capture; release_object(previous);
    }
}
static void camera_drag(id self, SEL command, id window, BOOL dragging)
{
    ((void (*)(id, SEL, id, BOOL))original_drag)(self, command, window, dragging);
    id set = object_getIvar(self, dragging_ivar);
    dragging_cached = ((unsigned long (*)(id, SEL))objc_msgSend)(set, sel_registerName("count")) != 0;
    if (dragging_cached) release_lease("release-window-drag");
}
static BOOL camera_start_clip(id self, SEL command, CGRect rect)
{
    release_lease("release-windows-start"); entry_blocked = 1;
    return ((BOOL (*)(id, SEL, CGRect))original_start_clip)(self, command, rect);
}
static BOOL camera_stop_clip(id self, SEL command)
{
    release_lease("release-windows-stop"); entry_blocked = 1;
    return ((BOOL (*)(id, SEL))original_stop_clip)(self, command);
}
static void camera_notification(id self, SEL command, id notification)
{
    id object = object_get(notification, sel_registerName("object"));
    if (object == geometry.owner) { invalidate_geometry(); entry_blocked = 0; }
    if (application_slot && object == *application_slot) { invalidate_geometry(); entry_blocked = 0; }
    if (!protocol_transition && lease.active && (object == lease.owner || (application_slot && object == *application_slot)))
    {
        release_lease("release-focus-geometry-lifecycle"); entry_blocked = 0;
    }
}
static int type_matches(Method method, int index, const char *type)
{
    char *actual = method ? (index < 0 ? method_copyReturnType(method) : method_copyArgumentType(method, index)) : NULL;
    int result = actual && !strcmp(actual, type); free(actual); return result;
}
static int prepare_notifications(void)
{
    const char *names[] = {"NSWindowDidResignKeyNotification", "NSWindowWillCloseNotification", "NSWindowDidMoveNotification", "NSWindowDidResizeNotification", "NSWindowDidChangeScreenNotification", "NSApplicationDidResignActiveNotification", "NSApplicationWillTerminateNotification", "NSApplicationDidChangeScreenParametersNotification"};
    id *values[sizeof(names)/sizeof(names[0])];
    Class base = objc_getClass("NSObject"), center_class = objc_getClass("NSNotificationCenter");
    if (!base || !center_class) return 0;
    for (unsigned i = 0; i < sizeof(names)/sizeof(names[0]); ++i)
        if (!(values[i] = dlsym(RTLD_DEFAULT, names[i]))) return 0;
    Class observer_class = objc_allocateClassPair(base, "IDVNativeProtocolLeaseObserver", 0);
    SEL callback = sel_registerName("cameraStateChanged:");
    if (!observer_class || !class_addMethod(observer_class, callback, (IMP)camera_notification, "v@:@")) return 0;
    objc_registerClassPair(observer_class);
    notification_observer = object_get((id)observer_class, sel_registerName("new"));
    id center = object_get((id)center_class, sel_registerName("defaultCenter"));
    for (unsigned i = 0; i < sizeof(names)/sizeof(names[0]); ++i)
        ((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(center, sel_registerName("addObserver:selector:name:object:"), notification_observer, callback, *values[i], nil);
    return notification_observer && center;
}

/* Main-thread bootstrap only. No dlopen wrapper: retain the original loader's
 * caller image and transitive @rpath search semantics without emulation. */
static int startup_slot_is_safe(id *slot)
{
    return slot && (!*slot || !object_get(*slot, sel_registerName("keyWindow")));
}
static void install_background_on_main(void)
{
    if (!enabled || install_state || !pthread_main_np()) return;
    Class controller = objc_getClass("WineApplicationController");
    Class window = objc_getClass("WineWindow");
    if (!controller || !window) return;
    Method method = class_getInstanceMethod(controller, sel_registerName("setCursorPosition:"));
    Dl_info owner;
    IMP original = method ? method_getImplementation(method) : NULL;
    id *slot = (id *)dlsym(RTLD_DEFAULT, "NSApp");
    if (!signature_matches(method) || !original || !dladdr((const void *)original, &owner) ||
        !owner.dli_fname || !module_has_known_hash(owner.dli_fname))
    {
        install_state = 3; gate_audit("IDV_WARP_GATE skipped reason=baseline-identity-or-type\n"); return;
    }
    if (!startup_slot_is_safe(slot))
    {
        install_state = 3; gate_audit("IDV_WARP_GATE skipped reason=late-key-window\n"); return;
    }
    application_slot = slot; wine_window_class = window;
    active_selector = sel_registerName("isActive"); key_selector = sel_registerName("keyWindow");
    kind_selector = sel_registerName("isKindOfClass:");
    __atomic_store_n(&original_warp, (warp_imp)original, __ATOMIC_RELEASE);
    method_setImplementation(method, (IMP)eligible_warp); install_state = 2;
    gate_audit("IDV_WARP_GATE installed baseline=365fefb1 policy=foreground-only delegate=original mainThread=1\n");
}

static void install_camera(void)
{
    int is_game = getprogname() && !strcasecmp(getprogname(), "dwrg.exe");
    enabled = background_requested || (camera_requested && is_game);
    install_background_on_main();
    if (!camera_requested || !is_game || install_state != 2 || camera_ready) return;
    Class controller = objc_getClass("WineApplicationController");
    Method warp = class_getInstanceMethod(controller, sel_registerName("setCursorPosition:"));
    Method unhide = class_getInstanceMethod(controller, sel_registerName("unhideCursor"));
    Method capture = class_getInstanceMethod(controller, sel_registerName("setMouseCaptureWindow:"));
    Method start = class_getInstanceMethod(controller, sel_registerName("startClippingCursor:"));
    Method stop = class_getInstanceMethod(controller, sel_registerName("stopClippingCursor"));
    native_handler_class=objc_getClass("WineConfinementClipCursorHandler");
    native_owner_ivar=native_handler_class?class_getInstanceVariable(native_handler_class,"clippingWindowNumber"):NULL;
    front_selector=sel_registerName("frontWineWindow");flip_rect_selector=sel_registerName("flipRect:");update_windows_selector=sel_registerName("updateWindowsForCursorClipping");
    Method front=class_getInstanceMethod(controller,front_selector),retina=class_getInstanceMethod(controller,sel_registerName("setRetinaMode:"));
    Method drag = class_getInstanceMethod(controller, sel_registerName("window:isBeingDragged:"));
    hidden_ivar = class_getInstanceVariable(controller, "clientWantsCursorHidden");
    capture_ivar = class_getInstanceVariable(controller, "mouseCaptureWindow");
    handler_ivar = class_getInstanceVariable(controller, "clipCursorHandler");
    dragging_ivar = class_getInstanceVariable(controller, "windowsBeingDragged");
    capture_selector = sel_registerName("mouseCaptureWindow"); clipping_selector = sel_registerName("clippingCursor");
    parent_selector = sel_registerName("parentWindow"); native_get = sel_registerName("mouseConfinementRect"); native_set = sel_registerName("setMouseConfinementRect:");
    frame_selector = sel_registerName("frame"); client_selector = sel_registerName("contentRectForFrameRect:");
    convert_selector = sel_registerName("convertRectFromScreen:"); flip_selector = sel_registerName("flippedMouseLocation:");
    if (!native_handler_class || !native_owner_ivar || strcmp(ivar_getTypeEncoding(native_owner_ivar),@encode(long)) ||
        !type_matches(class_getClassMethod(native_handler_class,sel_registerName("isAvailable")),-1,@encode(BOOL)) ||
        !type_matches(class_getInstanceMethod(native_handler_class,sel_registerName("startClippingCursor:")),-1,@encode(BOOL)) ||
        !type_matches(class_getInstanceMethod(native_handler_class,sel_registerName("startClippingCursor:")),2,@encode(CGRect)) ||
        !type_matches(class_getInstanceMethod(native_handler_class,sel_registerName("stopClippingCursor")),-1,@encode(BOOL)) ||
        !type_matches(class_getInstanceMethod(native_handler_class,clipping_selector),-1,@encode(BOOL)) ||
        !type_matches(class_getInstanceMethod(native_handler_class,sel_registerName("cursorClipRect")),-1,@encode(CGRect)) ||
        class_getInstanceMethod(native_handler_class,sel_registerName("setCursorPosition:")) ||
        !type_matches(front,-1,@encode(id)) || !type_matches(retina,-1,@encode(void)) || !type_matches(retina,2,@encode(BOOL)) ||
        !type_matches(class_getInstanceMethod(controller,flip_rect_selector),-1,@encode(void)) || !type_matches(class_getInstanceMethod(controller,flip_rect_selector),2,@encode(CGRect*)) ||
        !type_matches(class_getInstanceMethod(controller,update_windows_selector),-1,@encode(void)) ||
        !type_matches(class_getInstanceMethod(wine_window_class,sel_registerName("windowNumber")),-1,@encode(long)) ||
        !hidden_ivar || strcmp(ivar_getTypeEncoding(hidden_ivar), @encode(BOOL)) || !dragging_ivar || ivar_getTypeEncoding(dragging_ivar)[0] != '@' ||
        !capture_ivar || ivar_getTypeEncoding(capture_ivar)[0] != '@' || !handler_ivar || ivar_getTypeEncoding(handler_ivar)[0] != '@' ||
        !type_matches(drag,-1,@encode(void)) || !type_matches(drag,2,@encode(id)) || !type_matches(drag,3,@encode(BOOL)) ||
        !type_matches(unhide,-1,@encode(void)) || !type_matches(capture,-1,@encode(void)) || !type_matches(capture,2,@encode(id)) ||
        !type_matches(start,-1,@encode(BOOL)) || !type_matches(start,2,@encode(CGRect)) || !type_matches(stop,-1,@encode(BOOL)) ||
        !type_matches(class_getInstanceMethod(controller,capture_selector),-1,@encode(id)) || !type_matches(class_getInstanceMethod(controller,clipping_selector),-1,@encode(BOOL)) ||
        !type_matches(class_getInstanceMethod(controller,flip_selector),-1,@encode(CGPoint)) || !type_matches(class_getInstanceMethod(controller,flip_selector),2,@encode(CGPoint)) ||
        !type_matches(class_getInstanceMethod(wine_window_class,parent_selector),-1,@encode(id)) ||
        !type_matches(class_getInstanceMethod(wine_window_class,native_get),-1,@encode(CGRect)) || !type_matches(class_getInstanceMethod(wine_window_class,native_set),-1,@encode(void)) || !type_matches(class_getInstanceMethod(wine_window_class,native_set),2,@encode(CGRect)) ||
        !type_matches(class_getInstanceMethod(wine_window_class,frame_selector),-1,@encode(CGRect)) ||
        !type_matches(class_getInstanceMethod(wine_window_class,client_selector),-1,@encode(CGRect)) || !type_matches(class_getInstanceMethod(wine_window_class,client_selector),2,@encode(CGRect)) ||
        !type_matches(class_getInstanceMethod(wine_window_class,convert_selector),-1,@encode(CGRect)) || !type_matches(class_getInstanceMethod(wine_window_class,convert_selector),2,@encode(CGRect)) ||
        method_getImplementation(warp) != (IMP)eligible_warp || !prepare_notifications())
    {
        gate_audit("IDV_NATIVE_CAMERA skipped reason=interface-or-observer\n"); return;
    }
    original_front=method_getImplementation(front);original_retina=method_getImplementation(retina);
    method_setImplementation(front,(IMP)protocol_front);method_setImplementation(retina,(IMP)protocol_retina);
    hidden_offset=ivar_getOffset(hidden_ivar); capture_offset=ivar_getOffset(capture_ivar); handler_offset=ivar_getOffset(handler_ivar);
    original_drag=method_getImplementation(drag);
    method_setImplementation(drag,(IMP)camera_drag);
    original_unhide=method_getImplementation(unhide); original_capture=method_getImplementation(capture);
    original_start_clip=method_getImplementation(start); original_stop_clip=method_getImplementation(stop);
    method_setImplementation(unhide,(IMP)camera_unhide); method_setImplementation(capture,(IMP)camera_capture);
    method_setImplementation(start,(IMP)camera_start_clip); method_setImplementation(stop,(IMP)camera_stop_clip);
    method_setImplementation(warp,(IMP)camera_warp); camera_ready=1;
    gate_audit("IDV_NATIVE_CAMERA installed nativeOnly=1 fullClient=1 keepsOEMWarp=1 capturePolicy=absent-or-owned driverProtocol=1\n");
}
#ifndef IDV_CAMERA_TEST
static CFRunLoopObserverRef startup_observer;
static int camera_image_seen;
static void camera_image_added(const struct mach_header *header, intptr_t slide)
{
    Dl_info info;
    if (!dladdr(header, &info) || !info.dli_fname) return;
    const char *name = strrchr(info.dli_fname, '/');
    if (!strcmp(name ? name + 1 : info.dli_fname, "winemac.so"))
        __atomic_store_n(&camera_image_seen, 1, __ATOMIC_RELEASE);
}
static void install_before_sources(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *context)
{
    /* This observes existing runloop activity; it creates no event source,
     * timer, worker or input monitor. Metadata may arrive transitively. */
    if (!__atomic_load_n(&camera_image_seen, __ATOMIC_ACQUIRE) || !objc_getClass("WineApplicationController")) return;
    if (!background_requested && camera_requested &&
        (!getprogname() || strcasecmp(getprogname(), "dwrg.exe")))
    {
        install_state = 3;
        gate_audit("IDV_NATIVE_CAMERA skipped reason=process-scope\n");
    }
    else install_camera();
    if (install_state == 2 || install_state == 3)
    {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
        startup_observer = NULL; CFRelease(observer);
    }
}
__attribute__((constructor)) static void camera_initialize(void)
{
    const char *value=getenv("IDENTITYV_NATIVE_CAMERA_CLIP");camera_requested=value&&!strcmp(value,"1");
    value=getenv("IDENTITYV_FOREGROUND_WARP_GATE");background_requested=value&&!strcmp(value,"1");
    value=getenv("IDENTITYV_WARP_GATE_AUDIT");audit_enabled=value&&!strcmp(value,"1");
    if (!camera_requested && !background_requested) return;
    _dyld_register_func_for_add_image(camera_image_added);
    startup_observer=CFRunLoopObserverCreate(NULL,kCFRunLoopBeforeSources|kCFRunLoopBeforeWaiting,1,-2147483647,install_before_sources,NULL);
    if (startup_observer) CFRunLoopAddObserver(CFRunLoopGetMain(),startup_observer,kCFRunLoopCommonModes);
    gate_audit("IDV_NATIVE_CAMERA loaded install=main-runloop-pending loaderInterpose=0\n");
}
#endif
