# Reader API And CLI Implementation Plan

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference:
  `workflow-input:<workspace>#Build a Swift Instagram/Meta SDK and permission-separated CLI`
- Feature id: `reader-api-cli`
- Fanout feature id: `reader-api-cli`
- Design reference: `design-docs/specs/reader-api-cli.md`
- Implementation plan path: `impl-plans/reader-api-cli.md`
- Codex agent references: none

## Accepted Review Input

Step 3 accepted the reader design with no high or mid findings. Low findings to
carry forward:

- `design-docs/specs/reader-api-cli.md`: Meta product path, exact read-only
  permission names, and business-discovery insight coverage remain bounded open
  questions for credential provisioning.
- `design-docs/specs/reader-api-cli.md`: design content is currently untracked
  under `design-docs/`; implementation should keep progress artifacts explicit.

## Deliverables

1. Swift package reader foundation
   - Create package targets `InstagramGatewayCore`, `InstagramGatewayReader`,
     `InstagramGatewayCoreTests`, and `InstagramGatewayCLITests`.
   - Define public `InstagramGatewayClient` and `InstagramReaderService` as
     `Sendable` async SDK entry points.
   - Completion criteria: `swift build` discovers the library and
     `instagram-gateway-reader` executable target.

2. Reader DTOs, fields, and pagination
   - Implement `Page<Element>`, `Paging`, `FacebookPage`, `InstagramAccount`,
     `BusinessProfile`, `InstagramMedia`, `InstagramComment`,
     `InsightsResponse`, and metric DTOs.
   - Model documented closed sets as `Codable & Sendable` enums with unknown
     value preservation; keep provider ids, usernames, captions, URLs, metrics,
     and cursors as strings.
   - Completion criteria: fixture decoding tests cover known and unknown enum
     values plus cursor preservation.

3. Configuration and credential loading
   - Implement config discovery from `--config`, `INSTAGRAM_GATEWAY_CONFIG`,
     and default paths.
   - Support env/kinko-oriented secret references:
     `INSTAGRAM_GATEWAY_META_APP_ID`,
     `INSTAGRAM_GATEWAY_META_APP_SECRET`,
     `INSTAGRAM_GATEWAY_READER_ACCESS_TOKEN`,
     `INSTAGRAM_GATEWAY_DEFAULT_PAGE_ID`, and
     `INSTAGRAM_GATEWAY_DEFAULT_IG_USER_ID`.
   - Completion criteria: `config validate` and `doctor` report redacted,
     deterministic JSON for valid and invalid fixture config files.

4. Async transport and error model
   - Implement injectable `InstagramHTTPTransport` with a URLSession default.
   - Build requests with `URLComponents`, bearer-token authorization, timeout
     configuration, response body limits, and token redaction.
   - Implement public `Codable & Sendable` errors:
     `configurationInvalid`, `credentialUnavailable`,
     `authenticationRequired`, `permissionDenied`, `notFound`, `rateLimited`,
     `providerRejected`, `providerUnavailable`, `decodingFailed`,
     `transportFailed`, and `unsupportedOperation`.
   - Completion criteria: transport tests verify request construction, status
     mapping, retryable flags, provider request id propagation, and redaction.

5. Reader SDK operations
   - Implement account/page discovery, Instagram account listing, account get,
     business discovery, media list/get, comments list/get, account insights,
     and media insights.
   - Do not implement publishing, reply, moderation, hide, delete, or other
     writer operations in this feature.
   - Completion criteria: each operation has fixture-backed request and decode
     tests without network access.

6. Reader CLI
   - Implement `instagram-gateway-reader [--config <path>] [--pretty]
     <command>`, `--help`, `--version`, `version`, `doctor`, `config validate`,
     `accounts`, `media`, `comments`, and `insights` commands.
   - Return stable JSON envelopes: `{"ok":true,"data":...,"paging":...}` on
     success and `{"ok":false,"error":...}` on failure.
   - Reject writer-only verbs with `unsupportedByReaderBinary`.
   - Strip `access_token` from any URL printed in JSON.
   - Completion criteria: subprocess-style CLI tests cover help/version,
     config/doctor, representative command JSON, pretty output, and
     writer-only rejection.

7. Documentation hooks for parent credential provisioning
   - Document reader app setup placeholders, safe kinko secret names, and live
     smoke-test commands without embedding credentials.
   - Preserve open questions for parent/browser setup:
     Meta product path, exact read-only permission names, and business-discovery
     insight coverage.
   - Completion criteria: README or docs section names the reader binary,
     secret variables, least-privilege scope intent, and live smoke commands.

## Dependencies

- `design-docs/specs/reader-api-cli.md` is the source of truth for behavior.
- `../mail-gateway` is the reference for CLI UX, JSON
  output conventions, diagnostics, package layout, and permission-separated
  binaries.
