# Pin-Line Guides Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a footprint is dragged in the PCB editor, its centre or one of its own pads snaps
onto a neighbouring pad's centre line. The guide ignores the grid and wins its axis over the
existing edge/centre guides.

**Architecture:**
- **Engine:** `ALIGNMENT_GUIDE_ENGINE` (pure geometry, `common/tool/`) gets two new inputs: pin
  targets (world points) and moving points (relative to the moving box origin). It also gets a
  new candidate kind, `KIND_PIN_LINE`, which is decided before every other kind on each axis and
  is exempt from the grid step.
- **PCB grid helper:** `PCB_GRID_HELPER` collects the pin targets in `CollectAlignmentNeighbors()`
  through a pure static helper, and sets the moving points through a new `SetMovingPads()`.
- **Move tool:** `edit_tool_move_fct.cpp` calls `SetMovingPads()` wherever it (re)sets the move
  context.

**Tech Stack:** C++20, KiCad source tree (`~/projecte/PixelCad/kicad`, branch
`feature/smart-guides`), Boost.Test (`qa_common`, `qa_pcbnew`), ninja in the PixelCad dev shell.

**Spec:** `docs/superpowers/specs/2026-10-06-pin-line-guides-design.md`

## Global Constraints

- **Repo:** `~/projecte/PixelCad/kicad`, branch `feature/smart-guides`.
- **Remote:** `origin` = `grannyaviation/kicad`. Push to `feature/smart-guides` only.
- **Build and test** only inside the PixelCad dev shell:
  ```
  cd ~/projecte/PixelCad && nix develop -c bash -c 'cd kicad && <command>'
  ```
  Build with ninja in `kicad/build`; it is already configured with QA tests on.
- **Pin-line candidates:**
  - win their axis over all other kinds whenever any is within `aSnapRange`, nearest first;
  - are never subject to `aGridStep`;
  - `Approx` is always false.
- **Sources:** the moving box centre, plus every moving point (box-origin-relative, so it
  travels with the box).
- **Targets:**
  - pad centres of the neighbour footprints on the drag side;
  - plus PTH pads of opposite-side footprints;
  - excluding NPTH pads and pads with an empty number (paste-only apertures);
  - nearest 400 to the moving box centre.
- **Graphics:** one `SEG` on the shared ordinate, from the target point to the source point
  (post-snap). No badges.
- **Schematic / symbol editor:** unchanged. They never set pin targets.
- **Commits:**
  - message style as the branch: `Pcbnew: …` for pcbnew changes, plain sentence for common/engine
    changes;
  - trailers, after a blank line:
    ```
    Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
    Claude-Session: https://claude.ai/code/session_0197nXmgXMbyAcLrpUnwUMRc
    ```
- Never kill processes you did not start.

---

### Task 1: Engine — pin targets, moving points, `KIND_PIN_LINE`

**Files:**
- Modify: `include/tool/alignment_guide_engine.h`
- Modify: `common/tool/alignment_guide_engine.cpp`
- Test: `qa/tests/common/test_alignment_guide_engine.cpp` (new cases before `BOOST_AUTO_TEST_SUITE_END()`)

**Interfaces:**
- Produces:
  - `void ALIGNMENT_GUIDE_ENGINE::SetPinTargets( std::vector<VECTOR2I> aPoints )`: world
    coordinates.
  - `void ALIGNMENT_GUIDE_ENGINE::SetMovingPoints( std::vector<VECTOR2I> aPoints )`: relative to
    the moving box's `GetOrigin()`.
  - `Clear()` clears both.
  - `HasInputs()` is true when pin targets exist.
  - `FindSnap` behaviour as in Global Constraints.

- [ ] **Step 1: Write the failing tests** (append before `BOOST_AUTO_TEST_SUITE_END()` in `qa/tests/common/test_alignment_guide_engine.cpp`):

