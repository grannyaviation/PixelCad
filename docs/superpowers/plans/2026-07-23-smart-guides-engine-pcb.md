# Smart Alignment Guides — Plan 1: Engine + PCB Editor

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Figma-style alignment/equal-spacing/midpoint/center snapping with live guide rendering, working end-to-end in the KiCad PCB editor, backed by a unit-tested pure-geometry engine.

**Architecture:** A dependency-free `ALIGNMENT_GUIDE_ENGINE` (bbox in → snap offset + guide drawables out) lives in `common/tool/`, owned by `SNAP_MANAGER`. A new `KIGFX::ALIGNMENT_GUIDE_GEOM` preview item renders guides. `PCB_GRID_HELPER::BestSnapAnchor()` queries the engine during moves (priority: item anchor > guide > grid). The move tool provides drag context (original bbox + cursor) and neighbor collection happens once per drag.

**Tech Stack:** C++17, CMake/Ninja, Boost.Test (`qa_common`), KiCad GAL/tool framework. Repo: `/home/asqude/projecte/PixelCad/kicad` (upstream master). Build dir: `/home/asqude/projecte/PixelCad/build`. All build/test commands run inside `nix develop` from `/home/asqude/projecte/PixelCad`.

**Spec:** `docs/superpowers/specs/2026-07-23-smart-guides-design.md`

**Scope of this plan:** spec milestones 1–2 only (engine + PCB editor). Schematic/symbol port, Align/Distribute port, and preferences UI are follow-up plans.

**Design deviations from spec (approved-pending):**
- Mid-drag suppression uses **Shift**, not Ctrl: the move tool already maps Shift to "disable snapping" (`edit_tool_move_fct.cpp:1097` — `grid.SetSnap( !evt->Modifier( MD_SHIFT ) )`), and guides are snapping. Ctrl would collide with existing constraint toggles.
- "Midpoint between neighbors" is implemented as equal-gap-between-edges (gap left == gap right), which is what Figma actually shows, rather than center-of-centers.
- Badges display mm fixed in v1 (`ponytail:` comment marks the units-provider upgrade path).
- Center-in-area containers = board outline only in v1; "any item whose bbox encloses the cursor" (spec) is a follow-up — it needs an enclosure query per drag that the outline case doesn't.
- **`aGrid`/grid quantization dropped from this plan (decided after Task 1 review).** The spec's schematic rule ("guide candidates are quantized to the active grid first, so pins never leave the wire grid") still stands, but it belongs to the schematic/symbol plan, where it will have a real caller to design against. Quantizing the *delta*, as originally drafted here, was wrong in a way tests would not have caught: it rewrote each candidate's delta before the range test, so any candidate nearer than half a grid step collapsed to `0`, and `|0|` outranked every genuine candidate — yielding a reported "snap" with zero offset and a guide line aligned to nothing, while also bypassing the caller's grid fallback. The schematic plan should quantize the *target position* and reject candidates that then fall outside the snap range, not mangle deltas. Task 6 is removed accordingly.

**Conventions:**
- World units are nm (`pcbIUScale.IU_PER_MM = 1e6`). Y grows downward; `BOX2I::GetTop()` is min-Y.
- Commit messages: plain imperative (KiCad style), each ending with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`
- Run all commands from `/home/asqude/projecte/PixelCad` unless stated.

---

### Task 0: Branch + build baseline

**Files:** none created; git + cmake state only.

- [ ] **Step 0.1: Create feature branch**

```bash
git -C kicad checkout -b feature/smart-guides
```

- [ ] **Step 0.2: Configure the build**

```bash
nix develop -c cmake -S kicad -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DKICAD_BUILD_QA_TESTS=ON
```

Expected: configure completes without error. If `KICAD_BUILD_QA_TESTS` is reported unknown, re-run without it — QA tests are on by default in that case.

- [ ] **Step 0.3: Baseline build of the test target (long — first build compiles common)**

```bash
nix develop -c cmake --build build --target qa_common
```

Expected: `qa_common` binary at `build/qa/tests/common/qa_common`. This validates the toolchain before any code changes. First build may take 30–60 min; later builds are incremental (ccache is enabled by the dev shell).

- [ ] **Step 0.4: Smoke-run the existing grid helper tests**

```bash
nix develop -c ./build/qa/tests/common/qa_common --run_test="*GridHelper*" -l message
```

Expected: existing tests pass (or report "no test cases matching" — fine; the point is the binary runs).

---

### Task 1: Engine skeleton + first failing test (edge alignment, X axis)

**Files:**
- Create: `kicad/include/tool/alignment_guide_engine.h`
- Create: `kicad/common/tool/alignment_guide_engine.cpp`
- Create: `kicad/qa/tests/common/test_alignment_guide_engine.cpp`
- Modify: `kicad/common/CMakeLists.txt` (add source; find the line containing `tool/construction_manager.cpp` and add ours next to it)
- Modify: `kicad/qa/tests/common/CMakeLists.txt` (add test source alphabetically near `test_action_manager.cpp`)

- [ ] **Step 1.1: Write the header**

`kicad/include/tool/alignment_guide_engine.h` (KiCad GPL header comment block first — copy the one from `include/tool/construction_manager.h`, drop the author line):

```cpp
#pragma once

#include <optional>
#include <vector>

#include <geometry/seg.h>
#include <math/box2.h>
#include <math/vector2d.h>

/**
 * Pure-geometry engine computing "smart" alignment and spacing snaps for a moving
 * bounding box against a set of neighbor bounding boxes (Figma-style guides).
 *
 * Coordinates are KiCad world units.  The engine has no view, tool or wx
 * dependencies: callers translate items to boxes and interpret the returned
 * offset.  Headless unit-testable.
 */
class ALIGNMENT_GUIDE_ENGINE
{
public:
    struct GAP_BADGE
    {
        VECTOR2I Pos;      ///< World position of the gap midpoint
        int      Gap;      ///< Gap size in world units
        bool     Vertical; ///< True if the gap is measured along Y
    };

    struct RESULT
    {
        VECTOR2I               Offset;      ///< Add to the moving box position to snap
        std::vector<SEG>       Lines;       ///< Guide lines, already at snapped position
        std::vector<GAP_BADGE> Badges;      ///< Equal-spacing distance badges
        std::vector<VECTOR2I>  CenterMarks; ///< Crosshair marks for center snaps
    };

    void SetNeighbors( std::vector<BOX2I> aBoxes ) { m_neighbors = std::move( aBoxes ); }
    void SetContainers( std::vector<BOX2I> aBoxes ) { m_containers = std::move( aBoxes ); }

    void Clear()
    {
        m_neighbors.clear();
        m_containers.clear();
    }

    bool HasCandidates() const { return !m_neighbors.empty() || !m_containers.empty(); }

