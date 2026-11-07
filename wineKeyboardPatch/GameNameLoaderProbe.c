/* Probe-only: the original signed loader's --version path. No AppKit/game,
 * prefix creation or file writes. VM/unsetenv interposers forward unchanged;
 * they only observe the exact original Info range and input lifetime. */
#include "IdentityVGameNameBootstrap.h"
#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <stdint.h>
// SDKs may omit the convenience macro; this is the same two-pointer dyld
// observation table. It is only in this isolated probe, never the product.
#define IDV_OBSERVE_SYMBOL(replacement, original) \
    __attribute__((used)) static struct { const void *new_function; const void *old_function; } \
    idv_observe_##original __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(uintptr_t)&replacement, (const void *)(uintptr_t)&original };
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

static bool restored, present_before, initialized, write_seen, restore_seen, unset_seen;
static kern_return_t write_status = -999, restore_status = -999, after_unset_status = -999;
static vm_address_t expected_start;
static vm_size_t expected_size;
static size_t capacity, before_length, selected_length, after_unset_length;
static bool after_unset_matches, code_page_overlap;
static unsigned long page_size, text_length;
static uintptr_t name_offset, text_offset;
static char selected[64];

static kern_return_t observe_vm_protect(vm_map_t task, vm_address_t address, vm_size_t size,
                                        boolean_t set_maximum, vm_prot_t protection)
{
    kern_return_t result = vm_protect(task, address, size, set_maximum, protection);
    if (initialized && task == mach_task_self() && address == expected_start && size == expected_size && !set_maximum) {
        if (protection == (VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE | VM_PROT_COPY)) {
            write_seen = true; write_status = result;
        } else if (protection == (VM_PROT_READ | VM_PROT_EXECUTE)) {
            restore_seen = true; restore_status = result;
        }
    }
    return result;
}
IDV_OBSERVE_SYMBOL(observe_vm_protect, vm_protect)

static int observe_unsetenv(const char *key)
{
    bool observe = initialized && !strcmp(key, "WINEPRELOADERAPPNAME");
    const char *value = observe ? getenv(key) : NULL;
    mach_vm_address_t address = (mach_vm_address_t)(uintptr_t)value;
    int result = unsetenv(key);
    if (observe && address) {
        unsigned char bytes[64] = {0};
        mach_vm_size_t read_size = 0;
        unset_seen = true;
        after_unset_status = mach_vm_read_overwrite(mach_task_self(), address, sizeof(bytes),
            (mach_vm_address_t)(uintptr_t)bytes, &read_size);
        if (after_unset_status == KERN_SUCCESS) {
            while (after_unset_length < read_size && bytes[after_unset_length]) after_unset_length++;
            after_unset_matches = read_size > selected_length && after_unset_length == selected_length &&
                !memcmp(bytes, selected, selected_length);
        }
    }
    return result;
}
IDV_OBSERVE_SYMBOL(observe_unsetenv, unsetenv)

static const unsigned char *loader_info(const struct mach_header_64 **header, unsigned long *length)
{
    *header = (const struct mach_header_64 *)_NSGetMachExecuteHeader();
    return getsectiondata(*header, "__TEXT", "__info_plist", length);
}

