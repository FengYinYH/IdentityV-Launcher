/* Historical negative-control adapter, included by probes only. External
 * localizedName changed while the real Dock title stayed wine. The product
 * uses a named metadata host and does not install this LaunchServices SPI. */
#include <dlfcn.h>
typedef CFTypeRef (*IDVLSGetASN)(void);
typedef CFTypeID (*IDVLSASNType)(void);
typedef OSStatus (*IDVLSSetItem)(int, CFTypeRef, CFStringRef, CFTypeRef, CFDictionaryRef *);
typedef void *(*IDVSymbolLookup)(const char *);
static BOOL IDVSystemLSSymbol(const void *pointer)
{
    Dl_info image = {0};
    if (!pointer || !dladdr(pointer, &image) || !image.dli_fname) return NO;
    NSString *path = [NSString stringWithUTF8String:image.dli_fname];
    return [path hasPrefix:@"/System/Library/"] &&
        ([path containsString:@"/LaunchServices.framework/"] || [path containsString:@"/CoreServicesInternal.framework/"]);
}
static void *IDVLookupLSSymbol(const char *name) { return dlsym(RTLD_DEFAULT, name); }
static BOOL IDVRegisterSystemName(NSString *name, IDVSymbolLookup lookup)
{
    if (![NSThread isMainThread] || !lookup ||
        (![name isEqualToString:@"第五人格"] && ![name isEqualToString:@"Identity V"])) return NO;
    IDVLSGetASN getASN = (IDVLSGetASN)lookup("_LSGetCurrentApplicationASN");
    IDVLSASNType asnType = (IDVLSASNType)lookup("_LSASNGetTypeID");
    IDVLSSetItem setItem = (IDVLSSetItem)lookup("_LSSetApplicationInformationItem");
    const CFStringRef *key = (const CFStringRef *)lookup("_kLSDisplayNameKey");
    if (!IDVSystemLSSymbol((const void *)getASN) || !IDVSystemLSSymbol((const void *)asnType) ||
        !IDVSystemLSSymbol((const void *)setItem) || !IDVSystemLSSymbol(key) || !key || !*key ||
        CFGetTypeID(*key) != CFStringGetTypeID()) return NO;
    CFTypeRef current = getASN();
    if (!current || CFGetTypeID(current) != asnType()) return NO;
    return setItem(-2, current, *key, (__bridge CFStringRef)name, NULL) == noErr;
}