    /**
     * Compute the best snap for aMoving.
     *
     * @param aMoving    the moving selection's bbox at the unsnapped position
     * @param aSnapRange maximum snap distance in world units
     * @param aGrid      if set, offsets are quantized to multiples of this grid so
     *                   items that started on-grid stay on-grid; quantized offsets
     *                   that leave aSnapRange are dropped
     * @return snap offset + guide graphics, or std::nullopt if nothing in range
     */
    std::optional<RESULT> FindSnap( const BOX2I& aMoving, int aSnapRange,
                                    const std::optional<VECTOR2D>& aGrid = std::nullopt ) const;

private:
    /// One potential snap position along one axis
    ///
    /// NOTE: named SNAP_CANDIDATE, not CANDIDATE — `include/eda_item_flags.h:46`
    /// defines a `CANDIDATE` macro that leaks in through the include chain and
    /// breaks compilation.  (Found during Task 1 implementation.)
    struct SNAP_CANDIDATE
    {
        int    Delta;  ///< Offset along the axis to reach this candidate
        int    Kind;   ///< KIND_* — drives which guide graphics get built
        size_t N1;     ///< Index of first involved neighbor (or container)
        size_t N2;     ///< Index of second involved neighbor (equal-gap kinds)
    };

    enum
    {
        KIND_ALIGN,     ///< Edge/center aligned with a neighbor edge/center
        KIND_EQUAL_GAP, ///< Extends an existing neighbor gap (a->b == b->moving)
        KIND_BETWEEN,   ///< Equal gap on both sides between two neighbors
        KIND_CONTAINER, ///< Centered inside a container box
    };

    void collectAxisCandidates( const BOX2I& aMoving, int aAxis,
                                std::vector<SNAP_CANDIDATE>& aOut ) const;

    void buildGraphics( const BOX2I& aSnapped, int aAxis, const SNAP_CANDIDATE& aWinner,
                        RESULT& aResult ) const;

    std::vector<BOX2I> m_neighbors;
    std::vector<BOX2I> m_containers;
};
```

- [ ] **Step 1.2: Write the stub implementation**

`kicad/common/tool/alignment_guide_engine.cpp` (same GPL header block):

```cpp
#include <tool/alignment_guide_engine.h>

#include <cmath>
#include <cstdlib>

#include <math/util.h>

namespace
{
/// Min/max of a box along one axis (axis 0 = X, 1 = Y)
struct SPAN
{
    int Min;
    int Max;

    int Center() const { return Min + ( Max - Min ) / 2; }
    int Size() const { return Max - Min; }
};

SPAN spanOf( const BOX2I& aBox, int aAxis )
{
    if( aAxis == 0 )
        return { aBox.GetLeft(), aBox.GetRight() };

    return { aBox.GetTop(), aBox.GetBottom() };
}

bool spansOverlap( const SPAN& aA, const SPAN& aB )
{
    return aA.Min <= aB.Max && aB.Min <= aA.Max;
}
} // namespace


void ALIGNMENT_GUIDE_ENGINE::collectAxisCandidates( const BOX2I& aMoving, int aAxis,
                                                    std::vector<CANDIDATE>& aOut ) const
{
}


void ALIGNMENT_GUIDE_ENGINE::buildGraphics( const BOX2I& aSnapped, int aAxis,
                                            const CANDIDATE& aWinner, RESULT& aResult ) const
{
}


std::optional<ALIGNMENT_GUIDE_ENGINE::RESULT>
ALIGNMENT_GUIDE_ENGINE::FindSnap( const BOX2I& aMoving, int aSnapRange,
                                  const std::optional<VECTOR2D>& aGrid ) const
{
    return std::nullopt;
}
```

- [ ] **Step 1.3: Register the source files in CMake**

In `kicad/common/CMakeLists.txt`, find the line containing `tool/construction_manager.cpp` (grep for it) and add directly above it:

```
    tool/alignment_guide_engine.cpp
```

In `kicad/qa/tests/common/CMakeLists.txt`, add near `test_action_manager.cpp` (alphabetical):

```
    test_alignment_guide_engine.cpp
```

- [ ] **Step 1.4: Write the first failing test**

`kicad/qa/tests/common/test_alignment_guide_engine.cpp`:

```cpp
#include <boost/test/unit_test.hpp>

#include <tool/alignment_guide_engine.h>

BOOST_AUTO_TEST_SUITE( AlignmentGuideEngine )


BOOST_AUTO_TEST_CASE( NoNeighborsNoSnap )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    BOX2I moving( VECTOR2I( 0, 0 ), VECTOR2I( 40, 20 ) );

    BOOST_CHECK( !engine.FindSnap( moving, 10 ).has_value() );
}


BOOST_AUTO_TEST_CASE( EdgeAlignLeftX )
{
    ALIGNMENT_GUIDE_ENGINE engine;

    // Neighbor occupying x:[0,100], y:[0,50]
    engine.SetNeighbors( { BOX2I( VECTOR2I( 0, 0 ), VECTOR2I( 100, 50 ) ) } );

    // Moving box near x=3: left edges should align at x=0.  Y is far away on
    // purpose so no Y candidate is in range.
    BOX2I moving( VECTOR2I( 3, 500 ), VECTOR2I( 40, 20 ) );

    auto result = engine.FindSnap( moving, 10 );

    BOOST_REQUIRE( result.has_value() );
    BOOST_CHECK_EQUAL( result->Offset.x, -3 );
    BOOST_CHECK_EQUAL( result->Offset.y, 0 );
    BOOST_CHECK( !result->Lines.empty() );
}


BOOST_AUTO_TEST_SUITE_END()
```

- [ ] **Step 1.5: Build and verify the test fails**

```bash
nix develop -c cmake --build build --target qa_common && \
  nix develop -c ./build/qa/tests/common/qa_common --run_test="AlignmentGuideEngine/*" -l message
```

Expected: compiles; `EdgeAlignLeftX` FAILS (`result.has_value()` false), `NoNeighborsNoSnap` passes.

- [ ] **Step 1.6: Implement alignment candidates + minimal FindSnap**

Replace the two stub bodies in `alignment_guide_engine.cpp`:

```cpp
void ALIGNMENT_GUIDE_ENGINE::collectAxisCandidates( const BOX2I& aMoving, int aAxis,
                                                    std::vector<CANDIDATE>& aOut ) const
{
    const SPAN ms = spanOf( aMoving, aAxis );

    // Edge/center alignment: min-min, min-max, max-min, max-max, center-center.
    // Center-to-edge pairings are deliberately excluded as visual noise.
    for( size_t i = 0; i < m_neighbors.size(); ++i )
    {
        const SPAN ns = spanOf( m_neighbors[i], aAxis );

        aOut.push_back( { ns.Min - ms.Min, KIND_ALIGN, i, i } );
        aOut.push_back( { ns.Max - ms.Min, KIND_ALIGN, i, i } );
        aOut.push_back( { ns.Min - ms.Max, KIND_ALIGN, i, i } );
        aOut.push_back( { ns.Max - ms.Max, KIND_ALIGN, i, i } );
        aOut.push_back( { ns.Center() - ms.Center(), KIND_ALIGN, i, i } );
    }
}


