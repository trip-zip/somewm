#ifndef SOMEWM_NESTED_INHIBITOR_H
#define SOMEWM_NESTED_INHIBITOR_H

/*
 * Why: when somewm runs nested under another Wayland compositor, the
 * host eats Mod4 combos unless we ask it to forward them via the
 * shortcut inhibitor protocol. The test-mode Lua layer handles the
 * fallback when this isn't possible.
 */

struct wlr_backend;
struct wlr_output;

void nested_inhibitor_init(struct wlr_backend *backend);
void nested_inhibitor_attach_output(struct wlr_output *output);

/* Returns one of "active", "unavailable", "not-applicable". Used by the
 * orchestrator to print accurate keybind status after a test start. */
const char *nested_inhibitor_status(void);

#endif
