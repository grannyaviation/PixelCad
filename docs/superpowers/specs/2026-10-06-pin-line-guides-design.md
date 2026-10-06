# Pin-Line Guides for PCB Moves — Design

When a part is dragged in the PCB editor, smart guides align its bounding box to other parts'
edges and centres. They never look at pads, so placing a decoupling capacitor directly in line
with the connector or IC pin it serves is done by eye. A real case on the GraNNy sensor board:
`C79`'s pad had to sit on `J13` pin 4's centre line, and "nearly in line" was 13.5 µm off, with
no way to see it on screen.

Owner decisions (2026-10-06):

- **Option (b): one part on the pin line.** A dragged part snaps so that its centre, or one of
  its own pads, sits on a neighbouring pad's centre line. Centring a *pair* of parts on a pin
  (option a) is not part of this work.
- **Pad lines beat the grid.** A pin-line snap is an exact electrical alignment, like the direct
  pad snapping that already outranks the grid, so it is taken even when the result is off-grid.
  Edge and centre guides between parts keep the grid-legal rule (`4710bb0cf3`).

## Behaviour

- **Targets:** the X and Y centre lines through the pads of neighbouring footprints. These are
  the footprints the guides already collect (same side as the dragged footprint, nearest first),
  plus through-hole pads, which exist on both sides.
- **Sources:**
  - the dragged selection's bounding-box centre;
  - every pad centre of the dragged footprints.

  A vertical 0603 capacitor therefore lands with both pads on the pin line, through its centre
  or either pad. A horizontal one lands with one pad on the line.
- **Per axis:** X and Y are decided independently, as for the existing guides. A pin-line
  candidate in range wins its axis over every edge, centre, spacing and container candidate,
  whatever their distances. Among pin-line candidates the nearest wins.
- **Grid:** pin-line candidates are exempt from `aGridStep`. Nothing is rounded: the source
  lands exactly on the target ordinate.
- **Range:** the same zoom-dependent snap range as the existing guides.
- **Graphics:** a guide line along the shared ordinate, from the target pad centre to the source
  point, in the existing guide colour. No badge.
- **Off switch:** Shift suppresses it, like every guide (`m_enableSnap`).
- **Priority with the rest of the snapping:** anchor snaps (pads and other magnetic items)
  still come first, as today. The order is anchor > guide (pin line, then edge/centre) > grid.
- **Scope:** the PCB move tool only. Schematic and symbol editors are unchanged; the engine
  sees no pin targets there.

## Engine (`ALIGNMENT_GUIDE_ENGINE`)

The engine stays pure geometry.

- `SetPinTargets( std::vector<VECTOR2I> )`: neighbour pad centres in world coordinates.
- `SetMovingPoints( std::vector<VECTOR2I> )`: the dragged pad centres **relative to the moving
  box's origin** (`GetOrigin()`). They then travel with whatever box `FindSnap` is given. The
  box centre is always a source; it is not passed in.
- `Clear()` clears both new inputs. `HasInputs()` is also true when there are pin targets only.
- A new kind, `KIND_PIN_LINE`:
  - `N1` indexes `m_pinTargets`;
  - `Ord` is the target's ordinate on the axis;
  - `Dist` = |Delta|;
  - `Approx` is never set.
- On each axis: if any `KIND_PIN_LINE` candidate is within `aSnapRange`, the nearest one wins
  and no other kind is considered. The grid check is skipped for this kind only.
- `buildGraphics` for `KIND_PIN_LINE` emits one `SEG` on the ordinate. After the snap it runs
  from the target point to the source point (both in post-snap coordinates), with no badges.

## PCB (`PCB_GRID_HELPER`)

- `CollectAlignmentNeighbors` also collects pad centres:
  - from the neighbour footprints it already keeps (same side), capped at the nearest 400 pads
    to the moving box's centre;
  - plus the through-hole pads of opposite-side footprints in the same sweep.

  A pure static helper does the selection so it can be tested without a view:
  `CollectPinTargets( const std::vector<const FOOTPRINT*>&, PCB_LAYER_ID aDragSide,
  const VECTOR2I& aRef, size_t aCap )`.
- The moving points are the pad centres of the dragged footprints, made relative to the moving
  bbox's origin. They are set when the move context is set, and again wherever the move tool
  already re-measures the guide bbox (rotation or flip mid-move, `0c2c8d0f1`).
- `BestSnapAnchor` is unchanged. It already passes the grid step (or none), and the engine
  decides the pin-line exemption.

## Tests

- **Engine** (`qa/tests/common/test_alignment_guide_engine.cpp`):
  - box centre to pin target, on X and on Y;
  - moving pad to pin target;
  - a pin-line candidate beats a nearer edge candidate on the same axis;
  - an off-grid pin line is accepted with a grid step set, while an off-grid edge candidate is
    still rejected;
  - out of range gives no snap;
  - the guide segment runs from target to source;
  - `Clear()` empties the pin inputs.
- **PCB** (`qa/tests/pcbnew/test_pcb_grid_helper.cpp`): `CollectPinTargets` keeps same-side SMD
  pads and opposite-side through-hole pads, drops opposite-side SMD pads, and keeps the nearest
  `aCap`.
- **Manual check** (appended to the PCB verification checklist): drag a vertical 0603 cap toward
  a connector pin on B.Cu with a 0.1 mm grid on. It snaps onto the pin's line at an off-grid X,
  the red line runs from the pin to the cap, and Shift turns it off.

## Not in scope

- Centring a pair or group on a pin (option a).
- Pin lines in the schematic or symbol editors.
- Snapping to track or via centres.
