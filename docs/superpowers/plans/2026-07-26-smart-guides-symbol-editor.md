# Smart Alignment Guides in the Symbol Editor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `SYMBOL_EDIT_FRAME` the same Figma-style alignment guides the schematic and board already have, so pins line up with pins, body graphics line up with each other, and equal pin pitch snaps and is measured.

**Architecture:** The engine (`ALIGNMENT_GUIDE_ENGINE`), the overlay (`ALIGNMENT_GUIDE_GEOM`) and the `GRID_HELPER` plumbing are already shared and need no changes. `EE_GRID_HELPER` is *already* the grid helper the symbol editor uses, and `queryVisible()` already has a symbol-editor branch — so neighbours are already being found. The only reason guides never fire there is that `GetAlignmentBox()` recognises `SCH_SYMBOL_T` and `SCH_SHEET_T` only, and returns `nullopt` for everything a symbol is made of. This plan adds a second, editor-specific box rule and wires `SYMBOL_EDITOR_MOVE_TOOL` the way `SCH_MOVE_TOOL` is wired.

**Tech Stack:** C++20, KiCad 10.99 master, Boost.Test (`qa_eeschema`, `qa_common`), CMake + Ninja under `nix develop`.

---

## Why a separate box rule

`GetAlignmentBox()` cannot simply gain `SCH_PIN_T` and `SCH_SHAPE_T` cases. Those types exist on a schematic sheet too — a symbol's pins are `SCH_PIN_T` children, and sheet graphics are `SCH_SHAPE_T`. Adding them would reintroduce exactly the behaviour the user rejected earlier: a chip snapping to individual pins instead of to another chip's body. So there are two named rules and the shared sweep picks one by frame type.

## Geometry decisions, and the reasoning

**Pins become zero-size boxes at their connection point.** A pin's useful geometry is the point a wire attaches to, not its rectangle-with-name-text. A degenerate box makes `SPAN::Min == Max == Center`, so every alignment candidate the engine builds reduces to "line this pin up with that pin", and consecutive pins in a column produce clusters whose gaps *are* the pin pitch — which is what makes equal-pitch snapping work for free. Two pins on opposite sides of a body have different cross coordinates and therefore never cross-overlap, so they correctly do not form a spacing run with each other.

**Shapes are deflated back to their drawn geometry.** `EDA_SHAPE::getBoundingBox()` ends with `bbox.Inflate( std::max( 0, GetWidth() ) / 2 )` (`common/eda_shape.cpp`), so a body rectangle's box is half a stroke wider than the rectangle. Two shapes of equal stroke width cancel, but a body outline and a thinner internal graphic do not, and the difference is never a whole grid step — so the guide would be silently rejected. Deflating by the same amount recovers the geometry that was actually drawn, which for a symbol drawn on grid is on grid.

**Text, text boxes and fields are skipped.** Their extents depend on font metrics and on whether the field happens to be visible; nobody aligns to the width of a pin name. Deliberate omission, not an oversight.

**No Y-flip handling is needed.** Checked: `LIB_SYMBOL::GetBodyBoundingBox()` merges child boxes without inverting Y, `SCH_PIN::GetPosition()` returns `m_position` verbatim when the parent is not a `SCH_SYMBOL`, and `symbol_edit_frame.cpp` sets no view mirror. Symbol-editor items, their bounding boxes and the view all share one coordinate space.

---

## File Structure

| File | Responsibility |
|---|---|
| `eeschema/tools/ee_grid_helper.h` | Declare `GetSymbolAlignmentBox()` and the private `inSymbolEditor()` |
| `eeschema/tools/ee_grid_helper.cpp` | Implement both; dispatch inside `CollectAlignmentNeighbors()`; reuse `inSymbolEditor()` in `queryVisible()` |
| `eeschema/tools/symbol_editor_move_tool.cpp` | Move-context lifecycle, one-shot neighbour sweep, guide clears |
| `eeschema/tools/sch_point_editor.cpp` | Extend resize-handle guides from sheets to symbol body shapes |
| `qa/tests/eeschema/test_ee_grid_helper.cpp` | Unit tests for the new box rule |
| `docs/superpowers/plans/2026-07-26-smart-guides-symbol-editor-verification.md` | Manual checklist (Task 6) |

