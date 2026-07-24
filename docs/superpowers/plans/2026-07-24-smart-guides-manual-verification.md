# Smart Alignment Guides — Manual Verification Checklist

Everything automatable is done: 19 engine unit tests, full `qa_common` (1302 cases,
one pre-existing unrelated failure), full `qa_pcbnew`, `pcbnew` builds and starts
clean on a real board. What remains genuinely needs a human dragging things.

## Launch

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c ./build/pcbnew/pcbnew kicad/demos/cm5_minima/CM5_MINIMA_3.kicad_pcb
```

(Any `kicad/demos/*/*.kicad_pcb` works; that one is dense enough to be a fair test.)

## Does the feature work at all

1. **Alignment.** Drag a footprint until an edge or centre lines up with another →
   a dashed magenta guide line appears and the footprint snaps to it.
2. **Equal spacing** (the original ask). Place A and B; drag C toward the position
   where C's gap to B equals A→B → snaps, and **two badges appear showing the same
   mm value**.
3. **Centre between.** Drag a footprint into the gap between two others → snaps
   centred, badges on both sides.
4. **Centre on board.** Drag near the board-outline centre → crosshair mark + snap.
5. **Shift suppresses.** Hold Shift while dragging → guides vanish, no guide snapping.
6. **Esc.** Cancel mid-drag → guides vanish, footprint returns, next drag is clean.
7. **No regression.** Pads, tracks and vias still snap exactly as before — item
   anchors must beat guides.

## Bugs the code review predicted — worth targeting

8. **Alignment accuracy.** The guide must land on the **drawn** courtyard edge, not a
   fraction of a millimetre outside it. A consistent outward offset means the moving
   selection is being measured with the wrong bbox rule.
9. **Constant drag offset.** Do a slow drag and then a fast flick. If the footprint
   settles slightly *past* the alignment — by roughly one mouse-motion's worth, and
   worse on a flick — the bbox/cursor pairing is wrong.
10. **Rotate mid-drag.** Press R while dragging. Guides should re-derive from the
    rotated box and keep working without a stall.
11. **Move Individually** with 3+ items: each item gets its own guides, and an
    already-placed item is not offered as its own alignment target.
12. **No leaked overlay.** Drag → Esc → immediately switch to the point editor or a
    drawing tool. No lingering guide lines, no nonsense snaps.

## Known open questions (design decisions, not defects)

13. **Snap radius may be too tight.** It is `min(25 px, one grid step)`. On a 0.1 mm
    grid a guide only engages within 0.1 mm, so guides may almost never appear.
    If they feel unreachable, the fix is a dedicated guide radius decoupled from the
    grid — deliberately not added until seen.
14. **Full crosshair on a single-axis centre snap.** If only one axis centres on the
    board, a full crosshair still draws and may read as "centred both ways".
    Needs an engine change (`CenterMarks` carries no axis) — decide once seen.
15. **Vertical-gap badges.** Badge pills are always horizontal (as in Figma; rotated
    numerals read worse), so for a vertical gap the pill sits across its guide line
    and may occlude it. Fix would be a small perpendicular offset, not rotation.
16. **Badge collision.** Two badges landing close together are not de-conflicted.

## Performance

17. Zoom out over the densest area and drag continuously for ~10 s. Compare against
    holding Shift (which takes the old code path). Any perceptible added lag is a
    failure — `CollectAlignmentNeighbors` should run once per drag, not per motion.

Record pass/fail. Rendering issues trace to `common/preview_items/alignment_guide_geom.cpp`,
snap behaviour to `pcbnew/tools/pcb_grid_helper.cpp`, lifecycle to
`pcbnew/tools/edit_tool_move_fct.cpp`.
