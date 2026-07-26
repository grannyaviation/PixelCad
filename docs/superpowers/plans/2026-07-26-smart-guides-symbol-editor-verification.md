# Smart Guides in the Symbol Editor — Manual Verification

Everything automatable passes: 12 `EEGridHelperTest` cases, 30 engine cases, eeschema and
pcbnew suites green. None of it exercises the GAL or the tool event loop, so nothing below is
covered by a test.

## Launch

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c ./build/kicad/kicad kicad/demos/cm5_minima/CM5_MINIMA_3.kicad_pro
```

Open the symbol editor (**Tools → Edit Symbol Libraries**, or double-click a symbol and press
`Ctrl+E`). `CM5IO.kicad_sym` in the demo has multi-pin parts worth testing on.

---

## Part 1 — the three checks that matter most

These are the three defects code review caught in the move tool. Each was a real bug in what
was first written, none is covered by any test, and each fails in a way that is easy to miss if
you are not looking for it. Do these first.

### 1. Rotate mid-drag

Grab a body rectangle, start dragging, and press `R` while still holding it.

- **Correct:** guides immediately re-align to the rotated shape.
- **The bug that was fixed:** the moving box was measured once at drag start, so after a
  rotate every guide was drawn against the *pre-rotation* box — roughly 100 mil off for a
  400×200 mil body — and the shape snapped to a phantom. Rotate and mirror mid-move reach a
  different tool through `SetPassEvent()`, which is why the first survey of this loop missed
  them entirely.

Repeat with `X` / `Y` (mirror). Then repeat with a **multi-item** selection, where the rotation
centre is the selection centre and every item moves.

### 2. Arrow-key nudge, then keep dragging with the mouse

Drag a pin, tap an arrow key once to nudge it, then carry on dragging with the mouse.

- **Correct:** guides keep appearing for the rest of the drag.
- **The bug that was fixed:** the axis lock is sticky and nothing resets it on mouse motion, so
  an unconditional guide-clear wiped every guide for the remainder of the gesture — silently,
  with no hint why. Guides are now dropped only when the lock actually overrode the cursor.

### 3. Dropping a pin exactly onto another pin

Drag a pin onto another pin's exact position — the gesture symbol authors use to stack hidden
power pins. Try it with the two pins **not** a whole grid step apart (e.g. 25 mil on a 50 mil
grid), which is what happens with legacy libraries.

- **Correct:** the pin lands exactly on the target. Pin-anchor snapping still wins for pins.
- **The bug that was fixed:** pins were given priority over anchor snapping. But a pin's guide
  box *is* its snap anchor — both are `GetPosition()` — and the guide path only accepts
  whole-grid-step offsets while the anchor lands exactly. So the guide suppressed the only
  mechanism that could reach the target, and the pin dropped 25 mil away: visually stacked,
  electrically two separate connection points.

---

## Part 2 — does the feature work

4. **Pin to pin.** Drag a pin until it is level with another → red dashed guide + snap.
5. **Equal pin pitch** — the original ask, applied inside a symbol. With two pins in a column,
   drag a third toward the position where its gap matches → snap plus two badges reading the
   same number.
6. **Three or more pins in a column** → a badge on **every** gap in the run, not just the pair
   the snap was computed from.
7. **Body outline to body outline.** Two rectangles, drag one until an edge lines up.
8. **Body edge to pin column.** Drag a rectangle so its edge meets the pins.
9. **Resize a body rectangle** (drag a corner) → the corner snaps to pins and to other shapes.
10. **Centre inside the body.** Draw a body rectangle, then drag a graphic or a text item around
    inside it → a guide line appears down the body's centre on whichever axis has centred, and
    the item snaps to it. Both axes centred gives **two lines, not a crosshair** — that is the
    change that removed the old no-axis crosshair.
11. **Pins must not move the body container.** Add pins sticking well past the rectangle, then
    repeat check 10. The centre must not shift: the container is the drawn outline, not the
    outline plus pin length.
12. **A symbol with no graphics yet** (pins only, no rectangle) must produce no container guide
    at all — not one at the origin. An invalid body box reaching the engine would read as a real
    container at (0, 0) and drag things toward it.

### Resize handles that are not corners — expected quirks, not bugs

10. A **circle's** radius handle and an **arc's** centre handle are not on the shape's visible
    boundary. Snapping them aligns the *handle*, so the visible edge can end up somewhere
    unexpected. Circle **centre** and arc **endpoints** behave sensibly. Reported by review as
    quirky-rather-than-wrong; per-handle filtering was judged out of scope. Report it only if
    it is worse than "surprising".

---

## Part 3 — rendering

This feature has shipped three separate rendering defects. Each looked like a different bug and
each was invisible to the test suite.

11. **The number must be readable.** White-on-red and red-on-red both shipped once. The badge is
    an unfilled dashed box with the number in guide red.
12. **The number must not be hidden** behind the shape underneath. The overlay pins itself to
    `GetMinDepth()`; the original bug was the GAL depth-testing the text against a filled badge
    drawn at the same depth, which no amount of recolouring fixed.
13. **Guide lines span the whole run** — from the first aligned item to the last, not just to
    the nearest one.
14. **Badge numbers must be plausible.** A 100 mil pin pitch reads `2.54`, not `0.03`. A wrong
    internal-units scale is a factor-of-100 error and this is where it shows.

---

## Part 4 — grid legality

15. After any snap, pins must still sit on the grid. A pin off-grid in a library part is a
    defect that propagates into every schematic that uses the symbol.
16. A **`≈` prefix** on a badge means the exact spacing was unreachable on the current grid and
    the snap went to the nearest legal position. Expect it on parts whose graphics are not on
    the working grid. This is designed behaviour — the alternative is a badge claiming an
    equality the grid refused.

---

## Part 5 — lifecycle and teardown

17. **Nothing left behind** after `Esc`, after a normal drop, and after switching tools mid-drag.
    Review traced all eleven exit paths and found teardown correct, but it depends on the
    grid helper being a stack local whose destructor unlinks the overlay — worth one look.
18. **Undo mid-drag** (`Ctrl+Z`) → no leftover dashed lines.
19. **Axis lock** after an arrow-key nudge suppresses guides on both axes while the lock is
    clamping. Deliberate: better no line than one drawn where the item cannot go.

---

## Part 6 — known ceilings, please don't report these

20. **Straight lines are alignment targets, circles and arcs use their bounding box.** A
    horizontal polyline has zero height; it is deliberately still a target, because dropping
    zero-extent shapes would lose every diode bar and ground symbol in the library.
21. **On a part with more than ~100 pins on one edge**, pins beyond roughly ±50 of wherever you
    grabbed stop taking part in guides. The neighbour sweep caps at 100 nearest. Review
    established this can only ever produce *fewer* guides, never a false pitch: for a dragged
    pin the cross-axis test degenerates to an exact coordinate match, so only a true column
    participates, and distance along a line is monotonic — so the cap trims contiguous ends and
    can never open a hole in the middle.
22. **Badges are always millimetres**, whatever your display units. Pre-existing across all
    three editors.
23. **A single-axis centre snap draws a full crosshair.** `CenterMarks` carries no axis.
24. **No preferences toggle.** Guides are on, with Shift as the bypass — which suppresses
    anchor snapping too, since they share it.

---

## Part 7 — regression sweep

25. Pin placement, pin editing and shape drawing behave exactly as before.
26. **In the schematic**, dragging a symbol still aligns to symbol *bodies* and never to
    individual pins, and hierarchical sheets still align to each other. This is the check that
    the two box rules did not leak into each other — the whole reason there are two.
27. Sheet resize still snaps in the schematic; shape resize there still does **not**.

---

## Part 8 — align commands (new, and nothing here is covered by a test)

`ALIGN_GEOM`'s arithmetic has unit tests. The two tools that call it have **none** — not the new
symbol editor one, and not the schematic one it was extracted from. All of this is hand-checked.

28. **The commands exist.** Select two or more items in the symbol editor → right-click → Align.
    Six entries: Left / Centre / Right, separator, Top / Middle / Bottom. Same menu as the
    schematic, because it reuses the same actions.
29. **Each moves on one axis only.** Align left must not shift anything vertically.
30. **The target is the item under the cursor.** Select three items, hover over the *middle* one,
    align left → the others move to it, not to the leftmost.
31. **Pins land on grid.** Align a set of pins whose target is off-grid → every pin ends on the
    grid, not on the target's exact ordinate. This is deliberate: a pin off-grid in a library
    part breaks every schematic that uses the symbol. Shapes and text are *not* re-snapped.
32. **Undo is one step.** After any align, one `Ctrl+Z` restores every item. The tool commits the
    whole `LIB_SYMBOL` once, so a partial undo means the commit was mis-scoped.
33. **A single-item selection does nothing** and pushes no undo entry.
34. **A derived symbol refuses.** Open a symbol inheriting from another; align must be
    unavailable or a no-op — its graphics belong to the parent.
35. **Text and fields are alignable**, unlike guide targets. Deliberate: the guides ignore text
    because font metrics make it a poor reference, but an explicit align command is the user
    asking for exactly that.
36. **In the schematic, all six align commands still behave as before.** The extraction rewired
    six working commands that have no test coverage — this is the only check that it did not
    regress a shipping feature. Include a case with a **locked** item in the selection: locking
    is how a user nominates the thing everything else lines up against, and that precedence was
    reproduced by hand.

---

Rendering issues trace to `common/preview_items/alignment_guide_geom.cpp`; the box rules to
`EE_GRID_HELPER::GetSymbolAlignmentBox` / `GetAlignmentBox`; move lifecycle to
`eeschema/tools/symbol_editor_move_tool.cpp`; resize to `eeschema/tools/sch_point_editor.cpp`.

For a trace of what the engine is deciding on each motion:

```bash
WXTRACE=KICAD_SNAP nix develop -c ./build/kicad/kicad <project> 2> /tmp/guides.log
grep "alignment guides" /tmp/guides.log
```

It logs the collected neighbour boxes once per drag, then per motion the moving box, the range,
the grid step, whether guides outrank anchors, and — per axis — any offset the grid rejected
with the value it wanted.
