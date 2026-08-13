# Core SDK, Auth, Transport, And Config Implementation Plan

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference: `workflow-input:<workspace>#Build a Swift Instagram/Meta SDK and permission-separated CLI`
- Feature id: `core-sdk-auth-transport-config`
- Fanout feature id: `core-sdk-auth-transport-config`
- Design reference: `design-docs/specs/core-sdk-auth-transport-config.md`
- Implementation plan path: `impl-plans/core-sdk-auth-transport-config.md`
- Codex agent references: none

## Accepted Review Input

Step 3 accepted the design with no high or mid findings. Carry forward these
risks as implementation constraints:

- Meta API permission names and app setup flow require live verification before
  credential provisioning.
- Publishing and moderation smoke tests depend on external Instagram/Facebook
  asset state.
- Token refresh and `appsecret_proof` policy remain open implementation
  boundaries.

## Objective

Implement the shared Swift core library foundation for Instagram Gateway:
package layout, async injected HTTP transport, public DTOs, pagination, typed
errors, redaction, Meta credential configuration, kinko/env secret resolution,
scope/access-mode gates, and deterministic config/doctor diagnostics used by
both reader and writer binaries.

## Deliverables

1. Swift package and shared target layout
   - Create `Package.swift` with `InstagramGatewayCore`,
     `InstagramGatewayReader`, `InstagramGatewayWriter`, and
     `InstagramGatewayCoreTests`.
   - Keep CLI argument parsing outside `InstagramGatewayCore`.
   - Use `../mail-gateway` as the reference for package
     layout, binary naming, diagnostics, JSON conventions, and release/build
     structure.
   - Completion criteria: `swift build` discovers the core library and both
     executable targets.

2. Async HTTP transport foundation
   - Implement `HTTPTransport`, `HTTPRequest`, `HTTPResponse`, HTTP method,
     header/query redaction classifications, and URL construction helpers.
   - Implement a default `URLSession` transport and a recording stub transport
     for tests.
   - Build query parameters through `URLComponents`; avoid token-bearing logged
     URLs.
   - Disable retries by default for mutating calls and expose retry policy hooks
     only where safe.
   - Completion criteria: transport tests verify request construction, bearer
     authorization, URL encoding, non-2xx handling, and redacted debug output.

3. Public DTOs, JSON primitives, and pagination
   - Implement stable `Codable & Sendable` DTOs for account/profile discovery,
     media, comments, insights, publishing workflow status, and provider error
     metadata needed by reader/writer features.
   - Model Meta-controlled closed sets as typed enums with unknown value
     preservation; keep provider ids, usernames, captions, comments, URLs,
     metric names, and cursors as `String`.
   - Implement `JSONValue`, `Page<Element>`, and `Paging`.
   - Completion criteria: fixture decoding tests cover known enum values,
     unknown enum preservation, raw metadata, and cursor preservation.

4. Typed error model and redacted JSON error conversion
   - Implement `InstagramGatewayError` cases for configuration,
     authentication, authorization, API, transport, decoding, unsupported, and
     redaction failure paths.
   - Preserve Meta error code, subcode, type, message, trace id, HTTP status,
     and retryability where available.
   - Convert errors to the shared CLI JSON shape without leaking secrets.
   - Completion criteria: tests cover Graph API error decoding, retryability,
     public error codes, display strings, and JSON serialization.

5. Central secret redaction
   - Implement `SecretRedactor` for app secrets, access tokens, auth codes,
     `client_secret`, `appsecret_proof`, signed requests, authorization header
     values, kinko command output, and secret-bearing paths.
   - Apply redaction to request/response debug descriptions, errors,
     diagnostics, CLI stderr/stdout JSON, and test helpers.
   - Fail closed when a request component lacks required secret
     classification.
   - Completion criteria: redaction tests prove raw token/app-secret/auth-code
     values do not appear in diagnostic strings, JSON output, or failure
     messages.