---

### Task 1: Extract the symbol-editor frame test

Pure refactor, no behaviour change. `queryVisible()` currently inlines the frame-type test; Task 3 needs the same test, and two copies would be free to drift apart.

**Files:**
- Modify: `eeschema/tools/ee_grid_helper.h`
- Modify: `eeschema/tools/ee_grid_helper.cpp`

- [ ] **Step 1: Declare the helper**

In `eeschema/tools/ee_grid_helper.h`, in the `private:` section, immediately above `queryVisible`:

```cpp
    /// True when this helper belongs to the symbol editor rather than the schematic.  The two
    /// have entirely different ideas of what an alignment target is, and one sweep serves both.
    bool inSymbolEditor() const;

    std::set<SCH_ITEM*> queryVisible( const BOX2I& aArea, const SCH_SELECTION& aSkipList ) const;
```

- [ ] **Step 2: Implement it**

In `eeschema/tools/ee_grid_helper.cpp`, immediately above `EE_GRID_HELPER::queryVisible`:

```cpp
bool EE_GRID_HELPER::inSymbolEditor() const
{
    if( !m_toolMgr )
        return false;

    EDA_DRAW_FRAME* frame = dynamic_cast<EDA_DRAW_FRAME*>( m_toolMgr->GetToolHolder() );

    return frame && frame->IsType( FRAME_SCH_SYMBOL_EDITOR );
}
```

- [ ] **Step 3: Use it in queryVisible**

Replace this block in `EE_GRID_HELPER::queryVisible`:

```cpp
        if( frame && frame->IsType( FRAME_SCH_SYMBOL_EDITOR ) )
        {
            // If we are in the symbol editor, don't use the symbol itself
            if( item->Type() == LIB_SYMBOL_T )
                continue;
        }
        else
        {
            // If we are not in the symbol editor, don't use symbol-editor-private items
            if( item->IsPrivate() )
                continue;
        }
```

with:

```cpp
        if( symbolEditor )
        {
            // If we are in the symbol editor, don't use the symbol itself
            if( item->Type() == LIB_SYMBOL_T )
                continue;
        }
        else
        {
            // If we are not in the symbol editor, don't use symbol-editor-private items
            if( item->IsPrivate() )
                continue;
        }
```

and hoist the flag out of the loop by replacing the `EDA_DRAW_FRAME* frame = ...` line near the top of `queryVisible` with:

```cpp
    const bool   symbolEditor = inSymbolEditor();
    KIGFX::VIEW* view = m_toolMgr->GetView();
```

(The local `frame` variable becomes unused — delete its declaration. Confirm with the build in Step 4 that nothing else in the function referenced it.)

- [ ] **Step 4: Build — no test yet, this is a refactor**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build --target qa_eeschema -j"$(nproc)"
```

Expected: compiles with no errors. If `frame` is reported unused or still referenced, fix that line only.

- [ ] **Step 5: Run the existing suite to prove nothing changed**

```bash
nix develop -c ./build/qa/tests/eeschema/qa_eeschema --run_test='EEGridHelperTest'
```

Expected: `*** No errors detected` (3 test cases).

- [ ] **Step 6: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add eeschema/tools/ee_grid_helper.h eeschema/tools/ee_grid_helper.cpp
git commit -m "eeschema: hoist the symbol-editor frame test out of queryVisible

The alignment sweep needs the same test, and a second copy of it would be
free to drift away from this one."
```

---

### Task 2: The symbol-editor box rule

**Files:**
- Modify: `eeschema/tools/ee_grid_helper.h`
- Modify: `eeschema/tools/ee_grid_helper.cpp`
- Test: `qa/tests/eeschema/test_ee_grid_helper.cpp`

- [ ] **Step 1: Write the failing tests**

