# Snapping Graphics to the Drawing Sheet — Design

Two requests, one mechanism:

1. Drop a logo into a title-block cell and have it centre there.
2. Draw separator lines that divide a schematic into visual areas, snapping to the page
   border and the page centre.

Both need the same thing the alignment guides have never had: **the drawing sheet's own drawn
geometry as alignment targets**. Everything else follows from that.

This extends the smart alignment guides described in
`docs/superpowers/specs/2026-07-23-smart-guides-design.md`. Read that first; this document
assumes `ALIGNMENT_GUIDE_ENGINE`, `EE_GRID_HELPER::CollectAlignmentNeighbors` and the
container/centring semantics.

## Decisions taken

| Question | Answer | Consequence |
|---|---|---|
| Where does the logo live | On the schematic, as `SCH_BITMAP` | One page only. Not sheet 2, not the PCB. The Drawing Sheet Editor is untouched. |
| Do separator lines and symbols see each other | No — lines align to the sheet and to other lines; symbols behave exactly as today | No new guides on any symbol drag. Enforced structurally, by rule selection, not by filtering. |
| May these snaps land off grid | No | A logo lands within half a graphics-grid step of the cell centre, not exactly on it. |
| How much of the title block is understood | The cell under the cursor, derived from the drawn segments | Works with any custom `.kicad_wks`, not just KiCad's default. |

### On "perfectly centred"

The request was a logo *perfectly* centred. Grid-legal snapping cannot deliver that: title-block
cells sit at coordinates like 5.5 mm from the page corner, which is not a whole step of any
sensible schematic grid. The snap therefore lands at the nearest grid position to the cell
centre — up to 0.635 mm off on a 50 mil grid.

This is a deliberate choice, not an oversight. Two things make it acceptable:

- The engine already handles it. `alignment_guide_engine.cpp` pushes an exact `KIND_CONTAINER`
  candidate and then a grid-rounded fallback immediately after it (`push` / `pushRounded`,
  around line 207). Choosing grid-legal means **no engine change is required at all**.
- KiCad's grids are per item class. A graphics-grid override (Preferences → Grids) of 5 mil puts
  the logo within 0.06 mm of centre while wires stay on 100 mil. That is the practical route to
  a visually perfect result without weakening grid discipline anywhere it matters.

If the residual offset turns out to be visible in practice, the escape hatch is narrow and
already designed for: `computeAlignmentGuideSnap` takes `aGridStep` as
`std::optional<VECTOR2I>`, so passing `std::nullopt` for a graphics-only selection relaxes the
rule for exactly the items that connect to nothing. That is a one-line change, deliberately not
being made now.

## Architecture

Five parts. Three are in eeschema; the other two are small additions in `common` — a pure
geometry function next to the one the align commands already use, and a three-line accessor on
the drawing sheet. `ALIGNMENT_GUIDE_ENGINE` itself is not touched.

### 1. Cell arithmetic — `ALIGN_GEOM::CellAt`

Added to the existing `ALIGN_GEOM` namespace in `include/tool/align_geom.h` /
`common/tool/align_geom.cpp` rather than a new file: it is the same kind of thing (pure,
frame-agnostic geometry serving the alignment tools), it lands in the existing `AlignGeom*`
test suite, and it needs no new CMake entry.

```cpp
/**
 * The cell of a rectilinear arrangement of segments that contains aPoint.
 *
 * @param aSegments axis-aligned segments; anything else is ignored
 * @return the bounding cell, or nullopt when aPoint is unbounded on any side or the
 *         resulting cell is degenerate
 */
std::optional<BOX2I> CellAt( const std::vector<SEG>& aSegments, const VECTOR2I& aPoint );
```

For each of the four sides, the bound is the nearest segment beyond the point that straddles it
on the other axis:

- right = `min{ s.A.x : s vertical, s.A.x > aPoint.x, s spans aPoint.y }`
- left = `max{ s.A.x : s vertical, s.A.x < aPoint.x, s spans aPoint.y }`
- bottom and top by symmetry over horizontal segments

