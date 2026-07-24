# Smart Alignment Guides — Plan 2: Schematic Editor

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the alignment guides built in Plan 1 work while dragging symbols in the schematic editor, without ever moving a symbol off the wire grid.

**Architecture:** The engine (`ALIGNMENT_GUIDE_ENGINE`) and renderer (`KIGFX::ALIGNMENT_GUIDE_GEOM`) already live in `common/` and are consumed by the PCB editor. `EE_GRID_HELPER` derives from the same `GRID_HELPER` base, so it already owns the move context and has the guide overlay registered with the view. This plan adds three things: an optional grid-legality filter in the engine, neighbour collection plus a guide query in `EE_GRID_HELPER::BestSnapAnchor()`, and drag-start/end wiring in `SCH_MOVE_TOOL`.

**Tech Stack:** C++17/20, CMake/Ninja, Boost.Test (`qa_common`), KiCad GAL/tool framework. Repo `/home/asqude/projecte/PixelCad/kicad`, branch `feature/smart-guides`. All commands run from `/home/asqude/projecte/PixelCad` inside `nix develop`.

**Spec:** `docs/superpowers/specs/2026-07-23-smart-guides-design.md` (milestone 3, schematic half)

---

## The one rule that matters

Schematic symbol pins must stay on the wire grid (typically 50 mil). If a symbol lands between grid points its pins no longer meet wires, **and KiCad does not warn you — the net silently disconnects.**

Therefore: **a candidate offset that is not a whole multiple of the grid step is rejected, never rounded.** Symbols start on-grid, so a whole-step offset keeps them on-grid. Rounding an offset to the nearest step would place the item somewhere that is *not* actually aligned while drawing a guide line claiming it is — a guide that lies. Silence is the honest outcome.

Consequence to accept, not fight: aligning two instances of the **same** symbol works (their exact offset is a whole number of steps). Aligning two **different** symbols by their edges often won't engage, because exact alignment would land off-grid.

**A previous draft of grid handling got this wrong in a way the tests missed** — it rounded each candidate's delta *before* the range test, collapsing every near candidate to zero; `|0|` then beat every genuine candidate and produced a "snap" with zero offset plus a guide aligned to nothing. That design was deleted. Do not reintroduce it. **Filter, never mutate.**

## Scope

**In:** the schematic editor (`eeschema`), symbol move via `SCH_MOVE_TOOL`.

**Out (Plan 3):** the **symbol editor** (`SYMBOL_EDIT_FRAME`) — it is a different frame with its own move tool, and shipping the schematic working is worth more than half of both. Also out: centre-in-container for the schematic (page-centring), which is far less useful than centring between neighbours and adds a page-geometry dependency; `KIND_BETWEEN` already covers "centre this between those two".

## File structure

| File | Responsibility | Change |
|---|---|---|
| `include/tool/alignment_guide_engine.h` | engine interface | add optional grid param to `FindSnap` |
| `common/tool/alignment_guide_engine.cpp` | candidate generation + selection | filter grid-illegal candidates |
| `qa/tests/common/test_alignment_guide_engine.cpp` | engine tests | 3 new cases |
| `eeschema/tools/ee_grid_helper.h` | schematic snapping interface | declare `CollectAlignmentNeighbors` |
| `eeschema/tools/ee_grid_helper.cpp` | schematic snapping | collect neighbours; query engine |
| `eeschema/tools/sch_move_tool.cpp` | schematic move loop | set/clear move context |

No new files. Every unit already exists; this plan connects them.

## Facts already established (do not re-derive)