```cpp
// --- Pin-line guides (PixelCad 2026-10-06) -------------------------------------------------

BOOST_AUTO_TEST_CASE( PinLineSnapsBoxCentreOnX )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    engine.SetPinTargets( { VECTOR2I( 100, 1000 ) } );

    // Box origin x 76, width 40: centre x = 96, 4 left of the target.
    BOX2I moving( VECTOR2I( 76, 0 ), VECTOR2I( 40, 20 ) );
    auto  result = engine.FindSnap( moving, 10 );

    BOOST_REQUIRE( result.has_value() );
    BOOST_CHECK_EQUAL( result->Offset.x, 4 );   // centre 96 -> 100
    BOOST_CHECK_EQUAL( result->Offset.y, 0 );   // target y 1000 is far out of range
}

BOOST_AUTO_TEST_CASE( PinLineSnapsBoxCentreOnY )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    engine.SetPinTargets( { VECTOR2I( 1000, 50 ) } );

    BOX2I moving( VECTOR2I( 0, 37 ), VECTOR2I( 40, 20 ) );   // centre y = 47
    auto  result = engine.FindSnap( moving, 10 );

    BOOST_REQUIRE( result.has_value() );
    BOOST_CHECK_EQUAL( result->Offset.x, 0 );
    BOOST_CHECK_EQUAL( result->Offset.y, 3 );
}

BOOST_AUTO_TEST_CASE( PinLineSnapsMovingPadOntoTarget )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    engine.SetPinTargets( { VECTOR2I( 200, 1000 ) } );
    // A horizontal 2-pad part: pads 5 from each end of a 40-wide box.
    engine.SetMovingPoints( { VECTOR2I( 5, 10 ), VECTOR2I( 35, 10 ) } );

    // Origin x 192: pad 1 at 197, centre at 212, pad 2 at 227.  Pad 1 is 3 from the target.
    BOX2I moving( VECTOR2I( 192, 0 ), VECTOR2I( 40, 20 ) );
    auto  result = engine.FindSnap( moving, 10 );

    BOOST_REQUIRE( result.has_value() );
    BOOST_CHECK_EQUAL( result->Offset.x, 3 );
}

BOOST_AUTO_TEST_CASE( PinLineBeatsNearerEdgeAlignment )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    // Neighbour left edge at x = 0; the moving box's left edge is 1 away from it.
    engine.SetNeighbors( { BOX2I( VECTOR2I( 0, 500 ), VECTOR2I( 100, 50 ) ) } );
    // Pin target 6 away from the moving box centre: farther, but a pin line wins its axis.
    engine.SetPinTargets( { VECTOR2I( 27, 1000 ) } );

    BOX2I moving( VECTOR2I( 1, 0 ), VECTOR2I( 40, 20 ) );    // left 1, centre 21
    auto  result = engine.FindSnap( moving, 10 );

    BOOST_REQUIRE( result.has_value() );
    BOOST_CHECK_EQUAL( result->Offset.x, 6 );
}

BOOST_AUTO_TEST_CASE( PinLineIgnoresGridStepEdgeDoesNot )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    engine.SetPinTargets( { VECTOR2I( 103, 1000 ) } );

    BOX2I moving( VECTOR2I( 80, 0 ), VECTOR2I( 40, 20 ) );   // centre 100
    auto  pinned = engine.FindSnap( moving, 10, VECTOR2I( 10, 10 ) );

    BOOST_REQUIRE( pinned.has_value() );
    BOOST_CHECK_EQUAL( pinned->Offset.x, 3 );   // not a multiple of 10, still taken

    // Same off-grid distance as an edge alignment: rejected under the same step.
    ALIGNMENT_GUIDE_ENGINE edges;
    edges.SetNeighbors( { BOX2I( VECTOR2I( 83, 500 ), VECTOR2I( 100, 50 ) ) } );
    BOOST_CHECK( !edges.FindSnap( moving, 10, VECTOR2I( 10, 10 ) ).has_value() );
}

BOOST_AUTO_TEST_CASE( PinLineOutOfRangeNoSnap )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    engine.SetPinTargets( { VECTOR2I( 500, 500 ) } );

    BOX2I moving( VECTOR2I( 0, 0 ), VECTOR2I( 40, 20 ) );
    BOOST_CHECK( !engine.FindSnap( moving, 10 ).has_value() );
}

BOOST_AUTO_TEST_CASE( PinLineGuideRunsFromTargetToSource )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    engine.SetPinTargets( { VECTOR2I( 100, 1000 ) } );

    BOX2I moving( VECTOR2I( 76, 0 ), VECTOR2I( 40, 20 ) );   // centre (96, 10)
    auto  result = engine.FindSnap( moving, 10 );

    BOOST_REQUIRE( result.has_value() );
    BOOST_REQUIRE_EQUAL( result->Lines.size(), 1 );
    BOOST_CHECK( result->Badges.empty() );

    const SEG& s = result->Lines[0];
    BOOST_CHECK_EQUAL( s.A, VECTOR2I( 100, 1000 ) );   // target
    BOOST_CHECK_EQUAL( s.B, VECTOR2I( 100, 10 ) );     // snapped box centre
}

BOOST_AUTO_TEST_CASE( PinLineClearEmptiesPinInputs )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    engine.SetPinTargets( { VECTOR2I( 100, 1000 ) } );
    engine.SetMovingPoints( { VECTOR2I( 5, 5 ) } );
    BOOST_CHECK( engine.HasInputs() );

    engine.Clear();
    BOOST_CHECK( !engine.HasInputs() );

    BOX2I moving( VECTOR2I( 76, 0 ), VECTOR2I( 40, 20 ) );
    BOOST_CHECK( !engine.FindSnap( moving, 10 ).has_value() );
}
```