"Straddles" is inclusive (`min <= p <= max`); the beyond-the-point comparison is strict, so a
point resting exactly on a divider falls into the cell on one side rather than collapsing to
zero width. Any side with no candidate means the point is not inside a closed cell, and the
function returns `nullopt` — a container inferred from three sides would drag the item toward a
boundary that does not exist.

No KiCad state, no view, no tool. Headless-testable, like `ALIGN_GEOM::Deltas`.

### 2. Segment source — `DS_PROXY_VIEW_ITEM::BuildDrawList`

`DS_DRAW_ITEM_LIST::BuildDrawItemsList()` is public, but seeding the list correctly needs a
dozen fields that only `DS_PROXY_VIEW_ITEM` holds (`m_project`, `m_pageInfo`, `m_fileName`,
the variant strings, the pen size from the render settings). Its `buildDrawList()` already does
exactly that seeding and is `protected`.

Rebuilding that recipe by hand in eeschema would be duplicated, would drift, and would risk
resolving text variables against a null project. Instead, expose what `ViewDraw` already does:

```cpp
// include/drawing_sheet/ds_proxy_view_item.h, public
/**
 * Build the drawn geometry of the current page into aDrawList.
 *
 * The same list ViewDraw() renders, so callers that snap to sheet geometry snap to exactly
 * what the user sees.
 */
void BuildDrawList( KIGFX::VIEW* aView, DS_DRAW_ITEM_LIST* aDrawList ) const;
```

A three-line forwarder to `buildDrawList( aView, m_properties, aDrawList )`. `ViewDraw` builds
this list on every frame already, so building it once per drag costs nothing measurable.

`EE_GRID_HELPER::collectDrawingSheetSegments()` then walks it via `GetFirst()` / `GetNext()`:

- `WSG_LINE_T` → one `SEG` from `GetStart()` / `GetEnd()`
- `WSG_RECT_T` → four `SEG`s from the corners
- text, bitmaps and polygons ignored — they are content, not structure

The page frame comes free: KiCad's default sheet draws it as
`(rect (start 0 0 ltcorner) (end 0 0) (repeat 2) (incrx 2) (incry 2))`, so the border is already
in the segment set. So is the big drawing area above the title block — it is simply the largest
cell, which is what separator lines want to centre in.

Reached the way other eeschema tools reach it, which is established:
`SCH_BASE_FRAME::GetCanvas()->GetView()->GetDrawingSheet()` (see `sch_edit_frame.cpp:2188`,
`sch_edit_tool.cpp:566`). `EE_GRID_HELPER` already obtains the frame this way for the page
container.

Collected once, in `CollectAlignmentNeighbors`, and cached in `m_sheetSegments`.

### 3. A third box rule — `GetGraphicAlignmentBox`

Alongside `GetAlignmentBox` (schematic bodies) and `GetSymbolAlignmentBox` (symbol editor):

```cpp
/**
 * The box alignment guides measure a *schematic graphic* by, or nullopt.
 *
 * Third rule rather than an extension of the other two, for the same reason there are already
 * two: which rule applies is decided by what is being dragged, so a symbol drag can never
 * acquire a graphic target and vice versa.
 */
static std::optional<BOX2I> GetGraphicAlignmentBox( const EDA_ITEM* aItem );
```

- `SCH_BITMAP_T` → `GetBoundingBox()`
- `SCH_LINE_T` **when `!IsConnectable()`** → box over both endpoints. A horizontal separator has
  zero height; that is deliberate, the same call already made for flat polylines in the symbol
  editor, because dropping zero-extent shapes would drop the entire use case.
- `SCH_SHAPE_T` → bounding box deflated by `std::max( 0, GetWidth() ) / 2`, as the symbol rule
  does, so the box is the rectangle actually drawn rather than one inflated by half a stroke
- everything else → `nullopt`

`SCH_TEXT_T` and `SCH_TEXTBOX_T` are excluded, consistent with both existing rules: font metrics
make text a poor alignment reference.

### 4. Rule selection and the moving cell

`CollectAlignmentNeighbors( aSkip )` chooses one mode per drag:

| Condition | Neighbours | Containers |
|---|---|---|
| Symbol editor | `GetSymbolAlignmentBox` | symbol body outline |
| Schematic, `aSkip` non-empty and every item has a graphic box | `GetGraphicAlignmentBox` | drawing-sheet cell **only** |
| Schematic, otherwise | `GetAlignmentBox` (today) | page (today) |

