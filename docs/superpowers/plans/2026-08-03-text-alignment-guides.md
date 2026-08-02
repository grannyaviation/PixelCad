# Text Alignment Guides Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give schematic symbol fields (`U1`, `R5`, values, sheet name/file name) and free text
their own smart-alignment rule, so they line up with each other, with symbol and sheet bodies, and
— for free text only — with the drawing-sheet frame and title-block cells.

**Architecture:** A fifth box rule (`GetTextAlignmentBox`) and a fifth gesture predicate
(`IsTextSelection`) join the four that already exist in `EE_GRID_HELPER`. Which rule applies is
decided once at drag start from what is being dragged, never by filtering targets afterwards. Text
mode reuses the graphics machinery for the grid exemption and the per-motion drawing-sheet cell, but
keeps its own target set.

**Tech Stack:** KiCad C++ master (10.99) fork, wxWidgets, Boost.Test, CMake, Nix dev shell.

## Global Constraints

- Design spec: `docs/superpowers/specs/2026-08-03-text-alignment-guides-design.md`. Read it first.
- Code changes go in the **`kicad/` submodule clone**, on branch `feature/smart-guides`.
  Documentation changes go in the **outer `PixelCad` repo**, on `main`. Never mix the two in one
  commit.
- Scope is exactly `SCH_FIELD_T` and `SCH_TEXT_T`. Not `SCH_TEXTBOX_T`, not `SCH_LABEL_T` or any
  other label type. Do not widen it.
- KiCad house style: 4 spaces, no tabs, 100-column soft limit, `a`-prefixed parameters
  (`aItem`, `aSelection`), braces on their own line, comments explaining *why* not *what*.
- Every commit must compile. Do not commit a test whose implementation lands in a later task.
- **Never launch a GUI application** (`kicad`, `eeschema`, `pcbnew`). On-screen verification is the
  user's job; this plan only produces the checklist for it.
- Builds are long. Run them with `run_in_background: true` and poll, or they hit the 10-minute
  tool timeout.
- Build: `nix develop -c cmake --build build --target qa_eeschema`
- Test: `nix develop -c ./build/qa/tests/eeschema/qa_eeschema --run_test=EEGridHelperTest`
- Commit trailer, on every commit: `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`

---

### Task 1: The fifth box rule and the gesture predicate

The pure, headless-testable half. Nothing consumes it yet, so it lands with its own tests and
compiles on its own.

**Files:**
- Modify: `kicad/eeschema/tools/ee_grid_helper.h` (declarations, after `IsSheetPinSelection`)
- Modify: `kicad/eeschema/tools/ee_grid_helper.cpp` (includes; new functions before
  `CollectAlignmentNeighbors`)
- Test: `kicad/qa/tests/eeschema/test_ee_grid_helper.cpp`

**Interfaces:**
- Consumes: `EE_GRID_HELPER::GetAlignmentBox`, `GetGraphicAlignmentBox`, `GetSymbolAlignmentBox`,
  `GetSheetPinAlignmentBox` — all existing `public static`.
- Produces:
  - `static std::optional<BOX2I> EE_GRID_HELPER::GetTextAlignmentBox( const EDA_ITEM* aItem )`
  - `static bool EE_GRID_HELPER::IsTextSelection( const SELECTION& aSelection )`

  Both `public static`, both used by Task 2 (the sweep) and Task 3 (the move tool).

- [ ] **Step 1: Write the failing tests**

In `kicad/qa/tests/eeschema/test_ee_grid_helper.cpp`, add to the include block at the top
(it currently ends with `#include <layer_ids.h>`):

```cpp
#include <sch_field.h>
```

`FIELD_T` lives in `include/template_fieldnames.h`; if it is not visible through `sch_field.h`,
add `#include <template_fieldnames.h>` beside it.

Then insert both cases immediately **before** the existing
`BOOST_AUTO_TEST_CASE( CollectAlignmentNeighborsWithoutAFrameIsSafe )`:

```cpp
// Text was excluded from the guides originally because font metrics make a poor reference.  The
// exclusion is lifted deliberately: what the user wants lined up is a column of reference
// designators, and that means the box the eye sees, not the anchor point the file stores.
BOOST_AUTO_TEST_CASE( TextAlignmentBoxIsTheTextBox )
{
    SCH_TEXT text;
    text.SetText( wxT( "Notes" ) );
    text.SetPosition( VECTOR2I( 2540, -1270 ) );

    const std::optional<BOX2I> textBox = EE_GRID_HELPER::GetTextAlignmentBox( &text );

    BOOST_REQUIRE( textBox.has_value() );
    BOOST_CHECK_EQUAL( textBox->GetOrigin(), text.GetBoundingBox().GetOrigin() );
    BOOST_CHECK_EQUAL( textBox->GetEnd(), text.GetBoundingBox().GetEnd() );
    BOOST_CHECK( textBox->GetWidth() > 0 );
    BOOST_CHECK( textBox->GetHeight() > 0 );

    SCH_SHEET sheet;
    SCH_FIELD field( &sheet, FIELD_T::USER, wxT( "Ref" ) );
    field.SetText( wxT( "U1" ) );
    field.SetVisible( true );

    const std::optional<BOX2I> fieldBox = EE_GRID_HELPER::GetTextAlignmentBox( &field );

    BOOST_REQUIRE( fieldBox.has_value() );
    BOOST_CHECK_EQUAL( fieldBox->GetOrigin(), field.GetBoundingBox().GetOrigin() );
    BOOST_CHECK_EQUAL( fieldBox->GetEnd(), field.GetBoundingBox().GetEnd() );

    // A guide against text nobody can see is a lie, and an empty field has no box worth drawing.
    field.SetVisible( false );
    BOOST_CHECK( !EE_GRID_HELPER::GetTextAlignmentBox( &field ).has_value() );

    field.SetVisible( true );
    field.SetText( wxEmptyString );
    BOOST_CHECK( !EE_GRID_HELPER::GetTextAlignmentBox( &field ).has_value() );

    // Exclusive against the other four rules, like each of them is against the rest.
    BOOST_CHECK( !EE_GRID_HELPER::GetTextAlignmentBox( &sheet ).has_value() );
    BOOST_CHECK( !EE_GRID_HELPER::GetAlignmentBox( &text ).has_value() );
    BOOST_CHECK( !EE_GRID_HELPER::GetGraphicAlignmentBox( &text ).has_value() );
    BOOST_CHECK( !EE_GRID_HELPER::GetSymbolAlignmentBox( &text ).has_value() );
    BOOST_CHECK( !EE_GRID_HELPER::GetSheetPinAlignmentBox( &text ).has_value() );
}


// All-of, unlike the sheet-pin predicate.  A sheet pin drag hauls its connected wires into the
// selection and the predicate has to tolerate them; neither a field nor free text connects to
// anything, so there are no drag additions and the stricter test is the correct one.
BOOST_AUTO_TEST_CASE( TextSelectionRejectsBodies )
{
    SCH_SHEET sheet;
    SCH_FIELD field( &sheet, FIELD_T::USER, wxT( "Ref" ) );
    field.SetText( wxT( "U1" ) );
    field.SetVisible( true );

    SCH_TEXT text;
    text.SetText( wxT( "Notes" ) );

    SCH_SELECTION sel;
    BOOST_CHECK( !EE_GRID_HELPER::IsTextSelection( sel ) );

    sel.Add( &field );
    BOOST_CHECK( EE_GRID_HELPER::IsTextSelection( sel ) );

    sel.Add( &text );
    BOOST_CHECK( EE_GRID_HELPER::IsTextSelection( sel ) );

    // A body in the selection is a symbol or sheet move carrying its fields along, and it has to
    // keep the body rule or the body would chase its own reference designator.
    sel.Add( &sheet );
    BOOST_CHECK( !EE_GRID_HELPER::IsTextSelection( sel ) );
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /home/asqude/projecte/PixelCad/kicad
nix develop -c cmake --build build --target qa_eeschema
```

Expected: **compile error**, along the lines of
`error: no member named 'GetTextAlignmentBox' in 'EE_GRID_HELPER'` and the same for
`IsTextSelection`. That is the red state — the tests name functions that do not exist yet.

- [ ] **Step 3: Declare both functions in the header**