- [ ] **Step 2: Build and run; confirm RED**

Run: `cd ~/projecte/PixelCad && nix develop -c bash -c 'cd kicad && ninja -C build qa/tests/common/qa_common'`
Expected: compile errors `'SetPinTargets' is not a member` / `'SetMovingPoints' is not a member`.

- [ ] **Step 3: Implement**

`include/tool/alignment_guide_engine.h`:

1. Next to `SetContainers`:
```cpp
    /// Pad centres the moving selection may line up with (pin-line guides), in world coordinates.
    void SetPinTargets( std::vector<VECTOR2I> aPoints ) { m_pinTargets = std::move( aPoints ); }

    /// The moving selection's own pad centres, relative to the moving box's GetOrigin(), so they
    /// travel with whatever box FindSnap() is handed.  The box centre is always a source too.
    void SetMovingPoints( std::vector<VECTOR2I> aPoints ) { m_movingPoints = std::move( aPoints ); }
```
2. `Clear()` also does `m_pinTargets.clear(); m_movingPoints.clear();`.
3. `HasInputs()` returns
   `!m_neighbors.empty() || !m_containers.empty() || !m_pinTargets.empty();`.
4. In the `FindSnap` doc comment, after the `@param aGridStep` block, add this paragraph:
   `Pin-line candidates (SetPinTargets) are decided first on each axis: if any is in range the nearest wins outright, and the grid step does not apply to them -- a pad's centre is an exact electrical alignment, like an anchor snap.`
5. Add `KIND_PIN_LINE` to the kind enum, with the doc
   `///< A source (box centre or moving point) on a pin target's ordinate`. Extend the N1/N2
   comment with: `KIND_PIN_LINE   N1 = index into m_pinTargets, N2 = source (0 = box centre, k = m_movingPoints[k-1])`.
6. Private declarations:
```cpp
    /// The nearest pin-line candidate in range on aAxis, or std::nullopt.
    std::optional<SNAP_CANDIDATE> bestPinLine( const BOX2I& aMoving, int aAxis,
                                               int aSnapRange ) const;

    /// Source point N of aBox: 0 is the centre, k is m_movingPoints[k-1].
    VECTOR2I sourcePoint( const BOX2I& aBox, size_t aIndex ) const;
```
   and the members `std::vector<VECTOR2I> m_pinTargets;` and `std::vector<VECTOR2I> m_movingPoints;`.

