# Writer API And CLI

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference: `workflow-input:<workspace>#Build a Swift Instagram/Meta SDK and permission-separated CLI`
- Feature id: `writer-api-cli`
- Feature title: `Writer API And CLI`
- Fanout group: `feature-local-planning`
- Fanout index: `2`
- Codex agent references: none

## Scope

Design and implement the write-capable Instagram SDK operations and
`instagram-gateway-writer` command surface for publishing, replies, comment
moderation, scope separation, confirmations where appropriate, and safe JSON
diagnostics. The implementation must follow the local UX and packaging style of
`../mail-gateway`, especially distinct permission
binaries, deterministic JSON output, explicit diagnostics, and no secret
printing.

## Goals

- Provide Swift library APIs for Instagram Graph API write workflows that are
  reliable for Business or Creator accounts connected to Facebook Pages.
- Ship `instagram-gateway-writer` as a separate executable from
  `instagram-gateway-reader` so write scopes are opt-in and auditably isolated.
- Support content publishing workflows, including media container creation,
  container status checks, and publish/finalize operations.
- Support comment replies and comment moderation operations where Instagram
  Graph API permissions allow them.
- Require explicit confirmation for high-impact CLI actions unless
  `--yes` is supplied.
- Return structured JSON for success and failure, with redaction applied before
  any diagnostic is printed.
- Keep SDK DTOs stable, public, `Codable`, and `Sendable`.

## Non-Goals

- Do not implement Instagram Basic Display API write behavior; write operations
  target the Instagram Graph API.
- Do not implement unsupported direct posting to personal Instagram accounts.
- Do not store or generate credentials in source, fixtures, logs, shell history
  examples, or generated artifacts.
- Do not mix reader and writer permission requirements into a single all-powerful
  CLI binary.
- Do not add browser automation to the writer command; developer-console setup
  and token provisioning are documented for the parent workflow.

## Package And Targets

The writer feature belongs in the same Swift package as the reader feature:

- `InstagramGatewayCore`: shared domain DTOs, config loading, redaction,
  transport, auth models, pagination, API errors, reader service contracts, and
  writer service contracts.
- `InstagramGatewayReader`: read-only executable target for
  `instagram-gateway-reader`.
- `InstagramGatewayWriter`: write-capable executable target for
  `instagram-gateway-writer`.
- `InstagramGatewayCoreTests`: unit tests for request construction, DTO coding,
  pagination, API errors, redaction, command parsing, and write safety guards.
- `InstagramGatewayCLITests`: deterministic CLI tests if the package structure
  supports separate executable testing cleanly.

The writer executable may reuse read-only account discovery operations needed to
resolve configured Instagram business account IDs, but it must not become the
recommended binary for routine read-only use.

## Permission Separation

`instagram-gateway-reader` supports read-oriented scopes only. It must reject
write commands at compile-time by absence of writer command registration and at
runtime by refusing any loaded credential profile whose configured access mode is
write-only or writer.

`instagram-gateway-writer` supports writer workflows and may require read scopes
that Meta couples to write operations. The configured access mode must be
explicit:

- `read`: usable by `instagram-gateway-reader`; no write commands.
- `write`: usable by `instagram-gateway-writer`; publishing and moderation
  commands enabled.

Initial writer scope set:

- `instagram_basic`
- `instagram_content_publish`
- `instagram_manage_comments`
- `pages_show_list`
- `pages_read_engagement`

The implementation should keep scopes as configured strings because Meta can
change exact permission names and review availability. Known provider-controlled
closed sets in responses should use typed enums with an `.unknown(String)` style
fallback only if the project adopts a resilient enum pattern; otherwise use
strings for provider-owned evolving values.

## Configuration

Configuration follows the mail-gateway pattern:

```toml
[[credentials]]
id = "meta-sandbox-writer"
provider = "meta"
access_mode = "write"
app_id_env = "INSTAGRAM_GATEWAY_META_SANDBOX_APP_ID"
app_secret_env = "INSTAGRAM_GATEWAY_META_SANDBOX_APP_SECRET"
access_token_env = "INSTAGRAM_GATEWAY_META_SANDBOX_ACCESS_TOKEN"
scopes = [
  "instagram_basic",
  "instagram_content_publish",
  "instagram_manage_comments",
  "pages_show_list",
  "pages_read_engagement"
]

[[accounts]]
id = "sandbox"
provider = "instagram_graph"
instagram_user_id = "provider-owned-id"
page_id = "provider-owned-page-id"
credential_id = "meta-sandbox-writer"
```

