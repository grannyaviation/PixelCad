# Drawing-Sheet Snapping for Schematic Graphics — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a logo centre itself in a title-block cell and let graphic separator lines snap to the drawing frame, by feeding the drawing sheet's own drawn geometry into the existing alignment-guide machinery.

**Architecture:** The drawing sheet is reduced to a list of axis-aligned segments once per drag. A pure function turns those segments plus a point into the cell containing it, and that cell is handed to `ALIGNMENT_GUIDE_ENGINE` as a container — recomputed on every motion, because the user carries the logo across the page. Which of three box rules applies is decided once per drag from what is being dragged, so symbol drags are bit-for-bit unaffected. `ALIGNMENT_GUIDE_ENGINE` itself is not modified.

**Tech Stack:** C++20, KiCad master (10.99), Boost.Test (`qa_common`, `qa_eeschema`), CMake + Ninja inside a Nix dev shell.

**Spec:** `docs/superpowers/specs/2026-07-27-logo-and-separator-snapping-design.md`

## Global Constraints

- Schematic internal units are 100 nm (`schIUScale`, `SCH_IU_PER_MM = 1e4`). Never hardcode a scale.
- KiCad house style: `aFoo` for parameters, `m_foo` for members, 4-space indent, 100-column lines, braces on their own line.
- Every new file needs the GPL header block copied verbatim from a neighbouring file in the same directory.
- **No behaviour change for symbols, pins, wires, labels or sheets.** Any task that alters what a symbol drag does has gone wrong.
- Build: `nix develop -c cmake --build build -j6 --target <target>` from `/home/asqude/projecte/PixelCad`.
- Test: `nix develop -c ./build/qa/tests/common/qa_common --run_test='<filter>'` (likewise `qa/tests/eeschema/qa_eeschema`).
- The pcbnew grid-helper suite is `PCBGridHelper*` and reports 23 cases. `PcbGridHelper*` matches almost nothing and prints a false green.
- **Never launch a GUI** (`kicad`, `eeschema`, `pcbnew`). They open on the user's real desktop. Interactive verification is the user's job.
- Commit to the `kicad/` repo (a git clone, branch `feature/smart-guides`), not the outer `PixelCad` repo. Docs go in the outer repo.

---

### Task 1: `ALIGN_GEOM::CellAt`

Pure geometry: given axis-aligned segments and a point, return the cell that bounds it. No KiCad state, headless-testable.

**Files:**
- Modify: `kicad/common/tool/align_geom.h` (append to the `ALIGN_GEOM` namespace)
- Modify: `kicad/common/tool/align_geom.cpp`
- Test: `kicad/qa/tests/common/test_align_geom.cpp` (already in `qa/tests/common/CMakeLists.txt:34`; no CMake change)

**Interfaces:**
- Consumes: nothing.
- Produces: `std::optional<BOX2I> ALIGN_GEOM::CellAt( const std::vector<SEG>& aSegments, const VECTOR2I& aPoint )`. Task 4 is its only caller.

- [ ] **Step 1: Write the failing tests**

Append to `kicad/qa/tests/common/test_align_geom.cpp`, immediately before `BOOST_AUTO_TEST_SUITE_END()`:

```cpp
// A title block is a rectangle plus a handful of dividers; the "box in the corner" a user wants
// to centre a logo in is never an object, only the region those lines happen to enclose.
BOOST_AUTO_TEST_CASE( CellAtFindsTheEnclosingRegion )
{
    // Verticals at x = 0, 10, 20, 30; horizontals at y = 0, 10, 20.  Six cells.
    std::vector<SEG> segs;

    for( int x : { 0, 10, 20, 30 } )
        segs.emplace_back( VECTOR2I( x, 0 ), VECTOR2I( x, 20 ) );

    for( int y : { 0, 10, 20 } )
        segs.emplace_back( VECTOR2I( 0, y ), VECTOR2I( 30, y ) );

    const std::optional<BOX2I> cell = ALIGN_GEOM::CellAt( segs, VECTOR2I( 15, 5 ) );

    BOOST_REQUIRE( cell.has_value() );
    BOOST_CHECK_EQUAL( cell->GetOrigin(), VECTOR2I( 10, 0 ) );
    BOOST_CHECK_EQUAL( cell->GetEnd(), VECTOR2I( 20, 10 ) );
}


// Unbounded on any side means the point is not inside a closed cell.  Returning a box built from
// three sides would invent a fourth edge and drag the item towards a boundary that is not there.
BOOST_AUTO_TEST_CASE( CellAtRejectsUnboundedPoints )
{
    const std::vector<SEG> box = { SEG( VECTOR2I( 0, 0 ), VECTOR2I( 10, 0 ) ),
                                   SEG( VECTOR2I( 10, 0 ), VECTOR2I( 10, 10 ) ),
                                   SEG( VECTOR2I( 10, 10 ), VECTOR2I( 0, 10 ) ),
                                   SEG( VECTOR2I( 0, 10 ), VECTOR2I( 0, 0 ) ) };

    // Inside: fine.
    BOOST_CHECK( ALIGN_GEOM::CellAt( box, VECTOR2I( 5, 5 ) ).has_value() );

    // Outside on the right: nothing bounds it to the right.
    BOOST_CHECK( !ALIGN_GEOM::CellAt( box, VECTOR2I( 15, 5 ) ).has_value() );

    // Three walls only.
    const std::vector<SEG> open = { SEG( VECTOR2I( 0, 0 ), VECTOR2I( 10, 0 ) ),
                                    SEG( VECTOR2I( 10, 0 ), VECTOR2I( 10, 10 ) ),
                                    SEG( VECTOR2I( 0, 10 ), VECTOR2I( 0, 0 ) ) };

    BOOST_CHECK( !ALIGN_GEOM::CellAt( open, VECTOR2I( 5, 5 ) ).has_value() );

    BOOST_CHECK( !ALIGN_GEOM::CellAt( {}, VECTOR2I( 5, 5 ) ).has_value() );
}


// A segment only bounds a point if it actually spans it on the other axis.  Title-block dividers
// are short -- the vertical between two fields runs a few mm, not the height of the block -- so
// ignoring the span would report a cell whose walls are nowhere near the point.
BOOST_AUTO_TEST_CASE( CellAtIgnoresSegmentsThatDoNotSpanThePoint )
{
    std::vector<SEG> segs = { SEG( VECTOR2I( 0, 0 ), VECTOR2I( 0, 100 ) ),
                              SEG( VECTOR2I( 100, 0 ), VECTOR2I( 100, 100 ) ),
                              SEG( VECTOR2I( 0, 0 ), VECTOR2I( 100, 0 ) ),
                              SEG( VECTOR2I( 0, 100 ), VECTOR2I( 100, 100 ) ) };

    // A stub vertical near the top must not become the right wall of a point near the bottom.
    segs.emplace_back( VECTOR2I( 50, 0 ), VECTOR2I( 50, 10 ) );

    const std::optional<BOX2I> cell = ALIGN_GEOM::CellAt( segs, VECTOR2I( 20, 90 ) );

    BOOST_REQUIRE( cell.has_value() );
    BOOST_CHECK_EQUAL( cell->GetEnd().x, 100 );
}


// A point resting exactly on a divider belongs to the cell on one side, not to a zero-width one.
// The comparison is strict for this reason; a logo dragged along a rule would otherwise flicker
// between a real cell and a degenerate one.
BOOST_AUTO_TEST_CASE( CellAtTreatsAPointOnADividerAsOutsideIt )
{
    std::vector<SEG> segs;

    for( int x : { 0, 10, 20 } )
        segs.emplace_back( VECTOR2I( x, 0 ), VECTOR2I( x, 10 ) );

    segs.emplace_back( VECTOR2I( 0, 0 ), VECTOR2I( 20, 0 ) );
    segs.emplace_back( VECTOR2I( 0, 10 ), VECTOR2I( 20, 10 ) );

    const std::optional<BOX2I> cell = ALIGN_GEOM::CellAt( segs, VECTOR2I( 10, 5 ) );

    BOOST_REQUIRE( cell.has_value() );
    BOOST_CHECK_EQUAL( cell->GetOrigin().x, 0 );
    BOOST_CHECK_EQUAL( cell->GetEnd().x, 20 );
}


// Drawing sheets may carry diagonals and polygons.  They bound nothing rectilinear, and treating
// an endpoint as a wall would put a cell edge at an arbitrary place.
BOOST_AUTO_TEST_CASE( CellAtIgnoresNonAxisAlignedSegments )
{
    const std::vector<SEG> segs = { SEG( VECTOR2I( 0, 0 ), VECTOR2I( 0, 10 ) ),
                                    SEG( VECTOR2I( 10, 0 ), VECTOR2I( 10, 10 ) ),
                                    SEG( VECTOR2I( 0, 0 ), VECTOR2I( 10, 0 ) ),
                                    SEG( VECTOR2I( 0, 10 ), VECTOR2I( 10, 10 ) ),
                                    SEG( VECTOR2I( 2, 2 ), VECTOR2I( 8, 8 ) ),   // diagonal
                                    SEG( VECTOR2I( 4, 4 ), VECTOR2I( 4, 4 ) ) }; // degenerate

    const std::optional<BOX2I> cell = ALIGN_GEOM::CellAt( segs, VECTOR2I( 5, 5 ) );

    BOOST_REQUIRE( cell.has_value() );
    BOOST_CHECK_EQUAL( cell->GetOrigin(), VECTOR2I( 0, 0 ) );
    BOOST_CHECK_EQUAL( cell->GetEnd(), VECTOR2I( 10, 10 ) );
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build -j6 --target qa_common
```

