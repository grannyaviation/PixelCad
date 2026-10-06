# Flip Footprints over the IPC API — Design

Konnect can move and rotate footprints on a live board, but it cannot flip one to the other side:
KiCad's IPC API has no flip command. Its `flip_component` only edits a closed board file, so the
owner has to flip by hand (select, F) before Konnect can place a part on B.Cu. The GraNNy sensor
board's boost converter (U25, L5, D5, C82, C83, C84, R51) is the case at hand.

Owner decision (2026-10-06): **approach A** — a new `FlipItems` command in PixelCad's API that
runs KiCad's own flip, and Konnect's `flip_component` uses it whenever KiCad has the board open.
Rejected: emulating the flip in Konnect through `UpdateItems` (it would re-implement KiCad's flip
and its frame handling, the class of bug fixed in `031f3d13eb`), and closing the board for every
flip (slow, and Konnect's file editor targets the KiCad 10.0 format, not PixelCad's
`(transform …)` footprints).

## Behaviour

- `FlipItems` flips each listed footprint **in place**: around its own anchor, so its position
  does not change. This is what F does to a single selected footprint.
- The flip direction is the board editor's setting (`m_FlipDirection`), as for F. A headless
  session has no editor settings and uses `FLIP_DIRECTION::LEFT_RIGHT`, KiCad's default.
- All footprints in one request are flipped in one commit: one undo step. A client inside its
  own `BeginCommit`/`EndCommit` gets the flip in that commit instead, like `UpdateItems`.
- The request is all or nothing. An unknown ID, or an ID that is not a footprint, rejects the
  whole request with `AS_BAD_REQUEST` naming the IDs, and nothing is flipped.
- Only footprints. Flipping tracks, shapes or text is not needed and not offered.

## PixelCad (`grannyaviation/kicad`, `feature/smart-guides`)

- **Proto** (`api/proto/board/board_commands.proto`, next to `RefillZones`):

  ```proto
  // Flips footprints to the opposite board side, each around its own anchor, as the F key
  // does for a single footprint. All or nothing; returns Empty.
  message FlipItems
  {
    kiapi.common.types.DocumentSpecifier board = 1;
    repeated kiapi.common.types.KIID     items = 2;
  }
  ```

- **Handler** `API_HANDLER_PCB::handleFlipItems`, registered as
  `registerHandler<FlipItems, Empty>`:
  1. `checkForBusy()`, then `validateDocument( board )`.
  2. Resolve every ID with `getItemById`; collect unknown and non-footprint IDs and reject if any.
  3. `COMMIT* commit = getCurrentCommit( aCtx.ClientName )`; for each footprint
     `commit->Modify( fp, nullptr, RECURSE_MODE::RECURSE )` then
     `fp->Flip( fp->GetPosition(), direction )`.
  4. Push with `pushCurrentCommit( client, _( "Flipped items via API" ) )` unless the client
     holds an open commit (`m_activeClients`), the same rule as `UpdateItems`.
- **Tests** (`qa/tests/api/test_api_handler_pcb.cpp`, headless fixture like `RefillZones*`):
  - a front footprint ends on B.Cu at the same position, its pads on B.Cu;
  - flipping it again brings it back to F.Cu;
  - an unknown ID is rejected and no footprint changes side;
  - a non-footprint ID (a track) is rejected the same way.

## Konnect (`~/projecte/Konnect`)

- **Protocol:** add `FlipItems` to the vendored
  `crates/konnect-ipc/proto/board/board_commands.proto`, verbatim from PixelCad.
- **Client:** `flip_footprints( references, layer )` in `crates/konnect-ipc/src/client.rs`:
  resolves references to footprint IDs with `get_items`, drops footprints already on the target
  layer, sends one `FlipItems` inside `run_commit`, and returns which references were flipped
  and which were already there. A missing reference is an error before anything is sent.
- **Tool:** `flip_component` tries the live board first through `attempt_ipc_write`, as
  `set_component_placements` does:
  - KiCad holds the board → `FlipItems`; the result says `"source": "ipc"` and that one undo
    step reverses it.
  - KiCad holds the board but answers that it has no handler for `FlipItems` (stock KiCad) →
    refuse with a message that this KiCad cannot flip over IPC and the board must be closed
    for the file flip. Nothing is written.
  - KiCad does not hold the board → the existing closed-board file flip, unchanged.
- **Tests:** follow the crate's existing patterns for placement tools: request building, the
  already-on-layer skip, the missing-reference error, and the stock-KiCad refusal.
- **Install:** release build; the current `~/.local/share/konnect/bin/konnect` is kept as
  `konnect.pre-flip.bak`; the owner reconnects with `/mcp`.

## Rollout

The owner runs `nhs` after the PixelCad flake bump (this also installs the zone/arc fix,
`031f3d13eb`) and reconnects Konnect. Until then `flip_component` behaves as today.

## Not in scope

- Flipping non-footprint items, flipping around a common centre, or a direction parameter.
- Upstreaming `FlipItems` to KiCad.
- Making Konnect's closed-board flip understand PixelCad's `(transform …)` format.
