# Implementation Plan: Resumable Upload And Typed Publishing Options

## Feature Contract

- Workflow mode: `issue-resolution`
- Issue reference: `workflow-input:codex-design-and-implement-review-loop-session-695`
- Feature ID: `instagram-publishing-extensions`
- Feature title: `Resumable upload and typed publishing options`
- Design reference: `design-docs/specs/instagram-publishing-extensions.md`
- Codex agent references: `/root/design_review`, `/root/plan_review`
- Scope boundary: `InstagramGatewayCore`, writer media commands, deterministic
  tests, README/coverage/live-test documentation; no reader command additions.

## Objective

Implement the accepted design's typed publishing options and Meta-confirmed
resumable upload flow without breaking existing public SDK callers, collapsing
reader/writer permission boundaries, buffering complete video files in memory,
or claiming success where Facebook Login for Business, permissions, account
eligibility, media, or owned-fixture prerequisites are absent.

## Deliverables

1. Backward-compatible public publishing DTOs in
   `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`.
   - Add explicit public initializers and `Codable`, `Equatable`, `Sendable`
     conformance for `InstagramTagPosition`, `InstagramUserTag`,
     `InstagramVideoCover`, `InstagramPublishingOptions`,
     `CreateResumableVideoContainerInput`, `UploadResumableVideoInput`, typed
     video-upload status DTOs, rupload response/error DTOs, and
     `ResumableVideoUploadResult`.
   - Extend `CreateMediaContainerInput`, `MediaContainer`, and
     `MediaContainerStatus` with custom decoders that supply defaults for
     absent new fields.
   - Add custom encoders that omit new nil/empty-default properties, preserving
     the legacy serialized key set, with exact key/fixture assertions.
   - Preserve all existing public initializer calls and encoded/decoded fixture
     behavior.

2. Source-compatible streamed transport and endpoint security.
   - Preserve `HTTPRequest.body: Data?` and its initializer behavior; add a
     non-conflicting file-slice request representation and optional absolute
     endpoint.
   - Validate absolute endpoints before `InstagramGatewayClient` attaches any
     credential: only HTTPS `rupload.facebook.com`, default port, no userinfo,
     and `/ig-api-upload/` paths are allowed outside the configured Graph
     origin; reject userinfo, explicit ports, query strings, and fragments.
   - Keep Bearer authorization for Graph requests and use OAuth authorization
     only for validated rupload requests.
   - Stream the file remainder from an offset with `URLSession`; never read the
     complete video into `Data`.
   - Disable rupload redirects or revalidate every redirect before forwarding
     authorization. Mirror the allowlist in transport as defense in depth.
   - Update redaction for Bearer and OAuth headers, upload URIs, and nested
     rupload `debug_info` messages.

3. Shared typed-option validation and encoding.
   - Implement one compatibility/encoding helper used by URL-fetch and
     resumable container creation.
   - Encode `user_tags` and `collaborators` as deterministic compact JSON and
     encode `location_id`, `cover_url`, `thumb_offset`, and `alt_text` with
     exact provider keys.
   - Enforce the accepted media matrix:
     - Feed/carousel images require positioned user tags and allow alt text.
     - Feed/Reel and video-carousel tags are username-only.
     - Image/video Stories allow tags with optional position.
     - Collaborators/location apply only to feed image, Reel, and top-level
       carousel.
     - Cover URL applies to Reel; thumbnail offset applies to Reel/video, video
       Story, and video-carousel item.
     - Stories and carousel children reject captions; top-level feed/Reel/
       carousel accept them.
   - Validate username form/uniqueness/provider maximum, finite `0...1`
     coordinates, non-empty text/IDs, HTTPS cover URLs, and mutually exclusive
     cover forms.
   - Reject every collision between `providerFields` and typed or service-owned
     keys, while preserving sorted non-colliding future fields.

4. Resumable writer service methods.
   - Create a container with `upload_type=resumable`, the existing video media
     mapping, typed options, and no `video_url`; reject non-video media types.
   - Decode and return Meta's versioned upload `uri` with the container ID.
   - Extend status requests to include and decode
     `video_status.uploading_phase.bytes_transferred`.
   - Upload a readable local regular file from the supplied provider-confirmed
     offset to the validated returned URI with `Authorization: OAuth`, total
     `file_size`, `offset`, `application/octet-stream`, and a streamed body.
   - Return provider success/message without inferring `nextOffset`; require a
     subsequent status query for confirmed progress.
   - Decode rupload `debug_info` failures, recursively redact provider text,
     and map HTTP status/error details to stable existing errors.