Expected: compile FAILS with `no member named 'CellAt' in namespace 'ALIGN_GEOM'`.

- [ ] **Step 3: Declare `CellAt`**

In `kicad/common/tool/align_geom.h`, add to the include block (it currently has `<cstddef>`, `<optional>`, `<vector>`, `<math/box2.h>`, `<math/vector2d.h>`):

```cpp
#include <geometry/seg.h>
```

Then add, immediately before the closing `} // namespace ALIGN_GEOM`:

```cpp
/**
 * The cell of a rectilinear arrangement of segments that contains aPoint.
 *
 * A title block is not made of cells -- it is a rectangle plus a few dividers, and the "box in
 * the corner" a user wants to centre a logo in is only the region those lines enclose.  Each of
 * the four walls is the nearest segment beyond the point that actually spans it on the other
 * axis; a short divider elsewhere in the block must not become a wall.
 *
 * Comparison against aPoint is strict, so a point resting exactly on a divider falls into the
 * cell on one side of it rather than into a zero-width one.  Consequently the returned box always
 * has positive area.
 *
 * @param aSegments axis-aligned segments; diagonals and degenerate points are ignored
 * @return the enclosing cell, or nullopt if aPoint is unbounded on any side
 */
std::optional<BOX2I> CellAt( const std::vector<SEG>& aSegments, const VECTOR2I& aPoint );
```

- [ ] **Step 4: Implement `CellAt`**

In `kicad/common/tool/align_geom.cpp`, add `#include <algorithm>` under the existing `#include <tool/align_geom.h>`, then append inside `namespace ALIGN_GEOM` (before the closing brace):

```cpp
std::optional<BOX2I> CellAt( const std::vector<SEG>& aSegments, const VECTOR2I& aPoint )
{
    std::optional<int> left, right, top, bottom;

    for( const SEG& seg : aSegments )
    {
        const bool vertical = seg.A.x == seg.B.x;
        const bool horizontal = seg.A.y == seg.B.y;

        // Equal means either a diagonal (neither) or a degenerate point (both).  Neither bounds
        // anything rectilinear, and taking an endpoint as a wall would put a cell edge at an
        // arbitrary place.
        if( vertical == horizontal )
            continue;

        if( vertical )
        {
            if( aPoint.y < std::min( seg.A.y, seg.B.y ) || aPoint.y > std::max( seg.A.y, seg.B.y ) )
                continue;

            // Strict: a segment through aPoint belongs to neither side.
            if( seg.A.x > aPoint.x && ( !right || seg.A.x < *right ) )
                right = seg.A.x;
            else if( seg.A.x < aPoint.x && ( !left || seg.A.x > *left ) )
                left = seg.A.x;
        }
        else
        {
            if( aPoint.x < std::min( seg.A.x, seg.B.x ) || aPoint.x > std::max( seg.A.x, seg.B.x ) )
                continue;

            if( seg.A.y > aPoint.y && ( !bottom || seg.A.y < *bottom ) )
                bottom = seg.A.y;
            else if( seg.A.y < aPoint.y && ( !top || seg.A.y > *top ) )
                top = seg.A.y;
        }
    }

    if( !left || !right || !top || !bottom )
        return std::nullopt;

    return BOX2I( VECTOR2I( *left, *top ), VECTOR2I( *right - *left, *bottom - *top ) );
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build -j6 --target qa_common \
  && nix develop -c ./build/qa/tests/common/qa_common --run_test='AlignGeom*'
```

Expected: `*** No errors detected`, with the case count risen from 7 to 12.

- [ ] **Step 6: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add common/tool/align_geom.h common/tool/align_geom.cpp qa/tests/common/test_align_geom.cpp
git commit -m "Add ALIGN_GEOM::CellAt, the region a point sits in

A title block has no cell objects -- it is a rectangle plus dividers, and
the box a logo belongs in is only the region they enclose.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `EE_GRID_HELPER::GetGraphicAlignmentBox`

The third box rule: how schematic graphics are measured. Independently testable.

**Files:**
- Modify: `kicad/eeschema/tools/ee_grid_helper.h` (declare next to the other two rules, around line 85)
- Modify: `kicad/eeschema/tools/ee_grid_helper.cpp` (implement next to `GetSymbolAlignmentBox`)
- Test: `kicad/qa/tests/eeschema/test_ee_grid_helper.cpp` (already in CMake)

**Interfaces:**
- Consumes: nothing.
- Produces: `static std::optional<BOX2I> EE_GRID_HELPER::GetGraphicAlignmentBox( const EDA_ITEM* aItem )`. Tasks 3 and 5 both call it.

**Note on the existing shape rule.** `GetSymbolAlignmentBox`'s `SCH_SHAPE_T` case (`ee_grid_helper.cpp:517-544`) already does exactly the stroke-deflation this rule needs. Extract it into a file-local helper and call it from both, rather than copying it — two copies of that reasoning will drift.

- [ ] **Step 1: Write the failing tests**