std::optional<ALIGNMENT_GUIDE_ENGINE::RESULT>
ALIGNMENT_GUIDE_ENGINE::FindSnap( const BOX2I& aMoving, int aSnapRange,
                                  const std::optional<VECTOR2D>& aGrid ) const
{
    RESULT result;
    result.Offset = VECTOR2I( 0, 0 );

    std::optional<CANDIDATE> winners[2];

    for( int axis = 0; axis < 2; ++axis )
    {
        std::vector<CANDIDATE> candidates;
        collectAxisCandidates( aMoving, axis, candidates );

        std::optional<CANDIDATE> best;

        for( CANDIDATE& c : candidates )
        {
            if( aGrid )
            {
                // Quantize the offset so items that started on-grid stay on-grid
                double g = ( axis == 0 ) ? aGrid->x : aGrid->y;

                if( g > 0 )
                    c.Delta = KiROUND( c.Delta / g ) * KiROUND( g );
            }

            if( std::abs( c.Delta ) > aSnapRange )
                continue;

            if( !best || std::abs( c.Delta ) < std::abs( best->Delta ) )
                best = c;
        }

        if( best )
        {
            if( axis == 0 )
                result.Offset.x = best->Delta;
            else
                result.Offset.y = best->Delta;

            winners[axis] = best;
        }
    }

    if( !winners[0] && !winners[1] )
        return std::nullopt;

    BOX2I snapped = aMoving;
    snapped.Move( result.Offset );

    for( int axis = 0; axis < 2; ++axis )
    {
        if( winners[axis] )
            buildGraphics( snapped, axis, *winners[axis], result );
    }

    return result;
}
```

And a first `buildGraphics()` that handles `KIND_ALIGN` (other kinds come later):

```cpp
void ALIGNMENT_GUIDE_ENGINE::buildGraphics( const BOX2I& aSnapped, int aAxis,
                                            const CANDIDATE& aWinner, RESULT& aResult ) const
{
    const BOX2I& other = ( aWinner.Kind == KIND_CONTAINER ) ? m_containers[aWinner.N1]
                                                            : m_neighbors[aWinner.N1];

    if( aWinner.Kind == KIND_ALIGN )
    {
        // Guide line runs along the snapped ordinate, spanning both boxes on the
        // cross axis.
        const SPAN ms = spanOf( aSnapped, aAxis );
        const SPAN ns = spanOf( other, aAxis );

        // Find which ordinate actually aligned (one of ms.Min/ms.Max/center)
        int ord;

        if( ms.Min == ns.Min || ms.Min == ns.Max )
            ord = ms.Min;
        else if( ms.Max == ns.Min || ms.Max == ns.Max )
            ord = ms.Max;
        else
            ord = ms.Center();

        const SPAN crossM = spanOf( aSnapped, 1 - aAxis );
        const SPAN crossN = spanOf( other, 1 - aAxis );
        const int  lo = std::min( crossM.Min, crossN.Min );
        const int  hi = std::max( crossM.Max, crossN.Max );

        if( aAxis == 0 )
            aResult.Lines.emplace_back( VECTOR2I( ord, lo ), VECTOR2I( ord, hi ) );
        else
            aResult.Lines.emplace_back( VECTOR2I( lo, ord ), VECTOR2I( hi, ord ) );
    }
}
```

- [ ] **Step 1.7: Build and verify tests pass**

```bash
nix develop -c cmake --build build --target qa_common && \
  nix develop -c ./build/qa/tests/common/qa_common --run_test="AlignmentGuideEngine/*" -l message
```

Expected: `*** No errors detected`

- [ ] **Step 1.8: Commit**

```bash
git -C kicad add include/tool/alignment_guide_engine.h common/tool/alignment_guide_engine.cpp \
  common/CMakeLists.txt qa/tests/common/test_alignment_guide_engine.cpp qa/tests/common/CMakeLists.txt
git -C kicad commit -m "Add alignment guide engine with edge/center alignment snapping

Pure-geometry engine for Figma-style smart guides: computes snap offsets
and guide graphics for a moving bbox against neighbor bboxes.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: More alignment coverage (Y axis, center, both axes, tie-breaking)

**Files:**
- Modify: `kicad/qa/tests/common/test_alignment_guide_engine.cpp`
- Modify: `kicad/common/tool/alignment_guide_engine.cpp` (only if a test exposes a bug)

- [ ] **Step 2.1: Add the tests**

Append inside the suite (before `BOOST_AUTO_TEST_SUITE_END`):

```cpp
BOOST_AUTO_TEST_CASE( CenterAlignY )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    engine.SetNeighbors( { BOX2I( VECTOR2I( 0, 0 ), VECTOR2I( 100, 50 ) ) } ); // centerY = 25

    // Moving box 20 tall, top at y=17 -> centerY = 27, should center-align to 25
    BOX2I moving( VECTOR2I( 500, 17 ), VECTOR2I( 40, 20 ) );

    auto result = engine.FindSnap( moving, 10 );

    BOOST_REQUIRE( result.has_value() );
    BOOST_CHECK_EQUAL( result->Offset.y, -2 );
    BOOST_CHECK_EQUAL( result->Offset.x, 0 );
}


BOOST_AUTO_TEST_CASE( BothAxesIndependent )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    engine.SetNeighbors( { BOX2I( VECTOR2I( 0, 0 ), VECTOR2I( 100, 50 ) ) } );

    // Left edge near x=0 (delta -4), top edge near y=0 (delta +3)
    BOX2I moving( VECTOR2I( 4, -3 ), VECTOR2I( 40, 20 ) );

    auto result = engine.FindSnap( moving, 10 );

    BOOST_REQUIRE( result.has_value() );
    BOOST_CHECK_EQUAL( result->Offset.x, -4 );
    BOOST_CHECK_EQUAL( result->Offset.y, 3 );
    BOOST_CHECK_EQUAL( result->Lines.size(), 2 );
}


BOOST_AUTO_TEST_CASE( NearestCandidateWins )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    // Two neighbors: right edge of A at 100, left edge of B at 103
    engine.SetNeighbors( { BOX2I( VECTOR2I( 0, 0 ), VECTOR2I( 100, 50 ) ),
                           BOX2I( VECTOR2I( 103, 0 ), VECTOR2I( 50, 50 ) ) } );

    // Moving left edge at 102: B.left (delta +1) beats A.right (delta -2)
    BOX2I moving( VECTOR2I( 102, 500 ), VECTOR2I( 40, 20 ) );

    auto result = engine.FindSnap( moving, 10 );

    BOOST_REQUIRE( result.has_value() );
    BOOST_CHECK_EQUAL( result->Offset.x, 1 );
}


BOOST_AUTO_TEST_CASE( OutOfRangeNoSnap )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    engine.SetNeighbors( { BOX2I( VECTOR2I( 0, 0 ), VECTOR2I( 100, 50 ) ) } );

    BOX2I moving( VECTOR2I( 500, 500 ), VECTOR2I( 40, 20 ) );

    BOOST_CHECK( !engine.FindSnap( moving, 10 ).has_value() );
}
```

- [ ] **Step 2.2: Run — expect pass (implementation from Task 1 already covers these)**

```bash
nix develop -c cmake --build build --target qa_common && \
  nix develop -c ./build/qa/tests/common/qa_common --run_test="AlignmentGuideEngine/*" -l message
```

Expected: `*** No errors detected`. If a case fails, fix `collectAxisCandidates`/`FindSnap` minimally until green.

- [ ] **Step 2.3: Commit**

