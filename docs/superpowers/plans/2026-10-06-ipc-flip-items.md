# Flip Footprints over the IPC API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Konnect's `flip_component` flips a footprint on a board that KiCad (PixelCad) has open, through a new `FlipItems` IPC command, in one undo step.

**Architecture:** PixelCad gains `FlipItems` (proto + `API_HANDLER_PCB::handleFlipItems`), which runs KiCad's own `FOOTPRINT::Flip` around each footprint's anchor. Konnect vendors the message, adds `KiCadIpcClient::flip_footprints`, and `flip_component` uses it when KiCad holds the requested board; every other board state keeps today's closed-board file flip.

**Tech Stack:** C++/protobuf/Boost.Test (KiCad), Rust/prost/tokio (Konnect), Nix dev shells.

Spec: `docs/superpowers/specs/2026-10-06-ipc-flip-items-design.md`.

## Global Constraints

- PixelCad code lives in `~/projecte/PixelCad/kicad` (repo `grannyaviation/kicad`), branch `feature/smart-guides`; push to `origin feature/smart-guides`.
- Build and run KiCad tests only inside the PixelCad dev shell: `cd ~/projecte/PixelCad && nix develop -c bash -c '…'`, build dir `kicad/build`, target `qa_api`.
- Konnect lives in `~/projecte/Konnect`, branch `update/0.11.0`; push only to the `granny` remote (`grannyaviation/Konnect`). Never open pull requests.
- Run Konnect cargo commands inside its dev shell: `cd ~/projecte/Konnect && nix develop -c cargo …` (the shell sets `PROTOC`).
- `FlipItems` flips each footprint around its own anchor (`fp->GetPosition()`); position does not change.
- Flip direction: `frame()->GetPcbNewSettings()->m_FlipDirection`; headless (no frame) uses `FLIP_DIRECTION::LEFT_RIGHT`.
- All or nothing: an unknown ID or a non-footprint ID rejects the whole request with `AS_BAD_REQUEST`, nothing flipped.
- One commit per request, pushed as `_( "Flipped items via API" )` unless the client holds an open commit (`m_activeClients`).
- Konnect: stock KiCad answers `AS_UNHANDLED`; Konnect then refuses, writes nothing, and says the board must be closed for the file flip.
- Konnect: when KiCad is reachable but holds a *different* board, the closed-board file flip still proceeds (existing test `flip_proceeds_when_kicad_holds_a_different_board`).
- Never stage or edit the GraNNy board files (`sensor_ts/kicad/sensor/*`).
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_0197nXmgXMbyAcLrpUnwUMRc
  ```

---

### Task 1: `FlipItems` in PixelCad

**Files:**
- Modify: `kicad/api/proto/board/board_commands.proto` (after `message RefillZones`, ~line 316)
- Modify: `kicad/pcbnew/api/api_handler_pcb.h:98` (declaration next to `handleRefillZones`)
- Modify: `kicad/pcbnew/api/api_handler_pcb.cpp:125` (registration) and after `handleRefillZones` (~line 1612, implementation)
- Test: `kicad/qa/tests/api/test_api_handler_pcb.cpp`

**Interfaces:**
- Produces: proto message `kiapi.board.commands.FlipItems { DocumentSpecifier board = 1; repeated KIID items = 2; }`, answered with `google.protobuf.Empty` (Task 2 vendors this message verbatim).

- [ ] **Step 1: Write the failing tests**

In `kicad/qa/tests/api/test_api_handler_pcb.cpp`, add the includes after `#include <connectivity/connectivity_data.h>`:

```cpp
#include <footprint.h>
#include <pcb_track.h>
```

Add these two members to `API_HANDLER_PCB_FIXTURE`, after `makeRefillRequest`:

```cpp
    kiapi::common::ApiRequest makeFlipRequest( BOARD* aBoard, const std::vector<KIID>& aIds ) const
    {
        kiapi::board::commands::FlipItems command;
        command.mutable_board()->set_type( kiapi::common::types::DocumentType::DOCTYPE_PCB );
        command.mutable_board()->set_board_filename(
                wxFileName( aBoard->GetFileName() ).GetFullName().ToStdString() );

        for( const KIID& id : aIds )
            command.add_items()->set_value( id.AsStdString() );

        kiapi::common::ApiRequest request;
        request.mutable_header()->set_client_name( "kicad.qa" );
        BOOST_REQUIRE( request.mutable_message()->PackFrom( command ) );

        return request;
    }

    FOOTPRINT* frontFootprint( BOARD* aBoard ) const
    {
        for( FOOTPRINT* footprint : aBoard->Footprints() )
        {
            if( footprint->GetLayer() == F_Cu )
                return footprint;
        }

        return nullptr;
    }
```

Add these cases before `BOOST_AUTO_TEST_SUITE_END()` (issue5830 has 19 front footprints and 146 tracks):