Append to `kicad/qa/tests/eeschema/test_ee_grid_helper.cpp`, immediately before `BOOST_AUTO_TEST_SUITE_END()`. It already includes `sch_line.h`, `sch_shape.h`, `sch_text.h`, `sch_pin.h`, `sch_sheet.h` and `layer_ids.h` — no new includes needed.

`SCH_BITMAP_T` is deliberately not covered by a unit test: a bitmap with no image loaded has no meaningful bounding box, and constructing one with an image needs a `REFERENCE_IMAGE` and file I/O that would make the case fragile without proving much. That path is checked by hand (checklist item 19).

```cpp
// The third box rule.  Separate from the other two because which one applies is decided by what
// is being dragged -- so a symbol drag can never acquire a graphic target, and vice versa.
BOOST_AUTO_TEST_CASE( GraphicAlignmentBoxAcceptsBitmapsAndGraphicLines )
{
    // A separator line is a graphic SCH_LINE.  Horizontal, so the box has zero height: kept on
    // purpose, exactly as the symbol rule keeps flat polylines.  Dropping zero-extent shapes
    // would drop the entire separator use case.
    SCH_LINE separator( VECTOR2I( 1000, 5000 ), LAYER_NOTES );
    separator.SetEndPoint( VECTOR2I( 9000, 5000 ) );

    const std::optional<BOX2I> lineBox = EE_GRID_HELPER::GetGraphicAlignmentBox( &separator );

    BOOST_REQUIRE( lineBox.has_value() );
    BOOST_CHECK_EQUAL( lineBox->GetOrigin(), VECTOR2I( 1000, 5000 ) );
    BOOST_CHECK_EQUAL( lineBox->GetEnd(), VECTOR2I( 9000, 5000 ) );
    BOOST_CHECK_EQUAL( lineBox->GetHeight(), 0 );

    // Drawn right-to-left: the box must still be normalised, or every guide against it is wrong.
    SCH_LINE backwards( VECTOR2I( 9000, 5000 ), LAYER_NOTES );
    backwards.SetEndPoint( VECTOR2I( 1000, 5000 ) );

    const std::optional<BOX2I> backBox = EE_GRID_HELPER::GetGraphicAlignmentBox( &backwards );

    BOOST_REQUIRE( backBox.has_value() );
    BOOST_CHECK_EQUAL( backBox->GetOrigin(), VECTOR2I( 1000, 5000 ) );
    BOOST_CHECK_EQUAL( backBox->GetEnd(), VECTOR2I( 9000, 5000 ) );
}


// A wire is not a graphic.  It has to keep the body rule and grid-legal snapping, or dragging one
// would silently gain the off-grid exemption that the graphics path carries.
BOOST_AUTO_TEST_CASE( GraphicAlignmentBoxRejectsConnectableLines )
{
    SCH_LINE wire( VECTOR2I( 0, 0 ), LAYER_WIRE );
    wire.SetEndPoint( VECTOR2I( 1000, 0 ) );

    BOOST_CHECK( !EE_GRID_HELPER::GetGraphicAlignmentBox( &wire ).has_value() );
}


// Same stroke deflation as the symbol rule: EDA_SHAPE::getBoundingBox() inflates by half the
// stroke, and half a stroke is not a whole grid step.
BOOST_AUTO_TEST_CASE( GraphicAlignmentBoxDeflatesShapeStroke )
{
    SCH_SHAPE rect( SHAPE_T::RECTANGLE );
    rect.SetStart( VECTOR2I( 0, 0 ) );
    rect.SetEnd( VECTOR2I( 2540, 2540 ) );
    rect.SetWidth( 254 );

    // Precondition, as the symbol-rule test does: the inflated box really is bigger, or this
    // test would pass against an implementation that deflates nothing.
    BOOST_REQUIRE_EQUAL( rect.GetBoundingBox().GetOrigin(), VECTOR2I( -127, -127 ) );

    const std::optional<BOX2I> box = EE_GRID_HELPER::GetGraphicAlignmentBox( &rect );

    BOOST_REQUIRE( box.has_value() );
    BOOST_CHECK_EQUAL( box->GetOrigin(), VECTOR2I( 0, 0 ) );
    BOOST_CHECK_EQUAL( box->GetEnd(), VECTOR2I( 2540, 2540 ) );
}


// Text is excluded by all three rules: font metrics make it a poor alignment reference.
BOOST_AUTO_TEST_CASE( GraphicAlignmentBoxRejectsTextAndBodies )
{
    SCH_TEXT text;
    BOOST_CHECK( !EE_GRID_HELPER::GetGraphicAlignmentBox( &text ).has_value() );

    SCH_SHEET sheet;
    BOOST_CHECK( !EE_GRID_HELPER::GetGraphicAlignmentBox( &sheet ).has_value() );

    SCH_PIN pin( nullptr );
    BOOST_CHECK( !EE_GRID_HELPER::GetGraphicAlignmentBox( &pin ).has_value() );
}


// The invariant that matters is NOT "no type is accepted by more than one rule".  SCH_SHAPE_T is
// deliberately accepted by both the symbol rule and the graphic rule, and that is harmless --
// they never apply in the same editor.  What must stay disjoint is the pair that competes: both
// schematic rules, chosen per drag.  Overlap there makes a single drag ambiguous.
BOOST_AUTO_TEST_CASE( TheTwoSchematicRulesDoNotOverlap )
{
    SCH_SHEET sheet;
    BOOST_CHECK( EE_GRID_HELPER::GetAlignmentBox( &sheet ).has_value() );
    BOOST_CHECK( !EE_GRID_HELPER::GetGraphicAlignmentBox( &sheet ).has_value() );

    SCH_LINE separator( VECTOR2I( 0, 0 ), LAYER_NOTES );
    separator.SetEndPoint( VECTOR2I( 1000, 0 ) );
    BOOST_CHECK( !EE_GRID_HELPER::GetAlignmentBox( &separator ).has_value() );
    BOOST_CHECK( EE_GRID_HELPER::GetGraphicAlignmentBox( &separator ).has_value() );
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build -j6 --target qa_eeschema
```

Expected: compile FAILS with `no member named 'GetGraphicAlignmentBox' in 'EE_GRID_HELPER'`.

- [ ] **Step 3: Declare the rule**

In `kicad/eeschema/tools/ee_grid_helper.h`, directly after the `GetSymbolAlignmentBox` declaration:

```cpp
    /**
     * The box alignment guides measure a *schematic graphic* by, or nullopt if it is not
     * something anyone aligns to.
     *
     * A third rule rather than an extension of the other two, for the same reason there are
     * already two: which rule applies is decided by what is being dragged, so a symbol drag can
     * never acquire a graphic target and a logo can never chase a pin.
     *
     * Text is excluded, as it is everywhere else here -- font metrics make it a poor reference.
     */
    static std::optional<BOX2I> GetGraphicAlignmentBox( const EDA_ITEM* aItem );
```

- [ ] **Step 4: Extract the shared shape rule and implement**

In `kicad/eeschema/tools/ee_grid_helper.cpp`, add this file-local helper immediately above `GetSymbolAlignmentBox`:

```cpp
/**
 * The nominal outline of a shape, as authored.
 *
 * EDA_SHAPE::getBoundingBox() ends with Inflate( GetWidth() / 2 ), so the box is half a stroke
 * wider than the shape on every side.  Half a stroke is not a whole grid step, so a shape
 * measured that way can never align on grid to anything drawn with a different width.
 *
 * Shared by the symbol and graphic rules deliberately: two copies of this reasoning would drift.
 */
static std::optional<BOX2I> shapeAlignmentBox( const SCH_SHAPE* aShape )
{
    BOX2I box = aShape->GetBoundingBox();

    // An empty POLY, or a BEZIER whose curve points have not been rebuilt, leaves
    // getBoundingBox() with a default-constructed box.  The engine would read that as a real
    // point box at the origin and pull the selection towards (0, 0).
    //
    // Deliberately not a size test: a straight polyline or segment has zero extent on one axis,
    // and dropping those would lose every diode bar and ground symbol in the library.
    if( !box.IsValid() )
        return std::nullopt;

    box.Inflate( -( std::max( 0, aShape->GetWidth() ) / 2 ) );

    return box;
}
```

Then replace the whole body of the `case SCH_SHAPE_T:` block inside `GetSymbolAlignmentBox` (currently `ee_grid_helper.cpp:517-544`, from `case SCH_SHAPE_T:` through its closing `}`) with:

```cpp
    case SCH_SHAPE_T:
        return shapeAlignmentBox( static_cast<const SCH_SHAPE*>( aItem ) );
```

Then add the new rule immediately after `GetSymbolAlignmentBox`'s closing brace:

```cpp
std::optional<BOX2I> EE_GRID_HELPER::GetGraphicAlignmentBox( const EDA_ITEM* aItem )
{
    switch( aItem->Type() )
    {
    case SCH_BITMAP_T:
    {
        const BOX2I box = aItem->GetBoundingBox();

        // A bitmap with no image loaded has no extent to align to.
        if( !box.IsValid() )
            return std::nullopt;

        return box;
    }

    case SCH_LINE_T:
    {
        const SCH_LINE* line = static_cast<const SCH_LINE*>( aItem );

        // A wire or bus keeps the body rule and its grid-legal snapping.  Only a notes line is
        // a separator.
        if( line->IsConnectable() )
            return std::nullopt;

        // Merge rather than construct from the pair: a line drawn right-to-left would otherwise
        // produce a box with negative size, and every guide against it would be wrong.  A
        // horizontal separator is legitimately zero-height, exactly as flat polylines are in the
        // symbol rule.
        BOX2I box( line->GetStartPoint(), VECTOR2I( 0, 0 ) );
        box.Merge( line->GetEndPoint() );

        return box;
    }

    case SCH_SHAPE_T:
        return shapeAlignmentBox( static_cast<const SCH_SHAPE*>( aItem ) );

    default:
        return std::nullopt;
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build -j6 --target qa_eeschema \
  && nix develop -c ./build/qa/tests/eeschema/qa_eeschema --run_test='EEGridHelperTest*'
```

Expected: `*** No errors detected`, case count risen from 14 to 18. The pre-existing `SymbolAlignmentBoxDeflatesShapeStroke`, `SymbolAlignmentBoxAcceptsZeroHeightSegment`, `SymbolAlignmentBoxAcceptsThinRectangleAtAnyStroke`, `SymbolAlignmentBoxOddStrokeWidthStillExact`, `SymbolAlignmentBoxCircleRoundTrips` and `SymbolAlignmentBoxRejectsUnmeasurableShape` cases must all still pass — they are the regression check on the extraction.

- [ ] **Step 6: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add eeschema/tools/ee_grid_helper.h eeschema/tools/ee_grid_helper.cpp \
        qa/tests/eeschema/test_ee_grid_helper.cpp
git commit -m "eeschema: a box rule for schematic graphics

Bitmaps, notes lines and shapes, measured for alignment.  A third rule
rather than an extension of the other two: which one applies is decided by
what is being dragged, so a symbol drag cannot acquire a graphic target.

The shape stroke deflation is extracted and shared rather than copied.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Drawing-sheet segments and graphics mode

Reduce the drawing sheet to segments once per drag, and decide which box rule the drag uses.

**Files:**
- Modify: `kicad/include/drawing_sheet/ds_proxy_view_item.h` (public `BuildDrawList`)
- Modify: `kicad/common/drawing_sheet/ds_proxy_view_item.cpp`
- Modify: `kicad/include/tool/grid_helper.h` (`clearMoveState` hook)
- Modify: `kicad/eeschema/tools/ee_grid_helper.h` / `.cpp`
- Test: `kicad/qa/tests/eeschema/test_ee_grid_helper.cpp`

**Interfaces:**
- Consumes: `EE_GRID_HELPER::GetGraphicAlignmentBox` (Task 2).
- Produces: `EE_GRID_HELPER::m_sheetSegments` (`std::vector<SEG>`) and `EE_GRID_HELPER::m_graphicsMode` (`bool`), both private, both read by Task 4.

**Honest note on coverage.** Only the no-frame safety case below is automatable — the rest needs a `VIEW`, a `TOOL_MANAGER` and a real frame. The suites prove nothing else here broke; they do not prove this works. That matches the rest of this feature.

- [ ] **Step 1: Write the failing test**

Append to `kicad/qa/tests/eeschema/test_ee_grid_helper.cpp`, before `BOOST_AUTO_TEST_SUITE_END()`:

```cpp
// EE_GRID_HELPER is default-constructible with no tool manager, which is how every test above
// uses it, and how it is briefly constructed in some tool paths.  The drawing-sheet sweep must
// be a safe no-op there rather than dereferencing its way to a frame that does not exist.
BOOST_AUTO_TEST_CASE( CollectAlignmentNeighborsWithoutAFrameIsSafe )
{
    EE_GRID_HELPER helper;
    SCH_SELECTION  empty;

    BOOST_CHECK_NO_THROW( helper.CollectAlignmentNeighbors( empty ) );
}
```

- [ ] **Step 2: Run it to verify it passes already**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build -j6 --target qa_eeschema \
  && nix develop -c ./build/qa/tests/eeschema/qa_eeschema --run_test='EEGridHelperTest/CollectAlignmentNeighborsWithoutAFrameIsSafe'
```

Expected: PASS. This one is a guard written *before* the change, not a red test — it is here to fail if the sweep added below forgets its null checks. Note that in the plan honestly; do not pretend it went red.

- [ ] **Step 3: Expose the drawing sheet's draw list**

In `kicad/include/drawing_sheet/ds_proxy_view_item.h`, in the `public:` section immediately before `bool HitTestDrawingSheetItems(...)`:

```cpp
    /**
     * Build the drawn geometry of the current page into aDrawList.
     *
     * The same list ViewDraw() renders, so a caller that snaps to sheet geometry snaps to
     * exactly what the user sees.  Seeding the list correctly needs a dozen fields only this
     * class holds (the project, the page info, the variant strings, the pen size from the render
     * settings), so reconstructing the recipe outside would drift.
     */
    void BuildDrawList( KIGFX::VIEW* aView, DS_DRAW_ITEM_LIST* aDrawList ) const;