In `kicad/eeschema/tools/ee_grid_helper.h`, insert immediately after the closing `;` of the
`IsSheetPinSelection` declaration and before the `IsOffGrid` doc comment:

```cpp
    /**
     * The box alignment guides measure a *schematic text item* by, or nullopt for anything else.
     *
     * Fields and free text only -- SCH_FIELD_T and SCH_TEXT_T.  Text boxes already align under the
     * graphic rule, and a net label is connectable, so it must keep whole-grid-step offsets and
     * anchor-beats-guide.
     *
     * The drawn box, deliberately not the anchor point the other point rules use.  Anchors only
     * line up visually when two texts share a justification, and what the user wants is a column
     * of reference designators that reads flush.  The price is that the box moves when the string
     * does: renaming U1 to U10 shifts its right edge.
     *
     * Invisible fields, empty text and degenerate boxes are rejected -- a guide against something
     * nobody can see is a lie.
     */
    static std::optional<BOX2I> GetTextAlignmentBox( const EDA_ITEM* aItem );

    /**
     * True when aSelection is the gesture "move one or more fields or free text items".
     *
     * All-of, unlike IsSheetPinSelection(): a sheet pin drag hauls its connected wires into the
     * same selection, but text connects to nothing, so there are no drag additions to tolerate.  A
     * body in the selection makes it false, which keeps a whole-symbol move on the body rule with
     * its fields riding along.
     *
     * Shared by SCH_MOVE_TOOL and the neighbour sweep: the moving box and the targets must be
     * chosen by the same rule or the guides measure two different things.
     */
    static bool IsTextSelection( const SELECTION& aSelection );
```

- [ ] **Step 4: Add the includes**

In `kicad/eeschema/tools/ee_grid_helper.cpp`, the include block currently runs
`sch_draw_panel.h`, `sch_group.h`, `sch_item.h`, … Add two, keeping alphabetical order:

Insert before `#include <sch_group.h>`:

```cpp
#include <sch_field.h>
```

Insert after `#include <sch_tablecell.h>`:

```cpp
#include <sch_text.h>
```

Both are required, not cosmetic: the `static_cast` below fails on an incomplete type without them.

- [ ] **Step 5: Implement both functions**

In `kicad/eeschema/tools/ee_grid_helper.cpp`, insert immediately **before**
`void EE_GRID_HELPER::CollectAlignmentNeighbors( const SCH_SELECTION& aSkip )`:

```cpp
std::optional<BOX2I> EE_GRID_HELPER::GetTextAlignmentBox( const EDA_ITEM* aItem )
{
    const EDA_TEXT* text = nullptr;

    switch( aItem->Type() )
    {
    case SCH_FIELD_T:
    {
        const SCH_FIELD* field = static_cast<const SCH_FIELD*>( aItem );

        // A hidden reference or value still has a position and a box.  Drawing a guide against
        // one would line the user up with something that is not on the page.
        if( !field->IsVisible() )
            return std::nullopt;

        text = field;
        break;
    }

    case SCH_TEXT_T:
        // Only plain text.  SCH_LABEL and friends derive from SCH_TEXT but carry their own type
        // ids, so they never reach here -- which is what keeps connectable items on the strict
        // rule.
        text = static_cast<const SCH_TEXT*>( aItem );
        break;

    default:
        return std::nullopt;
    }

    // Tested on the string rather than on the resulting box: an empty string's text box is a
    // font-dependent sliver, not reliably zero, and a sliver at the item's position would win an
    // axis with an offset no user can see the reason for.
    if( text->GetText().IsEmpty() )
        return std::nullopt;

    const BOX2I box = aItem->GetBoundingBox();

    // Both implementations normalise and apply rotation -- and, for a field, the parent symbol's
    // transform -- so this is the box KiCad hit-tests, i.e. the one the eye sees.  The guards are
    // for the degenerate cases the font machinery can still produce.
    if( !box.IsValid() || box.GetWidth() <= 0 || box.GetHeight() <= 0 )
        return std::nullopt;

    return box;
}


bool EE_GRID_HELPER::IsTextSelection( const SELECTION& aSelection )
{
    return !aSelection.Empty()
           && std::all_of( aSelection.begin(), aSelection.end(),
                           []( const EDA_ITEM* aItem )
                           {
                               return GetTextAlignmentBox( aItem ).has_value();
                           } );
}
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd /home/asqude/projecte/PixelCad/kicad
nix develop -c cmake --build build --target qa_eeschema
nix develop -c ./build/qa/tests/eeschema/qa_eeschema --run_test=EEGridHelperTest
```