Append to `qa/tests/eeschema/test_ee_grid_helper.cpp`, immediately before `BOOST_AUTO_TEST_SUITE_END()`. Add `#include <sch_pin.h>` and `#include <sch_shape.h>` to the include block at the top of the file first.

```cpp
// A pin is a point, not a rectangle: what anyone aligns is the place a wire attaches.  A
// zero-size box collapses min, max and centre onto that point, which is what makes both
// pin-to-pin alignment and equal pin pitch fall out of the existing engine.
BOOST_AUTO_TEST_CASE( SymbolAlignmentBoxForPin )
{
    SCH_PIN pin( nullptr );
    pin.SetPosition( VECTOR2I( 2540, -1270 ) );

    const std::optional<BOX2I> box = EE_GRID_HELPER::GetSymbolAlignmentBox( &pin );

    BOOST_REQUIRE( box.has_value() );
    BOOST_CHECK_EQUAL( box->GetOrigin(), VECTOR2I( 2540, -1270 ) );
    BOOST_CHECK_EQUAL( box->GetEnd(), VECTOR2I( 2540, -1270 ) );
    BOOST_CHECK_EQUAL( box->GetWidth(), 0 );
    BOOST_CHECK_EQUAL( box->GetHeight(), 0 );
}


// EDA_SHAPE::getBoundingBox() inflates by half the stroke width.  Half a stroke is never a whole
// grid step, so a body outline measured that way can never align to anything on grid.  The rule
// has to hand back the rectangle that was actually drawn.
BOOST_AUTO_TEST_CASE( SymbolAlignmentBoxDeflatesShapeStroke )
{
    SCH_SHAPE rect( SHAPE_T::RECTANGLE );
    rect.SetStart( VECTOR2I( 0, 0 ) );
    rect.SetEnd( VECTOR2I( 5080, 2540 ) );
    rect.SetWidth( 254 );

    // Precondition: the inflated box really is bigger, or this test proves nothing.
    BOOST_REQUIRE_EQUAL( rect.GetBoundingBox().GetOrigin(), VECTOR2I( -127, -127 ) );

    const std::optional<BOX2I> box = EE_GRID_HELPER::GetSymbolAlignmentBox( &rect );

    BOOST_REQUIRE( box.has_value() );
    BOOST_CHECK_EQUAL( box->GetOrigin(), VECTOR2I( 0, 0 ) );
    BOOST_CHECK_EQUAL( box->GetEnd(), VECTOR2I( 5080, 2540 ) );
}


// A stroke wider than the shape would invert the box when deflated.  Degenerate geometry must be
// dropped, not handed to the engine as a box with negative extents.
BOOST_AUTO_TEST_CASE( SymbolAlignmentBoxRejectsStrokeWiderThanShape )
{
    SCH_SHAPE rect( SHAPE_T::RECTANGLE );
    rect.SetStart( VECTOR2I( 0, 0 ) );
    rect.SetEnd( VECTOR2I( 100, 100 ) );
    rect.SetWidth( 4000 );

    BOOST_CHECK( !EE_GRID_HELPER::GetSymbolAlignmentBox( &rect ).has_value() );
}


// Text extents depend on font metrics and on field visibility.  Nobody aligns to the width of a
// pin name, and guides drawn on one would look arbitrary.
BOOST_AUTO_TEST_CASE( SymbolAlignmentBoxRejectsText )
{
    SCH_TEXT text;
    BOOST_CHECK( !EE_GRID_HELPER::GetSymbolAlignmentBox( &text ).has_value() );
}


// The two rules must stay separate.  A schematic symbol is a body; in the symbol editor there is
// no such thing, and pins must not become schematic alignment targets.
BOOST_AUTO_TEST_CASE( TheTwoAlignmentRulesDoNotOverlap )
{
    SCH_PIN pin( nullptr );
    pin.SetPosition( VECTOR2I( 0, 0 ) );

    BOOST_CHECK( !EE_GRID_HELPER::GetAlignmentBox( &pin ).has_value() );

    SCH_SHEET sheet;
    BOOST_CHECK( !EE_GRID_HELPER::GetSymbolAlignmentBox( &sheet ).has_value() );
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build --target qa_eeschema -j"$(nproc)"
```