```

In `kicad/common/drawing_sheet/ds_proxy_view_item.cpp`, immediately after `buildDrawList`'s closing brace:

```cpp
void DS_PROXY_VIEW_ITEM::BuildDrawList( VIEW* aView, DS_DRAW_ITEM_LIST* aDrawList ) const
{
    buildDrawList( aView, m_properties, aDrawList );
}
```

- [ ] **Step 4: Add the per-drag state hook to `GRID_HELPER`**

In `kicad/include/tool/grid_helper.h`, add to the `protected:` section (next to `showConstructionGeometry`):

```cpp
    /**
     * Per-drag state owned by a subclass, dropped whenever the move context is.
     *
     * A stale flag here exempts the *next* drag from whatever the last one was allowed, and the
     * next drag is usually a symbol.
     */
    virtual void clearMoveState() {}
```

Then call it from both teardown paths. In `FullReset()`, after `SetOffGridWarnings( {} );`:

```cpp
        clearMoveState();
```

And in `ClearMoveContext()`, after `SetOffGridWarnings( {} );`:

```cpp
        clearMoveState();
```

- [ ] **Step 5: Collect the segments and pick the rule**

In `kicad/eeschema/tools/ee_grid_helper.h`, add to the `private:` section:

```cpp
    /// Reduce the drawing sheet to axis-aligned segments.  Once per drag: BuildDrawItemsList()
    /// re-instantiates the whole sheet, which ViewDraw() already does every frame, so this is
    /// affordable there but not per motion.
    void collectDrawingSheetSegments();

    void clearMoveState() override;

    /// The drawing sheet's lines and rect edges, for ALIGN_GEOM::CellAt.  Only populated in
    /// graphics mode.
    std::vector<SEG> m_sheetSegments;

    /// This drag is moving graphics only, so the graphic box rule applies, the drawing sheet is
    /// a target, and offsets need not be whole grid steps.
    bool m_graphicsMode = false;
```

Add `#include <geometry/seg.h>` and `#include <vector>` to the header's include block.

In `kicad/eeschema/tools/ee_grid_helper.cpp`, add to the include block:

```cpp
#include <drawing_sheet/ds_draw_item.h>
#include <drawing_sheet/ds_proxy_view_item.h>
#include <sch_draw_panel.h>
#include <sch_view.h>
#include <tool/align_geom.h>
```

Add the two new members' implementations immediately after `inSymbolEditor()`:

```cpp
void EE_GRID_HELPER::clearMoveState()
{
    m_sheetSegments.clear();
    m_graphicsMode = false;
}


void EE_GRID_HELPER::collectDrawingSheetSegments()
{
    m_sheetSegments.clear();

    if( !m_toolMgr )
        return;

    SCH_BASE_FRAME* frame = dynamic_cast<SCH_BASE_FRAME*>( m_toolMgr->GetToolHolder() );

    if( !frame || !frame->GetCanvas() )
        return;

    KIGFX::SCH_VIEW* view = frame->GetCanvas()->GetView();

    if( !view || !view->GetDrawingSheet() )
        return;

    DS_DRAW_ITEM_LIST drawList( schIUScale );
    view->GetDrawingSheet()->BuildDrawList( view, &drawList );

    for( DS_DRAW_ITEM_BASE* item = drawList.GetFirst(); item; item = drawList.GetNext() )
    {
        switch( item->Type() )
        {
        case WSG_LINE_T:
        {
            const DS_DRAW_ITEM_LINE* line = static_cast<const DS_DRAW_ITEM_LINE*>( item );
            m_sheetSegments.emplace_back( line->GetStart(), line->GetEnd() );
            break;
        }

        case WSG_RECT_T:
        {
            // The page frame arrives this way: KiCad's default sheet draws the border as a rect,
            // so the four edges below are what a separator line snaps to.
            const DS_DRAW_ITEM_RECT* rect = static_cast<const DS_DRAW_ITEM_RECT*>( item );
            const VECTOR2I           a = rect->GetStart();
            const VECTOR2I           b = rect->GetEnd();

            m_sheetSegments.emplace_back( VECTOR2I( a.x, a.y ), VECTOR2I( b.x, a.y ) );
            m_sheetSegments.emplace_back( VECTOR2I( b.x, a.y ), VECTOR2I( b.x, b.y ) );
            m_sheetSegments.emplace_back( VECTOR2I( b.x, b.y ), VECTOR2I( a.x, b.y ) );
            m_sheetSegments.emplace_back( VECTOR2I( a.x, b.y ), VECTOR2I( a.x, a.y ) );
            break;
        }

        // Texts, bitmaps and polygons are content, not structure: they bound no cell.
        default:
            break;
        }
    }

    wxLogTrace( traceSnap, "  alignment guides: %zu drawing-sheet segments",
                m_sheetSegments.size() );
}
```

Now wire the mode into `CollectAlignmentNeighbors`. Immediately after the existing line

```cpp
    SYMBOL_EDIT_FRAME* symbolEditor = inSymbolEditor();
```

insert:

```cpp
    // Which of the three box rules applies is decided once, here, by what is being dragged --
    // not by filtering targets later.  A mixed selection is a symbol move that happens to
    // include a graphic, and must keep the body rule; an empty one keeps it too.
    m_graphicsMode = !symbolEditor && !aSkip.Empty()
                     && std::all_of( aSkip.begin(), aSkip.end(),
                                     []( const EDA_ITEM* aItem )
                                     {
                                         return GetGraphicAlignmentBox( aItem ).has_value();
                                     } );
```

Replace the existing rule selection line inside the sweep loop

```cpp
        const std::optional<BOX2I> box = symbolEditor ? GetSymbolAlignmentBox( item ) : GetAlignmentBox( item );
```

with

```cpp
        const std::optional<BOX2I> box = symbolEditor  ? GetSymbolAlignmentBox( item )
                                         : m_graphicsMode ? GetGraphicAlignmentBox( item )
                                                          : GetAlignmentBox( item );
```

Finally, add the graphics branch to the container block. The existing chain reads
`if( symbolEditor ) { ... } else if( SCH_BASE_FRAME* frame = ... ) { ... }`. Insert a branch
between them:

```cpp
    else if( m_graphicsMode )
    {
        // No static container in graphics mode.  The container is the drawing-sheet cell the
        // item is currently over, which changes as the user carries it across the page, so it is
        // set per motion by updateDynamicContainers().
        //
        // The page container the branch below sets is deliberately not used here: it is the
        // *paper* rectangle, while the drawing frame is inset from it by the sheet margins.
        // Offering both would put two centring candidates millimetres apart, one of them on an
        // edge that is never drawn.
        collectDrawingSheetSegments();
    }
```