Expected: build succeeds, `*** No errors detected`, and the case count is **two higher** than
before (22 → 24).

If `TextAlignmentBoxIsTheTextBox` fails on the empty-field assertion, the font returned a
non-degenerate box for an empty string — that is exactly why the check is on `GetText()` and not on
the box, so re-read Step 5 rather than loosening the test.

- [ ] **Step 7: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add eeschema/tools/ee_grid_helper.h eeschema/tools/ee_grid_helper.cpp \
        qa/tests/eeschema/test_ee_grid_helper.cpp
git commit -F - <<'EOF'
Add an alignment rule for schematic fields and text

A fifth box rule beside the body, symbol-editor, graphic and sheet-pin
ones. Fields and free text are measured by their drawn box rather than
by their anchor point: anchors only line up visually when two texts
share a justification, and what is wanted is a column of reference
designators that reads flush.

Invisible fields, empty text and degenerate boxes are rejected. The
gesture predicate is all-of, unlike the sheet-pin one, because text
connects to nothing and so a drag hauls no wires in alongside it.

Nothing consumes either function yet.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 2: Wire text mode into the neighbour sweep and the containers

Everything inside `ee_grid_helper.cpp` that has to know text mode exists. No new unit test is
possible here — the sweep needs a live `KIGFX::VIEW` and a frame — so the gate is that the whole
existing suite stays green and the build stays clean. Say so honestly in the commit; do not claim
coverage this task does not have.

**Files:**
- Modify: `kicad/eeschema/tools/ee_grid_helper.h` (private members)
- Modify: `kicad/eeschema/tools/ee_grid_helper.cpp` (grid exemption ×2, sweep, containers,
  `clearMoveState`, `updateDynamicContainers`)

**Interfaces:**
- Consumes: `GetTextAlignmentBox`, `IsTextSelection` from Task 1.
- Produces: private members `bool m_textMode`, `bool m_dynamicCells`,
  `std::vector<BOX2I> m_dynamicNeighbors` (the last renamed from `m_graphicsNeighbors`). Nothing
  outside this file consumes them.

- [ ] **Step 1: Rename `m_graphicsNeighbors` and add the two new members**

In `kicad/eeschema/tools/ee_grid_helper.h`, replace this member block:

```cpp
    /// The graphics neighbours collected at drag start.  Kept because updateDynamicContainers()
    /// re-sets the engine's neighbour list on every motion to append the cell the item is
    /// currently over, and would otherwise drop them.
    std::vector<BOX2I> m_graphicsNeighbors;

    /// This drag is moving graphics only, so the graphic box rule applies, the drawing sheet is
    /// a target, and offsets need not be whole grid steps.
    bool m_graphicsMode = false;
```

with:

```cpp
    /// The neighbours collected at drag start, in the modes that use a dynamic container.  Kept
    /// because updateDynamicContainers() re-sets the engine's neighbour list on every motion to
    /// append the cell the item is currently over, and would otherwise drop them.
    std::vector<BOX2I> m_dynamicNeighbors;

    /// This drag is moving graphics only, so the graphic box rule applies, the drawing sheet is
    /// a target, and offsets need not be whole grid steps.
    bool m_graphicsMode = false;

    /// This drag is moving fields or free text only, so the text box rule applies and offsets
    /// need not be whole grid steps -- glyph extents are not grid multiples, so enforcing them
    /// would make the feature silent rather than strict.  Safe because text has no connection
    /// points to drag off a net.
    bool m_textMode = false;

    /// The drawing-sheet cell under the moving box is offered as a container, rebuilt per motion.
    /// Graphics always; text only when no field is selected -- see CollectAlignmentNeighbors().
    bool m_dynamicCells = false;
```

- [ ] **Step 2: Exempt text from the whole-grid-step rule**

In `kicad/eeschema/tools/ee_grid_helper.cpp` there are exactly two occurrences of this line, one
in `BestSnapAnchor()` and one in `AlignPointToGuides()`:

```cpp
    if( canUseGrid() && !m_graphicsMode )
```

Replace **both** with:

```cpp
    if( canUseGrid() && !m_graphicsMode && !m_textMode )
```

- [ ] **Step 3: Decide text mode at drag start**

In `CollectAlignmentNeighbors()`, immediately after the existing `sheetPinMode` declaration and its
comment:

```cpp
    // Disjoint from the other two by construction: a sheet pin has no graphic box, so the all_of
    // above already fails whenever one is in the selection.
    const bool sheetPinMode = !symbolEditor && IsSheetPinSelection( aSkip );
```

insert:

```cpp
    // Also disjoint: neither a field nor free text has a graphic box or a sheet-pin box, so both
    // tests above already fail whenever one is in the selection.
    m_textMode = !symbolEditor && IsTextSelection( aSkip );

    // The drawing-sheet cell as a container, rebuilt per motion.  Graphics always; text only when
    // no field is in the selection.  The cell spans the page, so as a neighbour it merges every
    // other target into a single cluster and the equal-gap search never runs -- which would cost a
    // reference-designator column its equal-pitch badges, a likelier want than centring a refdes
    // on the page.  Free text loses those badges and gains title-block centring, which is the
    // right trade for a notes block.
    m_dynamicCells = m_graphicsMode
                     || ( m_textMode
                          && std::none_of( aSkip.begin(), aSkip.end(),
                                           []( const EDA_ITEM* aItem )
                                           {
                                               return aItem->Type() == SCH_FIELD_T;
                                           } ) );
```

- [ ] **Step 4: Collect text targets, expanding fields from their parents**

Still in `CollectAlignmentNeighbors()`, inside the `for( SCH_ITEM* item : queryVisible( ... ) )`
loop, insert this block immediately after the closing brace of the `if( sheetPinMode )` block and
immediately before the `const std::optional<BOX2I> box = symbolEditor ? ...` ternary:

```cpp
        if( m_textMode )
        {
            // Fields are not view items -- SCH_SCREEN::Append() keeps SCH_FIELD_T out of the
            // R-tree by the same guard that keeps SCH_SHEET_PIN_T out -- so the query hands back
            // the owning symbol or sheet and the fields have to be expanded from it.
            std::vector<SCH_FIELD>* fields = nullptr;

            if( item->Type() == SCH_SYMBOL_T )
                fields = &static_cast<SCH_SYMBOL*>( item )->GetFields();
            else if( item->Type() == SCH_SHEET_T )
                fields = &static_cast<SCH_SHEET*>( item )->GetFields();

            if( fields )
            {
                for( SCH_FIELD& field : *fields )
                {
                    // The dragged field's parent is not itself selected, so queryVisible()'s
                    // by-pointer erase never reaches the field.  A target sitting on top of the
                    // moving box is an offset of zero, which wins its axis with an unbeatable
                    // distance and would freeze the drag under a permanent guide.
                    if( aSkip.Contains( &field ) )
                        continue;

                    if( const std::optional<BOX2I> fieldBox = GetTextAlignmentBox( &field ) )
                        pushTarget( &field, *fieldBox );
                }
            }

            // Text aligns to text and to bodies both, so this item contributes whichever it has:
            // its text box if it is free text, otherwise its body box if it is a symbol or sheet.
            if( const std::optional<BOX2I> textBox = GetTextAlignmentBox( item ) )
                pushTarget( item, *textBox );
            else if( const std::optional<BOX2I> bodyBox = GetAlignmentBox( item ) )
                pushTarget( item, *bodyBox );

            continue;
        }
```

- [ ] **Step 5: Point the container plumbing at the new flags**

Three edits, all in `CollectAlignmentNeighbors()` and `updateDynamicContainers()`.

First, replace:

```cpp
    // Copied before the move: updateDynamicContainers() rebuilds the list every motion.
    if( m_graphicsMode )
        m_graphicsNeighbors = boxes;
```

with:

```cpp
    // Copied before the move: updateDynamicContainers() rebuilds the list every motion.
    if( m_dynamicCells )
        m_dynamicNeighbors = boxes;
```

