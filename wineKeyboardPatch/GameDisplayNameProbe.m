/* No windows, input, or audio streams. Compile with the production helper so
 * this tests its actual adapter, rather than a second implementation. */
#include "IdentityVCommandGraveForwarder.m"
#include <unistd.h>

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 2) return 2;
        if (strcmp(argv[1], "第五人格") && strcmp(argv[1], "Identity V")) return 3;
        // Force the old cache to exist before invoking the production adapter.
        CFDictionaryRef oldInfo = CFBundleGetInfoDictionary(CFBundleGetMainBundle());
        if (!CFEqual(CFDictionaryGetValue(oldInfo, kCFBundleNameKey), CFSTR("CrossOver-Hosted Application"))) return 4;
        setenv("IDENTITYV_GAME_DISPLAY_NAME", argv[1], 1);
        configureGameDisplayName();
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        [app finishLaunching];
        sleep(8); // External LaunchServices query; no event loop or activation.
    }
    return 0;
}
