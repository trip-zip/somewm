/**
 * test-x11-grab-client - X11 client that grabs the pointer like a game.
 *
 * Maps a window and, when the pointer enters it, issues an active XGrabPointer
 * confined to the window with a blank cursor (the classic game capture
 * pattern; Xwayland translates it into a pointer constraint). Appends one line
 * per event to a marker file:
 *
 *     GRAB <status>          0 = success (xcb_grab_status_t otherwise)
 *     ENTER
 *     FOCUS_IN mode=M detail=D
 *     FOCUS_OUT mode=M detail=D
 *     BUTTON press|release
 *
 * Used by test-xwayland-pointer-grab-click.lua: a left click on the grabbing
 * window must not produce FOCUS_OUT, which is what makes Xwayland tear the
 * grab down.
 *
 * Usage: test-x11-grab-client <marker-path> <wm-class> <x> <y> <w> <h>
 *
 * The window is created at the given box. It must match where the compositor
 * places the client and avoid the X pointer's resting position: a window that
 * maps under the pointer delivers EnterNotify (and grabs) immediately.
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xcb/xcb.h>

static const char *g_marker;

static void log_line(const char *fmt, ...) {
    FILE *f = fopen(g_marker, "a");
    if (!f)
        return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

/* Grab like a game entering mouse capture: on pointer enter, so the cursor
 * is inside the window when the grab (and any pointer constraint Xwayland
 * derives from it) takes effect. Retried until it succeeds. */
static int try_grab(xcb_connection_t *conn, xcb_window_t win,
                    xcb_cursor_t cursor) {
    xcb_grab_pointer_reply_t *reply = xcb_grab_pointer_reply(conn,
        xcb_grab_pointer(conn, 1, win,
            XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE
                | XCB_EVENT_MASK_POINTER_MOTION,
            XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC,
            win, cursor, XCB_CURRENT_TIME),
        NULL);
    uint8_t status = reply ? reply->status : 0xff;
    free(reply);
    log_line("GRAB %u", status);
    return status == XCB_GRAB_STATUS_SUCCESS;
}

/* 1x1 empty-pixmap cursor: hides the pointer for the grab's duration. */
static xcb_cursor_t blank_cursor(xcb_connection_t *conn, xcb_screen_t *screen) {
    xcb_pixmap_t pixmap = xcb_generate_id(conn);
    xcb_create_pixmap(conn, 1, pixmap, screen->root, 1, 1);
    xcb_cursor_t cursor = xcb_generate_id(conn);
    xcb_create_cursor(conn, cursor, pixmap, pixmap, 0, 0, 0, 0, 0, 0, 0, 0);
    xcb_free_pixmap(conn, pixmap);
    return cursor;
}

int main(int argc, char *argv[]) {
    if (argc != 7) {
        fprintf(stderr, "Usage: %s <marker-path> <wm-class> <x> <y> <w> <h>\n",
                argv[0]);
        return 1;
    }
    g_marker = argv[1];
    const char *wm_class = argv[2];
    int16_t x = (int16_t)atoi(argv[3]);
    int16_t y = (int16_t)atoi(argv[4]);
    uint16_t w = (uint16_t)atoi(argv[5]);
    uint16_t h = (uint16_t)atoi(argv[6]);

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
        XCB_EVENT_MASK_EXPOSURE | XCB_EVENT_MASK_STRUCTURE_NOTIFY
            | XCB_EVENT_MASK_FOCUS_CHANGE | XCB_EVENT_MASK_BUTTON_PRESS
            | XCB_EVENT_MASK_BUTTON_RELEASE | XCB_EVENT_MASK_ENTER_WINDOW,
    };
    xcb_create_window(conn, XCB_COPY_FROM_PARENT, win, screen->root,
                      x, y, w, h, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT,
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
    /* WM_NORMAL_HINTS: PPosition | PSize. */
    uint32_t size_hints[18] = { (1 << 2) | (1 << 3) };
    size_hints[1] = (uint32_t)x; size_hints[2] = (uint32_t)y;
    size_hints[3] = w; size_hints[4] = h;
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win,
                        XCB_ATOM_WM_NORMAL_HINTS, XCB_ATOM_WM_SIZE_HINTS,
                        32, 18, size_hints);

    xcb_gcontext_t gc = xcb_generate_id(conn);
    uint32_t gc_values[] = { screen->white_pixel };
    xcb_create_gc(conn, gc, win, XCB_GC_FOREGROUND, gc_values);

    xcb_map_window(conn, win);
    xcb_flush(conn);

    xcb_cursor_t cursor = blank_cursor(conn, screen);
    int grabbed = 0;
    xcb_generic_event_t *ev;
    while ((ev = xcb_wait_for_event(conn))) {
        switch (ev->response_type & ~0x80) {
        case XCB_EXPOSE: {
            /* Paint the window: Xwayland only maps a Wayland buffer for
             * windows with rendered content. */
            xcb_rectangle_t rect = { 0, 0, w, h };
            xcb_poly_fill_rectangle(conn, win, gc, 1, &rect);
            break;
        }
        case XCB_ENTER_NOTIFY:
            log_line("ENTER");
            if (!grabbed)
                grabbed = try_grab(conn, win, cursor);
            break;
        case XCB_FOCUS_IN: {
            xcb_focus_in_event_t *fe = (xcb_focus_in_event_t *)ev;
            log_line("FOCUS_IN mode=%u detail=%u", fe->mode, fe->detail);
            break;
        }
        case XCB_FOCUS_OUT: {
            xcb_focus_out_event_t *fe = (xcb_focus_out_event_t *)ev;
            log_line("FOCUS_OUT mode=%u detail=%u", fe->mode, fe->detail);
            break;
        }
        case XCB_BUTTON_PRESS:
            log_line("BUTTON press");
            break;
        case XCB_BUTTON_RELEASE:
            log_line("BUTTON release");
            break;
        }
        free(ev);
        xcb_flush(conn);
    }

    xcb_disconnect(conn);
    return 0;
}
