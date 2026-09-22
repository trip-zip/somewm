# Clay example goldens

These files specify the integration examples in `tests/_clay_golden.lua` vocabulary.
The reducer preserves sizing, source words, declaration order and widget
subtrees; it removes solved boxes and offsets. The dump walks Clay's own
tree roots in the order of the command array: Clay's root container holds
the output, and every floating element is a root of its own, listed after
the roots below its band and before the roots above it, so a float never
prints under the element it was declared in. Tests check geometry, client
configures and pixels separately. `_clay_example.lua` optionally saves dumps
and PNGs to `SOMEWM_EXAMPLE_EVIDENCE`; it normalizes only the headless output
name so the same handwritten fixtures work with either backend.
The `test-clay-tidy-*` batch fixtures save every independent shape difference and fail
after collecting the cases. A failed shape never counts as a passing case.
Evidence includes the full dump, reduced shape and captured pixels; none of
these artifacts changes an expectation.

| Example | Golden(s) | Integration test |
| --- | --- | --- |
| Most basic representation per screen | most-basic-representation-per-screen | test-clay-golden-output-examples |
| Add some wibar widgets | add-some-wibar-widgets; basic-desktop (combined desktop) | test-clay-golden-output-examples; test-clay-golden-basic |
| Multiple wibars | multiple-wibars | test-clay-golden-output-examples |
| Adding a background to clay trees | adding-a-background-to-clay-trees | test-clay-golden-output-examples |
| Gaps, bar half | gaps-bar | test-clay-golden-output-examples |
| Layer shell, bar half | layer-shell-bar | test-clay-layer-bar |
| Ontop bar acceptance case | ontop-wibar | test-clay-golden-output-examples |
| Client is comprised of a titlebar plus surface buffer | client-titlebar | test-clay-golden-clients |
| Clients can also have n titlebars | clients-can-also-have-n-titlebars | test-clay-golden-clients |
| Nested client layouts | nested-client-layouts | test-clay-golden-clients |
| Resizable splits | resizable-splits-before; resizable-splits-after | test-clay-client-resize |
| Floating and fullscreen clients | floating-and-fullscreen-clients | test-clay-client-bands |
| Gaps, workarea half | client-gaps | test-clay-golden-clients |
| Bands | bands-normal; bands-raised; bands-ontop | test-clay-client-bands |
| Floating widget anchored to another widget | floating-widget-anchored-to-another-widget | test-clay-attachment-popup |
| Hover tooltip | hover-tooltip | test-clay-attachment-tooltip |
| Notification stack | notification-stack | test-clay-attachment-notifications |
| Centered launcher | centered-launcher | test-clay-attachment-launcher |
| Layer shell, overlay half | layer-shell-overlay | test-clay-attachment-layer-overlay |
| Pinned bundled bar and titlebar | tidy-bundled-wibar; tidy-bundled-titlebar | test-clay-tidy-bundled |
| Fold/retain boundaries, spacers, systray and native overlap | tidy-background-padding; tidy-padding-background; tidy-nested-backgrounds; tidy-shared-click-box; tidy-empty-and-spacer; tidy-systray-empty; tidy-systray-two; tidy-clay-overlap | test-clay-tidy-widgets |
| Shared grid tracks, independent axes, counts, holes, spans, wrapping, borders, overlap and nesting | all19 tidy-grid-* files | test-clay-tidy-grid |
| Stock-client declarations | tidy-fair-four; tidy-spiral-three; tidy-corner-nw-three; tidy-max-two; tidy-magnifier-three | test-clay-tidy-client-layouts |

The resizable-split fixture exercises tile mouse resizing through
`master_width_factor`; it does not add a divider widget. The client-band
fixtures cover clients and wibars. `test-clay-attachment-bands` also checks
overlap pixels through bands 60, 80, 90 and 100, including declaration order
within 90. Attachment behavior checks complement reduced tree comparisons.

The output background image belongs to OUTPUT, with `image` in its reduced
representation. It has no separate BACKGROUND element or floating root.
The centered clock remains a separate float, alongside any wallpaper widget tree.

## Expectations

Golden text specifies the declaration structure; it does not specify all
geometry, identity, input, pixel or performance behavior. The integration
fixtures assert those properties separately. Shared grid columns must stay
aligned even when individual cells contain different widgets.

Write expected text independently of the implementation and keep a failing
comparison visible until the declaration matches. `SOMEWM_GOLDEN=record`
exports a shape; its output must not automatically replace an expectation
or resolve a failing example.

## Attachment checks

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