- Writer feature work must remain separate; shared core APIs may be designed so
  writer fanout can add mutation services later without reader command leakage.
- Live Meta app details and token scopes depend on parent credential
  provisioning and must not block deterministic reader implementation.

## Parallelizable Tasks

- DTO/pagination/error modeling can proceed in parallel with config loading.
- Fixture transport tests can proceed in parallel with CLI parser scaffolding.
- Documentation of safe secret names and live smoke commands can proceed in
  parallel with SDK operation implementation.
- CLI subprocess tests can be added incrementally after target names and
  command routing are stable.

## Progress Tracking

- [x] Create Swift package targets and executable.
- [x] Implement DTOs, enums, pagination, and fixture decoding.
- [x] Implement config loading, validation, and doctor diagnostics.
- [x] Implement async transport and public error mapping.
- [x] Implement reader SDK operations.
- [x] Implement reader CLI commands and JSON envelopes.
- [x] Add deterministic unit and CLI tests.
- [x] Add reader documentation and live smoke commands.
- [x] Run deterministic verification commands.

## Implementation Record

- Implemented reader SDK request builders, DTO decoding, JSON envelopes, config/doctor diagnostics, help/version handling, and reader rejection of writer commands.
- Verification run: `swift build`, `swift test`, `swift run instagram-gateway-reader --help`, `swift run instagram-gateway-reader --version`, `swift run instagram-gateway-reader config validate --config Tests/Fixtures/reader-valid.toml`, and `swift run instagram-gateway-reader doctor --config Tests/Fixtures/reader-valid.toml --offline`.

## Revision Record

- Replaced placeholder non-diagnostic reader CLI responses with command routing into `InstagramReaderService` for account, media, comments, and insights surfaces.
- Added deterministic CLI test coverage proving `media list` builds and sends a service request through an injected recording transport.
- Step 7 business-discovery revision fix: added `InstagramReaderService.businessDiscovery(accountId:username:)`, routed `instagram-gateway-reader accounts business-discovery --username <name>` through the injected service, added deterministic CLI request/JSON coverage, and aligned README/live smoke commands.
- Step 7 paging-redaction revision fix: sanitized `SuccessEnvelope.paging`
  before reader CLI JSON output and added deterministic `media list` coverage
  proving token-bearing `paging.next` URLs do not print raw `access_token` or
  `client_secret` values.
- Verification rerun for paging redaction: `swift build` passed;
  `swift test` and `swift test --filter readerMediaListExecutesServiceRequest`
  printed passing test output before the wrapper timed out during SwiftPM
  cleanup/waiting; `.build/debug/instagram-gateway-reader --help` passed.

## Verification

Deterministic commands:

```bash
swift build
swift test
swift run instagram-gateway-reader --help
swift run instagram-gateway-reader --version
swift run instagram-gateway-reader version
swift run instagram-gateway-reader config validate --config Tests/Fixtures/reader-valid.toml
swift run instagram-gateway-reader doctor --config Tests/Fixtures/reader-valid.toml
git diff -- design-docs/specs/reader-api-cli.md impl-plans/reader-api-cli.md
git status --short
```

Live smoke commands after credentials are provisioned:

```bash
swift run instagram-gateway-reader doctor --live
swift run instagram-gateway-reader accounts pages --limit 5 --pretty
swift run instagram-gateway-reader accounts instagram --limit 5 --pretty
swift run instagram-gateway-reader accounts business-discovery --username "<business-username>" --pretty
swift run instagram-gateway-reader media list --account-id "$INSTAGRAM_GATEWAY_DEFAULT_IG_USER_ID" --limit 5 --pretty
swift run instagram-gateway-reader insights account --account-id "$INSTAGRAM_GATEWAY_DEFAULT_IG_USER_ID" --metric impressions,reach --period day --pretty
```

## Completion Criteria

- Reader SDK exposes all accepted read-only operations and no writer operations.
- `instagram-gateway-reader` implements accepted command surface with stable
  JSON output and deterministic help/version/config/doctor behavior.
- Config and diagnostics never print tokens, app secrets, auth codes, raw
  request headers, or inline secret values.
- Public DTOs, errors, transport, pagination, and services are `Sendable` where
  concurrency crossing requires it.
- Tests are network-free and fixture-backed except explicitly documented live
  smoke commands.
- Reader/writer least-privilege separation is visible in target names,
  commands, diagnostics, and documentation.

## Risks

- Meta API versions, permission names, and app review gates may change before
  live setup.
- Insights support can vary by account type, media type, metric, token state,
  and API version.
- Business Discovery may return data that cannot be followed up through
  owned-media endpoints without provider rejection.
- Reference behavior from `mail-gateway` may need adaptation because this
  repository starts empty and targets Meta rather than mail providers.
