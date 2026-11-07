/* Identity V foreground warp compatibility layer, candidate only.
 * Keep the known baseline winemac bytes and delegate every eligible call to
 * its original IMP. No event tap, timer, input synthesis or per-call logging.
 * Installation is attempted only at startup or AFTER winemac's dlopen returns.
 */
#include <CommonCrypto/CommonDigest.h>
#include <CoreGraphics/CGGeometry.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define IDV_BASELINE_SHA "365fefb1c0bf4c0e54f4fd3a00dbd44bd9a6febc75209846b6de2c270bdb9c60"
typedef BOOL (*warp_imp)(id, SEL, CGPoint);
static warp_imp original_warp;
static id *application_slot;
static Class wine_window_class;
static SEL active_selector, key_selector, kind_selector;
static int enabled, audit_enabled, install_state;

static void gate_audit(const char *message)
{
    if (audit_enabled) (void)write(STDERR_FILENO, message, strlen(message));
}

static BOOL eligible_warp(id self, SEL command, CGPoint position)
{
    id app = application_slot ? *application_slot : nil;
    if (!app || !((BOOL (*)(id, SEL))objc_msgSend)(app, active_selector)) return NO;
    id key = ((id (*)(id, SEL))objc_msgSend)(app, key_selector);
    if (!key || !((BOOL (*)(id, SEL, Class))objc_msgSend)(key, kind_selector, wine_window_class)) return NO;
    warp_imp original = __atomic_load_n(&original_warp, __ATOMIC_ACQUIRE);
    return original ? original(self, command, position) : NO;
}

static int module_has_known_hash(const char *path)
{
    unsigned char bytes[32768], digest[CC_SHA256_DIGEST_LENGTH];
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    struct stat info;
    CC_SHA256_CTX context;
    ssize_t count;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode)) { close(fd); return 0; }
    CC_SHA256_Init(&context);
    for (;;)
    {
        count = read(fd, bytes, sizeof(bytes));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        CC_SHA256_Update(&context, bytes, (CC_LONG)count);
    }
    close(fd);
    if (count < 0) return 0;
    CC_SHA256_Final(digest, &context);
    for (unsigned i = 0; i < sizeof(digest); ++i) sprintf(hex + i * 2, "%02x", digest[i]);
    return !strcmp(hex, IDV_BASELINE_SHA);
}

static int signature_matches(Method method)
{
    int valid;
    char *result, *argument;
    if (!method || method_getNumberOfArguments(method) != 3) return 0;
    result = method_copyReturnType(method);
    argument = method_copyArgumentType(method, 2);
    valid = result && !strcmp(result, @encode(BOOL)) && argument && !strcmp(argument, @encode(CGPoint));
    free(result); free(argument);
    return valid;
}

static void attempt_install(void)
{
    Class controller, window;
    Method method;
    IMP original;
    Dl_info owner;
    id *slot;
    int expected = 0;
    if (!enabled || !__atomic_compare_exchange_n(&install_state, &expected, 1, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) return;
    controller = objc_getClass("WineApplicationController");
    window = objc_getClass("WineWindow");
    if (!controller || !window) { __atomic_store_n(&install_state, 0, __ATOMIC_RELEASE); return; }
    method = class_getInstanceMethod(controller, sel_registerName("setCursorPosition:"));
    if (!signature_matches(method)) goto signature_failure;
    original = method_getImplementation(method);
    if (!original || !dladdr((const void *)original, &owner) || !owner.dli_fname || !module_has_known_hash(owner.dli_fname))
        goto identity_failure;
    slot = (id *)dlsym(RTLD_DEFAULT, "NSApp");
    /* Install before Wine initializes NSApplication. Refuse late attachment to
     * a running app; this candidate never patches a live game. */
    if (!slot || *slot) goto timing_failure;
    application_slot = slot;
    wine_window_class = window;
    active_selector = sel_registerName("isActive");
    key_selector = sel_registerName("keyWindow");
    kind_selector = sel_registerName("isKindOfClass:");
    __atomic_store_n(&original_warp, (warp_imp)original, __ATOMIC_RELEASE);
    /* This startup-only restriction avoids publication racing a live call.
     * Do not replace again if any other layer changed the IMP meanwhile. */
    if (method_getImplementation(method) != original) goto timing_failure;
    method_setImplementation(method, (IMP)eligible_warp);
    __atomic_store_n(&install_state, 2, __ATOMIC_RELEASE);
    gate_audit("IDV_WARP_GATE installed baseline=365fefb1 policy=foreground-only delegate=original noEventDiagnostics=1\n");
    return;
identity_failure:
    gate_audit("IDV_WARP_GATE skipped reason=baseline-identity\n");
    goto skipped;
signature_failure:
    gate_audit("IDV_WARP_GATE skipped reason=method-signature\n");
    goto skipped;
timing_failure:
    gate_audit("IDV_WARP_GATE skipped reason=late-or-unavailable-application\n");
skipped:
    __atomic_store_n(&install_state, 3, __ATOMIC_RELEASE);
}

#ifndef IDV_GATE_TEST
static int is_winemac(const char *path)
{
    const char *name;
    if (!path) return 0;
    name = strrchr(path, '/');
    return !strcmp(name ? name + 1 : path, "winemac.so");
}

static void *compat_dlopen(const char *path, int flags)
{
    /* dyld interpose tuples exclude their defining image when it calls the
     * original function. Failure never runs our installer or consumes dlerror. */
    void *result = dlopen(path, flags);
    int saved_errno = errno;
    if (result && is_winemac(path)) attempt_install();
    errno = saved_errno;
    return result;
}
__attribute__((used)) static struct { const void *replacement, *replacee; } interpose_dlopen
    __attribute__((section("__DATA,__interpose"))) = { (const void *)compat_dlopen, (const void *)dlopen };

__attribute__((constructor)) static void initialize_gate(void)
{
    const char *value = getenv("IDENTITYV_FOREGROUND_WARP_GATE");
    enabled = value && !strcmp(value, "1");
    value = getenv("IDENTITYV_WARP_GATE_AUDIT");
    audit_enabled = value && !strcmp(value, "1");
    attempt_install();
}
#endif