Expected: **compile failure**, `no member named 'GetSymbolAlignmentBox' in 'EE_GRID_HELPER'`. That is the failing state for this task — a compile error, because the function does not exist yet.

- [ ] **Step 3: Declare it**

In `eeschema/tools/ee_grid_helper.h`, directly below the existing `GetAlignmentBox` declaration:

```cpp
    /**
     * The box alignment guides measure a *symbol editor* item by, or nullopt if it is not
     * something anyone aligns to.
     *
     * Separate from GetAlignmentBox() on purpose rather than merged with it.  SCH_PIN_T and
     * SCH_SHAPE_T both occur on a schematic sheet as well, and teaching the schematic rule about
     * them would put a guide on every pin of every symbol -- which is the behaviour that made
     * chips snap to GND flags instead of to each other.
     */
    static std::optional<BOX2I> GetSymbolAlignmentBox( const EDA_ITEM* aItem );
```

- [ ] **Step 4: Implement it**

In `eeschema/tools/ee_grid_helper.cpp`, directly below `EE_GRID_HELPER::GetAlignmentBox`. Add `#include <sch_pin.h>` and `#include <sch_shape.h>` to the include block if not already present.

```cpp
std::optional<BOX2I> EE_GRID_HELPER::GetSymbolAlignmentBox( const EDA_ITEM* aItem )
{
    switch( aItem->Type() )
    {
    case SCH_PIN_T:
    {
        // A point, not a rectangle.  Zero size collapses min, max and centre onto the
        // connection point, so every alignment candidate the engine builds reduces to "line
        // this pin up with that one" -- and a column of pins yields clusters whose gaps are the
        // pin pitch, which is what makes equal-pitch snapping work with no extra machinery.
        const VECTOR2I pos = static_cast<const SCH_PIN*>( aItem )->GetPosition();

        return BOX2I( pos, VECTOR2I( 0, 0 ) );
    }

    case SCH_SHAPE_T:
    {
        const SCH_SHAPE* shape = static_cast<const SCH_SHAPE*>( aItem );

        // EDA_SHAPE::getBoundingBox() ends with Inflate( GetWidth() / 2 ), so the box is half a
        // stroke wider than the shape on every side.  Half a stroke is not a whole grid step, so
        // a body outline measured that way can never align on grid to anything drawn with a
        // different width.  Deflating by the same amount recovers the drawn geometry.
        const int deflate = std::max( 0, shape->GetWidth() ) / 2;

        BOX2I box = shape->GetBoundingBox();

        // A stroke wider than the shape itself would invert the box, and the engine would read
        // the inverted edges as real ones.  Drop it instead.
        if( box.GetWidth() <= 2 * deflate || box.GetHeight() <= 2 * deflate )
            return std::nullopt;

        box.Inflate( -deflate );

        return box;
    }

    default:
        // Text, text boxes and fields: extents depend on font metrics and on whether a field is
        // visible, and the width of a pin name is not something anyone aligns to.
        return std::nullopt;
    }
}
```

- [ ] **Step 5: Run to verify they pass**

```bash
nix develop -c cmake --build build --target qa_eeschema -j"$(nproc)" \
  && nix develop -c ./build/qa/tests/eeschema/qa_eeschema --run_test='EEGridHelperTest'
```

Expected: `*** No errors detected`, 8 test cases.

If `SymbolAlignmentBoxDeflatesShapeStroke` fails on the `BOOST_REQUIRE_EQUAL` precondition, the inflation amount differs from `GetWidth()/2` in this KiCad revision. Do not weaken the assertion — read `common/eda_shape.cpp`, find the actual amount, and match it in `deflate`.

- [ ] **Step 6: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add eeschema/tools/ee_grid_helper.h eeschema/tools/ee_grid_helper.cpp \
        qa/tests/eeschema/test_ee_grid_helper.cpp