6. Configuration and credential profiles
   - Implement config discovery from `--config`, `INSTAGRAM_GATEWAY_CONFIG`,
     `$XDG_CONFIG_HOME/instagram-gateway/config.toml`, and
     `~/.config/instagram-gateway/config.toml`.
   - Load credential profiles with unique ids, provider
     `meta-instagram`, access modes `read` and `write`, app id references,
     app secret references, access token references, Instagram user id, and
     page id.
   - Support TOML literals only for non-secret placeholder-safe values; support
     env and kinko secret references for secret material.
   - Resolve kinko references only at command execution time.
   - Completion criteria: config tests cover discovery order, duplicate ids,
     provider validation, access-mode validation, env precedence, missing
     secret references, and no source-controlled secret values.

7. Access-mode and scope gates
   - Implement `AccessMode`, scope metadata, and compatibility checks shared by
     reader and writer binaries.
   - Ensure reader paths may use only `read` credentials and writer mutation
     paths require `write` credentials.
   - Centralize versioned Meta permission assumptions so docs and doctor output
     can be updated together.
   - Completion criteria: tests cover reader rejection of write credentials,
     writer rejection of read credentials for mutation operations, and
     structured missing-scope diagnostics.

8. Core Graph client shell
   - Implement `InstagramGatewayClient` as the lower-level dependency-injected
     client shared by `InstagramReadClient` and `InstagramWriteClient`.
   - Provide request builders and response decoding helpers for the accepted
     API surfaces without embedding CLI command behavior in the core target.
   - Keep live API execution behind explicit transport calls and deterministic
     tests behind stubs.
   - Completion criteria: request-builder tests cover representative read,
     write, pagination, and error paths without network access.

9. Shared config and doctor diagnostics
   - Implement reusable diagnostic records for `config validate` and `doctor`.
   - Report resolved config path, credential ids, declared access modes,
     env/kinko reference presence, binary/credential compatibility, IG user id
     and page id presence, scope declaration status, and offline/live check
     state.
   - Support exit statuses `0`, `3`, `4`, and `5` for shared diagnostic
     outcomes.
   - Completion criteria: deterministic fixture diagnostics produce stable
     redacted JSON for reader and writer binaries in offline mode.

10. Examples and documentation hooks
    - Add `Examples/config.example.toml` using only placeholder-safe values and
      safe secret names:
      `instagram-gateway/meta/app-id`,
      `instagram-gateway/meta/app-secret`,
      `instagram-gateway/taco-dev-sandbox/read-access-token`,
      `instagram-gateway/taco-dev-sandbox/write-access-token`,
      `instagram-gateway/taco-dev-sandbox/instagram-user-id`, and
      `instagram-gateway/taco-dev-sandbox/page-id`.
    - Document Meta app setup boundaries, redirect/token/scope assumptions,
      kinko commands with placeholders only, deterministic verification, and
      live smoke-test commands after provisioning.
    - Completion criteria: README onboarding is complete enough for the parent
      agent to provision credentials without adding secrets to source.

## Dependencies

- Source design: `design-docs/specs/core-sdk-auth-transport-config.md`.
- Reference repository:
  `../mail-gateway` for CLI UX, JSON output,
  diagnostics, package layout, release/build structure, and binary separation.
- Reader feature plan: `impl-plans/reader-api-cli.md` depends on the shared
  DTOs, config, transport, error, redaction, and diagnostics from this feature.
- Writer feature plan: `impl-plans/writer-api-cli.md` depends on the shared
  DTOs, config, transport, error, redaction, access-mode gates, and diagnostics
  from this feature.
- Live Meta developer-console setup and credentials are external to this
  feature and must not block deterministic implementation.

## Task Breakdown

1. Inspect `../mail-gateway` for package layout,
   executable target naming, JSON envelope conventions, config/doctor commands,
   diagnostics, and permission-separated binaries.
2. Create Swift package targets, directories, baseline executable entry points,
   examples directory, and test structure.
3. Implement core JSON primitives, DTOs, typed enums with unknown preservation,
   and pagination.
4. Implement async HTTP transport protocol, URLSession transport, request and
   response types, and recording test transport.
5. Implement `SecretRedactor` and apply redaction to descriptions, errors,
   diagnostics, and CLI JSON conversion.
