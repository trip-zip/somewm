# Clay example goldens

These files specify doc-2's examples in `tests/_clay_golden.lua` vocabulary.
The reducer preserves sizing, source words, declaration order and widget
subtrees; it removes solved boxes and offsets. Tests check geometry, client
configures and pixels separately. `_clay_example.lua` optionally saves dumps
and PNGs to `SOMEWM_EXAMPLE_EVIDENCE`; it normalizes only the headless output
name so the same handwritten fixtures work with either backend.

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

Task 3's resizable-split gate is the existing tile mouse-resize interaction:
it changes `master_width_factor`. It does not add the schematic divider widget.
The band examples cover clients and wibars, not task 4's attachments. Existing
converted widget subtrees remain intact; wrapper folding belongs to task 10.
The background image lives on OUTPUT's grow/grow BACKGROUND child at band -10,
as established by task 2's wallpaper fix; the golden shows this representation.

## Historical limitation

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