git commit -m "eeschema: an alignment box rule for symbol editor items

Pins become zero-size boxes at their connection point, so pin-to-pin
alignment and equal pin pitch both fall out of the existing engine: a column
of degenerate boxes has gaps that are the pitch.

Shapes are deflated by half their stroke width.  EDA_SHAPE inflates its
bounding box by that much, and half a stroke is never a whole grid step, so a
body outline measured raw could never align on grid to a graphic drawn with a
different width.

Kept separate from the schematic rule rather than merged into it.  SCH_PIN_T
and SCH_SHAPE_T occur on a sheet too, and one shared rule would put a guide
on every pin of every symbol."
```

---

### Task 3: Dispatch the neighbour sweep on the editor

**Files:**
- Modify: `eeschema/tools/ee_grid_helper.cpp`

- [ ] **Step 1: Dispatch on the frame**

In `EE_GRID_HELPER::CollectAlignmentNeighbors`, replace:

```cpp
    for( SCH_ITEM* item : queryVisible( viewport, aSkip ) )
    {
        const std::optional<BOX2I> box = GetAlignmentBox( item );

        if( !box )
            continue;

        boxes.push_back( *box );
    }
```

with:

```cpp
    // One sweep, two rules.  A symbol is made of pins and graphics; a sheet is made of symbols
    // and subsheets.  Neither set of targets makes any sense in the other editor.
    const bool symbolEditor = inSymbolEditor();

    for( SCH_ITEM* item : queryVisible( viewport, aSkip ) )
    {
        const std::optional<BOX2I> box = symbolEditor ? GetSymbolAlignmentBox( item )
                                                     : GetAlignmentBox( item );

        if( !box )
            continue;

        // A zero-size pin box is legitimate, so IsValid() is the test rather than a non-empty
        // one.  GetBodyBoundingBox() can hand back a default-constructed box on a broken symbol,
        // and the engine would read that as a real point box at the origin.
        if( !box->IsValid() )
            continue;

        boxes.push_back( *box );
    }
```

- [ ] **Step 2: Build**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build --target qa_eeschema -j"$(nproc)"
```

Expected: compiles.

- [ ] **Step 3: Run both suites**

```bash
nix develop -c ./build/qa/tests/eeschema/qa_eeschema \
  && nix develop -c ./build/qa/tests/common/qa_common --run_test='AlignmentGuideEngine*'
```

Expected: both `*** No errors detected`.

- [ ] **Step 4: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add eeschema/tools/ee_grid_helper.cpp
git commit -m "eeschema: pick the alignment rule by editor in the neighbour sweep"
```

---

### Task 4: Wire the symbol editor move tool

This mirrors `SCH_MOVE_TOOL::doMoveSelection` (`eeschema/tools/sch_move_tool.cpp:815-895`). Read that first — the comments there explain why each piece is where it is, and every one of those reasons applies here.

**Files:**
- Modify: `eeschema/tools/symbol_editor_move_tool.cpp`

- [ ] **Step 1: Add the lifecycle flag**

In `SYMBOL_EDITOR_MOVE_TOOL::doMoveSelection`, directly after `AXIS_LOCK axisLock = AXIS_LOCK::NONE;` and `long lastArrowKeyAction = 0;` (around line 152):

```cpp
    // One-shot.  The block it guards sits in the follow-the-mouse path, which runs on every
    // motion event, so it needs a guard -- but unlike SCH_MOVE_TOOL this loop has no branch that
    // reshapes the selection mid-drag (checked: doDelete breaks out and duplicate only beeps),
    // so there is nothing to re-arm it for and the box measured at drag start stays correct.
    bool armGuides = true;
```

- [ ] **Step 2: Set the move context once the drag reference exists**

Directly after `m_moveInProgress = true;` closes its block (around line 271, the `}` ending the `if( !m_moveInProgress )` block) and *before* the `// Follow the mouse` comment, insert:

```cpp
            if( armGuides )
            {
                // Measured exactly as CollectAlignmentNeighbors() measures neighbours -- hence
                // the shared GetSymbolAlignmentBox() -- or the guides align edges that are not
                // where the user sees them.
                BOX2I guideBBox;

                for( EDA_ITEM* item : selection )
                {
                    if( std::optional<BOX2I> box = EE_GRID_HELPER::GetSymbolAlignmentBox( item ) )
                        guideBBox.Merge( *box );
                }

                // Guides outrank pin-anchor snapping only when everything being moved is
                // something the guides actually measure.  Dragging a field or a text box keeps
                // anchor > guide.
                const bool allBodies =
                        std::all_of( selection.begin(), selection.end(),
                                     []( const EDA_ITEM* aItem )
                                     {
                                         return EE_GRID_HELPER::GetSymbolAlignmentBox( aItem )
                                                 .has_value();
                                     } );

                // prevPos, not m_cursor: the items sit where prevPos put them and this event's
                // movement is applied further down.  The engine extrapolates the moving box from
                // the pair, so the two must agree.
                //
                // An invalid box would reach the engine as a real point box at the origin and
                // drag the selection towards it, so a selection with nothing measurable in it
                // gets no context rather than an empty one.
                if( guideBBox.IsValid() )
                {
                    grid.SetMoveContext( guideBBox, prevPos, allBodies );

                    // Must follow SetMoveContext(): the sweep sorts neighbours by distance from
                    // the moving box's centre.
                    grid.CollectAlignmentNeighbors( selection );
                }
                else
                {
                    grid.ClearMoveContext();
                }

                armGuides = false;
            }
```

- [ ] **Step 3: Drop stale guides on the arrow-key branch**

Inside `if( controls->GetSettings().m_lastKeyboardCursorPositionValid && ... )`, as the very first statement of the block (before `VECTOR2I keyboardPos(...)`):

```cpp
                // This branch repositions without BestSnapAnchor(), which is where stale guides
                // normally get dropped.  m_lastKeyboardCursorPositionValid stays true until the
                // mouse really moves, so guides painted by the preceding drag would linger on
                // screen while the selection walks off under the arrow keys.
                grid.clearAlignmentGuides();
```

- [ ] **Step 4: Drop guides when the axis lock overrides the cursor**

Replace:

```cpp
            if( axisLock == AXIS_LOCK::HORIZONTAL )
                m_cursor.y = prevPos.y;
            else if( axisLock == AXIS_LOCK::VERTICAL )
                m_cursor.x = prevPos.x;
```

with:

```cpp
            if( axisLock != AXIS_LOCK::NONE )
            {
                // The lock overrides the snapped cursor, so any guide just painted for it is
                // now a line the selection is not going to reach.  Better none than one drawn
                // where the item cannot go.
                grid.clearAlignmentGuides();

                if( axisLock == AXIS_LOCK::HORIZONTAL )
                    m_cursor.y = prevPos.y;
                else
                    m_cursor.x = prevPos.x;
            }
```

- [ ] **Step 5: Confirm there is nothing to re-arm**

`SCH_MOVE_TOOL` re-measures its box after a rotate, mirror or label conversion mid-drag. This loop has no such branch — verified by enumerating its `evt->IsAction` handlers:

```bash
cd /home/asqude/projecte/PixelCad/kicad
grep -n "IsAction( &SCH_ACTIONS::\|IsAction( &ACTIONS::" eeschema/tools/symbol_editor_move_tool.cpp
```

Expected: `move`, `refreshPreview`, `doDelete` (which `break`s out of the loop) and `duplicate` (which calls `wxBell()` and does nothing). No branch reshapes the selection, so the single-shot `armGuides` is correct and no re-arm is needed.

If this grep ever shows a rotate or mirror handler — i.e. upstream added one — set `armGuides = true` in it, or the guides will align against the pre-rotation shape for the rest of the drag.

- [ ] **Step 6: Add the include**

