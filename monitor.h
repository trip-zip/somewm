/*
 * monitor.h - Monitor/output management for somewm compositor
 *
 * Display lifecycle, hotplug, rendering, DPMS, and output configuration.
 */
#ifndef MONITOR_H
#define MONITOR_H

#include "somewm_types.h"

struct wl_listener;
struct wlr_box;
struct wlr_output_configuration_v1;

/* Monitor lifecycle */
void createmon(struct wl_listener *listener, void *data);
void cleanupmon(struct wl_listener *listener, void *data);
void closemon(Monitor *m);
void updatemons(struct wl_listener *listener, void *data);

/* Rendering */
void rendermon(struct wl_listener *listener, void *data);
void gpureset(struct wl_listener *listener, void *data);

/* Output configuration */
void outputmgrapply(struct wl_listener *listener, void *data);
void outputmgrapplyortest(struct wlr_output_configuration_v1 *config, int test);
void outputmgrtest(struct wl_listener *listener, void *data);
void powermgrsetmode(struct wl_listener *listener, void *data);
void requestmonstate(struct wl_listener *listener, void *data);

/* Queries */
Monitor *dirtomon(enum wlr_direction dir);
void focusmon(const Arg *arg);
Monitor *xytomon(double x, double y);

/* Listener structs (registered in setup(), defined in monitor.c) */
extern struct wl_listener gpu_reset;
extern struct wl_listener layout_change;
extern struct wl_listener new_output;
extern struct wl_listener output_mgr_apply;
extern struct wl_listener output_mgr_test;
extern struct wl_listener output_power_mgr_set_mode;

#endif /* MONITOR_H */