```bash
git -C kicad add qa/tests/common/test_alignment_guide_engine.cpp common/tool/alignment_guide_engine.cpp
git -C kicad commit -m "Add alignment guide engine tests for axes, centers and tie-breaking

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Equal-spacing candidates (a→b = b→c) + badges

**Files:**
- Modify: `kicad/include/tool/alignment_guide_engine.h`
- Modify: `kicad/common/tool/alignment_guide_engine.cpp`
- Modify: `kicad/qa/tests/common/test_alignment_guide_engine.cpp`

- [ ] **Step 3.0: Record the guide ordinate instead of reverse-engineering it**

Task 1's `buildGraphics()` guesses which edge aligned by comparing coordinates:

```cpp
        if( ms.Min == ns.Min || ms.Min == ns.Max )
            ord = ms.Min;
        else if( ms.Max == ns.Min || ms.Max == ns.Max )
            ord = ms.Max;
        else
            ord = ms.Center();
```

This currently produces the *right* answer — the chain compares only against the winner's
own neighbor, and push order plus the strict `<` in the nearest-wins comparison mean an
edge match would have won outright — so it is not a live bug. Replace it anyway, for two
reasons: its correctness rests on an undocumented coupling between push order in
`collectAxisCandidates` and an inequality in `FindSnap` (one `<=` typo silently changes
rendering), and the guessing chain gets strictly worse as Tasks 3–5 add kinds whose
post-snap box need not align with anything.

The candidate already knows the answer at collection time, so record it. In the header,
add a field to `SNAP_CANDIDATE`:

```cpp
        int    Ord;    ///< Guide ordinate along the axis (KIND_ALIGN), in post-snap coords
```

In `collectAxisCandidates()`, set it on each alignment push (the ordinate is the
*neighbor's* edge/center, which is where the guide line lands after snapping):

```cpp
        aOut.push_back( { ns.Min - ms.Min, KIND_ALIGN, i, i, ns.Min } );
        aOut.push_back( { ns.Max - ms.Min, KIND_ALIGN, i, i, ns.Max } );
        aOut.push_back( { ns.Min - ms.Max, KIND_ALIGN, i, i, ns.Min } );
        aOut.push_back( { ns.Max - ms.Max, KIND_ALIGN, i, i, ns.Max } );
        aOut.push_back( { ns.Center() - ms.Center(), KIND_ALIGN, i, i, ns.Center() } );
```

Then replace the guessing chain in `buildGraphics()` with `const int ord = aWinner.Ord;`
and delete the now-unused `ns` local. Every other `aOut.push_back` in the file must gain
a fifth initializer (use `0` for kinds that draw no alignment line).

Existing tests must stay green — run them before moving on:

```bash
nix develop -c cmake --build build --target qa_common && \
  nix develop -c ./build/qa/tests/common/qa_common --run_test="AlignmentGuideEngine/*" -l message
```

- [ ] **Step 3.1: Write the failing tests**

```cpp
BOOST_AUTO_TEST_CASE( EqualSpacingExtendsChain )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    // A x:[0,20], B x:[50,70] -> gap 30.  All share y:[0,20].
    engine.SetNeighbors( { BOX2I( VECTOR2I( 0, 0 ), VECTOR2I( 20, 20 ) ),
                           BOX2I( VECTOR2I( 50, 0 ), VECTOR2I( 20, 20 ) ) } );

    // Moving box (20 wide) near x=104; equal spacing puts left edge at 70+30=100
    BOX2I moving( VECTOR2I( 104, 0 ), VECTOR2I( 20, 20 ) );

    auto result = engine.FindSnap( moving, 10 );

    BOOST_REQUIRE( result.has_value() );
    BOOST_CHECK_EQUAL( result->Offset.x, -4 );

    // Two gaps -> two badges, both reporting 30
    BOOST_REQUIRE_EQUAL( result->Badges.size(), 2 );
    BOOST_CHECK_EQUAL( result->Badges[0].Gap, 30 );
    BOOST_CHECK_EQUAL( result->Badges[1].Gap, 30 );
    BOOST_CHECK( !result->Badges[0].Vertical );
}


BOOST_AUTO_TEST_CASE( EqualSpacingRequiresCrossOverlap )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    // Same as above but neighbors live at y:[0,20] while moving is at y:[400,420]:
    // no cross-axis overlap -> no equal-spacing candidate (alignment may still
    // fire on Y=aligned edges, so keep X far from alignment targets too).
    engine.SetNeighbors( { BOX2I( VECTOR2I( 0, 0 ), VECTOR2I( 20, 20 ) ),
                           BOX2I( VECTOR2I( 50, 0 ), VECTOR2I( 20, 20 ) ) } );

    BOX2I moving( VECTOR2I( 104, 400 ), VECTOR2I( 20, 20 ) );

    auto result = engine.FindSnap( moving, 10 );

    // x=104: nearest alignment target is B.right=70 (delta -34, out of range);
    // equal-spacing target x=100 must NOT fire because of the y separation.
    BOOST_CHECK( !result.has_value() );
}
```

- [ ] **Step 3.2: Run — expect `EqualSpacingExtendsChain` FAILS**

```bash
nix develop -c cmake --build build --target qa_common && \
  nix develop -c ./build/qa/tests/common/qa_common --run_test="AlignmentGuideEngine/*" -l message
```

- [ ] **Step 3.3: Implement equal-spacing candidates**

Append to `collectAxisCandidates()` after the alignment loop:

```cpp
    // Equal-spacing: for each pair of neighbors adjacent along this axis whose
    // cross-axis spans overlap the moving box, offer positions that extend the
    // pair's gap on either side.
    const SPAN crossMs = spanOf( aMoving, 1 - aAxis );

    std::vector<size_t> overlapping;

    for( size_t i = 0; i < m_neighbors.size(); ++i )
    {
        if( spansOverlap( spanOf( m_neighbors[i], 1 - aAxis ), crossMs ) )
            overlapping.push_back( i );
    }

    std::sort( overlapping.begin(), overlapping.end(),
               [&]( size_t a, size_t b )
               {
                   return spanOf( m_neighbors[a], aAxis ).Min
                          < spanOf( m_neighbors[b], aAxis ).Min;
               } );

    for( size_t k = 0; k + 1 < overlapping.size(); ++k )
    {
        const size_t i = overlapping[k];
        const size_t j = overlapping[k + 1];
        const SPAN   si = spanOf( m_neighbors[i], aAxis );
        const SPAN   sj = spanOf( m_neighbors[j], aAxis );
        const int    gap = sj.Min - si.Max;

        if( gap < 0 )
            continue; // overlapping neighbors: no meaningful gap

        // Moving box after j with the same gap: moving.Min = j.Max + gap
        aOut.push_back( { ( sj.Max + gap ) - ms.Min, KIND_EQUAL_GAP, i, j, 0 } );

        // Moving box before i with the same gap: moving.Max = i.Min - gap
        aOut.push_back( { ( si.Min - gap ) - ms.Max, KIND_EQUAL_GAP, j, i, 0 } );
    }
```

Note `std::sort` needs `#include <algorithm>` at the top of the file.

Extend `buildGraphics()` with the equal-gap case (after the `KIND_ALIGN` block):