```cpp
BOOST_AUTO_TEST_CASE( FlipItemsFlipsFootprintInPlace )
{
    BOARD*     board = loadBoard( wxS( "issue5830" ) );
    FOOTPRINT* footprint = frontFootprint( board );
    BOOST_REQUIRE( footprint );
    const VECTOR2I position = footprint->GetPosition();

    API_HANDLER_PCB handler( m_context );
    API_RESULT      result = handler.Handle( makeFlipRequest( board, { footprint->m_Uuid } ) );

    BOOST_REQUIRE_MESSAGE( result.has_value(),
                           ( result.has_value() ? std::string() : result.error().error_message() ) );
    BOOST_CHECK_EQUAL( footprint->GetLayer(), B_Cu );
    BOOST_CHECK( footprint->IsFlipped() );
    BOOST_CHECK_EQUAL( footprint->GetPosition(), position );
}


BOOST_AUTO_TEST_CASE( FlipItemsTwiceReturnsToFront )
{
    BOARD*     board = loadBoard( wxS( "issue5830" ) );
    FOOTPRINT* footprint = frontFootprint( board );
    BOOST_REQUIRE( footprint );
    const VECTOR2I position = footprint->GetPosition();

    API_HANDLER_PCB handler( m_context );
    BOOST_REQUIRE( handler.Handle( makeFlipRequest( board, { footprint->m_Uuid } ) ).has_value() );
    BOOST_REQUIRE( handler.Handle( makeFlipRequest( board, { footprint->m_Uuid } ) ).has_value() );

    BOOST_CHECK_EQUAL( footprint->GetLayer(), F_Cu );
    BOOST_CHECK( !footprint->IsFlipped() );
    BOOST_CHECK_EQUAL( footprint->GetPosition(), position );
}


BOOST_AUTO_TEST_CASE( FlipItemsUnknownIdRejected )
{
    BOARD*     board = loadBoard( wxS( "issue5830" ) );
    FOOTPRINT* footprint = frontFootprint( board );
    BOOST_REQUIRE( footprint );

    API_HANDLER_PCB handler( m_context );
    API_RESULT      result = handler.Handle( makeFlipRequest(
            board, { footprint->m_Uuid, KIID( wxS( "deadbeef-0000-0000-0000-000000000000" ) ) } ) );

    BOOST_REQUIRE( !result.has_value() );
    BOOST_CHECK_EQUAL( result.error().status(), kiapi::common::ApiStatusCode::AS_BAD_REQUEST );
    // All or nothing: the valid footprint in the same request stays where it was
    BOOST_CHECK_EQUAL( footprint->GetLayer(), F_Cu );
}


BOOST_AUTO_TEST_CASE( FlipItemsNonFootprintRejected )
{
    BOARD*     board = loadBoard( wxS( "issue5830" ) );
    FOOTPRINT* footprint = frontFootprint( board );
    BOOST_REQUIRE( footprint );
    BOOST_REQUIRE( !board->Tracks().empty() );
    PCB_TRACK*         track = board->Tracks().front();
    const PCB_LAYER_ID trackLayer = track->GetLayer();

    API_HANDLER_PCB handler( m_context );
    API_RESULT result = handler.Handle( makeFlipRequest( board, { footprint->m_Uuid, track->m_Uuid } ) );

    BOOST_REQUIRE( !result.has_value() );
    BOOST_CHECK_EQUAL( result.error().status(), kiapi::common::ApiStatusCode::AS_BAD_REQUEST );
    BOOST_CHECK_EQUAL( footprint->GetLayer(), F_Cu );
    BOOST_CHECK_EQUAL( track->GetLayer(), trackLayer );
}
```

- [ ] **Step 2: Build to verify the tests fail**

Run: `cd ~/projecte/PixelCad && nix develop -c bash -c 'cmake --build kicad/build --target qa_api -j$(nproc) 2>&1 | grep -E "error" | head'`
Expected: compile errors, `FlipItems` is not a member of `kiapi::board::commands`.

- [ ] **Step 3: Add the proto message**

In `kicad/api/proto/board/board_commands.proto`, directly after the closing brace of `message RefillZones`:

```proto

// Flips footprints to the opposite board side, each around its own anchor, as the F key
// does for a single footprint.  The flip direction is the board editor's setting (left/right
// in headless sessions).  All footprints are flipped in one commit; any ID that is not a
// footprint on this board rejects the whole request and nothing is flipped.
// Returns Empty.
message FlipItems
{
  kiapi.common.types.DocumentSpecifier board = 1;

  repeated kiapi.common.types.KIID items = 2;
}
```

- [ ] **Step 4: Build and run to verify the tests fail at runtime**

Run: `cd ~/projecte/PixelCad && nix develop -c bash -c 'cmake --build kicad/build --target qa_api -j$(nproc) 2>&1 | grep -E "error|FAILED" | head; cd kicad/build/qa/tests/api && ./qa_api --run_test="ApiHandlerPcb/FlipItems*" 2>&1 | tail -8'`
Expected: builds; the 4 FlipItems cases fail (no handler yet: `FlipItemsFlipsFootprintInPlace` reports `AS_UNHANDLED`, the rejection cases see the wrong status).

- [ ] **Step 5: Implement the handler**

`kicad/pcbnew/api/api_handler_pcb.h`, after the `handleRefillZones` declaration (line 98):

```cpp
    HANDLER_RESULT<Empty> handleFlipItems( const HANDLER_CONTEXT<FlipItems>& aCtx );
```

`kicad/pcbnew/api/api_handler_pcb.cpp`, registration after the `RefillZones` line (125):

```cpp
    registerHandler<FlipItems, Empty>( &API_HANDLER_PCB::handleFlipItems );
```

Implementation, directly after the closing brace of `API_HANDLER_PCB::handleRefillZones`:

