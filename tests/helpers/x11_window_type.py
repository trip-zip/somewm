#!/usr/bin/env python3
"""X11 test helper: create a window with a specific _NET_WM_WINDOW_TYPE.

Usage: python3 x11_window_type.py <WM_CLASS> <WINDOW_TYPE>

WINDOW_TYPE is one of: dialog, splash, utility, toolbar, dock, desktop,
    menu, dropdown_menu, popup_menu, tooltip, notification, combo, dnd, normal

The window stays mapped until SIGTERM is received.
"""

import ctypes
import ctypes.util
import signal
import sys

# --- Load libX11 via ctypes ---

_x11_path = ctypes.util.find_library("X11")
if not _x11_path:
    print("ERROR: libX11 not found", file=sys.stderr)
    sys.exit(1)

x11 = ctypes.cdll.LoadLibrary(_x11_path)

# Type aliases
Display_p = ctypes.c_void_p
Window = ctypes.c_ulong
Atom = ctypes.c_ulong

# XClassHint structure
class XClassHint(ctypes.Structure):
    _fields_ = [
        ("res_name", ctypes.c_char_p),
        ("res_class", ctypes.c_char_p),
    ]

# Function prototypes
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XOpenDisplay.restype = Display_p

x11.XDefaultScreen.argtypes = [Display_p]
x11.XDefaultScreen.restype = ctypes.c_int

x11.XRootWindow.argtypes = [Display_p, ctypes.c_int]
x11.XRootWindow.restype = Window

x11.XCreateSimpleWindow.argtypes = [
    Display_p, Window,
    ctypes.c_int, ctypes.c_int,   # x, y
    ctypes.c_uint, ctypes.c_uint, # width, height
    ctypes.c_uint,                 # border_width
    ctypes.c_ulong,               # border
    ctypes.c_ulong,               # background
]
x11.XCreateSimpleWindow.restype = Window

x11.XSetClassHint.argtypes = [Display_p, Window, ctypes.POINTER(XClassHint)]
x11.XSetClassHint.restype = ctypes.c_int

x11.XStoreName.argtypes = [Display_p, Window, ctypes.c_char_p]
x11.XStoreName.restype = ctypes.c_int

x11.XMapWindow.argtypes = [Display_p, Window]
x11.XMapWindow.restype = ctypes.c_int

x11.XFlush.argtypes = [Display_p]
x11.XFlush.restype = ctypes.c_int

x11.XDestroyWindow.argtypes = [Display_p, Window]
x11.XDestroyWindow.restype = ctypes.c_int

x11.XCloseDisplay.argtypes = [Display_p]
x11.XCloseDisplay.restype = ctypes.c_int

x11.XInternAtom.argtypes = [Display_p, ctypes.c_char_p, ctypes.c_int]
x11.XInternAtom.restype = Atom

x11.XChangeProperty.argtypes = [
    Display_p, Window, Atom, Atom,
    ctypes.c_int,   # format (bits per element: 8, 16, or 32)
    ctypes.c_int,   # mode (PropModeReplace=0)
    ctypes.c_void_p, # data
    ctypes.c_int,   # nelements
]
x11.XChangeProperty.restype = ctypes.c_int

# --- Constants ---

PropModeReplace = 0
XA_ATOM = 4  # X11 predefined atom type for ATOM

# Map of window type names to their _NET_WM_WINDOW_TYPE_* atom names
WINDOW_TYPE_ATOMS = {
    "dialog":        "_NET_WM_WINDOW_TYPE_DIALOG",
    "splash":        "_NET_WM_WINDOW_TYPE_SPLASH",
    "utility":       "_NET_WM_WINDOW_TYPE_UTILITY",
    "toolbar":       "_NET_WM_WINDOW_TYPE_TOOLBAR",
    "dock":          "_NET_WM_WINDOW_TYPE_DOCK",
    "desktop":       "_NET_WM_WINDOW_TYPE_DESKTOP",
    "menu":          "_NET_WM_WINDOW_TYPE_MENU",
    "dropdown_menu": "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU",
    "popup_menu":    "_NET_WM_WINDOW_TYPE_POPUP_MENU",
    "tooltip":       "_NET_WM_WINDOW_TYPE_TOOLTIP",
    "notification":  "_NET_WM_WINDOW_TYPE_NOTIFICATION",
    "combo":         "_NET_WM_WINDOW_TYPE_COMBO",
    "dnd":           "_NET_WM_WINDOW_TYPE_DND",
    "normal":        "_NET_WM_WINDOW_TYPE_NORMAL",
}

# --- Globals ---

dpy = None
win = None

def handle_term(signum, frame):
    """SIGTERM: Clean exit."""
    if dpy and win:
        x11.XDestroyWindow(dpy, win)
        x11.XCloseDisplay(dpy)
    sys.exit(0)

def main():
    global dpy, win

    if len(sys.argv) < 3:
        print("Usage: %s <WM_CLASS> <WINDOW_TYPE>" % sys.argv[0], file=sys.stderr)
        sys.exit(1)

    wm_class = sys.argv[1]
    window_type_name = sys.argv[2]

    if window_type_name not in WINDOW_TYPE_ATOMS:
        print("ERROR: unknown window type '%s'" % window_type_name, file=sys.stderr)
        print("Valid types: %s" % ", ".join(sorted(WINDOW_TYPE_ATOMS)), file=sys.stderr)
        sys.exit(1)

    # Open display
    dpy = x11.XOpenDisplay(None)
    if not dpy:
        print("ERROR: Cannot open X display", file=sys.stderr)
        sys.exit(1)

    screen = x11.XDefaultScreen(dpy)
    root = x11.XRootWindow(dpy, screen)

    # Create window
    win = x11.XCreateSimpleWindow(dpy, root, 0, 0, 200, 200, 0, 0, 0)

    # Set WM_CLASS
    hint = XClassHint()
    hint.res_name = wm_class.lower().encode()
    hint.res_class = wm_class.encode()
    x11.XSetClassHint(dpy, win, ctypes.byref(hint))

    # Set title
    x11.XStoreName(dpy, win, wm_class.encode())

    # Set _NET_WM_WINDOW_TYPE BEFORE mapping (like a real app would)
    atom_name = WINDOW_TYPE_ATOMS[window_type_name]
    wm_window_type = x11.XInternAtom(dpy, b"_NET_WM_WINDOW_TYPE", 0)
    type_atom = x11.XInternAtom(dpy, atom_name.encode(), 0)

    type_data = (Atom * 1)(type_atom)
    x11.XChangeProperty(
        dpy, win, wm_window_type, XA_ATOM,
        32, PropModeReplace,
        ctypes.cast(type_data, ctypes.c_void_p),
        1,
    )

    # Map window
    x11.XMapWindow(dpy, win)
    x11.XFlush(dpy)

    print("[x11_window_type] mapped: class=%s type=%s" % (wm_class, window_type_name),
          file=sys.stderr)

    # Install signal handlers
    signal.signal(signal.SIGTERM, handle_term)

    # Block until killed
    while True:
        signal.pause()

if __name__ == "__main__":
    main()
