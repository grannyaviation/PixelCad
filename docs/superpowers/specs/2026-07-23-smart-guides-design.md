# Smart Alignment Guides for KiCad — Design

**Date:** 2026-07-23
**Status:** Approved
**Target:** KiCad master (fork at `kicad/`, upstream MR intended)

## Goal

Figma-style live placement aids in the PCB, footprint, schematic, and symbol editors:
dragged items snap to alignment lines, equal-spacing points, midpoints, and area
centers relative to neighboring items, with guide lines and distance badges rendered
live during the move. Plus an Align/Distribute command port to the schematic and
symbol editors.

## Decisions (from brainstorming)

| Topic | Decision |
|---|---|
| Strategy | Design to upstream standards; MR intended after fork validation |
| Editors | All (PCB, footprint, schematic, symbol) via common implementation |
| Reference geometry | Bounding box edges + center (PCB: courtyard/footprint bbox; schematic: symbol body bbox) |
| Visual feedback | Full style: guide lines + distance badge per gap + equal marks (mockup choice "A") |
| Activation | On by default during move/drag; Ctrl suppresses; Preferences toggle |
| Snap priority | Guide snap beats grid snap within snap radius. Schematic/symbol exception: guide candidates are quantized to the active grid first, so pins never leave the wire grid |
| Centering | All three semantics: midpoint snap while dragging, center-in-area snap, center-align selection command (command = part of Align/Distribute port) |

## Features

1. **Alignment guides** — a dragged selection's bbox left/center/right (and
   top/center/bottom) snapping to the same lines of neighbor bboxes; dashed guide line
   drawn across the involved items.
2. **Equal-spacing snap** — when the gap between the dragged bbox and a neighbor can
   equal an existing neighbor-to-neighbor gap on that axis (the `a→b = b→c` case),
   snap there; render a distance badge on each gap plus an `≡` mark.
3. **Midpoint snap** — snap the dragged bbox center to the midpoint between two
   neighbors' centers; badges show the two equal distances.
4. **Center-in-area snap** — snap to the center of an enclosing bbox: board outline
   (PCB), sheet (schematic), symbol body (symbol editor), or any item whose bbox
   encloses the cursor. Snap-only in v1; no explicit menu command.
5. **Align/Distribute port** — schematic and symbol editors get the right-click
   Align/Distribute submenu from pcbnew (align left/right/top/bottom, center
   horizontal/vertical, distribute horizontal/vertical), grid-quantized.
6. **Suppression and settings** — hold Ctrl to bypass guides mid-drag; per-app
   "Show smart alignment guides" checkbox in Editing Options (default on); snap
   radius and neighbor cap in advanced config.

## Architecture

Existing plumbing this builds on: `GRID_HELPER` (`include/tool/grid_helper.h`) owns a
`SNAP_MANAGER` (`include/tool/construction_manager.h`) whose header comment
explicitly anticipates "equal-space snapping". `PCB_GRID_HELPER` already uses the
snap manager for construction geometry; `EE_GRID_HELPER` does not yet — wiring it is
part of this work. All move tools already call `BestSnapAnchor()` on every motion
event.

### New units

- **`common/tool/alignment_guide_engine.{h,cpp}`** — pure geometry engine.
  - Input: dragged union bbox, neighbor bboxes, container bboxes, snap radius (in
    world units, already converted from screen px), optional grid for quantization.
  - Output: `std::optional<VECTOR2I>` snap offset + list of guide drawables (lines,
    gap badges with values, equal marks, center marks).
  - No tool/view/wx dependencies; unit-testable headless.
- **`common/preview_items/alignment_guide_geom.{h,cpp}`** — `KIGFX` view item
  (sibling of `construction_geom`) rendering the drawables on the overlay layer:
  dashed lines spanning involved items, rounded-rect badges with distance text in
  current user units, `≡` ticks, center crosshair marks. Badge text zoom-clamped to
  readable pixel sizes. New theme color "Alignment guides" (default magenta,
  distinct from cyan construction lines).

