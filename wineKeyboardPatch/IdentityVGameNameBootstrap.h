#ifndef IDENTITYV_GAME_NAME_BOOTSTRAP_H
#define IDENTITYV_GAME_NAME_BOOTSTRAP_H
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

/* Probe-only input manipulation for the retired bootstrap hypothesis.
 * The real game already had a matching input, and restoring it did not fix
 * Dock. This header is not included or called by the production helper.
 * Keep the negative control reproducible without claiming a parent dropped
 * this variable or that consumption proves an embedded Info rewrite. */
static inline bool idv_restore_preloader_app_name(const char *selected)
{
    if (!selected || (strcmp(selected, "第五人格") && strcmp(selected, "Identity V"))) return false;
    return setenv("WINEPRELOADERAPPNAME", selected, 1) == 0;
}
#endif