```cpp
HANDLER_RESULT<Empty> API_HANDLER_PCB::handleFlipItems( const HANDLER_CONTEXT<FlipItems>& aCtx )
{
    if( std::optional<ApiResponseStatus> busy = checkForBusy() )
        return tl::unexpected( *busy );

    HANDLER_RESULT<bool> documentValidation = validateDocument( aCtx.Request.board() );

    if( !documentValidation )
        return tl::unexpected( documentValidation.error() );

    std::vector<FOOTPRINT*> footprints;
    std::string             rejected;

    for( const types::KIID& id : aCtx.Request.items() )
    {
        std::optional<BOARD_ITEM*> item = getItemById( KIID( id.value() ) );

        if( !item || ( *item )->Type() != PCB_FOOTPRINT_T )
        {
            rejected += ( rejected.empty() ? "" : ", " ) + id.value();
            continue;
        }

        FOOTPRINT* footprint = static_cast<FOOTPRINT*>( *item );

        // A repeated id would flip the same footprint back
        if( !alg::contains( footprints, footprint ) )
            footprints.push_back( footprint );
    }

    if( !rejected.empty() )
    {
        ApiResponseStatus e;
        e.set_status( ApiStatusCode::AS_BAD_REQUEST );
        e.set_error_message( fmt::format( "not footprints on this board: {}", rejected ) );
        return tl::unexpected( e );
    }

    // Headless sessions have no editor settings; left/right is KiCad's default flip
    const FLIP_DIRECTION direction = frame() ? frame()->GetPcbNewSettings()->m_FlipDirection
                                             : FLIP_DIRECTION::LEFT_RIGHT;

    COMMIT* commit = getCurrentCommit( aCtx.ClientName );

    for( FOOTPRINT* footprint : footprints )
    {
        commit->Modify( footprint, nullptr, RECURSE_MODE::RECURSE );
        footprint->Flip( footprint->GetPosition(), direction );
    }

    if( !m_activeClients.count( aCtx.ClientName ) )
        pushCurrentCommit( aCtx.ClientName, _( "Flipped items via API" ) );

    return Empty();
}
```

If `FLIP_DIRECTION` or `PCBNEW_SETTINGS` is not visible, add `#include <pcbnew_settings.h>` to the include block of `api_handler_pcb.cpp`.

- [ ] **Step 6: Build and run the tests**

Run: `cd ~/projecte/PixelCad && nix develop -c bash -c 'cmake --build kicad/build --target qa_api -j$(nproc) 2>&1 | grep -E "error|FAILED" | head; cd kicad/build/qa/tests/api && ./qa_api --run_test=ApiHandlerPcb 2>&1 | tail -3; ./qa_api --run_test=ApiProto 2>&1 | tail -3'`
Expected: `*** No errors detected` for both suites.

- [ ] **Step 7: Commit and push**

```bash
cd ~/projecte/PixelCad/kicad
git add api/proto/board/board_commands.proto pcbnew/api/api_handler_pcb.h pcbnew/api/api_handler_pcb.cpp qa/tests/api/test_api_handler_pcb.cpp
git commit -F - <<'EOF'
API: add FlipItems to flip footprints to the other board side

The IPC API could move and rotate footprints but not flip them, so a
client had to edit a closed board file to put a part on B.Cu. FlipItems
runs FOOTPRINT::Flip on each listed footprint around its own anchor, in
the editor's flip direction (left/right when headless), in one commit.
Any ID that is not a footprint on the board rejects the whole request.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0197nXmgXMbyAcLrpUnwUMRc
EOF
git push -q origin feature/smart-guides
```

---

### Task 2: Konnect client `flip_footprints`

**Files:**
- Modify: `crates/konnect-ipc/proto/board/board_commands.proto` (after `message RefillZones`, line 208)
- Modify: `crates/konnect-ipc/src/types.rs` (after `IpcFootprintPlacement`, line 56)
- Modify: `crates/konnect-ipc/src/client.rs` (new method after `set_footprint_placements`, which starts at line 1870)
- Test: `crates/konnect-ipc/tests/footprint_transform_test.rs`

**Interfaces:**
- Consumes: `FlipItems` message from Task 1, copied verbatim.
- Produces:
  - `konnect_ipc::types::IpcFlipOutcome { pub flipped: Vec<String>, pub already_on_layer: Vec<String> }` (derives `Debug, Clone, Default, Serialize, Deserialize, PartialEq`).
  - `KiCadIpcClient::flip_footprints(&self, references: &[String], layer: &str) -> anyhow::Result<IpcFlipOutcome>`. `layer` is `"F.Cu"` or `"B.Cu"`. Errors before sending anything for a missing or duplicate reference. Stock KiCad's `AS_UNHANDLED` becomes an error containing `no FlipItems IPC command` and `close the board`.

- [ ] **Step 1: Vendor the message**

In `crates/konnect-ipc/proto/board/board_commands.proto`, after the closing brace of `message RefillZones`, paste the `FlipItems` block from Task 1 Step 3 unchanged (comment included).

- [ ] **Step 2: Write the failing tests**

Append to `crates/konnect-ipc/tests/footprint_transform_test.rs`:

```rust
// ─── FlipItems (PixelCad) ───────────────────────────────────────────────────

type CapturedFlip = Arc<Mutex<Option<kiapi::board::commands::FlipItems>>>;

fn with_identity(
    mut footprint: kiapi::board::types::FootprintInstance,
    reference: &str,
    id: &str,
    layer: kiapi::board::types::BoardLayer,
) -> kiapi::board::types::FootprintInstance {
    footprint.id = Some(kiapi::common::types::Kiid {
        value: id.to_string(),
    });
    footprint.layer = layer as i32;
    footprint
        .reference_field
        .as_mut()
        .unwrap()
        .text
        .as_mut()
        .unwrap()
        .text
        .as_mut()
        .unwrap()
        .text = reference.to_string();
    footprint
}

/// Mock KiCad holding `footprints`; `FlipItems` is recorded and answered OK,
/// or with AS_UNHANDLED like stock KiCad when `flip_supported` is false.
fn spawn_flip_mock(
    footprints: Vec<kiapi::board::types::FootprintInstance>,
    flip_supported: bool,
) -> (MockKicad, CapturedFlip) {
    let captured: CapturedFlip = Arc::new(Mutex::new(None));
    let captured_in_mock = captured.clone();

    let mock = spawn_mock(move |req| {
        let msg = req.message.expect("request must pack a command");
        if msg.type_url.ends_with("GetOpenDocuments") {
            let resp = kiapi::common::commands::GetOpenDocumentsResponse {
                documents: vec![kiapi::common::types::DocumentSpecifier {
                    r#type: kiapi::common::types::DocumentType::DoctypePcb as i32,
                    project: None,
                    identifier: Some(
                        kiapi::common::types::document_specifier::Identifier::BoardFilename(
                            "test.kicad_pcb".to_string(),
                        ),
                    ),
                }],
            };
            Some(reply_with(builders::pack_any(
                &resp,
                "kiapi.common.commands.GetOpenDocumentsResponse",
            )))
        } else if msg.type_url.ends_with("GetItems") {
            let resp = kiapi::common::commands::GetItemsResponse {
                header: None,
                status: kiapi::common::types::ItemRequestStatus::IrsOk as i32,
                items: footprints
                    .iter()
                    .map(|footprint| {
                        builders::pack_any(footprint, "kiapi.board.types.FootprintInstance")
                    })
                    .collect(),
            };
            Some(reply_with(builders::pack_any(
                &resp,
                "kiapi.common.commands.GetItemsResponse",
            )))
        } else if msg.type_url.ends_with("BeginCommit") {
            Some(reply_with(builders::pack_any(
                &kiapi::common::commands::BeginCommitResponse {
                    id: Some(kiapi::common::types::Kiid {
                        value: "flip-commit".to_string(),
                    }),
                },
                "kiapi.common.commands.BeginCommitResponse",
            )))
        } else if msg.type_url.ends_with("EndCommit") {
            Some(reply_with(builders::pack_any(
                &kiapi::common::commands::EndCommitResponse {},
                "kiapi.common.commands.EndCommitResponse",
            )))
        } else if msg.type_url.ends_with("FlipItems") {
            *captured_in_mock.lock().unwrap() = Some(
                kiapi::board::commands::FlipItems::decode(msg.value.as_slice()).unwrap(),
            );
            if flip_supported {
                Some(ok_response())
            } else {
                Some(kiapi::common::ApiResponse {
                    status: Some(kiapi::common::ApiResponseStatus {
                        status: kiapi::common::ApiStatusCode::AsUnhandled as i32,
                        error_message: "no handler available for request of type \
                                        kiapi.board.commands.FlipItems"
                            .to_string(),
                    }),
                    header: None,
                    message: None,
                })
            }
        } else {
            Some(ok_response())
        }
    });

    (mock, captured)
}

#[test]
fn flip_footprints_sends_only_footprints_off_the_target_layer_in_one_request() {
    let r1 = with_identity(mk_footprint_r1(), "R1", "r1-id", kiapi::board::types::BoardLayer::BlFCu);
    let r2 = with_identity(mk_footprint_r1(), "R2", "r2-id", kiapi::board::types::BoardLayer::BlBCu);
    let (mock, captured) = spawn_flip_mock(vec![r1, r2], true);
    let client = KiCadIpcClient::new(&mock.url);

    let outcome = client
        .flip_footprints(&["R1".to_string(), "R2".to_string()], "B.Cu")
        .unwrap();

    assert_eq!(outcome.flipped, vec!["R1".to_string()]);
    assert_eq!(outcome.already_on_layer, vec!["R2".to_string()]);
    let sent = captured.lock().unwrap().take().expect("FlipItems sent");
    let ids: Vec<_> = sent.items.iter().map(|id| id.value.as_str()).collect();
    assert_eq!(ids, vec!["r1-id"]);
}

#[test]
fn flip_footprints_sends_nothing_when_every_footprint_is_already_there() {
    let r1 = with_identity(mk_footprint_r1(), "R1", "r1-id", kiapi::board::types::BoardLayer::BlBCu);
    let (mock, captured) = spawn_flip_mock(vec![r1], true);
    let client = KiCadIpcClient::new(&mock.url);

    let outcome = client.flip_footprints(&["R1".to_string()], "B.Cu").unwrap();

    assert!(outcome.flipped.is_empty());
    assert_eq!(outcome.already_on_layer, vec!["R1".to_string()]);
    assert!(captured.lock().unwrap().is_none(), "nothing to flip, nothing sent");
}

#[test]
fn flip_footprints_rejects_a_missing_reference_before_sending() {
    let r1 = with_identity(mk_footprint_r1(), "R1", "r1-id", kiapi::board::types::BoardLayer::BlFCu);
    let (mock, captured) = spawn_flip_mock(vec![r1], true);
    let client = KiCadIpcClient::new(&mock.url);

    let error = client
        .flip_footprints(&["R1".to_string(), "R9".to_string()], "B.Cu")
        .unwrap_err();

    assert!(format!("{error:#}").contains("R9"), "{error:#}");
    assert!(captured.lock().unwrap().is_none(), "all or nothing");
}

#[test]
fn flip_footprints_explains_a_kicad_without_flip_items() {
    let r1 = with_identity(mk_footprint_r1(), "R1", "r1-id", kiapi::board::types::BoardLayer::BlFCu);
    let (mock, _captured) = spawn_flip_mock(vec![r1], false);
    let client = KiCadIpcClient::new(&mock.url);

    let error = client.flip_footprints(&["R1".to_string()], "B.Cu").unwrap_err();
    let text = format!("{error:#}");

    assert!(text.contains("no FlipItems IPC command"), "{text}");
    assert!(text.contains("close the board"), "{text}");
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd ~/projecte/Konnect && nix develop -c cargo test -p konnect-ipc --test footprint_transform_test flip_footprints 2>&1 | tail -15`
Expected: compile error, no method named `flip_footprints` on `KiCadIpcClient`.