- `EE_GRID_HELPER::BestSnapAnchor( const VECTOR2I& aOrigin, GRID_HELPER_GRIDS aGrid, const SCH_SELECTION& aSkip )` — `eeschema/tools/ee_grid_helper.cpp:149`
- Its snap radius is **fixed**: `constexpr int snapRange = SNAP_RANGE * schIUScale.IU_PER_MILS;` with `SNAP_RANGE 55` (`eeschema/default_values.h:83`). 55 mil against a 50 mil grid means exactly one grid step is reachable — deliberate and correct here.
- Its final grid fallback is the last four statements: `m_snapItem = std::nullopt;` → `if( canUseGrid() && !gridChecked ) pt = nearestGrid;` → `snapLineManager.SetSnapLineEnd( std::nullopt );` → `m_toolMgr->GetView()->SetVisible( &m_viewSnapPoint, false );` → `return pt;`
- `EE_GRID_HELPER( TOOL_MANAGER* )` calls `GRID_HELPER( aToolMgr, LAYER_SCHEMATIC_ANCHOR )`, so **`m_alignGuidePreview` is already added to the view** — no registration work needed.
- `queryVisible( const BOX2I&, const SCH_SELECTION& ) const` returns `std::set<SCH_ITEM*>` — `ee_grid_helper.cpp:306`
- `SCH_SYMBOL::GetBodyBoundingBox()` — `eeschema/sch_symbol.h:407`. Body only, excluding field text.
- `SCH_MOVE_TOOL::doMoveSelection` — `eeschema/tools/sch_move_tool.cpp:669`. Drag start is the `if( !m_moveInProgress ) { initializeMoveOperation( ... ); prevPos = m_cursor; ... }` block near line 805. Cleanup tail begins `if( restore_state )` near line 1073; the function ends `return !restore_state;` near line 1107.
- `EE_GRID_HELPER grid( m_toolMgr );` is declared at `sch_move_tool.cpp:672` and is the instance whose `BestSnapAnchor` is called at line 866.

**Why `GetBodyBoundingBox()` and not `GetBoundingBox()`:** Plan 1 lost time to exactly this. On the PCB, `ViewBBox()` turned out to be the bbox inflated by the board's max clearance, so guides aligned to an invisible halo outside the drawn courtyard. The moving selection and the neighbours **must be measured by the same rule**, and that rule must match what the user sees. `GetBoundingBox()` on a symbol includes field text, which drifts and is not what anyone aligns to.

---

### Task 1: Engine — reject grid-illegal candidates

**Starting point confirmed:** branch `feature/smart-guides` at `9f1d8d5030`, working tree clean, and `FindSnap` currently takes exactly two arguments. An earlier ad-hoc attempt at this task was cancelled before it changed anything.

**Files:**
- Modify: `kicad/include/tool/alignment_guide_engine.h`
- Modify: `kicad/common/tool/alignment_guide_engine.cpp`
- Modify: `kicad/qa/tests/common/test_alignment_guide_engine.cpp`

- [ ] **Step 1.1: Write the failing tests**

Append inside the suite, before `BOOST_AUTO_TEST_SUITE_END()`:

```cpp
BOOST_AUTO_TEST_CASE( GridLegalOffsetSurvives )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    engine.SetNeighbors( { BOX2I( VECTOR2I( 0, 0 ), VECTOR2I( 100, 50 ) ) } );

    // Left edges align at x=0 with delta -10, which is exactly 1 step of a grid of 10.
    BOX2I moving( VECTOR2I( 10, 500 ), VECTOR2I( 40, 20 ) );

    auto result = engine.FindSnap( moving, 15, VECTOR2D( 10, 10 ) );

    BOOST_REQUIRE( result.has_value() );
    BOOST_CHECK_EQUAL( result->Offset.x, -10 );
    BOOST_CHECK_EQUAL( result->Offset.y, 0 );
}


BOOST_AUTO_TEST_CASE( GridIllegalOffsetIsRejectedNotRounded )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    engine.SetNeighbors( { BOX2I( VECTOR2I( 0, 0 ), VECTOR2I( 100, 50 ) ) } );

    // Left edges would align with delta -3, which is not a multiple of 10.
    // The engine must NOT round it to 0 and must NOT report a snap on X.
    BOX2I moving( VECTOR2I( 3, 500 ), VECTOR2I( 40, 20 ) );

    auto result = engine.FindSnap( moving, 15, VECTOR2D( 10, 10 ) );

    // No X candidate is grid-legal and Y is far away, so there is no snap at all.
    BOOST_CHECK( !result.has_value() );
}


BOOST_AUTO_TEST_CASE( GridLegalCandidateBeatsNearerIllegalOne )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    // A's right edge at 100, B's left edge at 104.
    engine.SetNeighbors( { BOX2I( VECTOR2I( 0, 0 ), VECTOR2I( 100, 50 ) ),
                           BOX2I( VECTOR2I( 104, 0 ), VECTOR2I( 50, 50 ) ) } );

    // Moving left edge at 110: B.left gives delta -6 (illegal on a grid of 10),
    // A.right gives delta -10 (legal).  The legal, farther candidate must win.
    BOX2I moving( VECTOR2I( 110, 500 ), VECTOR2I( 40, 20 ) );

    auto result = engine.FindSnap( moving, 15, VECTOR2D( 10, 10 ) );

    BOOST_REQUIRE( result.has_value() );
    BOOST_CHECK_EQUAL( result->Offset.x, -10 );
}
```