static void report_loader_name(void)
{
    unsigned long length = 0;
    const struct mach_header_64 *header;
    const unsigned char *info = loader_info(&header, &length);
    Dl_info image = {0}; dladdr(header, &image);
    const char *image_name = image.dli_fname ? strrchr(image.dli_fname, '/') : NULL;
    image_name = image_name ? image_name + 1 : "unknown";
    while (info && length && !info[length - 1]) length--;
    CFDataRef bytes = info ? CFDataCreate(NULL, info, (CFIndex)length) : NULL;
    CFPropertyListRef plist = bytes ? CFPropertyListCreateWithData(NULL, bytes, kCFPropertyListImmutable, NULL, NULL) : NULL;
    CFStringRef wanted = CFStringCreateWithCString(NULL, selected, kCFStringEncodingUTF8);
    CFTypeRef actual = plist && CFGetTypeID(plist) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(plist, kCFBundleNameKey) : NULL;
    bool match = actual && wanted && CFEqual(actual, wanted);
    char actual_name[128] = {0}, name_hex[255] = {0};
    if (actual && CFGetTypeID(actual) == CFStringGetTypeID() && CFStringGetCString(actual, actual_name, sizeof(actual_name), kCFStringEncodingUTF8)) {
        for (size_t index = 0; index < strlen(actual_name); index++) sprintf(name_hex + index * 2, "%02x", (unsigned char)actual_name[index]);
    }
    fprintf(stderr, "IdentityV loader bootstrap probe: {\"presentBefore\":%s,\"restored\":%s,\"sectionFound\":%s,\"plistParsed\":%s,\"rawNameMatches\":%s,\"rawNameHex\":\"%s\",\"image\":\"%s\",\"consumedByMain\":%s,\"pageSize\":%lu,\"nameOffset\":%lu,\"capacity\":%lu,\"selectedLength\":%lu,\"textOffset\":%lu,\"textLength\":%lu,\"infoCodePageOverlap\":%s,\"vmWriteSeen\":%s,\"vmWriteStatus\":%d,\"vmRestoreSeen\":%s,\"vmRestoreStatus\":%d,\"unsetSeen\":%s,\"afterUnsetReadStatus\":%d,\"afterUnsetLength\":%lu,\"afterUnsetMatches\":%s}\n",
        present_before ? "true" : "false", restored ? "true" : "false", info ? "true" : "false", plist ? "true" : "false", match ? "true" : "false", name_hex, image_name,
        getenv("WINEPRELOADERAPPNAME") ? "false" : "true", page_size, (unsigned long)name_offset, (unsigned long)capacity, (unsigned long)selected_length,
        (unsigned long)text_offset, text_length, code_page_overlap ? "true" : "false", write_seen ? "true" : "false", (int)write_status,
        restore_seen ? "true" : "false", (int)restore_status, unset_seen ? "true" : "false", (int)after_unset_status,
        (unsigned long)after_unset_length, after_unset_matches ? "true" : "false");
    if (wanted) CFRelease(wanted);
    if (plist) CFRelease(plist);
    if (bytes) CFRelease(bytes);
}

__attribute__((constructor))
static void prepare_loader_name(void)
{
    const char *choice = getenv("IDENTITYV_GAME_DISPLAY_NAME");
    if (choice) snprintf(selected, sizeof(selected), "%s", choice);
    selected_length = strlen(selected);
    present_before = getenv("WINEPRELOADERAPPNAME") != NULL;
    const char *rearm = getenv("IDENTITYV_LOADER_PROBE_REARM");
    if (rearm && !strcmp(rearm, "1")) restored = idv_restore_preloader_app_name(choice);
    unsigned long length = 0;
    const struct mach_header_64 *header;
    const unsigned char *info = loader_info(&header, &length);
    const char prefix[] = "<key>CFBundleName</key>\n    <string>";
    const char padding[] = "<!-- bundle name padding -->";
    const char *name = info ? strnstr((const char *)info, prefix, length) : NULL;
    if (name) {
        name += sizeof(prefix) - 1;
        const char *suffix = strnstr(name, "</string>", length - (size_t)(name - (const char *)info));
        if (suffix) {
            before_length = (size_t)(suffix - name); capacity = before_length;
            size_t remaining = length - (size_t)(suffix + 9 - (const char *)info);
            if (remaining >= sizeof(padding) - 1 && !memcmp(suffix + 9, padding, sizeof(padding) - 1)) capacity += sizeof(padding) - 1;
            page_size = (unsigned long)getpagesize();
            expected_start = (vm_address_t)(uintptr_t)name & ~(page_size - 1);
            vm_address_t end = ((vm_address_t)(uintptr_t)name + capacity + 9 + page_size - 1) & ~(page_size - 1);
            expected_size = end - expected_start;
            name_offset = (uintptr_t)name - (uintptr_t)header;
            const unsigned char *text = getsectiondata(header, "__TEXT", "__text", &text_length);
            text_offset = text ? (uintptr_t)text - (uintptr_t)header : 0;
            if (text) {
                uintptr_t text_start = (uintptr_t)text & ~(page_size - 1);
                uintptr_t text_end = ((uintptr_t)text + text_length + page_size - 1) & ~(page_size - 1);
                code_page_overlap = expected_start < text_end && end > text_start;
            }
        }
    }
    initialized = true;
    atexit(report_loader_name);
}
