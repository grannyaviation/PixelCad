# Smart Alignment Guides in the Schematic — Manual Verification

Everything automatable passes. What remains needs a human dragging symbols.

## Launch

```bash
cd /home/asqude/projecte/PixelCad && direnv reload   # or: nix develop
nix develop -c ./run-kicad.sh kicad/demos/cm5_minima/CM5_MINIMA_3.kicad_pro
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
4b. **Centre on the page.** Drag a symbol toward the middle of the drawing sheet → a guide line
   appears down the page centre on the axis that has centred, spanning the page. Check it against
   the **page** centre, not the drawing-sheet border or the title block — the container is the
   paper size, origin at (0, 0).

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

## Off-grid warning

An amber circled `!` at the top-right of an item you are moving means one of its connection
points does not sit on the current grid. Only during a move/drag; it never shows at rest.

9b. **It fires on the part that caused your original bug.** Set the grid to 100 mil and move
    a symbol whose pin pitch is 50 mil → `!` for the whole drag, on every grid-legal
    position. This is the same condition that makes equal-spacing snapping refuse to
    engage, so the `!` is the visible half of check 9.
9c. **It clears when the problem clears.** Move a symbol that was merely *placed* off grid
    (a file made on a different grid) → the `!` shows at grab and disappears as soon as the
    first motion snaps it onto the grid. A `!` that survives a correct placement is a bug.
9d. **Switch the grid to 50 mil and repeat 9b** → no `!`. The check reads the grid you are
    actually on, not a fixed one.
9e. **Noise check — this is the one most likely to need changing.** A `drag` (`G`) hauls
    every connected wire into the selection, and a wire's endpoint sits on the off-grid pin,
    so you may get a cluster of `!` glyphs — one for the symbol and one per wire — instead of
    one. Each is truthful, but if it reads as clutter, say so: the fix is to skip items the
    drag added by itself, which the move tool already tracks in `m_dragAdditions`.
9f. **Notes lines and graphics never warn**, whatever their coordinates. They connect to
    nothing.

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

## Drawing-sheet snapping (logos and separator lines)

Automated coverage stops at `ALIGN_GEOM::CellAt` and `GetGraphicAlignmentBox`. Everything below
is hand-checked. Work at **100 mil**, which is the grid this was designed against.

19. **Logo centres in a title-block cell.** Place → Image, drag it over a title-block box → it
    snaps to the exact centre of the cell it is over, and a guide line shows the centring axis.
20. **The cell follows the logo.** Pick the logo up in the middle of the page and carry it slowly
    across the title block. The cell it targets must change as it crosses each divider. A logo
    that keeps being pulled back toward the cell it started in means the container was computed
    once at drag start.
21. **A page with no other graphics still works.** Delete every other graphic, then drag the only
    logo on the sheet. It must still centre. This is the case that fails if the container hook
    runs after the `HasInputs()` guard rather than before it, and it is the primary use case.
22. **Exactly centred, not nearly.** On 100 mil the logo must land on the cell centre, not 1.27 mm
    from it. If it sits visibly against an edge, the grid exemption is not reaching the move path.
23. **Symbols are still strict — check this immediately after 22.** Drag a symbol on the same
    100 mil grid; it must still refuse off-grid guide snaps and still align only to symbols and
    sheets. A symbol that suddenly snaps anywhere means `m_graphicsMode` is sticky, and the next
    drag after a logo is usually a symbol.
24. **Separator lines.** Draw a notes line, then drag it → it snaps to the drawing frame, to the
    centre of the drawing area, and to other separator lines.
25. **The centre is the frame's, not the paper's.** The line must centre on the drawn border, not
    a few millimetres outside it where the paper edge is.
26. **Endpoint drags too.** Drag one end of a separator line → it reaches the frame the same way
    the whole line does.
27. **No `!` on graphics.** However far off grid a logo or separator ends up, the off-grid warning
    must never appear on it — it reads connection points, and these have none.
28. **A custom `.kicad_wks` behaves the same.** Try a template with a real logo box.
29. **Nothing left behind** after `Esc` and after a normal drop.
30. **A logo aligns to other logos as well as to the cell.** Place two images, drag one until
    their top edges line up → a guide appears. If a logo snaps to the frame but never to another
    graphic, the drag-start neighbour list was lost — it is copied before being moved into the
    engine, and getting that order wrong empties it silently.
31. **Endpoint drags reach the cell too.** Drag one end of a separator line → it snaps to the
    frame edges and to the frame centre, the same targets the whole line gets. An earlier design
    excluded the centre for endpoint drags; that guard was removed because it could never fire.
32. **Known limitation, do not report.** Equal-spacing badges and centre-between-two snaps do
    not work for graphics. The drawing-sheet cell spans the page, so as an alignment neighbour it
    merges every other graphic into a single cluster and the equal-gap search never runs. Symbols
    are unaffected. Getting both would need the engine to distinguish "edge target" from "spacing
    participant", which it currently does not.
33. **Known quirk, do not report.** The drawing area is not always the whole frame. The title
    block's top edge only spans the right-hand part of the page, so a separator whose centre sits
    to the *left* of the title block gets a cell that includes the title-block band, while one to
    the right gets a cell stopping at it. Nudging a vertical separator across that ordinate can
    jump its vertical centring target by over a centimetre on A4. Full-width separators sit well
    left of the boundary and get the true frame centre, which is the case that matters.

## Hierarchical sheet pins

34. **Pin to pin across the sheet.** Open a sheet with hierarchical pins on both borders. Drag a
    left-border pin vertically → a horizontal guide appears when it comes level with a
    right-border pin, and it snaps there. Then the same along a top/bottom border, horizontally.
35. **Equal pin pitch.** With three or more pins on one border, drag a fourth → equal-spacing
    badges appear as it reaches the pitch of the run, the same way symbols get them.
36. **The dragged pin is not its own target.** The guide must never appear the instant the drag
    starts and stay put. A target at the dragged pin's own position is an offset of zero, which
    wins its axis unbeatably and would freeze the drag; the sweep excludes selected pins for that
    reason.
37. **A sheet drag is unaffected.** Drag the whole sheet → guides align sheet rectangles to
    symbol bodies as before, never to pin points.
38. **Wire ends still win.** Drag a pin to within a few mils of a loose wire end → it snaps to
    the wire end, not to a pin guide. Pins are connectable, so they keep anchor > guide.
39. **Known limitation, do not report.** Two pins only align if they already sit on the same
    lattice of the connection grid: offsets have to be whole grid steps, or the pin would land off
    grid and break its net. Two pin columns half a grid step apart therefore get no guide at all.
    The off-grid `!` glyph is what flags that case.
40. **The vertical guide along the border is expected.** Pins on the same border already share an
    ordinate, so a zero-offset guide line runs down the column for the whole drag. It is telling
    the truth — the pin *is* aligned with them.

## Field and free-text alignment

41. **Reference designator to reference designator.** Drag `U1`'s refdes off its symbol until it
    comes level with `U2`'s → a guide appears and it snaps. Then line up their left edges. The
    guide must sit on the drawn glyphs, not above or below them.
42. **Text aligns to bodies too.** Drag a refdes toward the top edge of any symbol body or the
    border of a hierarchical sheet → a guide appears on that edge. This is deliberate: text
    aligns to text *and* to bodies.
43. **Fields of an unselected symbol are targets.** The symbol whose refdes you are lining up
    against is not selected, and its fields are not in the R-tree at all. If nothing ever appears,
    the field expansion in `CollectAlignmentNeighbors()` is not running.
44. **Equal pitch across a refdes column.** With three refdes at even spacing, drag a fourth → the
    equal-spacing badges appear. They must still work here; that is the whole reason fields are
    denied the drawing-sheet container.
45. **Free text centres in the title block.** Place → Text, drag it over a title-block box → it
    centres in the cell, with a guide on the centring axis. Free text *does* get the container, so
    it correspondingly gets no equal-spacing badges — see 47.
46. **A whole symbol drag is unaffected — check this immediately after 41.** Drag the symbol
    itself, not its refdes → it aligns to symbol bodies and sheets as before, never to text, and
    still refuses off-grid snaps. A symbol that suddenly snaps anywhere means `m_textMode` is
    sticky between drags.
47. **Known limitations, do not report.** Free text gets no equal-spacing badges (the drawing-sheet
    cell merges every neighbour into one cluster — the same cause as item 32). Text boxes
    (Place → Text Box) and net labels get no alignment guides at all: neither is in scope here,
    and no other rule covers them either. And a guide moves when you rename a field: the box is
    the glyph extents, so `U1` and `U10` do not have the same right edge.

---

Rendering issues trace to `common/preview_items/alignment_guide_geom.cpp`;
snap behaviour to `eeschema/tools/ee_grid_helper.cpp`; lifecycle to
`eeschema/tools/sch_move_tool.cpp`.