```cpp
    if( aWinner.Kind == KIND_EQUAL_GAP )
    {
        // N1 = far neighbor, N2 = near neighbor (the one adjacent to the moving box)
        const SPAN sFar = spanOf( m_neighbors[aWinner.N1], aAxis );
        const SPAN sNear = spanOf( m_neighbors[aWinner.N2], aAxis );
        const SPAN sMov = spanOf( aSnapped, aAxis );

        const SPAN crossNear = spanOf( m_neighbors[aWinner.N2], 1 - aAxis );
        const SPAN crossMov = spanOf( aSnapped, 1 - aAxis );
        const int  crossMid = ( std::max( crossNear.Min, crossMov.Min )
                                + std::min( crossNear.Max, crossMov.Max ) ) / 2;

        auto makeBadge = [&]( int aFrom, int aTo )
        {
            GAP_BADGE badge;
            badge.Gap = aTo - aFrom;
            badge.Vertical = ( aAxis == 1 );

            const int mid = aFrom + badge.Gap / 2;
            badge.Pos = ( aAxis == 0 ) ? VECTOR2I( mid, crossMid )
                                       : VECTOR2I( crossMid, mid );
            aResult.Badges.push_back( badge );
        };

        if( sMov.Min > sNear.Max ) // moving sits after the pair
        {
            makeBadge( sFar.Max, sNear.Min );
            makeBadge( sNear.Max, sMov.Min );
        }
        else // moving sits before the pair
        {
            makeBadge( sMov.Max, sNear.Min );
            makeBadge( sNear.Max, sFar.Min );
        }
    }
```

Careful with the before-case indices: when the moving box is placed *before*, N1 was
pushed as `j` (far) and N2 as `i` (near) by the candidate generator, so `sNear` is the
left/upper neighbor of the pair and `sFar` the right/lower one — the badge calls above
reflect that. If the assertion pattern in Step 3.1 fails on badge values, print both
spans and fix the badge endpoints, not the candidate deltas.

- [ ] **Step 3.4: Run — expect all green**

```bash
nix develop -c cmake --build build --target qa_common && \
  nix develop -c ./build/qa/tests/common/qa_common --run_test="AlignmentGuideEngine/*" -l message
```

- [ ] **Step 3.5: Commit**

```bash
git -C kicad add common/tool/alignment_guide_engine.cpp qa/tests/common/test_alignment_guide_engine.cpp
git -C kicad commit -m "Add equal-spacing snap candidates and gap badges to guide engine

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Between-two-neighbors centering (equal gap both sides)

**Files:**
- Modify: `kicad/common/tool/alignment_guide_engine.cpp`
- Modify: `kicad/qa/tests/common/test_alignment_guide_engine.cpp`

- [ ] **Step 4.1: Write the failing test**

```cpp
BOOST_AUTO_TEST_CASE( CenterBetweenTwoNeighbors )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    // A x:[0,20], B x:[100,120]; room between edges = 80, moving is 20 wide
    // -> centered position has 30 on each side: moving x:[50,70]
    engine.SetNeighbors( { BOX2I( VECTOR2I( 0, 0 ), VECTOR2I( 20, 20 ) ),
                           BOX2I( VECTOR2I( 100, 0 ), VECTOR2I( 20, 20 ) ) } );

    BOX2I moving( VECTOR2I( 53, 0 ), VECTOR2I( 20, 20 ) );

    auto result = engine.FindSnap( moving, 10 );

    BOOST_REQUIRE( result.has_value() );
    BOOST_CHECK_EQUAL( result->Offset.x, -3 );

    BOOST_REQUIRE_EQUAL( result->Badges.size(), 2 );
    BOOST_CHECK_EQUAL( result->Badges[0].Gap, 30 );
    BOOST_CHECK_EQUAL( result->Badges[1].Gap, 30 );
}
```

- [ ] **Step 4.2: Run — expect FAIL** (moving at x=53: nearest existing candidate is out of range or wrong offset)

- [ ] **Step 4.3: Implement**

In `collectAxisCandidates()`, inside the adjacent-pair loop from Task 3 (after the two `KIND_EQUAL_GAP` pushes):

```cpp
        // Moving box centered between the pair, if it fits
        if( gap >= ms.Size() )
        {
            const int targetMin = si.Max + ( gap - ms.Size() ) / 2;
            aOut.push_back( { targetMin - ms.Min, KIND_BETWEEN, i, j, 0 } );
        }
```

In `buildGraphics()`, add:

```cpp
    if( aWinner.Kind == KIND_BETWEEN )
    {
        const SPAN sLeft = spanOf( m_neighbors[aWinner.N1], aAxis );
        const SPAN sRight = spanOf( m_neighbors[aWinner.N2], aAxis );
        const SPAN sMov = spanOf( aSnapped, aAxis );

        const SPAN crossMov = spanOf( aSnapped, 1 - aAxis );
        const int  crossMid = crossMov.Min + crossMov.Size() / 2;

        auto makeBadge = [&]( int aFrom, int aTo )
        {
            GAP_BADGE badge;
            badge.Gap = aTo - aFrom;
            badge.Vertical = ( aAxis == 1 );

            const int mid = aFrom + badge.Gap / 2;
            badge.Pos = ( aAxis == 0 ) ? VECTOR2I( mid, crossMid )
                                       : VECTOR2I( crossMid, mid );
            aResult.Badges.push_back( badge );
        };

        makeBadge( sLeft.Max, sMov.Min );
        makeBadge( sMov.Max, sRight.Min );
    }
```

(The `makeBadge` lambda is duplicated between the two kinds; if you prefer, hoist it
to a file-local helper taking `(engine result, axis, crossMid, from, to)` — either is
acceptable, keep it mechanical.)

- [ ] **Step 4.4: Run — all green.  Step 4.5: Commit**

```bash
git -C kicad add common/tool/alignment_guide_engine.cpp qa/tests/common/test_alignment_guide_engine.cpp
git -C kicad commit -m "Add center-between-neighbors snapping to guide engine

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Center-in-container snapping

**Files:**
- Modify: `kicad/common/tool/alignment_guide_engine.cpp`
- Modify: `kicad/qa/tests/common/test_alignment_guide_engine.cpp`

- [ ] **Step 5.1: Write the failing test**

```cpp
BOOST_AUTO_TEST_CASE( CenterInContainer )
{
    ALIGNMENT_GUIDE_ENGINE engine;
    // Container (e.g. board outline) x:[0,200], y:[0,100] -> center (100,50)
    engine.SetContainers( { BOX2I( VECTOR2I( 0, 0 ), VECTOR2I( 200, 100 ) ) } );

    // Moving box 20x10, near-centered: center at (104,52)
    BOX2I moving( VECTOR2I( 94, 47 ), VECTOR2I( 20, 10 ) );

    auto result = engine.FindSnap( moving, 10 );

    BOOST_REQUIRE( result.has_value() );
    BOOST_CHECK_EQUAL( result->Offset.x, -4 );
    BOOST_CHECK_EQUAL( result->Offset.y, -2 );
    BOOST_REQUIRE_EQUAL( result->CenterMarks.size(), 1 );
    BOOST_CHECK_EQUAL( result->CenterMarks[0].x, 100 );
    BOOST_CHECK_EQUAL( result->CenterMarks[0].y, 50 );
}
```

- [ ] **Step 5.2: Run — expect FAIL.  Step 5.3: Implement**

In `collectAxisCandidates()`, append:

```cpp
    // Center inside a container (board outline, enclosing bbox)
    for( size_t i = 0; i < m_containers.size(); ++i )
    {
        const SPAN cs = spanOf( m_containers[i], aAxis );
        aOut.push_back( { cs.Center() - ms.Center(), KIND_CONTAINER, i, i, 0 } );
    }
```

In `buildGraphics()`:

