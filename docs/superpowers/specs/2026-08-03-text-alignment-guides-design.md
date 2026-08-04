# Alignment Guides for Schematic Text — Design

Symbol fields (`U1`, `R5`, values, sheet name and file name) and free text currently get no
alignment guides. Text was excluded from the original feature on the grounds that font metrics
make a poor reference. That exclusion is being lifted for the schematic, deliberately and with
the consequences priced in.

Scope is `SCH_FIELD_T` and `SCH_TEXT_T`. Text boxes and net labels stay out: a text box is a drawn
rectangle that happens to contain text, and a net label is connectable, so it would have to keep
whole-grid-step offsets and anchor-beats-guide.

An earlier draft of this document claimed a text box "already aligns under the graphics rule" —
that was wrong at the time. `GetGraphicAlignmentBox` switched on `SCH_BITMAP_T`, `SCH_LINE_T` and
`SCH_SHAPE_T`, and `SCH_TEXTBOX::Type()` returns `SCH_TEXTBOX_T`, so a text box matched no case in
any of the five rules and got no guides at all.

That gap was closed as a follow-on once this work landed: `SCH_TEXTBOX_T` now shares the
`SCH_SHAPE_T` case, so a text box is measured by its border, aligns to logos, separators and the
drawing sheet, and never chases a reference designator. It is a rectangle the user positions, which
is why `GetItemGrid()` already put it on the graphic grid. Net labels remain out — they are
connectable, and still get no guides from any rule.

## The fifth rule

`EE_GRID_HELPER::GetTextAlignmentBox( const EDA_ITEM* )` joins the four that exist —
`GetAlignmentBox` (bodies), `GetSymbolAlignmentBox` (symbol editor), `GetGraphicAlignmentBox`
(graphics), `GetSheetPinAlignmentBox` (sheet pins).

`SCH_FIELD_T` and `SCH_TEXT_T` return `GetBoundingBox()`. Both implementations already normalise
the box and apply rotation and, for a field, the parent symbol's transform, so the box is the one
KiCad hit-tests against — which is the point: the guide has to land on what the eye sees.

Rejected, returning `std::nullopt`:

- a field with `!IsVisible()` — a guide against invisible text is a lie
- empty text, i.e. a zero-width or zero-height box
- an invalid box

Everything else returns `nullopt`. The rule is exclusive against the other four by inspection:
no existing rule accepts a field or a text item, so there is nothing to arbitrate.

**Why the bounding box and not the anchor point.** The anchor was the cheaper option and matches
what `SCH_PIN` and `SCH_SHEET_PIN` do, but anchors only line up visually when two texts share a
justification, and the ask is that a column of reference designators looks flush. The cost is that
the box moves when the string changes: renaming `U1` to `U10` shifts its right edge. Accepted.

## The gesture

`EE_GRID_HELPER::IsTextSelection( const SELECTION& )` — all-of, not any-of.

The sheet-pin predicate had to be any-of because a pin drag hauls its connected wires into the
same selection. Neither a field nor free text connects to anything, so there are no drag additions
to tolerate and the stricter test is correct. A symbol or sheet anywhere in the selection makes it
false, which keeps a whole-symbol move on the body rule with its fields riding along, unchanged.

Empty selection is false.

## Targets

Text mode is chosen once at drag start, in `CollectAlignmentNeighbors()`, alongside the existing
`m_graphicsMode` and `sheetPinMode` decisions. Never by filtering targets afterwards.

Unlike those two it is *not* gated on `!inSymbolEditor()`. That gate was in the first version of
this work and it was wrong: a symbol's reference designator and value are `SCH_FIELD` in the symbol
editor exactly as they are on a sheet, the author drags them by hand into place, and wanting them
level is the same want. Free text placed in a symbol is `SCH_TEXT` there too.

What text aligns *to* does differ by editor, and that is the one thing the sweep branches on: the
body box that fills in behind the text rule is `GetSymbolAlignmentBox()` in the symbol editor and
`GetAlignmentBox()` on a sheet. So a value glyph lines up with a pin or with the body outline the
author drew, and a reference designator on a sheet lines up with symbol and sheet rectangles —
never the reverse. Pin names and pin numbers stay unaligned in both: they are glyphs a pin draws,
not items anyone drags.

No field expansion is needed in the symbol editor. `SCH_VIEW::DisplaySymbol()` adds the edited
symbol's fields to the view individually, so `KIGFX::VIEW::Query()` returns them directly and the
expansion branch matches nothing.

Each visible item contributes `GetTextAlignmentBox( item )` if it has one, otherwise
`GetAlignmentBox( item )`. So the candidate set is text, non-power symbol bodies and sheet
rectangles together — text aligns to text *and* to bodies.

Fields need expanding. `SCH_SCREEN::Append()` keeps `SCH_FIELD_T` out of the R-tree by the same
guard that keeps `SCH_SHEET_PIN_T` out, so `KIGFX::VIEW::Query()` never returns one. For every
`SCH_SYMBOL` and `SCH_SHEET` the sweep sees, its visible fields are pushed as extra targets,
skipping any the selection already contains. Same shape and same reason as the sheet-pin
expansion.