### Modified units

- **`SNAP_MANAGER`** — owns an `ALIGNMENT_GUIDE_ENGINE` instance and its view item;
  exposes it to grid helpers.
- **`GRID_HELPER` base** — API to set the per-drag neighbor/container set and to
  query guide snapping as part of the `BestSnapAnchor()` flow.
- **`PCB_GRID_HELPER`** — neighbor collection: visible items via the view R-tree,
  excluding the dragged selection, footprints filtered to the same board side,
  courtyard bbox preferred (fallback footprint bbox), capped at the ~100 nearest.
  Containers: board outline bbox + enclosing item bboxes.
- **`EE_GRID_HELPER`** — same with symbol body bboxes; also gains the SNAP_MANAGER
  wiring PCB already has. Guide candidates quantized to the active grid before
  scoring.
- **Move tools** (`pcbnew/tools/edit_tool_move_fct.cpp`,
  `eeschema/tools/sch_move_tool.cpp`, symbol editor move path) — provide the dragged
  selection's union bbox; honor Ctrl bypass; clear overlay on finish/cancel.
- **`eeschema/tools/sch_align_distribute_tool.{h,cpp}`** (new, modeled on
  `pcbnew/tools/align_distribute_tool`) — actions + right-click submenu for
  schematic and symbol editors.
- **Settings/UI** — checkbox in each app's Editing Options page; advanced config
  keys for snap radius (screen px) and neighbor cap; new color in theme editor.

## Data flow (per motion event during move)

1. Move tool calls `BestSnapAnchor()` with cursor and dragged selection (existing).
2. On drag start the grid helper collects and caches the neighbor/container set;
   refreshed on pan/zoom.
3. Engine generates candidates: alignment lines (edges/centers), equal-spacing
   positions from sorted per-axis neighbor gaps, neighbor-pair midpoints, container
   centers.
4. Scoring: nearest candidate within snap radius wins over grid/anchor snap. In
   schematic/symbol the candidate is grid-quantized first and must still fall within
   the radius. Ctrl held → steps 3–5 skipped.
5. Result: adjusted position + active guides rendered; no hit → overlay cleared.

## Performance

Target <1 ms per motion event on a 1000-footprint board. Neighbor cap (~100 nearest
to cursor) bounds candidate generation to ~O(k log k) per axis. Early-out when
zoomed out enough that bboxes are below a few screen px. Cap prefers
nearest-to-cursor items; truncation is acceptable (guides are hints, not data).
Profile a large demo board before/after; no measurable drag regression allowed.

## Edge cases

- Multi-item drag → selection union bbox.
- Rotated items → axis-aligned bbox (accepted).
- Degenerate bboxes (junctions, tiny text) → skipped.
- Overlapping neighbors (negative gaps) → skipped.
- Esc/cancel → overlay cleared, no position side effects.
- Undo → unaffected; snapping only alters the final position.
- Units → badges follow the current display units; light/dark themes both supported
  via the theme color.

## Testing

- Boost unit tests in `qa/tests/common/` for the engine: alignment candidates,
  equal-spacing math, midpoint, containment/center, grid quantization, neighbor-cap
  behavior, Ctrl-bypass (engine simply not queried).
- Manual per-editor interaction checklist recorded in the MR description (upstream
  norm for interactive tools).
- Performance check on a large demo board from `demos/`.

## Milestones

1. Engine + unit tests (pure geometry, no UI).
2. PCB editor wiring + rendering (visible end-to-end feature).
3. Schematic/symbol wiring, including EE_GRID_HELPER SNAP_MANAGER hookup.
4. Align/Distribute port to eeschema/symbol editor.
5. Preferences, theme color, polish.
6. Upstream: GitLab feature issue with screenshots/GIFs, then MR.

## Out of scope (v1)

- Explicit "center in area" menu command (snap covers the workflow).
- Pad/pin-level snap references (bbox only).
- Distribute-with-fixed-pitch input UI.
- Guides during routing/drawing tools (move/drag only).