```cpp
    if( aWinner.Kind == KIND_CONTAINER )
    {
        const BOX2I& c = m_containers[aWinner.N1];
        const VECTOR2I center( spanOf( c, 0 ).Center(), spanOf( c, 1 ).Center() );

        // One mark per snap, even if both axes won on the same container
        if( aResult.CenterMarks.empty() || aResult.CenterMarks.back() != center )
            aResult.CenterMarks.push_back( center );
    }
```

- [ ] **Step 5.4: Run — all green.  Step 5.5: Commit**

```bash
git -C kicad add common/tool/alignment_guide_engine.cpp qa/tests/common/test_alignment_guide_engine.cpp
git -C kicad commit -m "Add center-in-container snapping to guide engine

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: REMOVED — grid quantization dropped from this plan

Deleted after the Task 1 code-quality review. `aGrid` had no caller anywhere in this plan
(Task 9 calls `FindSnap( movingBox, snapRange )`), and its delta-quantization semantics
were actively wrong — see the deviations note in the header for the full failure mode.
The tests originally drafted here would have passed over that bug: `GridQuantizedOffset`
asserted only `Offset.x % 25 == 0`, which the phantom zero-offset "snap" satisfies, and
`GridQuantizationCanKillSnap` wrapped its assertion in `if( result )`.

The `aGrid` parameter and its quantization block are removed from the engine in the Task 1
follow-up fix commit. The spec's schematic grid requirement moves to the schematic/symbol
plan, to be designed against a real caller (quantize the target *position*, reject
candidates that then fall outside the snap range).

Renumbering is deliberately avoided — later tasks keep their original numbers.

---

### Task 7: ALIGNMENT_GUIDE_GEOM preview item (rendering)

**Files:**
- Create: `kicad/include/preview_items/alignment_guide_geom.h`
- Create: `kicad/common/preview_items/alignment_guide_geom.cpp`
- Modify: `kicad/common/CMakeLists.txt` (add next to `preview_items/construction_geom.cpp`)

No unit test (pure rendering); the deliverable is compilation plus visual check in Task 10. Before writing, **read** `kicad/common/preview_items/construction_geom.cpp` fully — mirror its idioms exactly: layer choice in `ViewGetLayers`, dash technique, GAL state setup, and its `ViewBBox()` (maximum box). The code below is the required structure; where it says "as construction_geom does", copy that file's approach.

- [ ] **Step 7.1: Header**

```cpp
#pragma once

#include <eda_item.h>
#include <gal/color4d.h>
#include <tool/alignment_guide_engine.h>

namespace KIGFX
{

/**
 * Preview item that renders smart alignment guides: dashed guide lines,
 * equal-spacing distance badges and center marks, from an
 * ALIGNMENT_GUIDE_ENGINE::RESULT.
 */
class ALIGNMENT_GUIDE_GEOM : public EDA_ITEM
{
public:
    ALIGNMENT_GUIDE_GEOM();

    void SetGuides( const ALIGNMENT_GUIDE_ENGINE::RESULT& aResult );
    void ClearGuides();
    bool HasGuides() const { return m_hasGuides; }

    void SetColor( const COLOR4D& aColor ) { m_color = aColor; }

    // EDA_ITEM boilerplate — mirror CONSTRUCTION_GEOM
    const BOX2I ViewBBox() const override;
    std::vector<int> ViewGetLayers() const override;
    void ViewDraw( int aLayer, VIEW* aView ) const override;

#if defined( DEBUG )
    void Show( int nestLevel, std::ostream& os ) const override {}
#endif

    wxString GetClass() const override { return wxT( "ALIGNMENT_GUIDE_GEOM" ); }

private:
    ALIGNMENT_GUIDE_ENGINE::RESULT m_guides;
    bool                           m_hasGuides;
    COLOR4D                        m_color;
};

} // namespace KIGFX
```

- [ ] **Step 7.2: Implementation**

Structure for `alignment_guide_geom.cpp` (fill GAL calls mirroring `construction_geom.cpp`):

```cpp
#include <preview_items/alignment_guide_geom.h>

#include <gal/graphics_abstraction_layer.h>
#include <view/view.h>
#include <wx/string.h>

using namespace KIGFX;

ALIGNMENT_GUIDE_GEOM::ALIGNMENT_GUIDE_GEOM() :
        EDA_ITEM( nullptr, NOT_USED ), // Same as CONSTRUCTION_GEOM: never in a BOARD, no type
        m_hasGuides( false ),
        m_color( COLOR4D( 0.9, 0.2, 0.6, 0.9 ) ) // magenta-ish default
{
}


void ALIGNMENT_GUIDE_GEOM::SetGuides( const ALIGNMENT_GUIDE_ENGINE::RESULT& aResult )
{
    m_guides = aResult;
    m_hasGuides = true;
}


void ALIGNMENT_GUIDE_GEOM::ClearGuides()
{
    m_guides = ALIGNMENT_GUIDE_ENGINE::RESULT();
    m_hasGuides = false;
}


const BOX2I ALIGNMENT_GUIDE_GEOM::ViewBBox() const
{
    // Same as CONSTRUCTION_GEOM: infinite bbox, we're a transient overlay
    BOX2I bbox;
    bbox.SetMaximum();
    return bbox;
}


std::vector<int> ALIGNMENT_GUIDE_GEOM::ViewGetLayers() const
{
    // Same layer as CONSTRUCTION_GEOM (which deliberately avoids LAYER_GP_OVERLAY
    // so it renders on top of the axis cross — construction_geom.cpp:192)
    return { LAYER_UI_START };
}


void ALIGNMENT_GUIDE_GEOM::ViewDraw( int aLayer, VIEW* aView ) const
{
    if( !m_hasGuides )
        return;

    GAL& gal = *aView->GetGAL();

    gal.SetIsStroke( true );
    gal.SetIsFill( false );
    gal.SetStrokeColor( m_color );
    gal.SetLineWidth( 1.0 / aView->GetGAL()->GetWorldScale() );

    // Dashed guide lines -- use the same dash drawing technique as
    // CONSTRUCTION_GEOM::ViewDraw
    for( const SEG& seg : m_guides.Lines )
        /* dashed line from seg.A to seg.B */;

    // Badges: filled rounded rect + centered text.  Value in mm.
    // ponytail: mm hardcoded; upgrade path = pass an EDA_IU_SCALE + EDA_UNITS
    // from the frame when other editors (mils users) come on board.
    for( const ALIGNMENT_GUIDE_ENGINE::GAP_BADGE& badge : m_guides.Badges )
    {
        wxString text = wxString::Format( wxT( "%.2f" ), badge.Gap / 1e6 );
        // filled rect sized to text extents at fixed screen-space height,
        // then gal.BitmapText( text, badge.Pos, ANGLE_0 ) centered
    }

    // Center marks: small crosshair (two short lines) at each mark
    for( const VECTOR2I& mark : m_guides.CenterMarks )
    {
        int r = KiROUND( 8.0 / aView->GetGAL()->GetWorldScale() ); // ~8 px arms
        gal.DrawLine( mark - VECTOR2I( r, 0 ), mark + VECTOR2I( r, 0 ) );
        gal.DrawLine( mark - VECTOR2I( 0, r ), mark + VECTOR2I( 0, r ) );
    }
}
```

The two comment-marked bodies (`ViewGetLayers`, dashed lines, badge drawing) must be
completed by copying the working technique from `construction_geom.cpp` — that file
is the authority for layer id, dash rendering, and screen-space sizing. Badge text:
if `construction_geom.cpp` doesn't draw text, take the text technique from
`common/preview_items/ruler_item.cpp` (it draws measurement labels on the overlay).

- [ ] **Step 7.3: Register in CMake** — in `kicad/common/CMakeLists.txt` add `preview_items/alignment_guide_geom.cpp` next to `preview_items/construction_geom.cpp`.

- [ ] **Step 7.4: Build**

```bash
nix develop -c cmake --build build --target qa_common
```

Expected: compiles clean (qa_common links `common`, so this validates the new file).

- [ ] **Step 7.5: Commit**

```bash
git -C kicad add include/preview_items/alignment_guide_geom.h \
  common/preview_items/alignment_guide_geom.cpp common/CMakeLists.txt
