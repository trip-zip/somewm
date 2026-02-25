#!/usr/bin/env python3
"""X11 test helper: create a window that can be unmapped/remapped via signals.

Usage: python3 x11_unmap_remap.py [WM_CLASS] [TITLE]

Signals:
    SIGUSR1 - Unmap the window (without destroying it)
    SIGUSR2 - Remap the window
    SIGTERM - Clean exit

This is used by test-xwayland-remap.lua to exercise the close-to-tray
lifecycle (unmap → remap) that apps like Discord use.
"""

import ctypes
import ctypes.util
import os
import signal
import sys
import time

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

x11.XUnmapWindow.argtypes = [Display_p, Window]
x11.XUnmapWindow.restype = ctypes.c_int

x11.XFlush.argtypes = [Display_p]
x11.XFlush.restype = ctypes.c_int

x11.XDestroyWindow.argtypes = [Display_p, Window]
x11.XDestroyWindow.restype = ctypes.c_int

x11.XCloseDisplay.argtypes = [Display_p]
x11.XCloseDisplay.restype = ctypes.c_int

# --- Globals ---

dpy = None
win = None

def handle_unmap(signum, frame):
    """SIGUSR1: Unmap window (close-to-tray)."""
    print("[x11_helper] SIGUSR1: unmapping window", file=sys.stderr)
    x11.XUnmapWindow(dpy, win)
    x11.XFlush(dpy)

def handle_remap(signum, frame):
    """SIGUSR2: Remap window (re-open from tray)."""
    print("[x11_helper] SIGUSR2: remapping window", file=sys.stderr)
    x11.XMapWindow(dpy, win)
    x11.XFlush(dpy)

def handle_term(signum, frame):
    """SIGTERM: Clean exit."""
    print("[x11_helper] SIGTERM: exiting", file=sys.stderr)
    if dpy and win:
        x11.XDestroyWindow(dpy, win)
        x11.XCloseDisplay(dpy)
    sys.exit(0)

def main():
    global dpy, win

    wm_class = sys.argv[1] if len(sys.argv) > 1 else "x11_remap_test"
    wm_title = sys.argv[2] if len(sys.argv) > 2 else wm_class

    # Open display
    dpy = x11.XOpenDisplay(None)
    if not dpy:
        print("ERROR: Cannot open X display (is DISPLAY set?)", file=sys.stderr)
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
    x11.XStoreName(dpy, win, wm_title.encode())

    # Map window
    x11.XMapWindow(dpy, win)
    x11.XFlush(dpy)

    print("[x11_helper] Window mapped: class=%s title=%s" % (wm_class, wm_title),
          file=sys.stderr)

    # Install signal handlers
    signal.signal(signal.SIGUSR1, handle_unmap)
    signal.signal(signal.SIGUSR2, handle_remap)
    signal.signal(signal.SIGTERM, handle_term)

    # Block until signalled
    while True:
        signal.pause()

if __name__ == "__main__":
    main()