- [ ] **Step 6: Build and run the full suites**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build -j6 --target qa_eeschema qa_common qa_pcbnew 2>&1 | grep -c "error:"
nix develop -c ./build/qa/tests/eeschema/qa_eeschema --run_test='EEGridHelperTest*'
nix develop -c ./build/qa/tests/common/qa_common --run_test='AlignGeom*,AlignmentGuideEngine*'
nix develop -c ./build/qa/tests/pcbnew/qa_pcbnew --run_test='PCBGridHelper*'
```

Expected: `0` errors; all three `*** No errors detected`. `PCBGridHelper*` must report **23** cases — 21 `BOOST_AUTO_TEST_CASE` (one more is commented out) plus 2 `BOOST_FIXTURE_TEST_CASE`. If it reports 1, the filter is wrong and the green is false. (The combined filter `PCBGridHelper*,*Align*` reports 24; the extra case is an `*Align*` match outside this suite. Do not use the 24 as the expectation for the narrow filter.)

- [ ] **Step 7: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add include/drawing_sheet/ds_proxy_view_item.h common/drawing_sheet/ds_proxy_view_item.cpp \
        include/tool/grid_helper.h eeschema/tools/ee_grid_helper.h \
        eeschema/tools/ee_grid_helper.cpp qa/tests/eeschema/test_ee_grid_helper.cpp
git commit -m "eeschema: collect drawing-sheet geometry for alignment

Reduce the sheet to axis-aligned segments once per drag, and decide from the
selection which of the three box rules the drag uses.

Expose DS_PROXY_VIEW_ITEM::BuildDrawList so the geometry snapped to is
exactly the geometry drawn; seeding the list needs fields only that class
holds.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Dynamic cell container and the grid exemption

The cell must follow the item, and graphics must be free of the whole-grid-step rule.

**Files:**
- Modify: `kicad/include/tool/grid_helper.h` (`updateDynamicContainers` hook)
- Modify: `kicad/common/tool/grid_helper.cpp` (`computeAlignmentGuideSnap` — **reorder**)
- Modify: `kicad/eeschema/tools/ee_grid_helper.h` / `.cpp`

**Interfaces:**
- Consumes: `ALIGN_GEOM::CellAt` (Task 1), `m_sheetSegments` / `m_graphicsMode` (Task 3).
- Produces: nothing new; Task 5 only supplies the selections that turn this on.

- [ ] **Step 1: Add the hook**

In `kicad/include/tool/grid_helper.h`, `protected:` section, next to `clearMoveState`:

```cpp
    /**
     * Called with the extrapolated moving box before each snap is scored, for containers that
     * depend on where the selection currently *is* rather than where the drag started.
     *
     * A logo is picked up somewhere on the page and carried to the corner box, so a container
     * computed once at drag start is the wrong one for the whole gesture.
     */
    virtual void updateDynamicContainers( const BOX2I& aMovingBox ) {}
```

- [ ] **Step 2: Reorder `computeAlignmentGuideSnap` and call the hook**

This is the step most likely to be got wrong. In `kicad/common/tool/grid_helper.cpp`, the function currently opens:

```cpp
    if( !m_toolMgr || !m_moveContext || !m_enableSnap )
        return std::nullopt;

    ALIGNMENT_GUIDE_ENGINE& engine = m_snapManager.GetAlignmentEngine();

    if( !engine.HasInputs() )
        return std::nullopt;

    BOX2I movingBox = m_moveContext->OriginalBBox;
    movingBox.Move( aPos - m_moveContext->OriginalCursor );
```

Replace that block with:

```cpp
    if( !m_toolMgr || !m_moveContext || !m_enableSnap )
        return std::nullopt;

    ALIGNMENT_GUIDE_ENGINE& engine = m_snapManager.GetAlignmentEngine();

    BOX2I movingBox = m_moveContext->OriginalBBox;
    movingBox.Move( aPos - m_moveContext->OriginalCursor );

    // Before HasInputs(), not after.  A subclass may supply its containers from here, and the
    // commonest case for that is a page whose only graphic is the logo being dragged -- zero
    // neighbours and zero containers at this moment.  Testing HasInputs() first would return
    // early and the container would never be computed, which is silence in exactly the case the
    // feature exists for.
    updateDynamicContainers( movingBox );

    if( !engine.HasInputs() )
        return std::nullopt;
```

- [ ] **Step 3: Override the hook in `EE_GRID_HELPER`**

Declare in `kicad/eeschema/tools/ee_grid_helper.h`, `private:` section:

```cpp
    void updateDynamicContainers( const BOX2I& aMovingBox ) override;
```

Implement in `kicad/eeschema/tools/ee_grid_helper.cpp`, after `collectDrawingSheetSegments()`:

```cpp
void EE_GRID_HELPER::updateDynamicContainers( const BOX2I& aMovingBox )
{
    if( !m_graphicsMode )
        return;

    ALIGNMENT_GUIDE_ENGINE& engine = getSnapManager().GetAlignmentEngine();

    // Measured from the moving box's centre, which is the point that ends up on the cell centre.
    // Cleared rather than left stale when the item is over no cell at all, or a logo dragged off
    // the title block keeps being pulled back into the cell it just left.
    if( std::optional<BOX2I> cell = ALIGN_GEOM::CellAt( m_sheetSegments, aMovingBox.Centre() ) )
        engine.SetContainers( { *cell } );
    else
        engine.SetContainers( {} );
}
```

- [ ] **Step 4: Apply the grid exemption at both call sites**

In `kicad/eeschema/tools/ee_grid_helper.cpp`, in `BestSnapAnchor` (around line 203), replace:

```cpp
    std::optional<VECTOR2I> gridStep;

    if( canUseGrid() )
        gridStep = KiROUND( gridSize );
```

with:

```cpp
    // Graphics are exempt from the whole-grid-step rule.  That rule exists so pins land on the
    // wire grid; a bitmap has no pins and a notes line connects to nothing, and at 100 mil the
    // nearest legal position is up to 1.27 mm from a title-block cell centre -- in a 3 mm row,
    // hard against an edge.  Keyed on the same graphics-only test that picked the box rule, so a
    // selection containing anything connectable stays strict.
    std::optional<VECTOR2I> gridStep;

    if( canUseGrid() && !m_graphicsMode )
        gridStep = KiROUND( gridSize );
```

Apply the identical change in `AlignPointToGuides` (around line 440), replacing the same three
lines. Its surrounding comment already says "offsets must be whole grid steps or a resized sheet
drags its pins off grid" — append to that comment:

```cpp
    // ... A graphic has no pins to drag off grid, so it is exempt; see BestSnapAnchor().
```

**Do not touch the position argument.** Both sites pass `canUseGrid() ? nearestGrid : aOrigin`
(or `aPoint`), and that must stay. The comment above it explains why: extrapolating the moving
box from a raw cursor while the grid is on pairs a snapped origin with an unsnapped current
point. The change here is "stop requiring the offset to be a whole number of steps", never "stop
snapping the cursor to the grid". Getting this wrong yields a drag that jitters rather than an
obvious failure.

- [ ] **Step 5: Build and run everything**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build -j6 --target qa_eeschema qa_common qa_pcbnew 2>&1 | grep -c "error:"
nix develop -c ./build/qa/tests/eeschema/qa_eeschema 2>&1 | tail -3
nix develop -c ./build/qa/tests/common/qa_common --run_test='AlignGeom*,AlignmentGuideEngine*' 2>&1 | tail -3
nix develop -c ./build/qa/tests/pcbnew/qa_pcbnew --run_test='PCBGridHelper*' 2>&1 | tail -3
```

Expected: `0` errors, all `*** No errors detected`. The reorder in Step 2 touches the path every
schematic and board drag uses, so the pcbnew suite passing matters here more than anywhere else
in this plan.

- [ ] **Step 6: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add include/tool/grid_helper.h common/tool/grid_helper.cpp \
        eeschema/tools/ee_grid_helper.h eeschema/tools/ee_grid_helper.cpp
git commit -m "eeschema: centre graphics in the drawing-sheet cell they are over

The container follows the item, because a logo is picked up elsewhere and
carried to the corner box.  The hook runs before the HasInputs() guard: in
graphics mode the container comes from the hook, so testing first would
return early on a page whose only graphic is the one being dragged.