git -C kicad commit -m "Add preview item rendering alignment guides, badges and center marks

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Plumb engine + preview into GRID_HELPER / SNAP_MANAGER

**Files:**
- Modify: `kicad/include/tool/construction_manager.h` (SNAP_MANAGER owns the engine)
- Modify: `kicad/include/tool/grid_helper.h` (move context + preview member)
- Modify: `kicad/common/tool/grid_helper.cpp` (view add, reset)

- [ ] **Step 8.1: SNAP_MANAGER owns the engine**

In `construction_manager.h`: add `#include <tool/alignment_guide_engine.h>` and, inside `SNAP_MANAGER`'s public section:

```cpp
    ALIGNMENT_GUIDE_ENGINE& GetAlignmentEngine() { return m_alignmentEngine; }
```

and in its member section:

```cpp
    ALIGNMENT_GUIDE_ENGINE m_alignmentEngine;
```

Also clear it in `SNAP_MANAGER::Clear()` (in `common/tool/construction_manager.cpp` — find the existing `Clear` implementation and append `m_alignmentEngine.Clear();`).

- [ ] **Step 8.2: GRID_HELPER gets move context + preview item**

In `include/tool/grid_helper.h`: add `#include <preview_items/alignment_guide_geom.h>`, and in the public section of `GRID_HELPER`:

```cpp
    /**
     * Provide the context needed for smart alignment guides during a move:
     * the moving selection's bbox and the cursor position at drag start.
     * While set, BestSnapAnchor implementations may offer alignment snaps.
     */
    void SetMoveContext( const BOX2I& aOriginalBBox, const VECTOR2I& aOriginalCursor )
    {
        m_moveContext = MOVE_CONTEXT{ aOriginalBBox, aOriginalCursor };
    }

    void ClearMoveContext()
    {
        m_moveContext = std::nullopt;
        m_snapManager.GetAlignmentEngine().Clear();
        m_alignGuidePreview.ClearGuides();
    }
```

In the protected section:

```cpp
    struct MOVE_CONTEXT
    {
        BOX2I    OriginalBBox;
        VECTOR2I OriginalCursor;
    };

    std::optional<MOVE_CONTEXT>   m_moveContext;
    KIGFX::ALIGNMENT_GUIDE_GEOM   m_alignGuidePreview;
```

- [ ] **Step 8.3: Add preview to the view + reset paths**

In `common/tool/grid_helper.cpp`:
- Next to line ~70 (`view->Add( &m_constructionGeomPreview );`) add `view->Add( &m_alignGuidePreview );`
- In the destructor / wherever `m_constructionGeomPreview` is removed from the view (search `Remove`), remove ours symmetrically.
- In `FullReset()` (header, line ~67) add `m_moveContext = std::nullopt;` and `m_alignGuidePreview.ClearGuides();`

- [ ] **Step 8.4: Build + run engine tests (no regressions)**

```bash
nix develop -c cmake --build build --target qa_common && \
  nix develop -c ./build/qa/tests/common/qa_common --run_test="AlignmentGuideEngine/*" -l message
```

Note: `GRID_HELPER` has a TOOL_MANAGER-less test constructor; if qa_common fails to
link or existing GRID_HELPER tests crash on the new member, ensure the preview item
is only added to a view when a view exists (the `view` pointer is already null-checked
at the construction-geom add site — keep ours inside the same guard).

- [ ] **Step 8.5: Commit**

```bash
git -C kicad add include/tool/construction_manager.h include/tool/grid_helper.h \
  common/tool/grid_helper.cpp common/tool/construction_manager.cpp
git -C kicad commit -m "Wire alignment guide engine and preview into grid helper plumbing

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: PCB_GRID_HELPER — neighbor collection + guide snap in BestSnapAnchor

**Files:**
- Modify: `kicad/pcbnew/tools/pcb_grid_helper.h`
- Modify: `kicad/pcbnew/tools/pcb_grid_helper.cpp`

- [ ] **Step 9.1: Declare the collector**

In `pcb_grid_helper.h` public section:

```cpp
    /**
     * Collect neighbor footprint bboxes and container boxes for smart alignment
     * guides.  Call once at drag start, after SetMoveContext().
     *
     * @param aSkip items being dragged (excluded from neighbors)
     */
    void CollectAlignmentNeighbors( const std::vector<BOARD_ITEM*>& aSkip );