6. Implement `InstagramGatewayError`, Meta error decoding, retryability
   metadata, and redacted JSON error conversion.
7. Implement config discovery, TOML parsing, credential profile validation,
   env lookup, kinko lookup abstraction, and deferred secret resolution.
8. Implement `AccessMode`, centralized scope declarations, and reader/writer
   compatibility checks.
9. Implement `InstagramGatewayClient`, `InstagramReadClient`, and
   `InstagramWriteClient` shells with shared request builders and response
   decoders needed by downstream feature branches.
10. Implement shared diagnostic records and minimal reader/writer diagnostic
    command wiring needed for deterministic config/doctor verification.
11. Add unit tests for DTO coding, pagination, transport, error mapping,
    redaction, config validation, secret resolution boundaries, access-mode
    gates, and diagnostics.
12. Add README and `Examples/config.example.toml` with safe kinko/env setup and
    live smoke-test commands.
13. Run deterministic verification commands and inspect diffs for accidental
    secrets or unrelated changes.

## Parallelizable Tasks

- DTO/pagination implementation can run in parallel with config model design
  after package targets exist.
- Transport request-building tests can run in parallel with redaction tests.
- Error mapping can run in parallel with config discovery once shared JSON
  primitives exist.
- Documentation and example config can run in parallel with core implementation
  as long as all examples remain placeholder-only.
- Reader and writer command features can consume the core contracts after
  access-mode gates, diagnostic records, and client shells stabilize.

## Progress Tracking

- [x] Inspect `mail-gateway` reference patterns.
- [x] Create Swift package targets and source/test layout.
- [x] Implement DTOs, enums, JSON primitives, and pagination.
- [x] Implement async HTTP transport and recording test transport.
- [x] Implement typed error model and Meta error decoding.
- [x] Implement centralized redaction and fail-closed classifications.
- [x] Implement config discovery, TOML parsing, env, and kinko references.
- [x] Implement access-mode and scope compatibility gates.
- [x] Implement shared Graph client and read/write wrapper shells.
- [x] Implement shared config/doctor diagnostic records and exit statuses.
- [x] Add deterministic unit tests and fixture configs.
- [x] Add examples, README onboarding, and live smoke-test documentation.
- [x] Run build, tests, CLI help, offline diagnostics, and diff/status checks.

## Implementation Record

- Implemented `Package.swift`, `Sources/InstagramGatewayCore/`,
  `Sources/InstagramGatewayCLI/`, `Sources/InstagramGatewayReader/`,
  `Sources/InstagramGatewayWriter/`, `Tests/`, `Examples/`, README, and
  docs.
- Verification run: `swift build`, `swift test`, reader/writer `--help`, reader `--version`, reader config validate, reader doctor, writer doctor.
- `swiftlint` was attempted only if installed; command timed out/no lint result was available.

## Revision Record

- Addressed Step 6 self-review findings by wiring CLI command handlers to reader/writer SDK services, resolving credentials before live command execution, hardening TOML validation, and adding deterministic CLI execution tests with injected transports.
- Verification rerun: `swift test` passed with 14 Swift Testing tests; direct binary diagnostics and confirmation checks passed. `swift build` printed `Build complete!` but the wrapper command timed out after output in this environment.
- Step 7 revision fix: provider API error detail messages are redacted inside `InstagramGatewayClient` before typed errors can reach CLI JSON output; added deterministic test coverage for token-bearing provider error messages.
- Step 7 rerun fix: preserved caller-supplied `SecretRedactor` secrets when constructing `InstagramGatewayClient`, merged the bearer token into that redactor, added regression coverage for non-token caller secrets in provider error messages, and added public DTO initializers for the stable SDK value surface.
- Step 7 CLI-boundary fix: moved `InstagramGatewayCLI`, `ArgumentParser`,
  command dispatch, help text, and `Darwin.exit` handling out of
  `InstagramGatewayCore` into `Sources/InstagramGatewayCLI/`; reader/writer
  executable targets now depend on the CLI support target, while the core
  target remains focused on SDK DTOs, config/auth, transport, services, errors,
  diagnostics records, and redaction. Added public initializers for diagnostic
  DTOs required by the separated CLI support target.