Graphics are also exempt from whole-grid-step offsets.  At 100 mil the
nearest legal position is 1.27 mm from a cell centre and the default rows
are 3-4 mm tall.  A bitmap has no pins; symbols and wires stay strict.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Move tool and point editor

Nothing above reaches the user until the tools set a move context for a graphics selection.

**Files:**
- Modify: `kicad/eeschema/tools/sch_move_tool.cpp:832-886` (the `updateBBox` block)
- Modify: `kicad/eeschema/tools/sch_point_editor.cpp:1231-1235` (the `guideResize` condition)

**Interfaces:**
- Consumes: `EE_GRID_HELPER::GetGraphicAlignmentBox` (Task 2).
- Produces: nothing.

- [ ] **Step 1: Teach the move tool the graphics rule**

In `kicad/eeschema/tools/sch_move_tool.cpp`, the `updateBBox` block currently builds `guideBBox`
from `GetAlignmentBox` and then computes `allBodies`. Replace the `guideBBox` loop

```cpp
                BOX2I guideBBox;

                for( EDA_ITEM* item : selection )
                {
                    if( std::optional<BOX2I> box = EE_GRID_HELPER::GetAlignmentBox( item ) )
                        guideBBox.Merge( *box );
                }
```

with

```cpp
                // A logo or a separator line is measured by its own rule and aligned to the
                // drawing sheet, never to symbols.  Only when the whole selection is graphics: a
                // mixed bag is a symbol move that happens to include a graphic, and has to keep
                // the body rule or a symbol would inherit the graphics grid exemption.
                const bool graphicsOnly =
                        !selection.Empty()
                        && std::all_of( selection.begin(), selection.end(),
                                        []( const EDA_ITEM* aItem )
                                        {
                                            return EE_GRID_HELPER::GetGraphicAlignmentBox( aItem )
                                                    .has_value();
                                        } );

                BOX2I guideBBox;

                for( EDA_ITEM* item : selection )
                {
                    const std::optional<BOX2I> box =
                            graphicsOnly ? EE_GRID_HELPER::GetGraphicAlignmentBox( item )
                                         : EE_GRID_HELPER::GetAlignmentBox( item );

                    if( box )
                        guideBBox.Merge( *box );
                }
```

Then change the `SetMoveContext` call from

```cpp
                    grid.SetMoveContext( guideBBox, prevPos, allBodies );
```

to

```cpp
                    // Graphics prefer guides for the same reason whole symbols do: a logo has no
                    // business snapping to a pin.
                    grid.SetMoveContext( guideBBox, prevPos, allBodies || graphicsOnly );
```

- [ ] **Step 2: Teach the point editor about graphic endpoints**

In `kicad/eeschema/tools/sch_point_editor.cpp`, replace

```cpp
            const bool guideResize = item->Type() == SCH_SHEET_T
                                     || ( item->Type() == SCH_SHAPE_T && m_isSymbolEditor );
```

with

```cpp
            // Plus schematic graphics: dragging a separator line's endpoint should reach the
            // drawing frame the same way moving the whole line does.  Still excluded in the
            // symbol editor, where the SCH_SHAPE_T clause above already covers shapes.
            const bool guideResize =
                    item->Type() == SCH_SHEET_T
                    || ( item->Type() == SCH_SHAPE_T && m_isSymbolEditor )
                    || ( !m_isSymbolEditor
                         && EE_GRID_HELPER::GetGraphicAlignmentBox( item ).has_value() );
```

No include change: `sch_point_editor.cpp:24` already has `#include <ee_grid_helper.h>`. Note that
`item` at this point is an `EDA_ITEM*` (`selection.Front()`), which is exactly what
`GetGraphicAlignmentBox` takes.

- [ ] **Step 3: Build everything and run the suites**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build -j6 2>&1 | grep -c "error:"
nix develop -c ./build/qa/tests/eeschema/qa_eeschema 2>&1 | tail -3
nix develop -c ./build/qa/tests/common/qa_common --run_test='AlignGeom*,AlignmentGuideEngine*' 2>&1 | tail -3
nix develop -c ./build/qa/tests/pcbnew/qa_pcbnew --run_test='PCBGridHelper*,*Align*' 2>&1 | tail -3
```

Expected: `0` errors, all `*** No errors detected`. Build the full default target, not just the
qa ones — this is the last code task and the GUI binaries must link.

- [ ] **Step 4: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add eeschema/tools/sch_move_tool.cpp eeschema/tools/sch_point_editor.cpp
git commit -m "eeschema: guide graphics moves and graphic endpoint drags

A graphics-only selection previously produced no guide bbox at all and fell
straight into ClearMoveContext(), so logos and notes lines had no guides.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: The cell's edges as alignment targets

Found by the Task 4 review, not by the original plan. `KIND_CONTAINER` produces a **centring**
candidate and nothing else (`alignment_guide_engine.cpp:207`), so as built a separator line can
centre in the drawing area but can never sit flush against the frame. "Snap to the borders of the
schematic" was half the request and is not delivered.

The fix is to offer the current cell as a **neighbour** box as well as a container, so its four
edges become alignment targets. The cell only — never every drawing-sheet segment. Making each
title-block divider a target was considered and explicitly rejected during design; it puts a dozen
candidates within a few millimetres of each other.

This task also closes the latent defect the same review flagged, and a stale comment from Task 5.

**Files:**
- Modify: `kicad/eeschema/tools/ee_grid_helper.h` (one new member)
- Modify: `kicad/eeschema/tools/ee_grid_helper.cpp` (`CollectAlignmentNeighbors`, `updateDynamicContainers`, `clearMoveState`)
- Modify: `kicad/eeschema/tools/sch_point_editor.cpp` (comment only)
- Test: `kicad/qa/tests/common/test_alignment_guide_engine.cpp`

**Interfaces:**
- Consumes: `ALIGN_GEOM::CellAt`, `m_sheetSegments`, `m_graphicsMode` (Tasks 1, 3, 4).
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

This pins the *premise* of the change: a box offered as a container yields only centring, while
the same box offered as a neighbour yields edge alignment. Append to
`kicad/qa/tests/common/test_alignment_guide_engine.cpp`, before `BOOST_AUTO_TEST_SUITE_END()`:

```cpp
// Why the drawing-sheet cell is handed to the engine twice -- once as a container, once as a
// neighbour.  A container only ever produces a centring candidate, so a separator line offered
// nothing but a container could centre in the drawing area and never sit flush against the
// frame.  If this ever stops being true, the duplicate registration in EE_GRID_HELPER is dead
// weight and should go.
BOOST_AUTO_TEST_CASE( ContainerCentresButOnlyANeighbourAlignsAnEdge )
{
    const BOX2I frame( VECTOR2I( 0, 0 ), VECTOR2I( 1000, 1000 ) );

    // Tucked into the top-left corner: 40 from each edge, but 410 from the centre on both axes.
    const BOX2I moving( VECTOR2I( 40, 40 ), VECTOR2I( 100, 100 ) );

    ALIGNMENT_GUIDE_ENGINE containerOnly;
    containerOnly.SetContainers( { frame } );

    // The container's only offer is the centre, 410 away on each axis -- out of a 100 reach.
    BOOST_CHECK( !containerOnly.FindSnap( moving, 100 ).has_value() );

    ALIGNMENT_GUIDE_ENGINE withNeighbour;
    withNeighbour.SetContainers( { frame } );
    withNeighbour.SetNeighbors( { frame } );

    // As a neighbour the same box offers its top and left edges, 40 away on each axis.
    const std::optional<ALIGNMENT_GUIDE_ENGINE::RESULT> snap = withNeighbour.FindSnap( moving, 100 );

    BOOST_REQUIRE( snap.has_value() );
    BOOST_CHECK_EQUAL( snap->Offset.x, -40 );
    BOOST_CHECK_EQUAL( snap->Offset.y, -40 );
}
```

- [ ] **Step 2: Run it**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build -j6 --target qa_common \
  && nix develop -c ./build/qa/tests/common/qa_common --run_test='AlignmentGuideEngine*'
```