At the top of `eeschema/tools/symbol_editor_move_tool.cpp`, confirm `#include <tools/ee_grid_helper.h>` is present (it must be, the file constructs one) and add `#include <algorithm>` if `std::all_of` is not already available.

- [ ] **Step 7: Build**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build -j"$(nproc)" -- -k 0
```

Expected: no `error:` lines. `FAILED: resources/images.tar.gz` is a known, pre-existing packaging failure in this dev environment and must be ignored.

- [ ] **Step 8: Run every suite**

```bash
nix develop -c ./build/qa/tests/common/qa_common --run_test='AlignmentGuideEngine*'
nix develop -c ./build/qa/tests/eeschema/qa_eeschema
nix develop -c ./build/qa/tests/pcbnew/qa_pcbnew --run_test='PcbGridHelper*,*Align*'
```

Expected: three times `*** No errors detected`.

- [ ] **Step 9: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add eeschema/tools/symbol_editor_move_tool.cpp
git commit -m "Smart alignment guides in the symbol editor move tool

Pins align to pins and body graphics to each other, and a column of pins
snaps to equal pitch, because the engine sees each pin as a zero-size box
whose gaps to its neighbours are the pitch.

Lifecycle mirrors SCH_MOVE_TOOL: the moving box is re-measured whenever the
selection changes shape, the neighbour sweep is a one-shot, and guides are
dropped on the arrow-key branch and whenever the axis lock overrides the
snapped cursor -- both reposition without going through BestSnapAnchor(),
which is where stale guides otherwise get cleared."
```

---

### Task 5: Guides on symbol body resize handles

`SCH_POINT_EDITOR` already snaps sheet resize handles to guides via `EE_GRID_HELPER::AlignPointToGuides()`. In the symbol editor the same gesture resizes a body rectangle, and there the handle *does* have things worth lining up with — the pins.

**Files:**
- Modify: `eeschema/tools/sch_point_editor.cpp`

- [ ] **Step 1: Widen the gate**

Replace:

```cpp
            // Smart alignment guides while resizing a sheet: line the dragged corner up with
            // the sheets and symbols around it.  Sheets only for now -- a shape's handle has
            // no relationship to anything else on the sheet worth guiding to.
            if( item->Type() == SCH_SHEET_T )
            {
                cursorPos = grid->AlignPointToGuides(
                        cursorPos, collectGuideNeighbors ? &selection : nullptr );
                collectGuideNeighbors = false;
            }
```

with:

```cpp
            // Smart alignment guides while resizing.  A sheet lines its corner up with the
            // sheets and symbols around it.  In the symbol editor a body outline lines up with
            // the pins, which is the whole point of drawing one.  A shape on a schematic sheet
            // is excluded: there it has no relationship to anything worth guiding to.
            const bool guideResize = item->Type() == SCH_SHEET_T
                                     || ( item->Type() == SCH_SHAPE_T
                                          && m_frame->IsType( FRAME_SCH_SYMBOL_EDITOR ) );

            if( guideResize )
            {
                cursorPos = grid->AlignPointToGuides(
                        cursorPos, collectGuideNeighbors ? &selection : nullptr );
                collectGuideNeighbors = false;
            }
```

- [ ] **Step 2: Build**

```bash
cd /home/asqude/projecte/PixelCad
nix develop -c cmake --build build -j"$(nproc)" -- -k 0
```

Expected: no `error:` lines.

- [ ] **Step 3: Run the suites**

```bash
nix develop -c ./build/qa/tests/eeschema/qa_eeschema \
  && nix develop -c ./build/qa/tests/common/qa_common --run_test='AlignmentGuideEngine*'
```

Expected: both `*** No errors detected`.

- [ ] **Step 4: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add eeschema/tools/sch_point_editor.cpp
git commit -m "Snap symbol body resize handles to the alignment guides

A body outline exists to enclose the pins, so its corner has something worth
lining up with.  A shape on a schematic sheet still does not, and stays
excluded."
```

---

### Task 6: Manual verification checklist

Nothing automatable can prove a guide is on screen. Three rendering defects in this feature reached the user because no test exercises the GAL.

**Files:**
- Create: `docs/superpowers/plans/2026-07-26-smart-guides-symbol-editor-verification.md`

- [ ] **Step 1: Write the checklist**

```markdown
# Smart Guides in the Symbol Editor — Manual Verification