Second, in the container chain replace:

```cpp
    else if( m_graphicsMode )
    {
        // No static container in graphics mode.  The container is the drawing-sheet cell the
```

with:

```cpp
    else if( m_dynamicCells )
    {
        // No static container here.  The container is the drawing-sheet cell the
```

and replace the `sheetPinMode` branch:

```cpp
    else if( sheetPinMode )
    {
        // No container.  A sheet pin slides along its sheet's border, so "centred in the page" is
        // a position it cannot take and a candidate it must not be offered.
    }
```

with:

```cpp
    else if( sheetPinMode || m_textMode )
    {
        // No container.  A sheet pin slides along its sheet's border, so "centred in the page" is
        // a position it cannot take and a candidate it must not be offered.
        //
        // Text reaches here only when the selection holds a field, i.e. when m_dynamicCells was
        // deliberately refused above so the field keeps its equal-pitch badges.  The page
        // rectangle below is not an acceptable substitute: it is the *paper*, and the drawing
        // frame the user sees is inset from it by the sheet margins.
    }
```

Third, in `updateDynamicContainers()` replace:

```cpp
    if( !m_graphicsMode )
        return;
```

with:

```cpp
    if( !m_dynamicCells )
        return;
```

and, further down the same function, replace:

```cpp
    std::vector<BOX2I> neighbors = m_graphicsNeighbors;
```

with:

```cpp
    std::vector<BOX2I> neighbors = m_dynamicNeighbors;
```

- [ ] **Step 6: Reset the new state between drags**

Replace the whole of `clearMoveState()`:

```cpp
void EE_GRID_HELPER::clearMoveState()
{
    m_sheetSegments.clear();
    m_graphicsNeighbors.clear();
    m_graphicsMode = false;
}
```

with:

```cpp
void EE_GRID_HELPER::clearMoveState()
{
    m_sheetSegments.clear();
    m_dynamicNeighbors.clear();
    m_graphicsMode = false;
    m_textMode = false;
    m_dynamicCells = false;
}
```

A mode left set would apply the wrong box rule and the wrong grid exemption to the *next* drag,
which is how a stale-flag bug looks on screen: the first symbol move after a text move snaps
anywhere.

- [ ] **Step 7: Build and run the whole suite**

```bash
cd /home/asqude/projecte/PixelCad/kicad
nix develop -c cmake --build build --target qa_eeschema
nix develop -c ./build/qa/tests/eeschema/qa_eeschema
```

Expected: build succeeds with no new warnings, `*** No errors detected` for the whole
`qa_eeschema` binary — not just `EEGridHelperTest`. If `m_graphicsNeighbors` still appears
anywhere, the rename is incomplete; check with:

```bash
grep -rn "m_graphicsNeighbors" /home/asqude/projecte/PixelCad/kicad/eeschema
```

Expected: no output.

- [ ] **Step 8: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add eeschema/tools/ee_grid_helper.h eeschema/tools/ee_grid_helper.cpp
git commit -F - <<'EOF'
Collect text targets and containers for a text drag

Text mode picks its targets from the text rule and the body rule
together, so a field lines up with other fields, with free text, and
with symbol and sheet outlines. Fields are expanded from their owning
symbol or sheet: SCH_SCREEN::Append() keeps them out of the R-tree
beside sheet pins, so the view query never returns one.

Offsets need not be whole grid steps here, for the reason graphics get
the same exemption -- glyph extents are not grid multiples, so enforcing
them would make the feature silent rather than strict, and text has no
connection points to drag off a net.

The drawing-sheet cell is offered only when no field is selected. The
cell spans the page, so as a neighbour it merges every other target into
one cluster and the equal-gap search stops running; a reference
designator column keeps its equal-pitch badges instead, and free text
gets title-block centring.

No unit test: the sweep needs a live view and a frame. Covered by the
existing suite staying green and by manual checks 41-47.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 3: Wire text mode into the move tool

The moving box must be measured by the same rule as the targets, or the guides align edges that do
not exist. Without this the whole feature is silent: a text drag produces an invalid box, loses its
move context, and gets no guides at all — which is exactly how the sheet-pin gap presented.

