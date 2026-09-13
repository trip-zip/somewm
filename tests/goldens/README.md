# Clay example goldens

These files specify doc-2's examples in `tests/_clay_golden.lua` vocabulary.
The reducer preserves sizing, source words, declaration order and widget
subtrees; it removes solved boxes and offsets. Tests check geometry, client
configures and pixels separately. `_clay_example.lua` optionally saves dumps
and PNGs to `SOMEWM_EXAMPLE_EVIDENCE`; it normalizes only the headless output
name so the same handwritten fixtures work with either backend.
Task 10's batch fixtures save every independent shape difference and fail
after collecting the cases. A failed shape never counts as a passing case.
Evidence includes the full dump, reduced shape and captured pixels; none of
these artifacts changes an expectation.

| Task | Doc-2 example | Golden(s) | Integration test |
| --- | --- | --- | --- |
| 2 | Most basic representation per screen | most-basic-representation-per-screen | test-clay-golden-output-examples |
| 2 | Add some wibar widgets | add-some-wibar-widgets; basic-desktop (combined desktop) | test-clay-golden-output-examples; test-clay-golden-basic |
| 2 | Multiple wibars | multiple-wibars | test-clay-golden-output-examples |
| 2 | Adding a background to clay trees | adding-a-background-to-clay-trees | test-clay-golden-output-examples |
| 2 | Gaps, bar half | gaps-bar | test-clay-golden-output-examples |
| 2 | Layer shell, bar half | layer-shell-bar | test-clay-layer-bar |
| 2 | Ontop bar acceptance case | ontop-wibar | test-clay-golden-output-examples |
| 3 | Client is comprised of a titlebar plus surface buffer | client-titlebar | test-clay-golden-clients |
| 3 | Clients can also have n titlebars | clients-can-also-have-n-titlebars | test-clay-golden-clients |
| 3 | Nested client layouts | nested-client-layouts | test-clay-golden-clients |
| 3 | Resizable splits | resizable-splits-before; resizable-splits-after | test-clay-client-resize |
| 3 | Floating and fullscreen clients | floating-and-fullscreen-clients | test-clay-client-bands |
| 3 | Gaps, workarea half | client-gaps | test-clay-golden-clients |
| 3 | Bands | bands-normal; bands-raised; bands-ontop | test-clay-client-bands |
| 4 | Floating widget anchored to another widget | floating-widget-anchored-to-another-widget | test-clay-attachment-popup |
| 4 | Hover tooltip | hover-tooltip | test-clay-attachment-tooltip |
| 4 | Notification stack | notification-stack | test-clay-attachment-notifications |
| 4 | Centered launcher | centered-launcher | test-clay-attachment-launcher |
| 4 | Layer shell, overlay half | layer-shell-overlay | test-clay-attachment-layer-overlay |
| 10 | Pinned bundled bar and titlebar | tidy-bundled-wibar; tidy-bundled-titlebar | test-clay-tidy-bundled |
| 10 | Fold/retain boundaries, spacers, systray and native overlap | tidy-background-padding; tidy-padding-background; tidy-nested-backgrounds; tidy-shared-click-box; tidy-empty-and-spacer; tidy-systray-empty; tidy-systray-two; tidy-clay-overlap | test-clay-tidy-widgets |
| 10 | Shared grid tracks, independent axes, counts, holes, spans, wrapping, borders, overlap and nesting | all19 tidy-grid-* files | test-clay-tidy-grid |
| 10 | Stock-client declarations | tidy-fair-four; tidy-spiral-three; tidy-corner-nw-three; tidy-max-two; tidy-magnifier-three | test-clay-tidy-client-layouts |

Task 3's resizable-split gate is the existing tile mouse-resize interaction:
it changes `master_width_factor`. It does not add the schematic divider widget.
Task 3's band examples cover clients and wibars. Task 4's additional
`test-clay-attachment-bands` checks actual overlap pixels through bands 60, 80,
90 and 100, including declaration order within 90. Existing
attachment behavior checks remain required while task10 folds widget subtrees.
The background image lives on OUTPUT's grow/grow BACKGROUND child at band -10,
as established by task 2's wallpaper fix; the golden shows this representation.

## Historical limitation

Task10's55 complete expected texts were accepted before the first feature
commit, which contains only those text files. They replace21 existing shapes
and add34; the two resizable-split goldens are unchanged. Fixtures follow in
the next commit, before production declaration changes. The board's
evidence/task-10/grid-review packet contains the exact handwritten text and
the raw geometry, identity, input, pixels and performance requirements that
reduced shapes cannot express. The new grid text supersedes both preparation
grid candidates and preserves shared column alignment.

The original basic-desktop and three client goldens preceded their respective
implementations (the tasks retain the pre-squash red-test evidence). The other
fourteen files were handwritten during closeout, after the implementation.
They add regression coverage; they cannot retroactively meet doc-1's requirement
that every example golden be committed before its implementation. No recording
mode was used to create these files. Initial authoring corrections concerned
the wallpaper-image vocabulary, an explicit border in the resize fixture,
and an unnecessary fullscreen backing element in the expected fixture.

For new implementation, write and review the expected text first and keep the
test red until the declaration matches. `SOMEWM_GOLDEN=record` is only for a
shape already accepted; it is not a way to resolve a failing example.

## Task 4 evidence contract

All five task-4 expectations were shown for review and handwritten in the first
step commit, before fixtures or implementation. Every fixture first failed at
its first differing line. These golden files have remained unchanged.

The reduced vocabulary omits target IDs, attach points, offsets, pointer mode
and boxes. The fixtures therefore also assert those raw fields, actual
`root.content()` pixels, real tooltip pointer input, notification dismissal and
reflow, and layer-client configure sizes. The popup fixture changes the bar
layout and checks the painted attachment follows its widget. Launcher coverage
also exercises the real menubar/prompt path; separate menu, decoration, protocol
margin and XDG composition tests preserve their contracts.

Explicit tooltip visibility requests still require a widget opener and Clay's
previous-frame hover to declare a tooltip. A manual show can use the widget
currently under the pointer; no opener means no tooltip declaration.

The local review and original red evidence live in the companion board under
`evidence/task-4/`. No recording mode, wrapper folding or task-10 rewrite is
part of this task.