**Derivation for the third case, verify it yourself before running:** with `ms = [110,150]`, neighbour A `[0,100]` gives candidates `0-110 = -110`, `100-110 = -10`, `0-150 = -150`, `100-150 = -50`, centre `50-130 = -80`; neighbour B `[104,154]` gives `104-110 = -6`, `154-110 = +44`, `104-150 = -46`, `154-150 = +4`, centre `129-130 = -1`. Within range 15: `-10` (legal), `-6` (illegal), `-1` (illegal), `+4` (illegal). After filtering, `-10` is the only survivor. If the filter ran *after* selection instead of before, `-1` would win and the result would be wrong — that is what this test pins.

- [ ] **Step 1.2: Run — expect the new cases to fail**

```bash
nix develop -c cmake --build build --target qa_common && \
  nix develop -c ./build/qa/tests/common/qa_common --run_test="AlignmentGuideEngine/*" -l message
```

Expected: the three new cases fail (the two-argument `FindSnap` will not compile with three arguments — so this first "failure" is a compile error; that is fine and expected, fix it by doing Step 1.3).

- [ ] **Step 1.3: Add the parameter**

In the header, change the declaration and extend its doc comment:

```cpp
    /**
     * Compute the best snap for aMoving.
     *
     * @param aMoving    the moving selection's bbox at the unsnapped position
     * @param aSnapRange maximum snap distance in world units
     * @param aGridStep  if set, candidates whose offset is not a whole multiple of this
     *                   step are rejected outright.  Callers whose items must stay on a
     *                   grid (schematic pins) pass it; offsets are never rounded, because
     *                   a rounded offset would leave the item unaligned while the guide
     *                   line claimed otherwise.
     * @return snap offset + guide graphics, or std::nullopt if nothing in range
     */
    std::optional<RESULT> FindSnap( const BOX2I& aMoving, int aSnapRange,
                                    const std::optional<VECTOR2D>& aGridStep = std::nullopt ) const;
```

- [ ] **Step 1.4: Implement the filter**

In `FindSnap`'s definition, add the third parameter, then inside the per-axis candidate loop insert the filter **before** the range test and before the nearest-wins comparison:

```cpp
        for( const SNAP_CANDIDATE& c : candidates )
        {
            if( aGridStep )
            {
                const double g = ( axis == 0 ) ? aGridStep->x : aGridStep->y;

                if( g > 0 )
                {
                    const double steps = c.Delta / g;

                    // Reject, never round: a rounded offset would leave the item off the
                    // alignment the guide line is about to claim.
                    if( std::abs( steps - std::round( steps ) ) > 1e-6 )
                        continue;
                }
            }

            if( std::abs( c.Delta ) > aSnapRange )
                continue;

            // ... existing nearest-wins comparison unchanged ...
        }
```

**Superseded by the Task 1 review — the shipped form is integer, not floating point.** A `double` tolerance is *relative to the step*, so at PCB scale (1 nm IU, 100 mil grid = 2540000 IU) the acceptance window is 2.54 IU and off-by-1 and off-by-2 offsets are wrongly accepted — the same shape as the deleted bug, just at nanometre magnitude. The parameter is therefore `std::optional<VECTOR2I>` and the test is exact:

```cpp
            if( aGridStep )
            {
                const int g = ( axis == 0 ) ? aGridStep->x : aGridStep->y;

                // Reject, never round: a rounded offset would leave the item off the
                // alignment the guide line is about to claim.  Fails closed on a
                // non-positive step, since a missed rejection means a disconnected net.
                if( g <= 0 || c.Delta % g != 0 )
                    continue;
            }
```

Exact, scale-free, no epsilon to justify, and no `<cmath>` needed.

Order note: the grid test may sit either side of the range test — both are `continue` in a side-effect-free loop, so they commute. Range-first is marginally cheaper. The original instruction to place it first was a vestige of the deleted design, where the operation mutated `Delta` and order genuinely mattered.

- [ ] **Step 1.5: Run — all green**

```bash
nix develop -c cmake --build build --target qa_common && \
  nix develop -c ./build/qa/tests/common/qa_common --run_test="AlignmentGuideEngine/*" -l message
```

Expected: `*** No errors detected`, with 22 cases (19 existing + 3 new). The 19 existing must pass **unmodified** — they pass no grid, so the filter is inert for them.

- [ ] **Step 1.6: Commit**

```bash
git -C kicad add include/tool/alignment_guide_engine.h common/tool/alignment_guide_engine.cpp \
  qa/tests/common/test_alignment_guide_engine.cpp
git -C kicad commit -m "Let alignment guide callers require grid-legal offsets

Schematic symbols must stay on the wire grid or their pins silently stop
meeting wires.  Reject candidates whose offset is not a whole multiple of
the grid step rather than rounding them, since a rounded offset leaves the
item unaligned while the guide line claims otherwise.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: EE_GRID_HELPER — collect neighbour symbols

**Files:**
- Modify: `kicad/eeschema/tools/ee_grid_helper.h`
- Modify: `kicad/eeschema/tools/ee_grid_helper.cpp`

- [ ] **Step 2.1: Declare the collector**

In `ee_grid_helper.h`, in the public section next to the `BestSnapAnchor` declarations:

```cpp
    /**
     * Collect neighbour symbol bounding boxes for smart alignment guides.
     * Call once at drag start, after SetMoveContext().
     *
     * @param aSkip the items being dragged (excluded from the neighbour set)
     */
    void CollectAlignmentNeighbors( const SCH_SELECTION& aSkip );
```

- [ ] **Step 2.2: Implement it**

In `ee_grid_helper.cpp`, add near `queryVisible` (around line 306):

```cpp
void EE_GRID_HELPER::CollectAlignmentNeighbors( const SCH_SELECTION& aSkip )
{
    ALIGNMENT_GUIDE_ENGINE& engine = getSnapManager().GetAlignmentEngine();
    engine.Clear();

    if( !m_moveContext || !m_toolMgr )
        return;

    const BOX2I viewport = BOX2ISafe( m_toolMgr->GetView()->GetViewport() );

    struct SCORED
    {
        BOX2I  Box;
        double Dist;
    };

    std::vector<SCORED> scored;
    const VECTOR2D      ref( m_moveContext->OriginalBBox.Centre() );

    for( SCH_ITEM* item : queryVisible( viewport, aSkip ) )
    {
        if( item->Type() != SCH_SYMBOL_T )
            continue;

        // Body box only: must match how the moving selection is measured in
        // SCH_MOVE_TOOL, and field text is not what anyone aligns to.
        const BOX2I box = static_cast<SCH_SYMBOL*>( item )->GetBodyBoundingBox();

        if( !box.IsValid() )
            continue;

        scored.push_back( { box, ( VECTOR2D( box.Centre() ) - ref ).EuclideanNorm() } );
    }

    // Guides are hints; dropping distant neighbours bounds the per-motion cost.
    constexpr size_t MAX_GUIDE_NEIGHBORS = 100;

    if( scored.size() > MAX_GUIDE_NEIGHBORS )
    {
        std::partial_sort( scored.begin(), scored.begin() + MAX_GUIDE_NEIGHBORS, scored.end(),
                           []( const SCORED& a, const SCORED& b ) { return a.Dist < b.Dist; } );
        scored.resize( MAX_GUIDE_NEIGHBORS );
    }

    std::vector<BOX2I> boxes;
    boxes.reserve( scored.size() );

    for( const SCORED& s : scored )
        boxes.push_back( s.Box );

    engine.SetNeighbors( std::move( boxes ) );
}
```

Notes to verify rather than assume:
- The distance is computed in `VECTOR2D` deliberately. Plan 1 shipped an `int` subtraction here that could overflow for far-apart centres; do not "simplify" it back.
- `box.IsValid()` guards the engine's documented behaviour that an uninitialised `BOX2I` is treated as a real point box at the origin — an invalid box would become a phantom neighbour at (0,0).
- Includes: `<algorithm>` (for `std::partial_sort`) and `<sch_symbol.h>` (for `SCH_SYMBOL` and `SCH_SYMBOL_T`). Grep the top of the file first and add only what is genuinely absent.

- [ ] **Step 2.3: Build**

```bash
nix develop -c cmake --build build --target eeschema
```

Expected: compiles and links. Nothing calls the new method yet, so behaviour is unchanged.

- [ ] **Step 2.4: Commit**

```bash
git -C kicad add eeschema/tools/ee_grid_helper.h eeschema/tools/ee_grid_helper.cpp
git -C kicad commit -m "Collect neighbour symbol boxes for schematic alignment guides

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: EE_GRID_HELPER — query the engine in BestSnapAnchor

