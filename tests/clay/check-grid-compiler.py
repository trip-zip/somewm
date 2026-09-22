#!/usr/bin/env python3
"""Run serialized compiler declarations in the untouched solver.
Successful construction checks and unresolved contract comparisons are separate.
Expected pixels below are handwritten; never update goldens from this output.
"""
import math
from pathlib import Path
import re
import subprocess
import sys

binary, folder = sys.argv[1], Path(sys.argv[2])
results = {}
for source in sorted(folder.glob('*.tsv')):
    run = subprocess.run([binary, str(source)], capture_output=True, text=True, check=True)
    source.with_suffix('.boxes').write_text(run.stdout)
    results[source.stem] = {
        m[1]: tuple(map(float, m.groups()[1:]))
        for m in re.finditer(r'^(\w+).* box=([-\d.]+),([-\d.]+) ([-\d.]+)x([-\d.]+)$', run.stdout, re.M)
    }

def close(case, label, expected):
    actual = results[case][label]
    assert all(math.isclose(a, b, abs_tol=.002) for a, b in zip(actual, expected)), (case, label, actual, expected)

for n in (0, 1, 2, 7):
    actual = results[f'items-{n}']
    assert sum(k.startswith('widget') for k in actual) == n
    for i in range(n):
        close(f'items-{n}', f'widget{i+1}', ((i % 3)*305/3, (i//3)*25, 290/3, 20))
close('holes', 'widget2', (610/3, 25, 290/3, 20))
assert 'widget2' not in results['hidden']
close('reappeared', 'widget2', (610/3, 25, 290/3, 20))
close('resized', 'widget2', (135, 0, 130, 20))
close('removed', 'widget2', (305/3, 0, 290/3, 20))
close('added', 'widget2', (305/3, 0, 290/3, 20))
for i in range(4):
    close('expanded-uniform', f'widget{i+1}', ((i % 2)*100, (i//2)*40, 100, 40))
    close('authored-common-floors', f'widget{i+1}', ((i % 2)*75, (i//2)*35, 70, 30))
close('zero-minimum-holes', 'widget1', (610/3, 5, 290/3, 20))
print('PASS: pristine solver runs actual compiler declarations: counts, columns, gaps, holes, hidden/reappeared, resize/mutations, expanded sizing, zero-minimum occupancy')

# Existing contracts, deliberately NOT native-output expectations.
contracts = {
    'homogeneous-content': [(0,0,70,10),(75,0,70,10)],
    'content-both-axes': [(0,0,40,20),(45,0,70,20),(0,25,40,30),(45,25,70,30)],
    'homogeneous-both-axes': [(0,0,70,30),(75,0,70,30),(0,35,70,30),(75,35,70,30)],
    'independent-axes': [(0,0,80,20),(85,0,140,20),(0,25,80,30),(85,25,140,30)],
    'rounding': [(0,0,97,20),(102,0,97,20)],
}
for case, boxes in contracts.items():
    for i, expected in enumerate(boxes, 1):
        actual = results[case][f'widget{i}']
        if any(abs(a-b) > .002 for a,b in zip(actual,expected)):
            print(f'UNRESOLVED {case} widget{i}: contract={expected} upstream={actual}')
            break
close('minimum-shortage', 'widget1', (0,0,10,20))
close('minimum-shortage-both', 'widget1', (0,0,10,20))
# Check the empty logical cells as well as painted content. Six percentage
# slot widths and both row heights must survive shortage without a widget.
empty_source = (folder/'minimum-shortage-empty.tsv').read_text().splitlines()
slots = [line.split()[1] for line in empty_source if line.split()[4] == 'p']
rows = [line.split()[1] for line in empty_source if line.split()[8] == 'p']
assert len(slots) == 6 and len(rows) == 2
for i, label in enumerate(slots):
    close('minimum-shortage-empty', label, ((i % 3)*15, (i//3)*25, 10, 20))
for i, label in enumerate(rows):
    close('minimum-shortage-empty', label, (0, i*25, 40, 20))
print('PASS: authored 10x20 cell floors, empty/incomplete occupancy, 25x25 host shortage on both axes')
print('UNRESOLVED unequal intrinsic minima: a 70x50 widget still overhangs its homogeneous percentage slot; see intrinsic-shortage.boxes')
