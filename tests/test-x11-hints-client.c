/**
 * test-x11-hints-client - X11 client with WM_NORMAL_HINTS.
 *
 * minmax sets P_MIN_SIZE 300x200 and P_MAX_SIZE 900x700; base sets only
 * BASE_SIZE 300x200. Used by test-x11-size-hints-tile.lua.
 *
 * Usage: test-x11-hints-client <wm-class> minmax|base
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xcb/xcb.h>
#include <xcb/xcb_icccm.h>

int main(int argc, char *argv[]) {
    if (argc != 3 || (strcmp(argv[2], "minmax") && strcmp(argv[2], "base"))) {
        fprintf(stderr, "Usage: %s <wm-class> minmax|base\n", argv[0]);
        return 1;
    }
    const char *wm_class = argv[1];

    xcb_connection_t *conn = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(conn)) {
        fprintf(stderr, "Failed to connect to X display\n");
        return 1;
    }
    xcb_screen_t *screen =
        xcb_setup_roots_iterator(xcb_get_setup(conn)).data;

    xcb_window_t win = xcb_generate_id(conn);
    uint32_t values[] = {
        screen->white_pixel,
        XCB_EVENT_MASK_EXPOSURE | XCB_EVENT_MASK_STRUCTURE_NOTIFY,
    };
    xcb_create_window(conn, XCB_COPY_FROM_PARENT, win, screen->root,
                      0, 0, 400, 300, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT,
                      screen->root_visual,
                      XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK, values);

    /* WM_CLASS is "instance\0class\0"; the test finds the client by class. */
    char class_prop[256];
    size_t len = strlen(wm_class) + 1;
    if (2 * len > sizeof(class_prop)) {
        fprintf(stderr, "wm-class too long\n");
        return 1;
    }
    memcpy(class_prop, wm_class, len);
    memcpy(class_prop + len, wm_class, len);
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_CLASS,
                        XCB_ATOM_STRING, 8, 2 * len, class_prop);
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_NAME,
                        XCB_ATOM_STRING, 8, strlen(wm_class), wm_class);

    /* WM_HINTS: input = True, initial_state = NormalState. */
    uint32_t wm_hints[9] = { (1 << 0) | (1 << 1), 1, 1, 0, 0, 0, 0, 0, 0 };
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_HINTS,
                        XCB_ATOM_WM_HINTS, 32, 9, wm_hints);

    xcb_size_hints_t hints;
    memset(&hints, 0, sizeof(hints));
    if (strcmp(argv[2], "minmax") == 0) {
        xcb_icccm_size_hints_set_min_size(&hints, 300, 200);
        xcb_icccm_size_hints_set_max_size(&hints, 900, 700);
    } else {
        xcb_icccm_size_hints_set_base_size(&hints, 300, 200);
    }
    xcb_icccm_set_wm_normal_hints(conn, win, &hints);

    xcb_gcontext_t gc = xcb_generate_id(conn);
    uint32_t gc_values[] = { screen->white_pixel };
    xcb_create_gc(conn, gc, win, XCB_GC_FOREGROUND, gc_values);

    xcb_map_window(conn, win);
    xcb_flush(conn);

    xcb_generic_event_t *ev;
    while ((ev = xcb_wait_for_event(conn))) {
        if ((ev->response_type & ~0x80) == XCB_EXPOSE) {
            /* Paint the window: Xwayland only maps a Wayland buffer for
             * windows with rendered content. */
            xcb_rectangle_t rect = { 0, 0, 400, 300 };
            xcb_poly_fill_rectangle(conn, win, gc, 1, &rect);
        }
        free(ev);
        xcb_flush(conn);
    }

    xcb_disconnect(conn);
    return 0;
}