Safe kinko secret names for the taco-dev-sandbox account:

- `INSTAGRAM_GATEWAY_META_SANDBOX_APP_ID`
- `INSTAGRAM_GATEWAY_META_SANDBOX_APP_SECRET`
- `INSTAGRAM_GATEWAY_META_SANDBOX_ACCESS_TOKEN`

The README and diagnostics may name secret keys but must never print their
values. Examples must use placeholders and must not embed credentials for
`taco-dev-sandbox@mutvar.com`.

## SDK Writer API

Public write APIs should be async and dependency-injected through a transport
protocol:

```swift
public protocol InstagramWriterService: Sendable {
    func createMediaContainer(_ input: CreateMediaContainerInput) async throws -> MediaContainer
    func getMediaContainerStatus(containerId: String) async throws -> MediaContainerStatus
    func publishMediaContainer(_ input: PublishMediaContainerInput) async throws -> PublishedMedia
    func replyToComment(_ input: ReplyToCommentInput) async throws -> InstagramComment
    func hideComment(_ input: ModerateCommentInput) async throws -> ModerationResult
    func unhideComment(_ input: ModerateCommentInput) async throws -> ModerationResult
    func deleteComment(_ input: ModerateCommentInput) async throws -> ModerationResult
}
```

Primary DTOs:

- `CreateMediaContainerInput`: `accountId`, `mediaType`, `imageURL` or
  `videoURL`, optional `caption`, optional `children`, optional
  provider-specific fields.
- `MediaContainer`: provider container ID and creation metadata.
- `MediaContainerStatus`: container ID, status code, status text, error details
  if supplied by Meta.
- `PublishMediaContainerInput`: `accountId`, `containerId`.
- `PublishedMedia`: media ID, permalink if returned, timestamp if returned.
- `ReplyToCommentInput`: `accountId`, `commentId`, `message`.
- `ModerateCommentInput`: `accountId`, `commentId`.
- `ModerationResult`: target comment ID, action, success flag.

Provider identifiers, captions, URLs, comment text, and status text remain
strings. Closed local concepts such as requested moderation action should be
typed enums.

## CLI Commands

Shared flags:

```bash
instagram-gateway-writer [--config <path>] [--pretty] <command>
instagram-gateway-writer --help
instagram-gateway-writer version
```

Diagnostics:

```bash
instagram-gateway-writer doctor
instagram-gateway-writer config validate
```

Publishing workflow:

```bash
instagram-gateway-writer media create-container --account sandbox --image-url <url> --caption <text>
instagram-gateway-writer media container-status --account sandbox --container-id <id>
instagram-gateway-writer media publish --account sandbox --container-id <id> --yes
```

Comment operations:

```bash
instagram-gateway-writer comments reply --account sandbox --comment-id <id> --message <text> --yes
instagram-gateway-writer comments hide --account sandbox --comment-id <id> --yes
instagram-gateway-writer comments unhide --account sandbox --comment-id <id> --yes
instagram-gateway-writer comments delete --account sandbox --comment-id <id> --yes
```

`publish`, `reply`, `hide`, `unhide`, and `delete` are state-changing and must
prompt for confirmation on interactive terminals unless `--yes` is present.
When stdin is not interactive and `--yes` is omitted, commands must fail with a
structured confirmation-required error.

## JSON Output And Diagnostics

All successful commands return a single JSON object:

```json
{
  "ok": true,
  "operation": "media.publish",
  "result": {
    "mediaId": "17800000000000000"
  }
}
```

All failures return a single JSON object on stderr and a non-zero exit status:

```json
{
  "ok": false,
  "error": {
    "code": "CONFIRMATION_REQUIRED",
    "message": "Confirmation is required for media.publish.",
    "retryable": false
  }
}
```

Diagnostics must redact:

- access tokens
- app secrets
- authorization headers
- query parameters named `access_token`, `app_secret`, `client_secret`, or
  equivalent secret-bearing names
- environment variable values
- local secret file contents

Provider request IDs, status codes, non-secret error codes, and endpoint path
templates may be printed.

## HTTP And Error Handling

The writer service uses an async HTTP transport dependency, not hard-coded
`URLSession.shared`, so tests can verify request methods, paths, query items,
body encoding, and redaction behavior.

Explicit error cases:

- `configurationInvalid`
- `credentialMissing`
- `scopeMissing`
- `confirmationRequired`
- `providerRejected`
- `rateLimited`
- `notFound`
- `conflict`
- `transportFailed`
- `decodingFailed`

Errors must carry safe context only. Raw provider payloads are allowed in debug
structures only after the redactor has processed them.

## Testing Plan

Required deterministic tests:

- Writer commands are absent from `instagram-gateway-reader`.
- Writer binary rejects read-only credentials for write commands.
- State-changing commands require `--yes` when non-interactive.
- `media create-container` encodes expected Graph API request fields.
- `media publish` targets the expected account and container ID.
- `comments reply`, `hide`, `unhide`, and `delete` construct expected requests.
- Provider error payloads are mapped into explicit API errors.
- Redaction removes tokens, app secrets, and secret query parameters from JSON
  diagnostics.
- DTOs round-trip through `Codable` and conform to `Sendable`.

Required verification commands:

```bash
swift build
swift test
swift run instagram-gateway-writer --help
swift run instagram-gateway-writer doctor --pretty
swift run instagram-gateway-writer config validate --config Examples/config.placeholder.toml --pretty
```

If SwiftLint is configured and installed:

```bash
swiftlint
```

## Live Smoke Tests After Credential Provisioning

These commands are documented for after Meta app credentials and an access token
are provisioned through kinko or the local secret environment:

```bash
kinko export INSTAGRAM_GATEWAY_META_SANDBOX_APP_ID
kinko export INSTAGRAM_GATEWAY_META_SANDBOX_APP_SECRET
kinko export INSTAGRAM_GATEWAY_META_SANDBOX_ACCESS_TOKEN
swift run instagram-gateway-writer doctor --pretty
swift run instagram-gateway-writer media create-container --account sandbox --image-url https://example.com/public-test-image.jpg --caption "instagram-gateway smoke test" --pretty
swift run instagram-gateway-writer media container-status --account sandbox --container-id <container-id> --pretty
swift run instagram-gateway-writer media publish --account sandbox --container-id <container-id> --yes --pretty
```

The image URL must be public and non-sensitive. Smoke tests must not print token
values and must not include credentials in command history examples beyond
secret key names.

## Decisions

- Writer functionality ships in `instagram-gateway-writer`, separate from
  `instagram-gateway-reader`.
- Business write APIs are implemented in `InstagramGatewayCore` and exposed as
  public async Swift service methods.
- Write operations are CLI commands rather than generic mutation strings for the
  initial release, matching the requested practical SDK and CLI surface.
- High-impact state changes require confirmation unless `--yes` is supplied.
- Configuration refers to secret environment variable names and kinko exports,
  never raw secret values.
- Provider identifiers and free text remain strings; local closed operation
  concepts use typed enums.

## Open Questions

- Exact Meta app review state and available scopes for
  `taco-dev-sandbox@mutvar.com` must be verified by the parent agent in Brave or
  Meta developer console.
- Whether carousel publishing is required in the first implementation depends on
  live account eligibility and should be feature-gated if Meta rejects it.
- Whether comment deletion is available for every targeted media/comment type
  should be confirmed against the provisioned test account.

## Risks

- Meta Graph API write permissions and app-review availability can block live
  smoke tests even when deterministic build and unit tests pass.
- Container publishing has asynchronous provider state; callers must poll
  status and handle provider rejection before publish.
- Overly verbose provider diagnostics could leak token-bearing URLs unless every
  error path uses the shared redactor.
- Mixing reader and writer credential profiles in one config file can confuse
  users unless doctor output clearly reports binary compatibility without
  revealing secret values.
