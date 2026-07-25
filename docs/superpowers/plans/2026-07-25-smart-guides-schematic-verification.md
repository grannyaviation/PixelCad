# Smart Alignment Guides in the Schematic — Manual Verification

Everything automatable passes. What remains needs a human dragging symbols.

## Launch

```bash
cd /home/asqude/projecte/PixelCad && direnv reload   # or: nix develop
nix develop -c ./build/kicad/kicad kicad/demos/cm5_minima/CM5_MINIMA_3.kicad_pro
```

Open the schematic. Your two `ComputeModule5-CM5` symbols are the ideal test pair —
identical symbols, so exact alignment between them **is** a whole number of grid steps.

## Does it work

1. **Horizontal alignment.** Select the left CM5, press `M`, drag it until its top or
   centre lines up with the right one → dashed magenta guide line + snap.
2. **Vertical alignment.** Same, lining up left/right edges.
3. **Equal spacing** (your original ask). With two symbols placed, drag a third toward
   the position where its gap equals the existing one → snap plus **two badges showing
   the same distance**.
4. **Centre between.** Drag a symbol into the gap between two others → centres, badges
   both sides.

## The thing most likely to be wrong

5. **Badge numbers must be plausible.** A 100 mil gap should read about `2.54`, not
   `0.03`. That scale bug was found and fixed late; this is the check that confirms it.
6. **Guides must sit on the symbol body outline**, not on a halo outside it. If they
   look consistently offset by the reference-designator or pin overhang, the moving
   selection and the neighbours are being measured by different rules.
7. **Fast flick.** Slow drags hide a cursor-pairing error. Flick a symbol quickly — the
   guides must track it exactly, not lag by the flick distance.

## Grid legality — the one that corrupts data if wrong

8. After any guide snap, confirm pins still land on grid and **wires stay connected**.
   Nothing should ever sit between grid points. This is the whole reason guides reject
   rather than round.
8b. **Hierarchical sheets.** The big labelled boxes align to each other and to components,
    measured by the drawn rectangle — guides must sit on the border, not on the sheet name
    above it or the file name below it.
9. Aligning two **different** symbols often won't engage at all. That is designed
   behaviour, not a bug — exact alignment there would land off-grid, and silence is
   preferred to a guide line that lies.

## Lifecycle

10. **Rotate mid-drag.** Press `R` while dragging → guides re-align to the rotated body
    immediately, not to where it used to be. Same with `M`/`Y` mirror, and with a
    right-click label conversion mid-move.
11. **Arrow-key nudge.** Drag until a guide paints, then nudge with an arrow key → the
    guide must vanish at once, not linger while the symbol walks away.
12. **Nothing left behind.** After Esc, after a normal drop, and after switching to
    another tool mid-move — no leftover dashed lines, no phantom snapping when you then
    draw a wire.
13. **Groups.** Drag a group → it must not align to its own members.

## Known and expected — please don't report these as new

14. **Axis lock is sticky.** After any arrow-key nudge, mouse movement stays locked to
    one axis for the rest of that move. This is upstream KiCad behaviour (commit
    `823f0b5079`), unrelated to guides.
15. While an axis lock is active, guides are suppressed on **both** axes. Deliberate:
    better no guide than one drawn where the symbol cannot go.
16. Badges display millimetres regardless of your unit preference. Known simplification.
17. Guide reach is at least ±2 grid steps. On a fine grid it is wider.

## Regression sweep (a minute)

18. Plain move, drag, and BREAK (several successive break clicks) behave exactly as
    before. Pin/wire/junction snapping unchanged — item anchors still beat guides.

---

Rendering issues trace to `common/preview_items/alignment_guide_geom.cpp`;
snap behaviour to `eeschema/tools/ee_grid_helper.cpp`; lifecycle to
`eeschema/tools/sch_move_tool.cpp`.
