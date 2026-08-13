# Core SDK, Auth, Transport, And Config Design

## Status

Feature-local design for `core-sdk-auth-transport-config`.

## Workflow Context

- Workflow mode: `issue-resolution`
- Issue reference: `workflow-input:<workspace>#Build a Swift Instagram/Meta SDK and permission-separated CLI`
- Feature id: `core-sdk-auth-transport-config`
- Feature title: `Core SDK, Auth, Transport, And Config`
- Reference repository: `../mail-gateway`

## Scope

This feature creates the reusable Swift core library and the shared local
configuration foundation used by the read and write CLIs. It owns:

- async injected HTTP transport
- stable public DTOs for supported Instagram Graph API resources
- provider-owned identifier and text modeling
- pagination primitives
- typed API and configuration errors
- response and error redaction
- Meta credential and access-token configuration
- environment and kinko-backed secret lookup
- doctor and config diagnostics shared by reader and writer binaries

The permission-specific command surfaces are implemented by separate feature
work, but this feature must provide the capability gates and scope metadata that
allow reader and writer binaries to remain least-privileged.

## Goals

- Ship a Swift Package Manager core library usable directly by Swift callers.
- Keep HTTP side effects injectable for unit tests and live smoke tests.
- Model Meta-controlled closed sets as typed `Codable & Sendable` enums.
- Keep provider-owned IDs, usernames, captions, comments, URLs, and cursor
  values as strings.
- Normalize Graph API responses into stable DTOs without hiding raw provider
  error details needed for diagnosis.
- Redact access tokens, app secrets, authorization codes, signed requests, and
  secret-bearing paths from all errors, logs, JSON diagnostics, and test output.
- Support deterministic local diagnostics before live Meta credentials exist.
- Document exact safe secret names and provisioning commands without embedding
  secret values.

## Non-Goals

- Browser automation for Meta developer-console setup.
- Persisting or refreshing OAuth tokens automatically in v1 unless delegated to
  explicitly configured token files.
- Implementing every Instagram Graph API edge.
- Supporting Basic Display API as a parallel provider.
- Storing media binaries or upload payloads in the core library.
- Long-running daemon mode.

## Package Shape

The package should expose one shared library target and permission-separated
executables:

- `InstagramGatewayCore`: public SDK DTOs, config, auth, transport, pagination,
  typed errors, redaction, and diagnostics.
- `InstagramGatewayReader`: reader CLI entry point.
- `InstagramGatewayWriter`: writer CLI entry point.
- `InstagramGatewayCoreTests`: deterministic unit tests for core behavior.

The core library must not depend on CLI-only argument parsing. CLI targets call
core services and serialize command results as JSON.

## Module Boundaries

Recommended source layout:

- `Sources/InstagramGatewayCore/Transport`: `HTTPTransport`, requests,
  responses, retry policy hooks, and URL construction.
- `Sources/InstagramGatewayCore/Auth`: credential profiles, token providers,
  access-mode declarations, and scope validation.
- `Sources/InstagramGatewayCore/Config`: TOML loading, environment overrides,
  kinko command integration, path validation, and config diagnostics.
- `Sources/InstagramGatewayCore/Models`: public DTOs, enums, pagination
  connections, and provider metadata containers.
- `Sources/InstagramGatewayCore/Instagram`: Graph API client methods and
  endpoint-specific request builders.
- `Sources/InstagramGatewayCore/Diagnostics`: doctor checks, redaction, and
  JSON-safe diagnostic records.

## HTTP Transport

Core network calls use an injected async transport:

```swift
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
```

`HTTPRequest` contains method, URL, headers, optional body bytes, and a
redaction classification for headers and query items. `HTTPResponse` contains
status, headers, and body bytes. The default implementation wraps
`URLSession.data(for:)`; tests use a recording stub transport.

Transport requirements:

- All public service types are `Sendable` or isolated behind an actor.
- Request builders never append access tokens to logged URL strings.
- Authorization uses `Authorization: Bearer <token>` where supported.
- Query parameters are built through `URLComponents`, not string
  concatenation.
- Non-2xx responses are decoded into typed API errors when Meta returns a
  Graph API error object.
- Retry behavior is conservative and disabled by default for mutating calls.

## API Surface

The first reliable API surface covers:

- account/profile discovery for configured Instagram professional accounts
- media listing and media lookup
- comment listing and lookup where supported
- media insights where supported
- content publishing container creation/status/publish workflow
- comment reply, hide/unhide, delete, and moderation operations where supported

Public client grouping:

- `InstagramReadClient`: read-only operations and read scope requirements.
- `InstagramWriteClient`: publishing and moderation operations.
- `InstagramGatewayClient`: shared lower-level client used by both wrappers.

Reader binaries construct only `InstagramReadClient`. Writer binaries may
construct `InstagramWriteClient` only when config declares write access.

## DTO Rules

Public DTOs are stable, explicit, and `Codable & Sendable`.

Provider-controlled closed sets become enums with unknown preservation:

```swift
public enum InstagramMediaType: Codable, Sendable, Equatable {
    case image
    case video
    case carouselAlbum
    case reels
    case unknown(String)
}
```

Provider-owned identifiers and text remain strings:

- Instagram user id
- media id
- comment id
- page id
- username
- permalink
- caption
- comment text
- paging cursor
- insight metric name when not modeled as a local enum

DTOs should include `raw: [String: JSONValue]?` only for namespaced provider
metadata where forward compatibility is useful. Raw metadata must pass through
the same redaction layer before JSON output.

## Pagination

Use a provider-neutral page envelope:

```swift
public struct Page<Element: Codable & Sendable>: Codable, Sendable {
    public var data: [Element]
    public var paging: Paging?
}

public struct Paging: Codable, Sendable, Equatable {
    public var before: String?
    public var after: String?
    public var next: String?
    public var previous: String?
}
```

Core client methods accept `limit` and `after` where supported. The SDK does
not auto-drain pages by default. A helper async sequence may be added later, but
callers must opt into repeated network calls.

## Error Model

Expose typed errors:

- `InstagramGatewayError.configuration`
- `InstagramGatewayError.authentication`
- `InstagramGatewayError.authorization`
- `InstagramGatewayError.api`
- `InstagramGatewayError.transport`
- `InstagramGatewayError.decoding`
- `InstagramGatewayError.unsupported`
- `InstagramGatewayError.redactionFailure`

`api` errors preserve Meta error code, subcode, type, message, trace id, HTTP
status, and retryability when available. Secret-bearing fields are redacted
before constructing display strings or JSON.

CLI JSON error shape follows the reference repository convention:

```json
{
  "ok": false,
  "error": {
    "code": "AUTH_SCOPE_MISSING",
    "message": "Configured credential does not include required scopes.",
    "details": {}
  }
}
```

## Redaction

Redaction is centralized in `SecretRedactor`. It must handle:

- Meta app secret
- access tokens
- short-lived and long-lived tokens
- OAuth authorization codes
- `client_secret`
- `appsecret_proof`
- signed requests
- `Authorization` header values
- configured kinko command output
- paths marked as secret-bearing

Redaction runs on:

- request and response debug descriptions
- thrown error descriptions
- doctor/config JSON output
- test failure helpers
- any CLI log or stderr line

The implementation should fail closed when a required secret classification is
missing from a request component.

## Configuration

Default config path:

- `$XDG_CONFIG_HOME/instagram-gateway/config.toml`
- fallback: `~/.config/instagram-gateway/config.toml`
- override: `--config <path>` or `INSTAGRAM_GATEWAY_CONFIG`

Configuration model:

```toml
[[credentials]]
id = "taco-dev-sandbox-reader"
provider = "meta-instagram"
access_mode = "read"
app_id_env = "INSTAGRAM_GATEWAY_META_APP_ID"
app_secret_kinko = "instagram-gateway/meta/app-secret"
access_token_kinko = "instagram-gateway/taco-dev-sandbox/read-access-token"
instagram_user_id_env = "INSTAGRAM_GATEWAY_INSTAGRAM_USER_ID"

[[credentials]]
id = "taco-dev-sandbox-writer"
provider = "meta-instagram"
access_mode = "write"
app_id_env = "INSTAGRAM_GATEWAY_META_APP_ID"
app_secret_kinko = "instagram-gateway/meta/app-secret"
access_token_kinko = "instagram-gateway/taco-dev-sandbox/write-access-token"
instagram_user_id_env = "INSTAGRAM_GATEWAY_INSTAGRAM_USER_ID"
```

Configuration rules:

- credential ids are unique
- `provider` must be `meta-instagram` in v1
- `access_mode` must be `read` or `write`
- reader commands may use only `read` credentials
- writer commands may use only `write` credentials
- app id may come from TOML, environment, or kinko, but diagnostics must not
  print the value unless marked public-safe
- app secret and access tokens must never be stored in source-controlled files
- environment overrides win over TOML literal values
- kinko references are resolved only at command execution time
- missing secret values are reported as missing by name, not by attempted value

Safe secret names for the taco development account:

- `instagram-gateway/meta/app-id`
- `instagram-gateway/meta/app-secret`
- `instagram-gateway/taco-dev-sandbox/read-access-token`
- `instagram-gateway/taco-dev-sandbox/write-access-token`
- `instagram-gateway/taco-dev-sandbox/instagram-user-id`
- `instagram-gateway/taco-dev-sandbox/page-id`

Documentation may show commands that write placeholder values, but must never
show real credentials:

```bash
kinko secret set instagram-gateway/meta/app-id
kinko secret set instagram-gateway/meta/app-secret
kinko secret set instagram-gateway/taco-dev-sandbox/read-access-token
kinko secret set instagram-gateway/taco-dev-sandbox/write-access-token
```

## Meta App Setup Documentation

The README and design docs must instruct the parent agent or user to provision
Meta developer-console state outside source control:

- create or select a Meta app suitable for Instagram API with Facebook Login
- add the Instagram product/API capability required by the current Meta console
- connect the test Instagram professional account `taco-dev-sandbox@mutvar.com`
  through the associated Facebook Page/business assets as required by Meta
- configure OAuth redirect URIs for local token tooling
- request only scopes needed by the binary being provisioned
- store resulting app id, app secret, user/page/IG ids, and tokens in kinko or
  local environment, never in repository files

Scope documentation should be versioned as a checked assumption because Meta
renames permissions over time. The implementation should keep required scopes
centralized in code so docs and doctor output can be updated together.

Initial scope groups:

- read: Instagram account/profile, media, comments, and insights permissions
  required by the current Instagram Graph API setup
- write: read scopes plus content publishing and comment moderation permissions
  required by the current Instagram Graph API setup

## Doctor And Config Diagnostics

Shared commands:

```bash
instagram-gateway-reader config validate --config ./config.toml
instagram-gateway-reader doctor --config ./config.toml
instagram-gateway-writer config validate --config ./config.toml
instagram-gateway-writer doctor --config ./config.toml
```

Diagnostics report:

- resolved config path
- credential ids and declared access modes
- whether required env vars or kinko secret references are present
- whether the selected binary is compatible with the credential access mode
- whether an Instagram user id/page id is configured
- whether required scope declarations are satisfied if token metadata exists
- whether live API checks were skipped or executed

Diagnostics must not print secret values. Exit status conventions:

- `0`: all checks passed
- `3`: configuration problem
- `4`: missing authentication or credentials
- `5`: live API check failed

## Deterministic Verification Commands

These commands must work without credentials:

```bash
swift build
swift test
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
swift run instagram-gateway-reader config validate --config Examples/config.example.toml
swift run instagram-gateway-reader doctor --config Examples/config.example.toml --offline
swift run instagram-gateway-writer doctor --config Examples/config.example.toml --offline
```

Live smoke-test commands after provisioning:

```bash
swift run instagram-gateway-reader doctor --credential taco-dev-sandbox-reader
swift run instagram-gateway-reader account get --credential taco-dev-sandbox-reader
swift run instagram-gateway-reader media list --credential taco-dev-sandbox-reader --limit 5
swift run instagram-gateway-writer doctor --credential taco-dev-sandbox-writer
```

Publishing and moderation smoke tests must require explicit user-provided media
or comment ids and should not run by default in CI.

## Review Decisions

- Use a single core library with read and write wrapper clients, not duplicate
  SDK code per binary.
- Separate credentials by declared access mode so reader and writer tooling can
  be provisioned independently.
- Use injected async transport rather than static `URLSession.shared` calls.
- Keep provider ids and free text as strings to avoid false local constraints.
- Preserve unknown enum values to survive Meta API additions.
- Make pagination explicit and caller-driven.
- Use kinko secret references as first-class config inputs.
- Treat Meta permission names as centralized, versioned assumptions.

## Open Questions

- Which exact Meta app type and current permission names will the parent agent
  observe in the developer console on the provisioning date?
- Will the taco development account be connected to a Facebook Page/business
  asset that exposes publishing and insight APIs?
- Should token refresh be included in v1, or should v1 consume externally
  provisioned long-lived tokens only?
- Should `appsecret_proof` be required for all live calls once app secret
  provisioning is complete?

## Risks

- Meta API permission names and app setup flows change frequently, so setup docs
  require live console verification before credential provisioning.
- Publishing APIs require account and asset state that cannot be guaranteed by
  local deterministic tests.
- Over-broad write tokens would violate the repository requirement for
  permission-separated binaries; doctor must detect mismatches early.
- Error payloads may include sensitive request context; redaction must run
  before display or serialization.