**Files:**
- Modify: `kicad/eeschema/tools/ee_grid_helper.cpp`

- [ ] **Step 3.1: Clear stale guides at the top**

`BestSnapAnchor` has several early returns (construction-line snap, anchor snap). If guides are showing and one of those wins, the guides must not stay painted. Put the clear where **every** path passes — next to the existing `clearAnchors();` near line 162:

```cpp
    clearAnchors();
    m_snapItem = std::nullopt;

    // Any exit other than the guide path below means "no guides"; clearing here covers
    // the early returns too.  Guarded so the common case costs no VIEW::Update.
    if( m_alignGuidePreview.HasGuides() )
    {
        m_alignGuidePreview.ClearGuides();
        m_toolMgr->GetView()->Update( &m_alignGuidePreview, KIGFX::GEOMETRY );
    }
```

- [ ] **Step 3.2: Add the guide query before the final return**

The function's last four statements are the grid fallback. Insert the guide query **after** the teardown and immediately before `return pt;`:

```cpp
    m_snapItem = std::nullopt;

    if( canUseGrid() && !gridChecked )
        pt = nearestGrid;

    snapLineManager.SetSnapLineEnd( std::nullopt );
    m_toolMgr->GetView()->SetVisible( &m_viewSnapPoint, false );

    // Smart alignment guides: only during an active move (context set by the move tool)
    // and only when snapping is enabled at all.  Runs after the teardown above so a guide
    // return leaves the canvas in the same clean state the plain grid return does.
    if( m_moveContext && m_enableSnap )
    {
        ALIGNMENT_GUIDE_ENGINE& engine = getSnapManager().GetAlignmentEngine();

        if( engine.HasInputs() )
        {
            BOX2I movingBox = m_moveContext->OriginalBBox;
            movingBox.Move( aOrigin - m_moveContext->OriginalCursor );

            // Grid step passed so the engine only offers offsets that keep pins on the
            // wire grid; see the header note on why it rejects rather than rounds.
            if( auto guide = engine.FindSnap( movingBox, snapRange, GetGridSize( aGrid ) ) )
            {
                m_alignGuidePreview.SetGuides( *guide );
                m_toolMgr->GetView()->Update( &m_alignGuidePreview, KIGFX::GEOMETRY );

                return aOrigin + guide->Offset;
            }
        }
    }

    return pt;
}
```

**Priority is therefore: construction-line snap > item anchor > alignment guide > grid.** Verify by reading the function that no earlier return can be reached once an alignment guide is available but an item anchor is not — an ordinary pin/wire snap must behave exactly as before this change.

**Converting the grid step (corrected after the Task 1 review).** `FindSnap` takes `std::optional<VECTOR2I>` — an integer step, tested with `%`. `GetGridSize()` returns a `VECTOR2D`, so convert at this boundary:

```cpp
            const VECTOR2I gridStep = KiROUND( GetGridSize( aGrid ) );
```

then pass `gridStep` to `FindSnap`.

An earlier draft of this step asserted that the step was integral. **Do not add that assertion** — `GRID::ToDouble()` (`common/settings/grid_settings.cpp:53`) parses a user-typed string, and eeschema exposes custom grids, so a fractional step is a legitimate user configuration (a 0.1 mil grid is 25.4 IU at schematic scale). The assertion would fire on valid input. Rounding at the boundary is the honest handling: positions are integers, so the grid a snap can actually honour is the rounded one.

- [ ] **Step 3.3: Build**

```bash
nix develop -c cmake --build build --target eeschema
```

- [ ] **Step 3.4: Confirm no regression in the shared suites**

```bash
nix develop -c cmake --build build --target qa_common && \
  nix develop -c ./build/qa/tests/common/qa_common --run_test="GridHelperTest/*" -l message
```

Expected: `*** No errors detected` (18 cases). The guide block is inert here because `m_moveContext` is never set in those tests.

- [ ] **Step 3.5: Commit**

```bash
git -C kicad add eeschema/tools/ee_grid_helper.cpp
git -C kicad commit -m "Offer alignment guide snaps in the schematic grid helper

Priority is construction line, then item anchor, then alignment guide, then
grid.  The active grid step is passed so guides can only place symbols on
grid-legal positions.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: SCH_MOVE_TOOL — set and clear the move context

**Files:**
- Modify: `kicad/eeschema/tools/sch_move_tool.cpp`

- [ ] **Step 4.1: Set the context at drag start**

In `doMoveSelection`, the drag-start block is near line 805:

```cpp
            if( !m_moveInProgress )    // Prepare to start moving/dragging
            {
                initializeMoveOperation( aEvent, selection, aCommit, internalPoints, snapLayer );
                prevPos = m_cursor;
                refreshTraits();
            }
```

Extend it, inside the `if`, after `refreshTraits();`:

```cpp
                // Measure the moving selection exactly as CollectAlignmentNeighbors()
                // measures neighbours, or the guides align edges the user cannot see.
                // NOTE: deliberately not SCH_SELECTION::GetBoundingBox() -- that merges
                // symbols via GetBoundingBox(), i.e. body + pins + visible fields, so the
                // two sides would disagree by the field/pin halo and every guide would sit
                // consistently wrong.  (Same defect the PCB port hit with ViewBBox().)
                BOX2I guideBBox;

                for( EDA_ITEM* item : selection )
                {
                    if( item->Type() == SCH_SYMBOL_T )
                        guideBBox.Merge( static_cast<SCH_SYMBOL*>( item )->GetBodyBoundingBox() );
                    else
                        guideBBox.Merge( item->GetBoundingBox() );
                }

                // prevPos, not m_cursor: the items sit where prevPos put them.  The engine
                // extrapolates the moving box from this pair, so the two must agree.
                grid.SetMoveContext( guideBBox, prevPos );
                grid.CollectAlignmentNeighbors( selection );
```

**Groups must be expanded into the skip set (found during Task 2).** Selecting an item inside a group selects the `SCH_GROUP`, not the member symbols — but the view still returns those members, so `queryVisible()`'s pointer-based skip misses them and a group drag would align to its own contents. Before calling `CollectAlignmentNeighbors`, build a skip selection that includes group children:

```cpp
                SCH_SELECTION guideSkip = selection;

                for( EDA_ITEM* item : selection )
                {
                    if( item->Type() == SCH_GROUP_T )
                    {
                        static_cast<SCH_GROUP*>( item )->RunOnChildren(
                                [&]( SCH_ITEM* aChild )
                                {
                                    guideSkip.Add( aChild );
                                },
                                RECURSE_MODE::RECURSE );
                    }
                }

                grid.CollectAlignmentNeighbors( guideSkip );