## Launch

    cd /home/asqude/projecte/PixelCad
    nix develop -c ./build/kicad/kicad kicad/demos/cm5_minima/CM5_MINIMA_3.kicad_pro

Open the symbol editor and edit a multi-pin part (`CM5IO.kicad_sym` has several).

## Does it work

1. **Pin to pin.** Drag a pin until it is level with another → red dashed guide + snap.
2. **Equal pin pitch** — the original ask, applied to pins. With two pins in a column,
   drag a third toward the position where its gap equals the existing one → snap plus
   two badges reading the same number.
3. **Three or more pins** → a badge on every gap in the run, not just the pair.
4. **Body outline.** Drag a rectangle until an edge lines up with another shape.
5. **Body edge to pin.** Drag a rectangle so its edge meets the pin column.

## Rendering — where this feature has actually broken before

6. **Numbers must be readable.** White-on-red and red-on-red both shipped once. The
   badge is an unfilled dashed box with the number in guide red.
7. **Badges must not be hidden** by the shape underneath. The overlay pins itself to
   `GetMinDepth()`; if a number vanishes behind a filled body, that is the regression.
8. **Guide lines span the whole run**, from the first aligned item to the last, not
   just to the nearest one.
9. **Badge numbers must be plausible.** A 100 mil pin pitch reads `2.54`, not `0.03`.

## Grid legality

10. After any snap, pins must still sit on the grid. Symbol pins off-grid are a
    library-correctness bug that survives into every schematic using the part.
11. A `≈` prefix means the exact spacing was unreachable on this grid and the snap is
    the closest legal position. Expect it on parts whose graphics are not on the
    working grid; it is designed behaviour, not a defect.

## Lifecycle

12. **Rotate mid-drag** (`R`) → guides re-align to the rotated selection immediately.
13. **Arrow-key nudge** after a guide paints → the guide must vanish at once.
14. **Nothing left behind** after Esc, after a normal drop, and after switching tools.
15. **Axis lock** (post-arrow-key) suppresses guides on both axes. Deliberate.

## Regression sweep

16. Pin placement, pin editing, and shape drawing behave exactly as before.
17. In the *schematic*, dragging a symbol still aligns to bodies and never to individual
    pins. This is the check that the two box rules did not leak into each other.
```

- [ ] **Step 2: Commit**

```bash
cd /home/asqude/projecte/PixelCad
git add docs/superpowers/plans/2026-07-26-smart-guides-symbol-editor-verification.md
git commit -m "Add manual verification checklist for symbol editor guides"
```

---

## Known limitations, deliberately not addressed

- **Text, text boxes and fields are not alignment targets.** Font-dependent extents.
- **Badges are always millimetres**, ignoring the user's display units. Pre-existing
  across all three editors; tracked by the `ponytail:` marker in
  `common/preview_items/alignment_guide_geom.cpp`.
- **A single-axis centre snap draws a full crosshair** — `CenterMarks` carries no axis.
  Pre-existing, same marker file.
- **No preferences toggle.** Guides are on with Shift as the bypass, shared with anchor
  snapping. Out of scope here; needed before any upstream MR.
- **Pins are measured at their connection point, not their root.** Aligning the point a
  wire attaches to is the useful relationship; the root differs from it by the pin
  length, which is uniform within a well-drawn symbol anyway.
- **No centre-in-container.** `SetContainers()` is called only by the PCB port (board
  outline). The symbol-editor analogue would be centring a graphic inside the body
  outline, and the schematic analogue centring on the page; neither is wired. This is a
  gap shared by both remaining editors and belongs in its own change, not bolted onto
  this one.
- **No align/distribute integration.** `eeschema/tools/sch_align_tool.cpp` is upstream
  code, untouched, and does not use the guide engine.