`common/tool/alignment_guide_engine.cpp`:

1. Add before `FindSnap`:
```cpp
VECTOR2I ALIGNMENT_GUIDE_ENGINE::sourcePoint( const BOX2I& aBox, size_t aIndex ) const
{
    if( aIndex == 0 )
        return aBox.Centre();

    return aBox.GetOrigin() + m_movingPoints[aIndex - 1];
}


std::optional<ALIGNMENT_GUIDE_ENGINE::SNAP_CANDIDATE>
ALIGNMENT_GUIDE_ENGINE::bestPinLine( const BOX2I& aMoving, int aAxis, int aSnapRange ) const
{
    std::optional<SNAP_CANDIDATE> best;

    for( size_t t = 0; t < m_pinTargets.size(); ++t )
    {
        const int targetOrd = ( aAxis == 0 ) ? m_pinTargets[t].x : m_pinTargets[t].y;

        for( size_t s = 0; s <= m_movingPoints.size(); ++s )
        {
            const VECTOR2I src = sourcePoint( aMoving, s );
            const int      delta = targetOrd - ( ( aAxis == 0 ) ? src.x : src.y );

            if( std::abs( delta ) > aSnapRange )
                continue;

            // Strict <: the first target, then the first source, keeps a tie -- the box
            // centre before the pads, so a symmetric part lands on its centre.
            if( !best || std::abs( delta ) < best->Dist )
                best = SNAP_CANDIDATE{ delta, std::abs( delta ), KIND_PIN_LINE, t, s, targetOrd, false };
        }
    }

    return best;
}
```
2. In `FindSnap`, at the top of the per-axis loop (before `clusters[axis] = buildClusters(...)`):
```cpp
        // A pad's centre line wins its axis outright and is exempt from the grid: it is an exact
        // electrical alignment, the way an anchor snap is.  clusters[axis] stays empty; the
        // KIND_PIN_LINE graphics never read it.
        if( std::optional<SNAP_CANDIDATE> pin = bestPinLine( aMoving, axis, aSnapRange ) )
        {
            if( axis == 0 )
                result.Offset.x = pin->Delta;
            else
                result.Offset.y = pin->Delta;

            winners[axis] = pin;
            continue;
        }
```
3. In `buildGraphics`, add the case before `default:`:
```cpp
    case KIND_PIN_LINE:
    {
        // On the shared ordinate, from the pad the guide aligns to, to the point that now sits on
        // its line -- in post-snap coordinates, so the segment is exactly axis-parallel.
        const VECTOR2I target = m_pinTargets[aWinner.N1];
        const VECTOR2I source = sourcePoint( aSnapped, aWinner.N2 );

        if( aAxis == 0 )
            aResult.Lines.emplace_back( VECTOR2I( aWinner.Ord, target.y ), VECTOR2I( aWinner.Ord, source.y ) );
        else
            aResult.Lines.emplace_back( VECTOR2I( target.x, aWinner.Ord ), VECTOR2I( source.x, aWinner.Ord ) );

        break;
    }
```
   If the compiler rejects `std::abs( delta ) < best->Dist` for mixed types, both are `int`, so
   the check is fine as written. Use `std::abs` from `<cstdlib>`, which is already used in this
   file.

- [ ] **Step 4: Build and run; confirm GREEN**

Run: `cd ~/projecte/PixelCad && nix develop -c bash -c 'cd kicad && ninja -C build qa/tests/common/qa_common && ./build/qa/tests/common/qa_common --run_test=AlignmentGuideEngine --log_level=test_suite'`
Expected: `*** No errors detected`. The 33 existing cases and the 8 new ones all pass.

- [ ] **Step 5: Commit and push**

