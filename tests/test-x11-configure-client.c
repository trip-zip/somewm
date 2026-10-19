/* X11 geometry probe for test-xwayland-configure-request.lua.
 * create CLASS GRAVITY LOG; query WINDOW;
 * request WINDOW MASK X Y WIDTH HEIGHT [COUNT];
 * hints WINDOW GRAVITY MIN_WIDTH MIN_HEIGHT MAX_WIDTH MAX_HEIGHT.
 * Requests are explicit X11 content geometry, independent of SomeWM's API. */
#include <xcb/xcb.h>
#include <xcb/xcb_icccm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int number(const char *value) { return (int)strtol(value, NULL, 0); }

int main(int argc, char **argv)
{
    if (argc < 3) return 2;
    xcb_connection_t *conn = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(conn)) return 3;
    xcb_screen_t *screen = xcb_setup_roots_iterator(xcb_get_setup(conn)).data;
    xcb_window_t win;
    if (!strcmp(argv[1], "create")) {
        if (argc != 5 || !freopen(argv[4], "w", stdout)) return 2;
        setbuf(stdout, NULL);
        win = xcb_generate_id(conn);
        uint32_t values[] = {screen->white_pixel,
            XCB_EVENT_MASK_EXPOSURE | XCB_EVENT_MASK_STRUCTURE_NOTIFY};
        xcb_create_window(conn, XCB_COPY_FROM_PARENT, win, screen->root,
            100, 100, 400, 300, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT,
            screen->root_visual, XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK, values);
        char cls[256];
        size_t len = strlen(argv[2]) + 1;
        if (2 * len > sizeof(cls)) return 2;
        memcpy(cls, argv[2], len);
        memcpy(cls + len, argv[2], len);
        xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_CLASS,
            XCB_ATOM_STRING, 8, 2 * len, cls);
        xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_NAME,
            XCB_ATOM_STRING, 8, len - 1, argv[2]);
        xcb_size_hints_t hints = {0};
        xcb_icccm_size_hints_set_win_gravity(&hints, number(argv[3]));
        xcb_icccm_set_wm_normal_hints(conn, win, &hints);
        xcb_gcontext_t gc = xcb_generate_id(conn);
        uint32_t color = screen->white_pixel;
        xcb_create_gc(conn, gc, win, XCB_GC_FOREGROUND, &color);
        xcb_map_window(conn, win);
        xcb_flush(conn);
        xcb_generic_event_t *event;
        while ((event = xcb_wait_for_event(conn))) {
            if ((event->response_type & 127) == XCB_EXPOSE) {
                xcb_rectangle_t rect = {0, 0, 65535, 65535};
                xcb_poly_fill_rectangle(conn, win, gc, 1, &rect);
            } else if ((event->response_type & 127) == XCB_CONFIGURE_NOTIFY) {
                xcb_configure_notify_event_t *notify = (void *)event;
                printf("%d %d %u %u\n", notify->x, notify->y, notify->width, notify->height);
            }
            free(event);
            xcb_flush(conn);
        }
    } else {
        win = (xcb_window_t)strtoul(argv[2], NULL, 0);
        if (!strcmp(argv[1], "query")) {
            xcb_get_geometry_reply_t *g = xcb_get_geometry_reply(conn,
                xcb_get_geometry(conn, win), NULL);
            xcb_translate_coordinates_reply_t *p = xcb_translate_coordinates_reply(conn,
                xcb_translate_coordinates(conn, win, screen->root, 0, 0), NULL);
            if (!g || !p) return 4;
            printf("%d %d %u %u\n", p->dst_x, p->dst_y, g->width, g->height);
            free(g);
            free(p);
        } else if (!strcmp(argv[1], "request")) {
            if (argc != 8 && argc != 9) return 2;
            unsigned mask = (unsigned)number(argv[3]);
            if (mask & ~15u) return 2;
            uint32_t values[4];
            int len = 0;
            for (int i = 0; i < 4; i++)
                if (mask & (1 << i)) values[len++] = number(argv[4 + i]);
            int count = argc == 9 ? number(argv[8]) : 1;
            for (int i = 0; i < count; i++)
                xcb_configure_window(conn, win, mask, values);
        } else if (!strcmp(argv[1], "hints")) {
            if (argc != 8) return 2;
            xcb_size_hints_t hints = {0};
            xcb_icccm_size_hints_set_win_gravity(&hints, number(argv[3]));
            if (number(argv[4]) || number(argv[5]))
                xcb_icccm_size_hints_set_min_size(&hints, number(argv[4]), number(argv[5]));
            if (number(argv[6]) || number(argv[7]))
                xcb_icccm_size_hints_set_max_size(&hints, number(argv[6]), number(argv[7]));
            xcb_icccm_set_wm_normal_hints(conn, win, &hints);
        } else return 2;
        /* Flush and round-trip without waiting for the compositor to handle
         * the request: the Lua test must return to its event loop first. */
        free(xcb_get_input_focus_reply(conn, xcb_get_input_focus(conn), NULL));
    }
    xcb_disconnect(conn);
    return 0;
}