- Step 7 transport-redaction fix: wrapped injected `HTTPTransport.send`
  failures in `InstagramGatewayClient.request`, redacted the thrown localized
  message with the client `SecretRedactor`, and added deterministic regression
  coverage for bearer-token and caller-supplied secret leakage in transport
  failures.
- Step 7 paging-redaction fix: added `Paging.redacted(redactor:)` and sanitize
  `SuccessEnvelope.paging` before CLI JSON encoding so provider `next` and
  `previous` URLs cannot print `access_token`, `client_secret`, or similar
  secret query values.
- Verification rerun for paging redaction: `swift build` passed;
  `swift test` and `swift test --filter readerMediaListExecutesServiceRequest`
  printed passing test output before the wrapper timed out during SwiftPM
  cleanup/waiting; `.build/debug/instagram-gateway-reader --help` passed.

## Verification

Required deterministic commands:

```bash
swift build
swift test
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
swift run instagram-gateway-reader config validate --config Examples/config.example.toml
swift run instagram-gateway-reader doctor --config Examples/config.example.toml --offline
swift run instagram-gateway-writer doctor --config Examples/config.example.toml --offline
git diff -- design-docs/specs/core-sdk-auth-transport-config.md impl-plans/core-sdk-auth-transport-config.md Package.swift Sources Tests Examples README.md
git status --short --untracked-files=all
```

Run if configured and installed:

```bash
swiftlint
```

Live smoke-test commands after credential provisioning:

```bash
swift run instagram-gateway-reader doctor --credential taco-dev-sandbox-reader
swift run instagram-gateway-reader account get --credential taco-dev-sandbox-reader
swift run instagram-gateway-reader media list --credential taco-dev-sandbox-reader --limit 5
swift run instagram-gateway-writer doctor --credential taco-dev-sandbox-writer
```

Publishing and moderation smoke tests are owned by writer feature work and must
require explicit user-provided media or comment ids.

## Completion Criteria

- `InstagramGatewayCore` builds as a reusable Swift library independent of CLI
  argument parsing.
- `instagram-gateway-reader` and `instagram-gateway-writer` exist as separate
  executable targets.
- Public DTOs, pagination, errors, config records, diagnostics, and client
  entry points are `Codable` and `Sendable` where applicable.
- Provider-controlled closed sets are typed enums with unknown preservation;
  provider-owned ids and free text remain strings.
- HTTP side effects are dependency-injected and tests do not require network
  access.
- Config supports safe env/kinko integration and defers kinko secret resolution
  until command execution.
- Diagnostics and errors never print access tokens, app secrets, auth codes,
  signed requests, authorization headers, kinko secret output, or
  secret-bearing paths.
- Access-mode gates preserve least-privilege separation between read and write
  credentials and binaries.
- Deterministic verification commands pass without live Meta credentials.
- README and examples document provisioning and smoke tests without embedding
  credentials.

## Addressed Feedback

- Step 3 review decision for `core-sdk-auth-transport-config` was `accepted`.
- No high, mid, or low findings required design revision.
- This plan explicitly carries forward workflow mode `issue-resolution`, issue
  reference
  `workflow-input:<workspace>#Build a Swift Instagram/Meta SDK and permission-separated CLI`,
  fanout feature id `core-sdk-auth-transport-config`, design path
  `design-docs/specs/core-sdk-auth-transport-config.md`, implementation plan
  path `impl-plans/core-sdk-auth-transport-config.md`, and empty
  codex-agent references.
- Verification commands from the accepted design are preserved and expanded
  with diff/status checks.

## Risks

- Meta permission names, app type selection, and developer-console setup may
  change and require live verification before credential provisioning.
- Publishing and moderation live smoke tests require external Instagram and
  Facebook asset state unavailable to deterministic tests.
- Token refresh and `appsecret_proof` requirements may become necessary after
  live provisioning; v1 should keep those policies centralized and explicit.
- Redaction must be applied consistently before any diagnostic or error output
  because provider payloads can include sensitive request context.