The third row is today's behaviour, unchanged. The second row is where the two new features
live. An empty selection falls to the third row, as it does now.

Graphics mode uses the cell *instead of* the page container, not alongside it. The page
container is the paper rectangle, origin `(0, 0)` to the paper size; the drawing frame is inset
from it by the sheet's margins. Offering both would put two centring candidates several
millimetres apart, one of them on an edge that is never drawn. The drawing area above the title
block is itself a cell — bounded by the frame on all four sides — so "centre on the page" is
still available, measured against the border the user can actually see.

**The cell must follow the cursor.** Containers are otherwise set once at drag start, but a logo
is picked up somewhere on the page and *carried* to the corner box — a cell computed at drag
start is the wrong cell for the entire gesture. This is the one non-obvious part of the design.

`GRID_HELPER::computeAlignmentGuideSnap` already extrapolates the moving box on every motion.
Add a hook there:

```cpp
/// Called with the extrapolated moving box before each snap is scored, for containers that
/// depend on where the selection currently is rather than where it started.
virtual void updateDynamicContainers( const BOX2I& aMovingBox ) {}
```

`EE_GRID_HELPER` overrides it: when graphics mode is active, `CellAt( m_sheetSegments,
aMovingBox.Centre() )` and hand the result to the engine as the container set; `nullopt` clears
it. Roughly six lines. `GRID_HELPER` stays free of drawing-sheet knowledge and the box
extrapolation is not duplicated.

### 5. Tool wiring

`sch_move_tool.cpp` builds `guideBBox` from `GetAlignmentBox` only, so a graphics selection
currently produces an invalid box and falls into `ClearMoveContext()` — graphics get no guides
at all today. It learns the graphics rule, using the same merged walk.

`PreferGuides` is set for a graphics-only selection: a logo has no business snapping to a pin,
so an available guide should outrank anchor snapping, exactly as it does for whole symbols.

Separator-line endpoints are edited through `SCH_POINT_EDITOR`, which already calls
`AlignPointToGuides` for sheet resize. Graphic lines join that path, so dragging an endpoint
snaps to the sheet too.

## Testing

Automatable:

- `ALIGN_GEOM::CellAt` in the `AlignGeom*` suite: a plain grid of dividers; a point outside all
  segments; a point unbounded on exactly one side; a point resting on a divider; a degenerate
  (zero-area) cell; segments that are not axis-aligned, which must be ignored rather than
  corrupt a bound.
- `GetGraphicAlignmentBox` in `EEGridHelperTest`, mirroring the existing box-rule cases:
  bitmap, horizontal graphic line (zero height, accepted), connectable line (rejected), shape
  stroke deflation, text (rejected).
- Extend `TheTwoAlignmentRulesDoNotOverlap` to three rules: no item type may be accepted by more
  than one.

Not automatable, and consistent with the rest of this feature — everything touching the GAL or
the tool event loop is hand-checked. New checklist entries go in
`docs/superpowers/plans/2026-07-25-smart-guides-schematic-verification.md`:

- a logo carried across the page picks up the cell it is *currently* over, not the one it
  started in — the defect part 4 exists to prevent
- the residual grid offset is visible and expected; `≈` on any badge means the same thing
- a separator line snaps to the drawing frame, to the centre of the drawing area, and to other
  separator lines — and the centre it finds is the **frame** centre, not the paper centre a few
  millimetres outside it
- dragging a **symbol** shows no drawing-sheet guides whatsoever, which is the check that rule
  selection did not leak
- a custom `.kicad_wks` with a real logo box behaves the same as the default sheet
- nothing is left painted after `Esc` or a normal drop

## Out of scope

- The Drawing Sheet Editor (`pl_editor`). A logo placed there would appear on every page and on
  the PCB; that was considered and deliberately not chosen.
- pcbnew.
- Any change to symbol, pin, wire or sheet behaviour.
- Any relaxation of grid legality.
- Snapping to title-block *dividers* as edges. Cells are containers only; adding every divider
  as an alignment edge puts many competing candidates within a few mm of each other.