```

`RECURSE_MODE` is declared in `include/eda_item.h:47` with values `RECURSE` / `NO_RECURSE`; `SCH_GROUP::RunOnChildren` is at `eeschema/sch_group.h:156`. Use `RECURSE` so nested groups are covered. Verify `SCH_SELECTION::Add` is the right call for appending, and include `<sch_group.h>` if absent.

The same latent issue likely exists in the PCB port (`PCB_GROUP`); record it but do not fix it here — it is out of scope for this plan.

**Why `prevPos`:** Plan 1 hit exactly this. Pairing the bbox with a cursor value the items have not yet moved to offsets every guide for the whole drag by one event's movement — invisible on a slow drag, obvious on a fast flick. `prevPos` was just assigned `m_cursor` on the line above, so at this instant they are equal; using `prevPos` states the intent and stays correct if the surrounding code changes.

- [ ] **Step 4.2: Clear the context on every exit**

In the cleanup tail (the `if( restore_state )` block begins near line 1073; the function ends `return !restore_state;` near line 1107), add before the `return`:

```cpp
    grid.ClearMoveContext();
```

**Verify, do not assume:** enumerate every way `doMoveSelection` returns. Any `return` that happens *after* `EE_GRID_HELPER grid( m_toolMgr );` on line 672 and bypasses your call leaks the context, and the next interaction — possibly in a different tool — would see a stale bbox and offer nonsense snaps. `grid` is function-local, so its destructor is the backstop, but do not rely on that for correctness of a normal exit. Report the list of exits you found.

- [ ] **Step 4.3: Build**

```bash
nix develop -c cmake --build build --target eeschema
```

- [ ] **Step 4.4: Commit**

```bash
git -C kicad add eeschema/tools/sch_move_tool.cpp
git -C kicad commit -m "Enable smart alignment guides in the schematic move tool

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Whole-feature verification

**Files:** none — verification only, plus any fixes it forces.

- [ ] **Step 5.1: Build everything that could be affected**

```bash
nix develop -c cmake --build build --target eeschema pcbnew kicad qa_common
```

Expected: all link clean. `pcbnew` is included because Tasks 1–3 touch shared code it consumes.

- [ ] **Step 5.2: Full shared suite**

```bash
nix develop -c ./build/qa/tests/common/qa_common -l warning 2>&1 | tail -5
```

Expected: exactly one failure, `DrawingSheetReactive/AttachRegistersProxyAsDependent`. That is a **pre-existing upstream crash** (a dangling pointer in `TEXT_VAR_DEPENDENCY_INDEX::Unregister`), already confirmed to reproduce at clean upstream HEAD. Any *other* failure is yours.

- [ ] **Step 5.3: Confirm the PCB editor did not regress**

```bash
nix develop -c ./build/qa/tests/pcbnew/qa_pcbnew --run_test="*GridHelper*" -l message
```

Expected: `*** No errors detected` (23 cases).

- [ ] **Step 5.4: Report for manual verification**

Do **not** launch the GUI — it runs on the user's desktop and the interactive check is theirs. Report that the code is ready and list what needs eyes:

1. Drag one of two identical symbols toward horizontal alignment with the other → dashed guide line appears and the symbol snaps to it.
2. Same for vertical alignment.
3. Three identical symbols: drag the third toward equal spacing → snap plus two badges showing the same value.
4. Drag a symbol between two others → centres with equal badges both sides.
5. **Grid legality — the critical one.** After any guide snap, confirm pins still land on grid and wires stay connected. Nothing should ever sit between grid points.
6. Aligning two *different* symbols may not engage. That is the designed behaviour, not a bug.
7. Existing pin/wire/junction snapping unchanged.
8. Esc mid-drag → guides vanish, no leftovers on the next drag or in another tool.

---

## Out of scope, recorded so it is not lost

- **Symbol editor** (`SYMBOL_EDIT_FRAME`) — Plan 3. Different frame, different move tool.
- **Centre-in-container for the schematic** (page centring) — `KIND_BETWEEN` covers the useful case.
- **Preferences toggle and theme colour** — still unbuilt for both editors; the guide colour is the preview item's hard-coded default.
- **Align/Distribute port to eeschema** — separate spec item, unrelated to snapping.