A symbol therefore contributes its body box *and* its fields' boxes. Intended.

## Containers

Split on whether the selection holds a field:

- **No `SCH_FIELD`** — `collectDrawingSheetSegments()` and the per-motion drawing-sheet cell, the
  graphics path exactly. Free text centres in a title-block cell or on the drawn frame. The paper
  rectangle is deliberately not offered alongside it; the frame is inset from the paper by the
  sheet margins and two centring candidates millimetres apart, one on an edge that is never drawn,
  is worse than one.
- **Any `SCH_FIELD`** — no container at all.

In the symbol editor neither applies: the container is the symbol's body outline, set for every
mode there and unchanged by this work. Text gets it, unlike a field on a sheet, because the reason
a sheet refuses is that its container spans the whole page and merges every neighbour into one
cluster. A body outline is small enough that it does not, and "value centred under the body" is
something symbol authors want.

The split exists because of a known limitation already recorded for graphics (checklist item 32):
the drawing-sheet cell spans the page, so as an alignment neighbour it merges every other item
into a single cluster and the equal-gap search never runs. Offering the container to fields would
kill equal-pitch badges for a reference-designator column, which is a likelier want than centring
a refdes on the page.

`updateDynamicContainers()`'s early-out widens from `!m_graphicsMode` to cover text as well.
`m_graphicsNeighbors` is renamed `m_dynamicNeighbors`, since two modes now populate it.
`clearMoveState()` resets `m_textMode`.

## Grid legality

`gridStep` is suppressed in text mode at both call sites — `BestSnapAnchor()` and
`AlignPointToGuides()` — the same exemption graphics have.

The whole-grid-step rule exists so that pins land on the connection grid. Glyph extents are
arbitrary internal units, so two text boxes essentially never differ by a whole grid step, and
enforcing the rule here would make the feature silent rather than strict. Safe because text has no
connection points: nothing can be dragged off a net.

The off-grid `!` warning needs no change. `IsOffGrid()` reads `GetConnectionPoints()`, which is
empty for a field and for free text, so text never warns — as it already does not.

## Guide priority

`preferGuides` becomes `allBodies || graphicsOnly || textOnly`.

Text is not connectable, so ranking the guide above item anchors cannot break a connection. Without
it, a refdes dragged near a pin snaps to the pin instead of lining up with the refdes above it,
because anchors are checked first. This is the opposite of the sheet-pin decision, and for the
opposite reason: a sheet pin *is* connectable and had to keep anchor-beats-guide.

## Move tool

`SCH_MOVE_TOOL::doMoveSelection()` gains a `textOnly` branch in the `updateBBox` block, choosing
`GetTextAlignmentBox` for the moving box, mirroring the existing `sheetPinsOnly` branch. The moving
box and the targets must come from the same rule or the guides measure two different things.

## Testing

Headless, in `qa/tests/eeschema/test_ee_grid_helper.cpp` (`EEGridHelperTest`):

1. `TextAlignmentBoxIsTheTextBox` — a field and a free text item return their bounding box; an
   invisible field and an empty one return `nullopt`; the rule is exclusive against the other four.
2. `TextSelectionRejectsBodies` — a field alone is true, field plus free text is true, adding a
   symbol makes it false, empty is false.

On-screen checks are appended to
`docs/superpowers/plans/2026-07-25-smart-guides-schematic-verification.md` as items 41 onward:
refdes-to-refdes alignment, refdes to symbol body edge, free text centred in a title-block cell,
equal pitch across a refdes column, fields of an unselected symbol reachable as targets, a whole
symbol drag unaffected, and no `!` glyph on text however far off grid it lands.

## Known costs

- **The box moves with the string.** Renaming a field changes its extents and therefore where its
  guide sits. Inherent to measuring glyphs; the price of the bounding-box choice.
- **Neighbour cap bites sooner.** In text mode a dense sheet pushes a body box plus a refdes and a
  value per symbol, roughly three times the candidates. `MAX_GUIDE_NEIGHBORS` stays at 100 and the
  list is sorted by distance from the moving box, so the far ones are trimmed first — but on a
  crowded sheet a target that is visible on screen may fall outside the hundred.
- **The sweep runs once per drag.** A field made visible mid-drag is not picked up until the next
  one. Consistent with every other mode.
- **No equal-spacing badges for free text.** It takes the container, and the container merges the
  neighbours into one cluster. Fields keep their badges; that is the whole point of the split.
- **Hidden fields get no guides in the symbol editor.** The rule rejects `!IsVisible()`, but that
  editor draws hidden fields greyed out rather than hiding them, so Footprint and Datasheet — both
  hidden by default — are on screen there and still unaligned. Fixing it means teaching a static
  rule the frame's show-hidden setting; not worth the plumbing until someone asks.