**Files:**
- Modify: `kicad/eeschema/tools/sch_move_tool.cpp` (the `if( updateBBox )` block in
  `doMoveSelection()`, around lines 819–900)

**Interfaces:**
- Consumes: `EE_GRID_HELPER::IsTextSelection`, `EE_GRID_HELPER::GetTextAlignmentBox` from Task 1.
- Produces: nothing new. `ee_grid_helper.h` is already included by this file.

- [ ] **Step 1: Add the gesture test and extend the box ternary**

Replace:

```cpp
                // A hierarchical sheet pin is measured by its own rule and aligned to other sheet
                // pins.  Neither of the two rules above accepts one, so without this a sheet-pin
                // drag produced an invalid box, lost its move context, and got no guides at all.
                const bool sheetPinsOnly = EE_GRID_HELPER::IsSheetPinSelection( selection );

                BOX2I guideBBox;

                for( EDA_ITEM* item : selection )
                {
                    const std::optional<BOX2I> box =
                            sheetPinsOnly ? EE_GRID_HELPER::GetSheetPinAlignmentBox( item )
                            : graphicsOnly ? EE_GRID_HELPER::GetGraphicAlignmentBox( item )
                                           : EE_GRID_HELPER::GetAlignmentBox( item );

                    if( box )
                        guideBBox.Merge( *box );
                }
```

with:

```cpp
                // A hierarchical sheet pin is measured by its own rule and aligned to other sheet
                // pins.  Neither of the two rules above accepts one, so without this a sheet-pin
                // drag produced an invalid box, lost its move context, and got no guides at all.
                const bool sheetPinsOnly = EE_GRID_HELPER::IsSheetPinSelection( selection );

                // Fields and free text likewise, and for the same reason.  All-of rather than
                // any-of: text connects to nothing, so a drag hauls no wires in alongside it and
                // there is nothing to tolerate.
                const bool textOnly = EE_GRID_HELPER::IsTextSelection( selection );

                BOX2I guideBBox;

                for( EDA_ITEM* item : selection )
                {
                    const std::optional<BOX2I> box =
                            sheetPinsOnly ? EE_GRID_HELPER::GetSheetPinAlignmentBox( item )
                            : textOnly    ? EE_GRID_HELPER::GetTextAlignmentBox( item )
                            : graphicsOnly ? EE_GRID_HELPER::GetGraphicAlignmentBox( item )
                                           : EE_GRID_HELPER::GetAlignmentBox( item );

                    if( box )
                        guideBBox.Merge( *box );
                }
```

- [ ] **Step 2: Let a text drag prefer guides over anchors**

Replace:

```cpp
                    // Graphics prefer guides for the same reason whole symbols do: a logo has no
                    // business snapping to a pin.
                    //
                    // Sheet pins deliberately do NOT: a pin is connectable, so it keeps the
                    // anchor > guide rule every connectable thing here keeps, or dragging a pin
                    // onto a wire end stops attaching to it.  Anchors only reach 55 mil while
                    // guides reach two grid steps, so the two barely compete in open border space.
                    grid.SetMoveContext( guideBBox, prevPos, allBodies || graphicsOnly );
```

with:

```cpp
                    // Graphics prefer guides for the same reason whole symbols do: a logo has no
                    // business snapping to a pin.  Text is the same case -- a reference designator
                    // dropped near a pin should line up with the designator above it, not jump
                    // onto the pin, and anchors are checked first without this.
                    //
                    // Sheet pins deliberately do NOT: a pin is connectable, so it keeps the
                    // anchor > guide rule every connectable thing here keeps, or dragging a pin
                    // onto a wire end stops attaching to it.  Anchors only reach 55 mil while
                    // guides reach two grid steps, so the two barely compete in open border space.
                    grid.SetMoveContext( guideBBox, prevPos, allBodies || graphicsOnly || textOnly );
```

- [ ] **Step 3: Build and run the whole suite**

```bash
cd /home/asqude/projecte/PixelCad/kicad
nix develop -c cmake --build build --target qa_eeschema
nix develop -c ./build/qa/tests/eeschema/qa_eeschema
```

Expected: build succeeds, `*** No errors detected`.

- [ ] **Step 4: Commit**