- [ ] **Step 4: Add the outcome type**

In `crates/konnect-ipc/src/types.rs`, after `IpcFootprintPlacement`:

```rust
/// What `flip_footprints` did: the references it flipped and the ones that
/// were already on the requested side.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct IpcFlipOutcome {
    pub flipped: Vec<String>,
    pub already_on_layer: Vec<String>,
}
```

- [ ] **Step 5: Implement `flip_footprints`**

In `crates/konnect-ipc/src/client.rs`, as a new method of `KiCadIpcClient` right after `set_footprint_placements`:

```rust
    /// Flip footprints to `layer` ("F.Cu" or "B.Cu") with KiCad's own flip,
    /// through PixelCad's `FlipItems`: each around its own anchor, all in one
    /// undo step. Footprints already on `layer` are left alone and reported.
    /// Stock KiCad has no `FlipItems` and answers AS_UNHANDLED, which is
    /// reported as such so the caller can point at the closed-board flip.
    pub fn flip_footprints(&self, references: &[String], layer: &str) -> Result<IpcFlipOutcome> {
        let target = match layer {
            "F.Cu" => kiapi::board::types::BoardLayer::BlFCu,
            "B.Cu" => kiapi::board::types::BoardLayer::BlBCu,
            other => anyhow::bail!("footprints flip to F.Cu or B.Cu, not '{other}'"),
        } as i32;

        let mut requested = std::collections::HashSet::new();
        for reference in references {
            if !requested.insert(reference.as_str()) {
                anyhow::bail!("flip request names footprint '{reference}' more than once");
            }
        }

        let items = self.get_items(kiapi::common::types::KiCadObjectType::KotPcbFootprint)?;
        let mut outcome = IpcFlipOutcome::default();
        let mut ids = Vec::new();

        for item in &items {
            if !crate::builders::any_is(item, "kiapi.board.types.FootprintInstance") {
                continue;
            }
            let footprint = kiapi::board::types::FootprintInstance::decode(item.value.as_slice())?;
            let reference = footprint_reference(&footprint);
            if !requested.remove(reference) {
                continue;
            }
            if footprint.layer == target {
                outcome.already_on_layer.push(reference.to_string());
            } else {
                ids.push(
                    footprint
                        .id
                        .clone()
                        .with_context(|| format!("footprint '{reference}' has no id"))?,
                );
                outcome.flipped.push(reference.to_string());
            }
        }

        if !requested.is_empty() {
            let mut missing: Vec<_> = requested.into_iter().collect();
            missing.sort_unstable();
            anyhow::bail!(
                "footprint{} {} not found on board",
                if missing.len() == 1 { "" } else { "s" },
                missing.join(", ")
            );
        }

        if ids.is_empty() {
            return Ok(outcome);
        }

        let board = self.get_board_document()?;
        self.run_commit("Flip components", |client| {
            let command = kiapi::board::commands::FlipItems {
                board: Some(board),
                items: ids,
            };
            match client.send_command(&command, "kiapi.board.commands.FlipItems") {
                Ok(_) => Ok(()),
                Err(error) if format!("{error:#}").contains("AS_UNHANDLED") => Err(error.context(
                    "this KiCad has no FlipItems IPC command (PixelCad adds it); \
                     close the board in KiCad to flip the file instead",
                )),
                Err(error) => Err(error),
            }
        })?;

        Ok(outcome)
    }
```

If `Context` (for `with_context`) or `prost::Message` (for `decode`) is not already imported in `client.rs`, add them to its existing `use` lines (both are already used elsewhere in the file: `.context(` in `send_command`, `::decode(` in `set_footprint_placements`).

- [ ] **Step 6: Run the tests**

Run: `cd ~/projecte/Konnect && nix develop -c cargo test -p konnect-ipc 2>&1 | grep -E "^test result|FAILED|panicked" | head`
Expected: every `test result: ok`, no `FAILED`.