```

- [ ] **Step 9.2: Implement the collector**

In `pcb_grid_helper.cpp` (near `queryVisible`, line ~1040). Notes: `m_toolMgr->GetView()->GetViewport()` returns `BOX2D` (`include/view/view.h:242`); footprint side via `FOOTPRINT::GetSide()` (`pcbnew/footprint.h:623`); text-free bbox via `GetBoundingBox( false )` (`footprint.h:366`); board edges bbox via `BOARD::GetBoardEdgesBoundingBox()` (`board.h:1164`).

```cpp
void PCB_GRID_HELPER::CollectAlignmentNeighbors( const std::vector<BOARD_ITEM*>& aSkip )
{
    ALIGNMENT_GUIDE_ENGINE& engine = getSnapManager().GetAlignmentEngine();
    engine.Clear();

    if( !m_moveContext )
        return;

    const BOX2D viewportD = m_toolMgr->GetView()->GetViewport();
    const BOX2I viewport = BOX2ISafe( viewportD );

    // Which side is being dragged?  Take it from the first dragged footprint.
    std::optional<PCB_LAYER_ID> dragSide;

    for( BOARD_ITEM* item : aSkip )
    {
        if( item->Type() == PCB_FOOTPRINT_T )
        {
            dragSide = static_cast<FOOTPRINT*>( item )->GetSide();
            break;
        }
    }

    struct SCORED
    {
        BOX2I  Box;
        double Dist;
    };

    std::vector<SCORED> scored;
    const VECTOR2I      ref = m_moveContext->OriginalBBox.Centre();

    for( BOARD_ITEM* item : queryVisible( viewport, aSkip ) )
    {
        if( item->Type() != PCB_FOOTPRINT_T )
            continue;

        FOOTPRINT* fp = static_cast<FOOTPRINT*>( item );

        if( dragSide && fp->GetSide() != *dragSide )
            continue;

        const BOX2I box = fp->GetBoundingBox( false );
        scored.push_back( { box, ( box.Centre() - ref ).EuclideanNorm() } );
    }

    // Cap the neighbor count: nearest first.  Guides are hints; dropping far
    // neighbors is fine and keeps the per-motion cost bounded.
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

    // Containers: the board outline (v1; enclosing-item bboxes are a follow-up).
    // Board access matches this file's existing pattern (see lines ~183/198).
    if( BOARD* board = static_cast<BOARD*>( m_toolMgr->GetModel() ) )
        engine.SetContainers( { board->GetBoardEdgesBoundingBox() } );
}
```

Add the needed includes at the top if missing: `<algorithm>`, `<footprint.h>`.

- [ ] **Step 9.3: Query the engine in BestSnapAnchor**

In `PCB_GRID_HELPER::BestSnapAnchor( const VECTOR2I&, const LSET&, GRID_HELPER_GRIDS, const std::vector<BOARD_ITEM*>& )` (starts `pcb_grid_helper.cpp:597`):

The method computes `snapRange` (line ~615), collects anchors, then chooses between anchor snap, snap-line/construction snap, and grid. Find the point where the method has decided **no item anchor is taken** and is about to fall back to grid (the tail of the function, where the return value is computed from `nearestGrid`). Insert the guide query **before** that grid fallback so priority is: item anchor > alignment guide > grid:

```cpp
    // Smart alignment guides: only during an active move (context set by the
    // move tool) and only when snapping is enabled at all (Shift suppresses).
    if( m_moveContext && m_enableSnap )
    {
        ALIGNMENT_GUIDE_ENGINE& engine = getSnapManager().GetAlignmentEngine();

        if( engine.HasInputs() )
        {
            // Moving bbox at the current (unsnapped) cursor position
            BOX2I movingBox = m_moveContext->OriginalBBox;
            movingBox.Move( aOrigin - m_moveContext->OriginalCursor );

            if( auto guide = engine.FindSnap( movingBox, snapRange ) )
            {
                m_alignGuidePreview.SetGuides( *guide );
                m_toolMgr->GetView()->Update( &m_alignGuidePreview, KIGFX::GEOMETRY );

                return aOrigin + guide->Offset;
            }
        }

        if( m_alignGuidePreview.HasGuides() )
        {
            m_alignGuidePreview.ClearGuides();
            m_toolMgr->GetView()->Update( &m_alignGuidePreview, KIGFX::GEOMETRY );
        }
    }
```

Placement guidance: the anchor-snap early-returns (search `m_snapItem` assignments
and the `updateSnapPoint` calls around lines 750–910) must stay above this block;
the plain-grid return at the very end stays below it. If the function has multiple
grid-fallback returns, put the block once, immediately before the first statement
that computes the final grid-aligned return value.

- [ ] **Step 9.4: Build pcbnew**

```bash
nix develop -c cmake --build build --target pcbnew
```

Expected: compiles and links. (First pcbnew build after qa_common adds time; ccache softens repeats.)

- [ ] **Step 9.5: Commit**

```bash
git -C kicad add pcbnew/tools/pcb_grid_helper.h pcbnew/tools/pcb_grid_helper.cpp
git -C kicad commit -m "Offer alignment guide snaps in PCB grid helper during moves

Priority is item anchor, then alignment guide, then grid.  Neighbors are
footprints on the dragged side, capped to the 100 nearest.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Move tool wiring + first live run

**Files:**
- Modify: `kicad/pcbnew/tools/edit_tool_move_fct.cpp`

- [ ] **Step 10.1: Set context at drag start**

In the move loop, the `updateBBox` block (line ~1193) computes `originalBBox` on the first motion event:

```cpp
                if( updateBBox )
                {
                    originalBBox = BOX2I();
                    bboxMovement = VECTOR2D();

                    for( EDA_ITEM* item : sel_items )
                        originalBBox.Merge( item->ViewBBox() );

                    updateBBox = false;
                }
```

Extend it (inside the `if`, after `updateBBox = false;`):

```cpp
                    grid.SetMoveContext( originalBBox, m_cursor );
                    grid.CollectAlignmentNeighbors( sel_items );
```

Note `m_cursor` here is the snapped cursor of this first event — that's the
correct pairing with `originalBBox`, which is also measured at this instant.
`sel_items` is already a `std::vector<BOARD_ITEM*>` in this scope (see line 1182
usage).

- [ ] **Step 10.2: Clear context on exit**

The move function has a single cleanup path after its event loop (search for where
the loop ends and the tool restores cursor/controls state — e.g.
`controls->ForceCursorPosition( false` and the final selection cleanup). Add there:

```cpp
    grid.ClearMoveContext();
```

Also verify Esc/cancel routes through that same tail (it does — the loop breaks and
falls through); if you find an early `return` above the cleanup, add the call there
too.

- [ ] **Step 10.3: Build + launch**

```bash
nix develop -c cmake --build build --target pcbnew && \
  nix develop -c ./build/pcbnew/pcbnew kicad/demos/kit-dev-coldfire-xilinx_5213/kit-dev-coldfire-xilinx_5213.kicad_pcb
```

(Any demo `.kicad_pcb` works; that one has plenty of footprints.)

- [ ] **Step 10.4: Manual verification checklist**

In the PCB editor:
1. Move a footprint near another → dashed magenta line appears when edges/centers align; footprint snaps to it.
2. Place three footprints in a row: A, B fixed; drag C near the equal-spacing point → snap + two badges showing the same mm value.
3. Drag a footprint into the gap between two others → centers with equal badges both sides.
4. Drag near the board-outline center → crosshair mark + snap to center.
5. Hold Shift while dragging → guides disappear, no guide snapping.
6. Press Esc mid-drag → guides vanish, footprint returns, no artifacts on next move.
7. Pads/tracks still snap as before (item anchors beat guides).
8. Zoom far out and drag on the densest board area → no visible lag.

Record pass/fail per item. Failures → fix before commit; rendering issues trace to Task 7, snap issues to Task 9, lifecycle issues to this task.

- [ ] **Step 10.5: Commit**

```bash
git -C kicad add pcbnew/tools/edit_tool_move_fct.cpp
git -C kicad commit -m "Enable smart alignment guides in the PCB move tool

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Perf sanity + full test suite + wrap-up

**Files:** none (verification only), plus any fixes it forces.

- [ ] **Step 11.1: Full qa_common suite (no regressions elsewhere)**

```bash
nix develop -c ./build/qa/tests/common/qa_common -l warning
```

Expected: `*** No errors detected` (pre-existing failures, if any, must match a clean checkout — verify with `git -C kicad stash` + rerun if in doubt, then `git -C kicad stash pop`).

- [ ] **Step 11.2: Perf spot-check**

On the largest demo board you can find (`ls kicad/demos/**/*.kicad_pcb`), select a footprint in the densest area, drag continuously for ~10 s. Watch for cursor lag versus a build without the feature (toggle by holding Shift — suppressed guides take the old path). Perceptible added lag = failure: profile `CollectAlignmentNeighbors` (should run once per drag, not per motion) and `FindSnap` (candidate count should be ≤ ~1000).

- [ ] **Step 11.3: Verify working tree clean + summarize**

```bash
git -C kicad status --short && git -C kicad log --oneline master..HEAD
```

Expected: clean tree; ~8 commits on `feature/smart-guides`. Report the checklist results from Task 10 and any deviations for review (superpowers:requesting-code-review comes next per workflow).
