#!/usr/bin/env python3
"""X11 test helper: create an override_redirect window (simulates popup/menu).

Usage: python3 x11_override_redirect.py <WM_CLASS> [x y width height]

Creates an override_redirect=True window, which bypasses the window manager.
This is what Wine, Steam, and other X11 apps use for popup menus and tooltips.

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

# XSetWindowAttributes structure (partial — only fields we need)
class XSetWindowAttributes(ctypes.Structure):
    _fields_ = [
        ("background_pixmap", ctypes.c_ulong),
        ("background_pixel", ctypes.c_ulong),
        ("border_pixmap", ctypes.c_ulong),
        ("border_pixel", ctypes.c_ulong),
        ("bit_gravity", ctypes.c_int),
        ("win_gravity", ctypes.c_int),
        ("backing_store", ctypes.c_int),
        ("backing_planes", ctypes.c_ulong),
        ("backing_pixel", ctypes.c_ulong),
        ("save_under", ctypes.c_int),
        ("event_mask", ctypes.c_long),
        ("do_not_propagate_mask", ctypes.c_long),
        ("override_redirect", ctypes.c_int),
    ]

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

x11.XCreateWindow.argtypes = [
    Display_p, Window,
    ctypes.c_int, ctypes.c_int,     # x, y
    ctypes.c_uint, ctypes.c_uint,   # width, height
    ctypes.c_uint,                   # border_width
    ctypes.c_int,                    # depth (CopyFromParent=0)
    ctypes.c_uint,                   # class (InputOutput=1)
    ctypes.c_void_p,                 # visual (CopyFromParent=NULL)
    ctypes.c_ulong,                  # valuemask
    ctypes.POINTER(XSetWindowAttributes),
]
x11.XCreateWindow.restype = Window

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

# --- Constants ---

CWOverrideRedirect = (1 << 9)   # valuemask bit for override_redirect
CWBackPixel = (1 << 1)          # valuemask bit for background_pixel
InputOutput = 1
CopyFromParent = 0

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

    if len(sys.argv) < 2:
        print("Usage: %s <WM_CLASS> [x y width height]" % sys.argv[0], file=sys.stderr)
        sys.exit(1)

    wm_class = sys.argv[1]
    wx = int(sys.argv[2]) if len(sys.argv) > 2 else 100
    wy = int(sys.argv[3]) if len(sys.argv) > 3 else 100
    ww = int(sys.argv[4]) if len(sys.argv) > 4 else 200
    wh = int(sys.argv[5]) if len(sys.argv) > 5 else 150

    # Open display
    dpy = x11.XOpenDisplay(None)
    if not dpy:
        print("ERROR: Cannot open X display", file=sys.stderr)
        sys.exit(1)

    screen = x11.XDefaultScreen(dpy)
    root = x11.XRootWindow(dpy, screen)

    # Set up attributes with override_redirect = True
    attrs = XSetWindowAttributes()
    attrs.override_redirect = 1
    attrs.background_pixel = 0xFF0000  # Red background for visibility

    # Create override_redirect window
    win = x11.XCreateWindow(
        dpy, root,
        wx, wy, ww, wh,
        0,                          # border_width
        CopyFromParent,             # depth
        InputOutput,                # class
        None,                       # visual (CopyFromParent)
        CWOverrideRedirect | CWBackPixel,
        ctypes.byref(attrs),
    )

    # Set WM_CLASS
    hint = XClassHint()
    hint.res_name = wm_class.lower().encode()
    hint.res_class = wm_class.encode()
    x11.XSetClassHint(dpy, win, ctypes.byref(hint))

    # Set title
    x11.XStoreName(dpy, win, wm_class.encode())

    # Map window
    x11.XMapWindow(dpy, win)
    x11.XFlush(dpy)

    print("[x11_override_redirect] mapped: class=%s override_redirect=1 geom=%dx%d+%d+%d"
          % (wm_class, ww, wh, wx, wy), file=sys.stderr)

    # Install signal handlers
    signal.signal(signal.SIGTERM, handle_term)

    # Block until killed
    while True:
        signal.pause()

if __name__ == "__main__":
    main()
