#!/usr/bin/env python3
"""Gate counts over saved tree dumps (spec E010).

    python3 tests/report.py gates DIR...
"""
import re
import sys
from pathlib import Path

WORDS = {'user', 'theme', 'output', 'protocol', 'legacy', 'transition',
         'scroll', 'derived'}
CLIENT_WORDS = {'user', 'protocol', 'output', 'legacy'}
NUM = r'[0-9.]+'
SIZE = re.compile(r'^[wh]=(?:fixed\(' + NUM + r'\)|fit>=' + NUM + r'<=' + NUM +
                  r'|(?:fit|grow)(?:>=|<=)' + NUM + r'|percent\(' + NUM + r'\))')
HEADER = re.compile(r'roots flow (\d+) floating (\d+) derived (\d+)(?: legacy (\d+))?$')
HEX = re.compile(r'^[0-9a-f]{8}$')
BANDS = {
    'CLIENT': {-6, 10, 20, 30, 40, 50, 110},
    'CELL': {20},
    'drawin': {25, 80},
    'WIBOX': {25},
    'WIBAR': {60},
    'POPUP': {80}, 'popup': {80}, 'TOOLTIP': {80},
    'LAUNCHER': {90}, 'NOTIFICATIONS': {90},
    'WALLPAPER': {-4},
    'LAYER_BACKGROUND': {-8}, 'LAYER_BOTTOM': {-2},
    'LAYER_TOP': {70}, 'LAYER_OVERLAY': {100},
    'cursor': {32767},
}
NAMES = ['R060.flow', 'R060.derived', 'R060.legacy', 'R050.unworded',
         'R020.word', 'R100.tiled', 'R090.band']


def band(tokens):
    for i, t in enumerate(tokens[:-1]):
        if t == 'band':
            return int(tokens[i + 1])
    return None


def unworded(tokens):
    for i, t in enumerate(tokens):
        if SIZE.match(t) and (i + 1 == len(tokens) or tokens[i + 1] not in WORDS):
            return True
    return False


def indent_of(text):
    return len(text) - len(text.lstrip(' '))


def flush(shadows, hit, owner=None):
    for n, text, b in shadows:
        if owner is None or b != owner - 1:
            hit('R090.band', n, text)


def scan(path, out):
    lines = path.read_text(errors='replace').splitlines()
    stack = []
    shadows = []
    realized = False

    def hit(name, n, text):
        out[name].append(f'{path}:{n}: {text}')

    for n, text in enumerate(lines, 1):
        tokens = text.split()
        if not tokens:
            continue
        if tokens[0] == 'output' and indent_of(text) == 0:
            flush(shadows, hit)
            stack, shadows, realized = [], [], False
            continue
        if text.strip() == 'realized:':
            realized = True
        if realized:
            continue
        m = HEADER.search(text)
        if m and tokens[0] == 'roots':
            if m[1] != '1':
                hit('R060.flow', n, text)
            if m[3] != '0':
                hit('R060.derived', n, text)
            if m[4] != '0':
                hit('R060.legacy', n, text)
            continue
        indent = indent_of(text)
        while stack and stack[-1][0] >= indent:
            stack.pop()
        role = tokens[0]
        debug = role.startswith('Clay__DebugView') or any(f == 'debug' for _, f in stack)
        under_workarea = any(f == 'workarea' for _, f in stack)
        if role.startswith('Clay__DebugView'):
            stack.append((indent, 'debug'))
        elif role == 'WORKAREA':
            stack.append((indent, 'workarea'))
        else:
            stack.append((indent, None))
        if not debug and unworded(tokens):
            hit('R050.unworded', n, text)
        if role == 'CLIENT' and 'fixed(' in text:
            if not CLIENT_WORDS & set(tokens):
                hit('R020.word', n, text)
            if under_workarea:
                hit('R100.tiled', n, text)
        b = band(tokens)
        if HEX.match(role) or debug:
            continue
        if role == 'SHADOW':
            shadows.append((n, text, b))
            continue
        if indent == 2:
            flush(shadows, hit, b or 0)
            shadows = []
        if b is not None and b not in BANDS.get(role, ()):
            hit('R090.band', n, text)
    flush(shadows, hit)


def gates(dirs):
    out = {name: [] for name in NAMES}
    for d in dirs:
        for path in sorted(Path(d).rglob('*.dump')):
            scan(path, out)
    for name in NAMES:
        dumps = len({e.split(':', 1)[0] for e in out[name]})
        print(f'{name} {len(out[name])} in {dumps} dumps')
        for e in out[name]:
            print(e)
    return 1 if any(out.values()) else 0


if __name__ == '__main__':
    if len(sys.argv) < 3 or sys.argv[1] != 'gates':
        sys.exit(__doc__.strip())
    sys.exit(gates(sys.argv[2:]))