This test describes the engine as it already is, so it should **pass first time**. It is a
characterisation test guarding the assumption the rest of the task rests on, not a red test.
Report honestly that it passed; do not manufacture a failure. If it *fails*, stop and report —
the premise is wrong and the rest of this task is built on sand.

- [ ] **Step 3: Keep the drag-time neighbour list**

In `kicad/eeschema/tools/ee_grid_helper.h`, next to `m_sheetSegments`:

```cpp
    /// The graphics neighbours collected at drag start.  Kept because updateDynamicContainers()
    /// re-sets the engine's neighbour list on every motion to append the cell the item is
    /// currently over, and would otherwise drop them.
    std::vector<BOX2I> m_graphicsNeighbors;
```

In `kicad/eeschema/tools/ee_grid_helper.cpp`, extend `clearMoveState()` so it reads:

```cpp
void EE_GRID_HELPER::clearMoveState()
{
    m_sheetSegments.clear();
    m_graphicsNeighbors.clear();
    m_graphicsMode = false;
}
```

In `CollectAlignmentNeighbors`, immediately **before** the existing
`engine.SetNeighbors( std::move( boxes ) );`:

```cpp
    // Copied before the move: updateDynamicContainers() rebuilds the list every motion.
    if( m_graphicsMode )
        m_graphicsNeighbors = boxes;
```

- [ ] **Step 4: Offer the cell as a neighbour, and skip centring for a resize handle**

Replace the body of `EE_GRID_HELPER::updateDynamicContainers` with:

```cpp
void EE_GRID_HELPER::updateDynamicContainers( const BOX2I& aMovingBox )
{
    if( !m_graphicsMode )
        return;

    ALIGNMENT_GUIDE_ENGINE& engine = getSnapManager().GetAlignmentEngine();

    // Measured from the moving box's centre, which is the point that ends up on the cell centre.
    const std::optional<BOX2I> cell = ALIGN_GEOM::CellAt( m_sheetSegments, aMovingBox.Centre() );

    // A degenerate box is a resize handle, not an item: AlignPointToGuides() collapses the move
    // context onto the point being dragged.  Centring a line *endpoint* inside a title-block cell
    // is meaningless -- what an endpoint drag wants is the cell's edges, which the neighbour
    // registration below provides.
    const bool centreable = aMovingBox.GetWidth() > 0 || aMovingBox.GetHeight() > 0;

    // Cleared rather than left stale when the item is over no cell at all, or a logo dragged off
    // the title block keeps being pulled back into the cell it just left.
    if( cell && centreable )
        engine.SetContainers( { *cell } );
    else
        engine.SetContainers( {} );

    // The cell is registered as a neighbour as well, because a container yields a centring
    // candidate and nothing else -- so without this a separator line could centre in the drawing
    // area but never sit flush against the frame, which is half of what was asked for.
    //
    // The cell only, never every drawing-sheet segment: making each title-block divider a target
    // was considered during design and rejected, because it puts a dozen candidates within a few
    // millimetres of each other.
    std::vector<BOX2I> neighbors = m_graphicsNeighbors;

    if( cell )
        neighbors.push_back( *cell );

    engine.SetNeighbors( std::move( neighbors ) );
}
```

- [ ] **Step 5: Correct the stale comment in the point editor**

In `kicad/eeschema/tools/sch_point_editor.cpp`, the comment above `guideResize` still ends with
"A shape on a schematic sheet is excluded: there it has no relationship to anything worth guiding
to." Task 5 made that false — the new clause admits `SCH_SHAPE_T` on a schematic sheet. Replace
that sentence with:

```cpp
            // On a schematic sheet, graphics guide to the drawing sheet instead: a shape, a
            // separator line or a logo lines its corner up with the title block and the frame.
```

Leave the two sentences before it alone.

- [ ] **Step 6: Build and run everything**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build -j6 2>&1 | grep -c "error:"
nix develop -c ./build/qa/tests/common/qa_common --run_test='AlignGeom*,AlignmentGuideEngine*'
nix develop -c ./build/qa/tests/eeschema/qa_eeschema --run_test='EEGridHelperTest*'
nix develop -c ./build/qa/tests/pcbnew/qa_pcbnew --run_test='PCBGridHelper*'
```

Expected: `0` errors; 44, 20 and 23 cases respectively, all `*** No errors detected`.

- [ ] **Step 7: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add eeschema/tools/ee_grid_helper.h eeschema/tools/ee_grid_helper.cpp \
        eeschema/tools/sch_point_editor.cpp qa/tests/common/test_alignment_guide_engine.cpp
git commit -m "eeschema: align graphics to the drawing-sheet cell's edges

A container yields a centring candidate and nothing else, so a separator
line could centre in the drawing area but never sit flush against the
frame.  Register the cell as a neighbour as well.

Also skip centring when the moving box is degenerate: that is a resize
handle, and centring a line endpoint in a title-block cell is meaningless.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Verification checklist

Nothing in this feature is confirmed by a test past the two box/geometry rules. Write down what a human has to look at.

**Files:**
- Modify: `docs/superpowers/plans/2026-07-25-smart-guides-schematic-verification.md` (outer repo)

- [ ] **Step 1: Append the section**

Add before the final `---` separator:

```markdown
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
31. **An endpoint drag aligns but does not centre.** Drag one end of a separator line → it reaches
    the frame edge, but the endpoint must not jump to the middle of a title-block cell. The
    resize path collapses the move context onto the handle, so centring there would centre the
    *handle*, which is meaningless.
32. **A separator line moved whole still centres.** A horizontal line has zero height by design;
    it must still centre in the drawing area. This and check 31 are two sides of one guard — if
    31 passes and 32 fails, the degenerate-box test is `&&` where it should be `||`.
```

- [ ] **Step 2: Commit**

```bash
cd /home/asqude/projecte/PixelCad
git add docs
git commit -m "Add drawing-sheet snapping to the schematic verification checklist

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **Do not modify `ALIGNMENT_GUIDE_ENGINE`.** If a task seems to need it, the design has been misread — say so rather than changing it.
- **Task 4 Step 2 is the risky one.** Reordering `computeAlignmentGuideSnap` changes a function every schematic and board drag runs. Run the pcbnew suite after it.
- Three defects in the spec were found and corrected while this plan was written: the `align_geom.h` path, the rules-overlap invariant (`SCH_SHAPE_T` is legitimately in two rules), and the `HasInputs()` ordering. If you find a fourth, fix the spec too rather than working around it.