```bash
cd ~/projecte/PixelCad/kicad
git add include/tool/alignment_guide_engine.h common/tool/alignment_guide_engine.cpp qa/tests/common/test_alignment_guide_engine.cpp
git commit -F - <<'EOF'
Add pin-line candidates to the alignment guide engine

Pin targets (pad centres) and moving points (the selection's own pads,
box-relative) feed a new KIND_PIN_LINE: decided first on each axis, nearest
in range wins outright, exempt from the grid step, drawn as one segment from
the target pad to the aligned source.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0197nXmgXMbyAcLrpUnwUMRc
EOF
git push -q origin feature/smart-guides
```

---

### Task 2: PCB — collect pin targets and moving pads

**Files:**
- Modify: `pcbnew/tools/pcb_grid_helper.h`, `pcbnew/tools/pcb_grid_helper.cpp`
- Modify: `pcbnew/tools/edit_tool_move_fct.cpp` (the `SetMoveContext` block, around line 1221)
- Test: `qa/tests/pcbnew/test_pcb_grid_helper.cpp`
- Docs (PixelCad repo, separate commit): `~/projecte/PixelCad/docs/superpowers/plans/2026-07-24-smart-guides-manual-verification.md`

**Interfaces:**
- Consumes (Task 1): `ALIGNMENT_GUIDE_ENGINE::SetPinTargets`, `SetMovingPoints`; `Clear()` clears both.
- Produces:
  - `static std::vector<VECTOR2I> PCB_GRID_HELPER::CollectPinTargets( const std::vector<const FOOTPRINT*>& aFootprints, PCB_LAYER_ID aDragSide, const VECTOR2I& aRef, size_t aCap );`
  - `static std::vector<VECTOR2I> PCB_GRID_HELPER::MovingPadPoints( const std::vector<const FOOTPRINT*>& aMoved, const BOX2I& aMovingBox );`
  - `void PCB_GRID_HELPER::SetMovingPads( const std::vector<const FOOTPRINT*>& aMoved, const BOX2I& aMovingBox );`

- [ ] **Step 1: Write the failing tests** (in `qa/tests/pcbnew/test_pcb_grid_helper.cpp`, before `BOOST_AUTO_TEST_SUITE_END()`):