```bash
cd /home/asqude/projecte/PixelCad/kicad
git add eeschema/tools/sch_move_tool.cpp
git commit -F - <<'EOF'
Measure a text drag by the text rule

The moving box and the targets have to come from the same rule or the
guides align edges the user cannot see. Without this a field or free
text drag produced an invalid box, lost its move context, and got no
guides at all.

A text drag also ranks guides above item anchors, as graphics and whole
symbols already do. Text is not connectable, so nothing can break, and
without it a reference designator dropped near a pin jumps to the pin
instead of lining up with the designator above it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

---

### Task 4: Full build, and the on-screen checklist

The automatable half ends here. This task proves nothing else in the tree broke and hands the user
the checks only they can run.

**Files:**
- Modify: `docs/superpowers/plans/2026-07-25-smart-guides-schematic-verification.md`
  (outer `PixelCad` repo, **not** the `kicad/` clone)

**Interfaces:**
- Consumes: the behaviour built in Tasks 1–3.
- Produces: checklist items 41–47.

- [ ] **Step 1: Build the whole tree**

This is long. Run it in the background and poll rather than blocking:

```bash
cd /home/asqude/projecte/PixelCad/kicad
nix develop -c cmake --build build
```

Expected: exit 0. Record the target count from the last line (it was 722/722 before this work).
A warning introduced by these files is a defect — fix it rather than noting it.

- [ ] **Step 2: Run the full eeschema QA binary**

```bash
cd /home/asqude/projecte/PixelCad/kicad
nix develop -c ./build/qa/tests/eeschema/qa_eeschema
```

Expected: `*** No errors detected`.

- [ ] **Step 3: Append the checklist section**

In `docs/superpowers/plans/2026-07-25-smart-guides-schematic-verification.md`, insert this section
immediately after the `40.` item that closes the "Hierarchical sheet pins" section and immediately
**before** the trailing `---` and the "Rendering issues trace to…" footer:

```markdown
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
    cell merges every neighbour into one cluster — the same cause as item 32). A text box
    (Place → Text Box) is not in scope and still aligns under the graphics rule. Net labels are
    not in scope at all. And a guide moves when you rename a field: the box is the glyph extents,
    so `U1` and `U10` do not have the same right edge.
```

- [ ] **Step 4: Verify the numbering and placement**

```bash
cd /home/asqude/projecte/PixelCad
grep -n "^4[0-7]\.\|^---\|^## " docs/superpowers/plans/2026-07-25-smart-guides-schematic-verification.md | tail -20
```

Expected: items 41–47 appear under a `## Field and free-text alignment` heading, after item 40, and
before the final `---`.

- [ ] **Step 5: Commit the docs to the outer repo**

```bash
cd /home/asqude/projecte/PixelCad
git add docs/superpowers/plans/2026-07-25-smart-guides-schematic-verification.md
git commit -F - <<'EOF'
Extend the schematic checklist for text alignment

Seven checks for the field and free-text rule, including the two that
catch the failure modes this design can actually produce: text targets
that never appear because fields are not view items, and a text mode
left set between drags.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
```

- [ ] **Step 6: Report to the user, do not launch anything**

Report: the full build result with its target count, the QA result, the commit hashes in both
repos, and the launch command for them to run themselves:

```
WAYLAND_DISPLAY=wayland-1 nix develop -c ./run-kicad.sh <your.kicad_pro>
```

Do **not** run it. Point them at checks 41–47.

---

## Notes for the implementer

- **The `!` off-grid glyph needs no change.** `IsOffGrid()` reads `GetConnectionPoints()`, which is
  empty for a field and for free text, so text never warns. If you find yourself editing it, you
  have misread the task.
- **The symbol editor is untouched.** Every mode decision is gated on `!symbolEditor`; pin names and
  field text there stay unaligned.
- **`MAX_GUIDE_NEIGHBORS` stays at 100.** Text mode pushes roughly three times the candidates on a
  dense sheet (body plus refdes plus value per symbol). The list is sorted by distance from the
  moving box, so the far ones trim first. This is a recorded cost in the spec, not a bug to fix
  here.
- **Do not add `SCH_TEXTBOX_T`.** It has a drawn rectangle and already aligns under the graphic
  rule. Adding it would give one item two rules.