- [ ] **Step 7: Commit**

```bash
cd ~/projecte/Konnect
git add crates/konnect-ipc/proto/board/board_commands.proto crates/konnect-ipc/src/types.rs crates/konnect-ipc/src/client.rs crates/konnect-ipc/tests/footprint_transform_test.rs
git commit -F - <<'EOF'
feat(ipc): flip_footprints over PixelCad's FlipItems command

Vendors FlipItems from grannyaviation/kicad and adds
KiCadIpcClient::flip_footprints: resolves references, skips footprints
already on the target side, and flips the rest in one KiCad commit.
Stock KiCad answers AS_UNHANDLED, which is reported with a pointer to
the closed-board flip.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0197nXmgXMbyAcLrpUnwUMRc
EOF
```

---

### Task 3: `flip_component` uses the live board

**Files:**
- Modify: `crates/konnect-core/src/tools/pcb_components.rs` (registration ~line 1828-1844; `handle_flip_component` ~line 2454-2500; tests module)
- Modify: `crates/konnect/src/install.rs:770-773` (board-access assertion)
- Modify: `README.md:301-303`, `README.md:343-344`, `tool-directory.md:247`, `crates/konnect/assets/skills/kicad-pcb/SKILL.md:24-26` and `:137`

**Interfaces:**
- Consumes: `KiCadIpcClient::flip_footprints(&[String], &str) -> Result<IpcFlipOutcome>` from Task 2; existing `crate::tools::with_board_ipc_classified`, `attempt_ipc_write`, `BoardWrite`, `crate::tools::pcb_board::refuse_if_board_open_in_kicad`, `set_closed_board_footprint_side`.
- Produces: `flip_component` result on the live path: `{"flipped": <ref>, "layer": <layer>, "changed": <bool>, "source": "ipc", "undo": "One KiCad undo step reverses the flip."}`. Tool board access `LivePreferredWithFallback`.

- [ ] **Step 1: Write the failing tests**

In the tests module of `pcb_components.rs`, next to `flip_proceeds_when_kicad_holds_a_different_board`, add:

```rust
    /// The footprint KiCad reports for U1, on `layer`.
    fn live_u1(layer: konnect_ipc::gen::kiapi::board::types::BoardLayer) -> prost_types::Any {
        use konnect_ipc::gen::kiapi;
        konnect_ipc::builders::pack_any(
            &kiapi::board::types::FootprintInstance {
                id: Some(kiapi::common::types::Kiid {
                    value: "u1-id".to_string(),
                }),
                layer: layer as i32,
                reference_field: Some(kiapi::board::types::Field {
                    name: "Reference".to_string(),
                    text: Some(kiapi::board::types::BoardText {
                        text: Some(kiapi::common::types::Text {
                            text: "U1".to_string(),
                            ..Default::default()
                        }),
                        ..Default::default()
                    }),
                    ..Default::default()
                }),
                ..Default::default()
            },
            "kiapi.board.types.FootprintInstance",
        )
    }

    /// A KiCad holding `board` with U1 on `layer`, recording any FlipItems.
    fn spawn_flipping_kicad(
        board: &std::path::Path,
        layer: konnect_ipc::gen::kiapi::board::types::BoardLayer,
    ) -> (
        String,
        std::sync::Arc<std::sync::Mutex<Option<konnect_ipc::gen::kiapi::board::commands::FlipItems>>>,
    ) {
        use konnect_ipc::gen::kiapi;
        use prost::Message;
        let captured = std::sync::Arc::new(std::sync::Mutex::new(None));
        let captured_in_mock = captured.clone();
        let address = crate::tools::pcb_board::board_mock::spawn_kicad_holding_board(
            board,
            move |command| {
                if command.type_url.ends_with("GetItems") {
                    Some(konnect_ipc::builders::pack_any(
                        &kiapi::common::commands::GetItemsResponse {
                            header: None,
                            status: kiapi::common::types::ItemRequestStatus::IrsOk as i32,
                            items: vec![live_u1(layer)],
                        },
                        "kiapi.common.commands.GetItemsResponse",
                    ))
                } else if command.type_url.ends_with("BeginCommit") {
                    Some(konnect_ipc::builders::pack_any(
                        &kiapi::common::commands::BeginCommitResponse {
                            id: Some(kiapi::common::types::Kiid {
                                value: "flip-commit".to_string(),
                            }),
                        },
                        "kiapi.common.commands.BeginCommitResponse",
                    ))
                } else if command.type_url.ends_with("EndCommit") {
                    Some(konnect_ipc::builders::pack_any(
                        &kiapi::common::commands::EndCommitResponse {},
                        "kiapi.common.commands.EndCommitResponse",
                    ))
                } else if command.type_url.ends_with("FlipItems") {
                    *captured_in_mock.lock().unwrap() = Some(
                        kiapi::board::commands::FlipItems::decode(command.value.as_slice()).unwrap(),
                    );
                    None
                } else {
                    None
                }
            },
        );
        (address, captured)
    }

    fn live_flip_board(dir: &std::path::Path) -> (std::path::PathBuf, String) {
        let board = dir.join("flip.kicad_pcb");
        let before = format!(
            "(kicad_pcb\n  (version 20260206)\n  (generator \"pcbnew\")\n  (net 0 \"\")\n{}\n)\n",
            FLIP_FOOTPRINT
                .lines()
                .map(|line| format!("  {line}"))
                .collect::<Vec<_>>()
                .join("\n")
        );
        std::fs::write(&board, &before).unwrap();
        (board, before)
    }

    #[tokio::test]
    async fn flip_uses_flip_items_when_kicad_holds_the_board() {
        let tmp = tempfile::tempdir().unwrap();
        let (board, before) = live_flip_board(tmp.path());
        let (address, captured) = spawn_flipping_kicad(
            &board,
            konnect_ipc::gen::kiapi::board::types::BoardLayer::BlFCu,
        );
        let ctx = crate::tools::pcb_board::board_mock::ctx_talking_to(address);

        let result = handle_flip_component(
            &json!({"board": board, "reference": "U1", "layer": "B.Cu"}),
            &ctx,
        )
        .await
        .unwrap();

        assert!(!result.is_error, "{:?}", result.content);
        let response: serde_json::Value =
            serde_json::from_str(&result_text(&result)).expect("flip result must be JSON");
        assert_eq!(response["source"], "ipc");
        assert_eq!(response["changed"], true);
        let sent = captured.lock().unwrap().take().expect("FlipItems sent");
        assert_eq!(sent.items.len(), 1);
        assert_eq!(sent.items[0].value, "u1-id");
        // KiCad holds the board: its next save writes the flip, the file is untouched
        assert_eq!(std::fs::read_to_string(&board).unwrap(), before);
    }

    #[tokio::test]
    async fn flip_on_a_live_board_already_on_the_side_changes_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let (board, before) = live_flip_board(tmp.path());
        let (address, captured) = spawn_flipping_kicad(
            &board,
            konnect_ipc::gen::kiapi::board::types::BoardLayer::BlBCu,
        );
        let ctx = crate::tools::pcb_board::board_mock::ctx_talking_to(address);

        let result = handle_flip_component(
            &json!({"board": board, "reference": "U1", "layer": "B.Cu"}),
            &ctx,
        )
        .await
        .unwrap();

        assert!(!result.is_error, "{:?}", result.content);
        let response: serde_json::Value =
            serde_json::from_str(&result_text(&result)).expect("flip result must be JSON");
        assert_eq!(response["source"], "ipc");
        assert_eq!(response["changed"], false);
        assert!(captured.lock().unwrap().is_none(), "nothing to flip, nothing sent");
        assert_eq!(std::fs::read_to_string(&board).unwrap(), before);
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/projecte/Konnect && nix develop -c cargo test -p konnect-core flip_ 2>&1 | grep -E "^test |test result" | head -30`
Expected: the two new tests FAIL (today the tool refuses a live board: `is_error` is true); the other flip tests pass.

