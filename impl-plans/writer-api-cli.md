# Implementation Plan: Writer API And CLI

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference: `workflow-input:<workspace>#Build a Swift Instagram/Meta SDK and permission-separated CLI`
- Feature id: `writer-api-cli`
- Feature title: `Writer API And CLI`
- Fanout group: `feature-local-planning`
- Fanout index: `2`
- Design reference: `design-docs/specs/writer-api-cli.md`
- Codex agent references: none

## Objective

Implement the write-capable SDK surface and `instagram-gateway-writer` executable
for Instagram Graph API publishing, comment replies, comment moderation,
confirmation-gated state changes, permission-separated credentials, and
redacted JSON diagnostics.

## Deliverables

1. Core writer SDK contracts and DTOs in `Sources/InstagramGatewayCore`.
   - Add `InstagramWriterService` with async methods for media container
     creation, container status, publish, reply, hide, unhide, and delete.
   - Add stable public `Codable` and `Sendable` DTOs for writer inputs and
     outputs.
   - Keep provider identifiers, URLs, captions, messages, and provider status
     text as `String`.
   - Use typed enums for local closed concepts such as moderation action.

2. Instagram Graph API writer client in `Sources/InstagramGatewayCore`.
   - Use the shared async HTTP transport dependency.
   - Build write requests without direct `URLSession.shared` usage.
   - Map Meta provider failures into explicit API errors.
   - Apply shared redaction to provider payloads, URLs, authorization headers,
     access tokens, app secrets, and secret query parameters before diagnostics.
   - Polling is not implicit in publish; expose `container-status` and make
     publish reject or report provider status failures clearly.

3. Writer CLI target in `Sources/InstagramGatewayWriter`.
   - Provide binary `instagram-gateway-writer`.
   - Support shared flags: `--config <path>`, `--pretty`, `--help`, and
     `version`.
   - Support diagnostics: `doctor` and `config validate`.
   - Support publishing commands:
     - `media create-container --account <id> --image-url <url> [--caption <text>] --yes`
     - `media container-status --account <id> --container-id <id>`
     - `media publish --account <id> --container-id <id> --yes`
   - Support comment commands:
     - `comments reply --account <id> --comment-id <id> --message <text> --yes`
     - `comments hide --account <id> --comment-id <id> --yes`
     - `comments unhide --account <id> --comment-id <id> --yes`
     - `comments delete --account <id> --comment-id <id> --yes`

4. Permission separation and credential compatibility.
   - Keep writer commands absent from `instagram-gateway-reader`.
   - Normalize access modes to `read` and `write`; do not introduce a third
     `writer` mode.
   - Make `instagram-gateway-reader` reject `write` credentials.
   - Make `instagram-gateway-writer` reject `read` credentials for write
     commands.
   - Allow writer commands to use read scopes that Meta requires for account
     discovery or write workflows.

5. Confirmation and non-interactive safety.
   - Require confirmation for `media publish`, `comments reply`,
     `comments hide`, `comments unhide`, and `comments delete`.
   - Skip prompts only when `--yes` is supplied.
   - When stdin is non-interactive and `--yes` is omitted, fail with structured
     `CONFIRMATION_REQUIRED` JSON on stderr and a non-zero exit code.

6. Documentation and safe examples.
   - Update README writer onboarding without embedding credentials.
   - Document Meta app/product setup, redirect/token/scopes, and kinko secret
     names for `taco-dev-sandbox@mutvar.com`.
   - Add placeholder config examples that name env vars only:
     - `INSTAGRAM_GATEWAY_META_SANDBOX_APP_ID`
     - `INSTAGRAM_GATEWAY_META_SANDBOX_APP_SECRET`
     - `INSTAGRAM_GATEWAY_META_SANDBOX_ACCESS_TOKEN`
   - Add live smoke-test commands that run only after credentials are
     provisioned.

## Dependencies

- Shared package layout and target setup from the core SDK feature.
- Shared config loading, credential profile model, redactor, API error model,
  JSON envelope output, and async HTTP transport.
- Reader/writer binary separation conventions from
  `../mail-gateway`.
- Meta app credentials and access token provisioned outside source control for
  live smoke tests.

## Task Breakdown

1. Inspect the reference repository and existing local package structure.
   - Review `../mail-gateway` for CLI target layout,
     JSON envelopes, diagnostics, config loading, and binary separation.
   - Confirm current `Package.swift` targets before adding writer code.

2. Add writer DTOs and service protocol.
   - Implement input/output models and `InstagramWriterService`.
   - Add coding tests and Sendable compile coverage where practical.

3. Implement Graph writer request construction.
   - Create media container request encoding.
   - Create container status lookup.
   - Create publish request.
   - Create comment reply, hide, unhide, and delete requests.
   - Add provider error mapping and redacted diagnostic context.

4. Implement writer CLI commands.
   - Register command tree for diagnostics, publishing, and comments.
   - Preserve deterministic JSON success and failure output.
   - Wire config/account/credential selection.
   - Enforce access-mode compatibility.

5. Implement confirmation guard.
   - Add reusable confirmation helper.
   - Detect non-interactive stdin.
   - Test `--yes`, interactive prompt behavior where feasible, and
     non-interactive failure behavior.

6. Add tests.
   - Unit test request methods, paths, query/body fields, and account IDs.
   - Unit test CLI command parsing and writer-only command availability.
   - Unit test reader rejection of writer commands and write credentials.
   - Unit test writer rejection of read credentials for write commands.
   - Unit test redaction for token-bearing URLs, authorization headers, app
     secrets, env values, and provider error payloads.