5. Permission-separated writer CLI commands in
   `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift`.
   - Extend `media create-container` with repeatable `--user-tag`, repeatable
     `--user-tag-at`, repeatable `--collaborator`, `--location-id`,
     `--cover-url`, `--thumb-offset-ms`, and `--alt-text`.
   - Add confirmation-gated `media create-resumable-container` and
     `media upload-resumable` commands.
   - Add read-only writer command `media resumable-status` for the confirmed
     offset; keep existing `media container-status` behavior compatible.
   - Require returned `--upload-uri`, local `--file`, and explicit
     `--offset` for upload so callers cannot accidentally guess the target or
     resume point.
   - Teach the argument parser to preserve repeated flags and reject malformed,
     duplicate, incompatible, mutually exclusive, unknown, or trailing input
     before service execution.
   - Keep all new commands absent from reader help/dispatch. Use existing JSON
     envelopes, access-mode selection, confirmation guard, and redaction.

6. Deterministic SDK and CLI tests.
   - Add tests in `Tests/InstagramGatewayCoreTests/CoreTests.swift` for public
     initializers, Codable round trips/default decoding, typed JSON query
     encoding, every compatibility-matrix branch, provider-field collisions,
     and legacy caller behavior.
   - Test resumable container query construction, returned URI decoding,
     `video_status` decoding, exact rupload host/path/OAuth/file headers, file
     slice metadata, success response, `debug_info` errors, and no inferred
     progress.
   - Test malicious absolute schemes/hosts/ports/userinfo/paths and cross-origin
     redirects never receive authorization; include query and fragment cases.
   - Use small temporary owned fixture files; assert recording transport stores
     metadata rather than binary contents and large-body code paths are
     streaming by construction.
   - Add tests in `Tests/InstagramGatewayCLITests/CLITests.swift` for repeated
     typed flags, both user-tag syntaxes, validation failures, confirmation,
     writer help, reader exclusion, exact request construction, and redacted
     JSON failure envelopes.

7. Documentation and coverage.
   - Update `README.md` writer examples and typed flag reference.
   - Update `docs/api-coverage.md` to mark typed SDK/CLI coverage separately
     from live/provider prerequisites and to state that resumable upload needs
     Facebook Login for Business plus `instagram_content_publish`.
   - Update `docs/live-smoke-tests.md` with safe unpublished container/status/
     upload steps, no third-party tags/collaborators/unowned locations, and no
     implicit publish.
   - Use a dated results table in `docs/live-smoke-tests.md` as the explicit
     pass/fail/skipped/Meta-blocked live record.
   - If an explicitly approved owned publish is tested, record the post and
     manual Instagram cleanup requirement; never claim API deletion.

8. Verification record.
   - Run deterministic tests and debug/release builds.
   - Run reader and writer help plus targeted command-help/separation checks.
   - Run repository security searches for secrets, unsafe upload-host handling,
     and complete-file buffering.
   - Record live results as pass, fail, skipped, or Meta-blocked with the exact
     prerequisite; do not turn blocked provider setup into a code failure or a
     claimed success.

## Dependencies

- Existing `InstagramGatewayClient`, `HTTPRequest`, `HTTPTransport`,
  `URLSessionHTTPTransport`, redactor, writer service, JSON envelopes, access
  modes, and confirmation guard.
- Existing media container/status/publish methods and `PublishingMediaType`
  mapping.
- Foundation file metadata, `FileHandle`/stream APIs, and URLSession behavior on
  supported Swift/macOS versions.
- For live resumable verification only: Facebook Login for Business, an
  eligible owned professional account, `instagram_content_publish`, any Meta
  Advanced Access/App Review required by the app/account relationship, a
  provider-compliant owned local video, and the configured kinko token
  reference.
- Manual Instagram cleanup and separate operator approval for any published
  smoke artifact because Graph API media deletion is unavailable.

## Ordered Task Breakdown