```cpp
namespace
{
// A footprint on aSide carrying one pad per entry: { number, attribute, position }.
std::unique_ptr<FOOTPRINT> makePinFootprint( PCB_LAYER_ID aSide,
        const std::vector<std::tuple<wxString, PAD_ATTRIB, VECTOR2I>>& aPads )
{
    auto fp = std::make_unique<FOOTPRINT>( nullptr );
    fp->SetLayer( aSide );

    for( const auto& [number, attrib, pos] : aPads )
    {
        PAD* pad = new PAD( fp.get() );
        pad->SetAttribute( attrib );
        pad->SetNumber( number );

        if( attrib == PAD_ATTRIB::SMD )
            pad->SetLayerSet( aSide == F_Cu ? PAD::SMDMask() : PAD::SMDMask().Flip() );
        else
            pad->SetLayerSet( PAD::PTHMask() );

        pad->SetPosition( pos );
        fp->Add( pad );
    }

    return fp;
}
} // namespace


BOOST_AUTO_TEST_CASE( PinTargetsKeepSameSideAndOppositeThroughHole )
{
    auto sameSide = makePinFootprint( B_Cu, { { "1", PAD_ATTRIB::SMD, VECTOR2I( 100, 0 ) },
                                              { "", PAD_ATTRIB::SMD, VECTOR2I( 110, 0 ) },     // paste-only aperture
                                              { "2", PAD_ATTRIB::NPTH, VECTOR2I( 120, 0 ) } } );
    auto otherSide = makePinFootprint( F_Cu, { { "1", PAD_ATTRIB::SMD, VECTOR2I( 200, 0 ) },
                                               { "2", PAD_ATTRIB::PTH, VECTOR2I( 210, 0 ) } } );

    const std::vector<VECTOR2I> got = PCB_GRID_HELPER::CollectPinTargets(
            { sameSide.get(), otherSide.get() }, B_Cu, VECTOR2I( 0, 0 ), 400 );

    BOOST_CHECK_EQUAL( got.size(), 2 );
    BOOST_CHECK( std::find( got.begin(), got.end(), VECTOR2I( 100, 0 ) ) != got.end() );
    BOOST_CHECK( std::find( got.begin(), got.end(), VECTOR2I( 210, 0 ) ) != got.end() );
}


BOOST_AUTO_TEST_CASE( PinTargetsKeepTheNearestCap )
{
    auto fp = makePinFootprint( F_Cu, { { "1", PAD_ATTRIB::SMD, VECTOR2I( 300, 0 ) },
                                        { "2", PAD_ATTRIB::SMD, VECTOR2I( 100, 0 ) },
                                        { "3", PAD_ATTRIB::SMD, VECTOR2I( 200, 0 ) } } );

    const std::vector<VECTOR2I> got =
            PCB_GRID_HELPER::CollectPinTargets( { fp.get() }, F_Cu, VECTOR2I( 0, 0 ), 2 );

    BOOST_REQUIRE_EQUAL( got.size(), 2 );
    BOOST_CHECK_EQUAL( got[0], VECTOR2I( 100, 0 ) );
    BOOST_CHECK_EQUAL( got[1], VECTOR2I( 200, 0 ) );
}


BOOST_AUTO_TEST_CASE( MovingPadPointsAreBoxRelative )
{
    auto fp = makePinFootprint( F_Cu, { { "1", PAD_ATTRIB::SMD, VECTOR2I( 1005, 2010 ) },
                                        { "2", PAD_ATTRIB::SMD, VECTOR2I( 1035, 2010 ) },
                                        { "", PAD_ATTRIB::SMD, VECTOR2I( 1020, 2010 ) } } );

    const BOX2I box( VECTOR2I( 1000, 2000 ), VECTOR2I( 40, 20 ) );
    const std::vector<VECTOR2I> got = PCB_GRID_HELPER::MovingPadPoints( { fp.get() }, box );

    BOOST_REQUIRE_EQUAL( got.size(), 2 );
    BOOST_CHECK_EQUAL( got[0], VECTOR2I( 5, 10 ) );
    BOOST_CHECK_EQUAL( got[1], VECTOR2I( 35, 10 ) );
}
```

Add `#include <tuple>`, `#include <memory>` and `#include <algorithm>` if not already included.
If `PAD::SMDMask()` / `PTHMask()` / `LSET::Flip()` differ in this tree, use the equivalent
layer sets (`LSET{ B_Cu, B_Mask, B_Paste }` for a back SMD pad, `LSET::AllCuMask() | LSET{ F_Mask, B_Mask }`
for PTH). The intent is: the SMD pads sit on their footprint's side, and the PTH pad is on all
copper.

- [ ] **Step 2: Build and run; confirm RED**

Run: `cd ~/projecte/PixelCad && nix develop -c bash -c 'cd kicad && ninja -C build qa/tests/pcbnew/qa_pcbnew'`
Expected: compile errors `'CollectPinTargets' is not a member of 'PCB_GRID_HELPER'` and `'MovingPadPoints' …`.

- [ ] **Step 3: Implement**