7. Update docs and examples.
   - Add README writer section and live smoke-test section.
   - Add `Examples/config.placeholder.toml` writer profile if not already
     present.
   - Ensure examples contain only placeholders and secret key names.

8. Verify.
   - Run deterministic build and test commands.
   - Run CLI help and config diagnostics without secrets.
   - Run lint only if configured and installed.

## Parallelizable Tasks

- DTO/service protocol implementation can run in parallel with README draft
  updates after package layout is known.
- Request-construction tests can be written in parallel with CLI parsing tests
  once command names and DTO names are fixed.
- Redaction tests can be shared with reader/core work and should be coordinated
  to avoid duplicate helpers.
- Live smoke-test documentation can be prepared independently from live
  credential provisioning.

## Verification

Required deterministic commands:

```bash
swift build
swift test
swift run instagram-gateway-writer --help
swift run instagram-gateway-writer doctor --pretty
swift run instagram-gateway-writer config validate --config Examples/config.placeholder.toml --pretty
```

Run if configured and installed:

```bash
swiftlint
```

## Revision Record

- Step 7 account-boundary fix: writer comment commands now require
  `--account`, pass the parsed account through reply and moderation service
  calls, and reject missing account arguments before mutating requests execute.
- Added deterministic CLI coverage for `comments reply --account ... --yes`
  request construction and missing `--account` rejection.
- Verification rerun: `swift test`, `.build/debug/instagram-gateway-writer
  --help`, and targeted `rg`/`sed` checks. Positive reply execution is covered
  by injected-transport tests to avoid live provider calls.
- Step 7 writer-DTO fix: added public `Codable`, `Equatable`, and `Sendable`
  writer input DTOs (`CreateMediaContainerInput`,
  `PublishMediaContainerInput`, `ReplyToCommentInput`, and
  `ModerateCommentInput`) and routed writer service methods through those
  inputs while preserving convenience overloads for the CLI.
- Added deterministic SDK coverage for video container request construction,
  provider-specific fields, and writer input DTO construction.

Live smoke-test commands after credential provisioning:

```bash
kinko export INSTAGRAM_GATEWAY_META_SANDBOX_APP_ID
kinko export INSTAGRAM_GATEWAY_META_SANDBOX_APP_SECRET
kinko export INSTAGRAM_GATEWAY_META_SANDBOX_ACCESS_TOKEN
swift run instagram-gateway-writer doctor --pretty
swift run instagram-gateway-writer media create-container --account sandbox --image-url https://example.com/public-test-image.jpg --caption "instagram-gateway smoke test" --yes --pretty
swift run instagram-gateway-writer media container-status --account sandbox --container-id <container-id> --pretty
swift run instagram-gateway-writer media publish --account sandbox --container-id <container-id> --yes --pretty
```

## Completion Criteria

- `instagram-gateway-writer` builds as a distinct executable from
  `instagram-gateway-reader`.
- Writer commands are not registered in the reader binary.
- Writer commands use only write-compatible credential profiles.
- State-changing commands require confirmation or `--yes`.
- Successful commands emit one JSON object on stdout.
- Failed commands emit one redacted JSON object on stderr and return non-zero.
- SDK writer APIs are public, async, dependency-injected, `Codable` where
  applicable, and `Sendable` where applicable.
- Tests cover request construction, credential separation, confirmations, error
  mapping, redaction, DTO coding, and deterministic CLI behavior.
- README and examples document setup without source-controlled secrets.

## Addressed Feedback

- The accepted design review found one low-severity naming inconsistency:
  `writer` was mentioned as an access mode even though only `read` and `write`
  are defined. This plan explicitly normalizes modes to `read` and `write`.
- The plan keeps implementation scoped to `writer-api-cli`.
- Verification commands from the design are carried forward explicitly.

## Risks

- Meta scope and app-review availability can block live smoke tests after
  deterministic verification passes.
- Provider status can remain asynchronous or rejected; publish must avoid
  assuming a newly created media container is ready.
- Every provider error path must use shared redaction to avoid leaking
  token-bearing URLs or credentials.
- Comment deletion may not be available for every account, media, or comment
  type and should surface provider errors safely.

## Implementation Record

- Implemented writer SDK request builders, writer CLI target, writer diagnostic handling, confirmation enforcement for state-changing commands, access-mode compatibility checks, and docs/examples for writer credential setup.
- Verification run: `swift build`, `swift test`, `swift run instagram-gateway-writer --help`, `swift run instagram-gateway-writer doctor --config Examples/config.placeholder.toml --offline --pretty`, and `swift run instagram-gateway-writer config validate --config Examples/config.placeholder.toml --pretty`.
- `swiftlint` was attempted only if installed; command timed out/no lint result was available.

## Revision Record

- Replaced placeholder non-diagnostic writer CLI responses with command routing into `InstagramWriterService` for media container creation, status, publish, replies, hide, unhide, and delete.
- Hardened confirmation gating so state-changing writer commands fail with `CONFIRMATION_REQUIRED` before config loading when `--yes` is omitted.
- Added deterministic CLI test coverage proving `comments hide --yes` builds and sends a service request through an injected recording transport.
- Step 7 revision fix: `media create-container` now requires `--yes`, help separates read-only `container-status`, and CLI tests cover create-container rejection without `--yes` plus successful request construction with `--yes`.
- Step 6 self-review revision fix: updated README, live smoke-test docs, and this implementation-plan command record so every documented `media create-container` invocation includes `--yes`.