1. Add compatibility tests before modifying public DTOs or HTTP requests.
2. Implement new DTOs and custom backward-compatible decoding; run targeted
   core tests.
3. Add absolute-endpoint validation, OAuth selection, redirect protection, and
   file-slice streaming; run security/transport tests before service wiring.
4. Implement the shared publishing-option matrix, validation, collision checks,
   and deterministic provider encoding; run matrix tests.
5. Add resumable creation/status/upload and rupload error mapping; run request
   and error-path tests.
6. Extend parser and writer command routing, then add CLI execution and
   reader-exclusion tests.
7. Update README, API coverage, and live verification docs against actual
   implemented command names and provider behavior.
8. Run full deterministic verification, inspect the diff for public-contract
   changes and secret exposure, and record any gated live checks accurately.

## Progress Tracking

- [ ] Legacy public API and HTTPRequest compatibility tests added.
- [ ] Typed publishing/resumable DTOs and custom decoding implemented.
- [ ] Endpoint allowlist, OAuth selection, redirect protection, and streaming implemented.
- [ ] Typed option matrix, validation, encoding, and collision checks implemented.
- [ ] Resumable create/status/upload service methods and rupload errors implemented.
- [ ] Writer CLI flags/commands and repeated-argument parsing implemented.
- [ ] Core and CLI deterministic tests completed.
- [ ] README, API coverage, and live-smoke documentation updated.
- [ ] `swift test` and debug/release builds passed.
- [ ] CLI help/separation and security searches passed.
- [ ] Live checks recorded without overstating Meta-blocked operations.

## Verification

Required deterministic commands:

```bash
swift test
swift build
swift build -c release
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
swift run instagram-gateway-writer --help | rg -F "create-resumable-container"
swift run instagram-gateway-writer --help | rg -F "resumable-status"
swift run instagram-gateway-writer --help | rg -F "upload-resumable"
if swift run instagram-gateway-reader --help | rg -q "create-resumable-container|resumable-status|upload-resumable"; then exit 1; fi
```

Targeted test filters may be used during iteration, but do not replace the full
suite:

```bash
swift test --filter InstagramGatewayCoreTests
swift test --filter InstagramGatewayCLITests
```

Static safety checks:

```bash
rg -n "Authorization|access_token|app_secret|rupload|absoluteEndpoint|Data\(contentsOf:|readToEnd|readDataToEndOfFile" Sources Tests README.md docs
rg -n "create-resumable-container|resumable-status|upload-resumable" Sources/InstagramGatewayReader Sources/InstagramGatewayCLI Tests
git diff --check
```

The second search is reviewed semantically: shared CLI source and rejection
tests may contain the names, but reader help/dispatch must not expose them.

Credential-gated live verification is conditional and never part of default
tests:

```bash
swift run instagram-gateway-writer media create-resumable-container --account <owned-id> --type reel --yes
swift run instagram-gateway-writer media resumable-status --container-id <owned-container-id>
swift run instagram-gateway-writer media upload-resumable --container-id <owned-container-id> --upload-uri <returned-uri> --file <owned-video> --offset <confirmed-offset> --yes
swift run instagram-gateway-writer media container-status --container-id <owned-container-id>
```

Do not run typed collaborator or user-tag live checks against third parties. Do
not publish unless separate explicit approval and manual cleanup are available.

## Completion Criteria

### Step 6 rerun update — 2026-08-13

- Added typed publishing options, resumable-container creation, validated
  rupload endpoint/upload request support, and typed product-tag compatibility
  foundations.
- Streaming transport, repeated CLI flags, status progress decoding, redirect
  handling, and live verification remain pending and must not be claimed done.
- Added deterministic URI rejection, status-progress decoding, confirmation,
  and reader-exclusion tests. Resumable commands are present in writer help.

- Existing SDK callers compile and legacy encoded payloads decode without the
  new keys; encoding default/nil extensions preserves the legacy key set.
- Known publishing options are public typed values and writer CLI flags; future
  non-colliding `providerFields` remain supported.
- SDK and CLI enforce the accepted per-media option matrix before network I/O.
- Resumable creation preserves Meta's returned versioned URI, status exposes
  Meta-confirmed bytes transferred, and upload streams the file remainder with
  exact trusted endpoint/auth/header behavior.