- [ ] **Step 3: Route the live board through `FlipItems`**

In `handle_flip_component`, replace everything from the comment `// KiCAD 10.0.5 and the protocol Konnect vendors carry no FlipItems command,` through the end of the `if let Some(refusal) = … refuse_if_board_open_in_kicad(…) … { return Ok(refusal); }` block with:

```rust
    // KiCad holding this very board gets the flip over IPC (PixelCad's
    // FlipItems), because a file edit would be discarded by its next save.
    // Every other state keeps the closed-board contract of
    // `refuse_if_board_open_in_kicad`: a KiCad holding a different board
    // cannot discard a write to this file, and an unreachable KiCad that held
    // it earlier this session refuses.
    let held_live = crate::tools::with_board_ipc_classified(ctx, &board, |_| Ok(()))
        .await?
        .is_ok();

    if held_live {
        let (reference_ipc, layer_ipc) = (reference.clone(), layer.clone());
        match attempt_ipc_write(ctx, &board, "footprint flip", move |client| {
            client.flip_footprints(&[reference_ipc], &layer_ipc)
        })
        .await?
        {
            BoardWrite::Ipc(outcome) => {
                return Ok(CallToolResult::json(&json!({
                    "flipped": reference,
                    "layer": layer,
                    "changed": !outcome.flipped.is_empty(),
                    "source": "ipc",
                    "undo": "One KiCad undo step reverses the flip."
                })))
            }
            BoardWrite::Refused(result) => return Ok(result),
            // KiCad let go of the board between the probe and the write
            BoardWrite::File => {}
        }
    }

    if let Some(refusal) =
        crate::tools::pcb_board::refuse_if_board_open_in_kicad(ctx, &board, "footprint flip")
            .await?
    {
        return Ok(refusal);
    }
```

Leave the `match set_closed_board_footprint_side(…)` block that follows unchanged.

- [ ] **Step 4: Update the registration**

In the `tool!( "flip_component", … )` registration, replace the description with:

```rust
            "Set a placed footprint to F.Cu or B.Cu. When KiCad holds the board open, flips \
             it with KiCad's own flip over IPC (PixelCad's FlipItems, one undo step); stock \
             KiCad lacks that command and is refused. Otherwise safely flips the closed board \
             file with KiCAD-equivalent geometry mirroring and revision checks, failing closed \
             on unsupported geometry.",
```

and change `.with_board_access(crate::tools::BoardAccess::ClosedBoardOnly)` on that tool to `.with_board_access(crate::tools::BoardAccess::LivePreferredWithFallback)`.

In `crates/konnect/src/install.rs` (lines 770-773), change the expected access:

```rust
        assert_eq!(
            registered.get("flip_component"),
            Some(&konnect_core::tools::BoardAccess::LivePreferredWithFallback)
        );
```

- [ ] **Step 5: Run the tests**

Run: `cd ~/projecte/Konnect && nix develop -c cargo test --workspace 2>&1 | grep -E "^test result|FAILED|panicked" | head -20`
Expected: every `test result: ok`. `flip_refuses_the_exact_open_board_without_touching_the_file` still passes: its mock answers nothing, so `flip_footprints` fails and the tool refuses without writing.

If `install.rs` has a test asserting that the `pre-pcb-closed` hook has targets (`hook_matcher` bails with "has no registered tool targets" when a class is empty), and `add_layer`/`set_active_layer` still use `ClosedBoardOnly`, it keeps passing; if it fails because the class became empty, report it instead of changing other tools.

- [ ] **Step 6: Update the docs**

- `README.md:301-303`: replace "`flip_component` intentionally requires a closed board because KiCAD IPC has no native footprint-flip command." with "`flip_component` flips over IPC with PixelCad's `FlipItems` when KiCAD holds the board, and otherwise flips a closed board file; stock KiCAD has no flip command, so there it requires the board closed."
- `README.md:343-344`: replace "`flip_component` requires one, and refuses while KiCAD holds that board open." with "`flip_component` does too, and on a board KiCAD holds open it needs PixelCad's `FlipItems` IPC command."
- `tool-directory.md:247`: replace the row's description with "Set a placed footprint to F.Cu or B.Cu: over IPC with PixelCad's `FlipItems` when KiCAD holds the board (one undo step), otherwise on the closed board file with KiCAD-equivalent geometry mirroring and revision checks; refuses unsupported geometry."
- `crates/konnect/assets/skills/kicad-pcb/SKILL.md:24-26`: replace "File-only operations such as `flip_component` proceed only when KiCad does not hold the target board open." with "`flip_component` flips a board KiCad holds open through PixelCad's `FlipItems` IPC command, and otherwise follows the closed-board rule."
- `crates/konnect/assets/skills/kicad-pcb/SKILL.md:137`: replace "Set F.Cu/B.Cu on a closed board with geometry mirroring" with "Set F.Cu/B.Cu (live via PixelCad FlipItems, or closed board)".

- [ ] **Step 7: Commit and push**

```bash
cd ~/projecte/Konnect
git add crates/konnect-core/src/tools/pcb_components.rs crates/konnect/src/install.rs README.md tool-directory.md crates/konnect/assets/skills/kicad-pcb/SKILL.md
git commit -F - <<'EOF'
feat(flip_component): flip a live board over PixelCad's FlipItems

When KiCad holds the requested board, flip_component now flips through
KiCadIpcClient::flip_footprints (one undo step) instead of refusing.
Stock KiCad answers AS_UNHANDLED and is refused without a file write.
A KiCad holding another board, or none, keeps the closed-board flip.
The tool's board access becomes LivePreferredWithFallback.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0197nXmgXMbyAcLrpUnwUMRc
EOF
git push -q granny update/0.11.0
```

---

### Task 4: Roll out

Controller task (no subagent): it touches the user's installed tools.

**Files:**
- Modify: `~/projecte/PixelCad/flake.lock`
- Replace: `~/.local/share/konnect/bin/konnect` (backup `konnect.pre-flip.bak`)
- Modify: `~/.claude/settings.json` (Konnect hook matchers)

- [ ] **Step 1: Bump PixelCad to the Task 1 commit**

```bash
cd ~/projecte/PixelCad && git pull -q --ff-only && nix flake update kicad-src
python3 -c "import json;print(json.load(open('flake.lock'))['nodes']['kicad-src']['locked']['rev'][:10])"
```
Expected: the printed rev equals `git -C kicad rev-parse --short=10 HEAD`. Then commit and push:

```bash
git add flake.lock && git commit -F - <<'EOF'
flake.lock: bump kicad-src (FlipItems IPC command)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0197nXmgXMbyAcLrpUnwUMRc
EOF
git push -q origin main
```

- [ ] **Step 2: Build and install Konnect**

```bash
cd ~/projecte/Konnect && nix develop -c cargo build --release -p konnect 2>&1 | tail -2
cp ~/.local/share/konnect/bin/konnect ~/.local/share/konnect/bin/konnect.pre-flip.bak
cp target/release/konnect ~/.local/share/konnect/bin/konnect
~/.local/share/konnect/bin/konnect --version
```
Expected: release build finishes; the version prints.

- [ ] **Step 3: Move `flip_component` to the fallback hook**

`konnect init` does not rewrite an existing hook's matcher, so edit `~/.claude/settings.json` directly (Edit tool): remove `flip_component|` from the matcher `mcp__konnect__(add_layer|flip_component|set_active_layer)` and insert `flip_component|` in alphabetical order into the `pre-pcb-fallback` matcher, between `delete_graphics|` and `get_component_pads|`. Then check the file is still valid JSON: `python3 -m json.tool ~/.claude/settings.json >/dev/null && echo ok`.

- [ ] **Step 4: Hand over**

Tell the owner: run `nhs` (installs `FlipItems` and the zone/arc fix), then `/mcp` to reconnect Konnect. Verify after that with a live flip of one part they choose, and `get_component_pads` showing its pads on B.Cu.