`pcbnew/tools/pcb_grid_helper.h`, after `AlignmentGuideStep`:
```cpp
    /**
     * Pin-line guide targets: pad centres of aFootprints on aDragSide (any side when it is
     * UNDEFINED_LAYER) plus plated through-hole pads on the other side, never NPTH holes or
     * unnumbered (paste-only) pads.  The aCap nearest to aRef are kept, nearest first.
     */
    static std::vector<VECTOR2I> CollectPinTargets( const std::vector<const FOOTPRINT*>& aFootprints,
                                                    PCB_LAYER_ID aDragSide, const VECTOR2I& aRef,
                                                    size_t aCap );

    /// The dragged footprints' pad centres (same filter) relative to aMovingBox's origin.
    static std::vector<VECTOR2I> MovingPadPoints( const std::vector<const FOOTPRINT*>& aMoved,
                                                  const BOX2I& aMovingBox );

    /**
     * Hand the dragged pads to the guide engine.  Call after SetMoveContext() and, at drag start,
     * after CollectAlignmentNeighbors() (which clears the engine).
     */
    void SetMovingPads( const std::vector<const FOOTPRINT*>& aMoved, const BOX2I& aMovingBox );
```

`pcbnew/tools/pcb_grid_helper.cpp`:

1. Near the top, in the anonymous namespace (or as a file-static), add:
```cpp
/// A pad a pin-line guide may use: not a mechanical hole, not a paste-only aperture.
bool isPinPad( const PAD* aPad )
{
    return aPad->GetAttribute() != PAD_ATTRIB::NPTH && !aPad->GetNumber().IsEmpty();
}
```
2. After `AlignmentGuideStep`:
```cpp
std::vector<VECTOR2I> PCB_GRID_HELPER::CollectPinTargets( const std::vector<const FOOTPRINT*>& aFootprints,
                                                          PCB_LAYER_ID aDragSide, const VECTOR2I& aRef,
                                                          size_t aCap )
{
    std::vector<VECTOR2I> points;

    for( const FOOTPRINT* fp : aFootprints )
    {
        const bool sameSide = aDragSide == UNDEFINED_LAYER || fp->GetSide() == aDragSide;

        for( const PAD* pad : fp->Pads() )
        {
            if( !isPinPad( pad ) )
                continue;

            if( !sameSide && pad->GetAttribute() != PAD_ATTRIB::PTH )
                continue;

            points.push_back( pad->GetPosition() );
        }
    }

    // Nearest first, ties broken by position so the order is total and stable across runs.
    auto key = [&]( const VECTOR2I& p )
    {
        return std::make_tuple( ( VECTOR2L( p ) - VECTOR2L( aRef ) ).SquaredEuclideanNorm(), p.x, p.y );
    };

    const size_t keep = std::min( points.size(), aCap );

    std::partial_sort( points.begin(), points.begin() + keep, points.end(),
                       [&]( const VECTOR2I& a, const VECTOR2I& b ) { return key( a ) < key( b ); } );
    points.resize( keep );

    return points;
}


std::vector<VECTOR2I> PCB_GRID_HELPER::MovingPadPoints( const std::vector<const FOOTPRINT*>& aMoved,
                                                        const BOX2I& aMovingBox )
{
    std::vector<VECTOR2I> points;

    for( const FOOTPRINT* fp : aMoved )
    {
        for( const PAD* pad : fp->Pads() )
        {
            if( isPinPad( pad ) )
                points.push_back( pad->GetPosition() - aMovingBox.GetOrigin() );
        }
    }

    return points;
}


void PCB_GRID_HELPER::SetMovingPads( const std::vector<const FOOTPRINT*>& aMoved,
                                     const BOX2I& aMovingBox )
{
    getSnapManager().GetAlignmentEngine().SetMovingPoints( MovingPadPoints( aMoved, aMovingBox ) );
}
```
   If `VECTOR2L` is not available, compute the squared distance in `int64_t` by hand.

3. In `CollectAlignmentNeighbors`:
   - Collect pin sources from **every** visible footprint, both sides, while the existing loop
     keeps building boxes only for same-side ones. Change the loop body to:
```cpp
        FOOTPRINT* fp = static_cast<FOOTPRINT*>( item );

        pinSources.push_back( fp );

        if( dragSide != UNDEFINED_LAYER && fp->GetSide() != dragSide )
            continue;

        boxes.push_back( fp->GetBoundingBox( false ) );
```
     Declare `std::vector<const FOOTPRINT*> pinSources;` next to `boxes`.
   - After `engine.SetNeighbors( std::move( boxes ) );`:
```cpp
    // Pin-line guides: pad centres of the same footprints plus through-hole pads from the other
    // side.  Nearest first and capped for the same reason as the neighbours above.
    constexpr size_t MAX_PIN_TARGETS = 400;

    engine.SetPinTargets( CollectPinTargets( pinSources, dragSide, m_moveContext->OriginalBBox.Centre(),
                                             MAX_PIN_TARGETS ) );
```

`pcbnew/tools/edit_tool_move_fct.cpp`, in the block that calls `grid.SetMoveContext( guideBBox, prevPos );`, after the `if( collectGuideNeighbors ) { … }` block:
```cpp
                    // The dragged pads ride on guideBBox, so they are re-measured with it (a
                    // rotation or flip mid-move), not only at drag start.  After the neighbour
                    // sweep, which clears the engine.
                    std::vector<const FOOTPRINT*> movedFootprints;

                    for( EDA_ITEM* item : moved_items )
                    {
                        if( item->Type() == PCB_FOOTPRINT_T )
                            movedFootprints.push_back( static_cast<const FOOTPRINT*>( item ) );
                    }

                    grid.SetMovingPads( movedFootprints, guideBBox );
```

- [ ] **Step 4: Build pcbnew and the tests; confirm GREEN**

Run: `cd ~/projecte/PixelCad && nix develop -c bash -c 'cd kicad && ninja -C build qa/tests/pcbnew/qa_pcbnew && ./build/qa/tests/pcbnew/qa_pcbnew --run_test=PCBGridHelperTest --log_level=test_suite'`
Expected: `*** No errors detected`, including the three new cases.

Also run `ninja -C build pcbnew/pcbnew_kiface_objects` (or `ninja -C build` if that target name
differs). `edit_tool_move_fct.cpp` must compile. Report the target used and its result.

- [ ] **Step 5: Manual check entry** (PixelCad repo).

Append to `~/projecte/PixelCad/docs/superpowers/plans/2026-07-24-smart-guides-manual-verification.md`, under "## Does the feature work at all", a subsection:
```markdown
### Pin-line guides (2026-10-06)

- [ ] On B.Cu with a 0.1 mm grid on, drag a vertical 0603 capacitor toward a connector pin whose
      centre is off the grid (e.g. sensor `J13` pin 4, x 165.65). It snaps so its centre (both pads)
      sits on the pin's X line, at the off-grid coordinate.
- [ ] A red line runs from the pin's pad centre to the capacitor's centre.
- [ ] A horizontal capacitor snaps one pad onto the pin line.
- [ ] Holding Shift: no pin-line snap, no line.
- [ ] Rotate the capacitor mid-drag (R): the snap follows the rotated pads.
- [ ] Edge guides between two parts still respect the grid (no off-grid edge snap).
```

- [ ] **Step 6: Commit and push** (two repos)

```bash
cd ~/projecte/PixelCad/kicad
git add pcbnew/tools/pcb_grid_helper.h pcbnew/tools/pcb_grid_helper.cpp pcbnew/tools/edit_tool_move_fct.cpp qa/tests/pcbnew/test_pcb_grid_helper.cpp
git commit -F - <<'EOF'
Pcbnew: pin-line guides while moving footprints

The move tool hands the guide engine the pad centres around the drag
(same side, plus through-hole pads from the other side; nearest 400) and
the dragged footprints' own pads, so a part's centre or pad snaps onto a
neighbouring pad's centre line.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0197nXmgXMbyAcLrpUnwUMRc
EOF
git push -q origin feature/smart-guides

cd ~/projecte/PixelCad
git add docs/superpowers/plans/2026-07-24-smart-guides-manual-verification.md
git commit -F - <<'EOF'
Checklist: pin-line guides

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0197nXmgXMbyAcLrpUnwUMRc
EOF
git push -q origin main
```