- Neither success nor failure infers a resume offset; only a later status result
  is authoritative.
- Malicious endpoints and redirects cannot receive the access token, and Graph
  versus rupload authorization schemes remain distinct.
- Rupload and Graph errors are typed, deterministically mapped, and redacted.
- New state-changing operations are writer-only and confirmation-gated; reader
  help/dispatch remains read-only.
- Deterministic test suite, debug build, release build, CLI help checks, and
  diff/safety checks pass.
- Documentation distinguishes implemented code from Facebook Login for
  Business, permission, review, account, media, and owned-fixture prerequisites.
- No live result claims third-party mutation, unowned Commerce/location use,
  API media deletion, or success for a Meta-blocked operation.

## Self-Review

- Design-plan consistency: all accepted DTO, compatibility matrix, returned URI,
  confirmed-offset, OAuth, endpoint, streaming, CLI, error, prerequisite, and
  cleanup decisions map to concrete tasks and completion criteria.
- Deliverables: SDK, transport, service, writer CLI, tests, docs, and verification
  are explicitly owned; unrelated parent features are excluded.
- Dependencies: current code dependencies and external Meta/live prerequisites
  are separated.
- Completion: deterministic code checks and conditional live outcomes have
  distinct acceptance rules.
- Progress tracking: every implementation group has an unchecked status item;
  this planning worker does not claim implementation progress.
- Verification: includes full tests, release build, CLI separation, streamed
  body/credential-host tests, security searches, and conditional live commands.
- Self-review decision: accepted for independent plan review.

## Review Decisions

- Design: accepted after independent review by `/root/design_review` and
  correction of four high and five mid design defects.
- Implementation plan: accepted after independent review by
  `/root/plan_review`; one mid design defect and two mid plan-only defects
  were corrected, with no high or mid findings remaining.

## Addressed Feedback

### Design defects addressed before planning

- Replaced inferred `nextOffset`/caller chunk semantics with the returned upload
  URI and `video_status.uploading_phase.bytes_transferred` as the only confirmed
  offset.
- Corrected rupload authentication to OAuth and preserved the provider's
  versioned upload URI.
- Made tag position optional with media-specific image, video/Reel, and Story
  rules; completed thumbnail, caption, and service-owned-field validation.
- Moved endpoint trust enforcement ahead of credential attachment and added
  redirect protection.
- Preserved Codable and `HTTPRequest.body` source compatibility and required
  public initializers/defaults.
- Added typed/redacted rupload `debug_info` error handling.
- Named Facebook Login for Business as an explicit resumable-upload prerequisite
  and removed the claim that publishing is reversible.

### Plan-only feedback addressed

- The design reviewer requested explicit full tests, release build, CLI
  help/separation checks, and streamed-body/redirect tests; all are required in
  this plan's verification and completion criteria.
- Plan review added query/fragment endpoint rejection, exact legacy encoding
  fixtures, effective help-output assertions, broader buffering searches, and
  a named live-result record in `docs/live-smoke-tests.md`.

## Risks

- Meta parameter availability and collaborator limits may change by Graph API
  version; use dated official checks and resilient provider failure handling.
- Swift URLSession streaming and redirect behavior can differ by platform;
  tests must exercise the supported deployment target rather than assuming
  handler behavior.
- Public monolithic source files increase merge-conflict risk with sibling
  features; implementation should make small scoped patches and rerun the full
  suite after integration.
- A transport failure can leave server progress ambiguous; never advance or
  automatically retry without a fresh provider status.
- Local file paths and returned upload URIs can leak operational context in
  diagnostics; minimize output and redact token-bearing text.
- Live collaborator/tag tests can notify third parties, and publishing requires
  manual cleanup; both remain outside default live verification.

## Step 6 Implementation Update — 2026-08-13

- Status: partial. Resumable files now use a streamed file slice and redirects
  are denied before credential replay; CLI user-tag/collaborator/location/cover
  options are wired. Typed/redacted `debug_info` failures are covered. Full
  supported-target streamed execution is covered through an injectable session
  boundary that invokes the production redirect delegate, proving offset bytes,
  redirect cancellation, and no forwarded authorization without URLProtocol
  hangs. `swift test` (53 tests) and `swift build -c release` passed; live
  verification remains META_BLOCKED.
