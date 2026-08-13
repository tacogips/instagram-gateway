# Reader API And CLI

## Status

Feature-local design for `reader-api-cli`.

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference:
  `workflow-input:<workspace>#Build a Swift Instagram/Meta SDK and permission-separated CLI`
- Feature id: `reader-api-cli`
- Feature title: Reader API And CLI
- Implementation plan path: `impl-plans/reader-api-cli.md`
- Reference repository:
  `../mail-gateway`

## Scope

Build the read-only Swift SDK surface and `instagram-gateway-reader` executable
for reliable Instagram Graph API operations:

- discover Facebook Pages and connected Instagram professional accounts
- read account/profile metadata for the authenticated account and supported
  business-discovery targets
- list media with pagination
- look up owned media by id
- list and look up comments for owned media
- read account and media insights where Meta supports the metric for the
  account/media type and token scopes
- emit stable JSON for every CLI command
- provide deterministic `--help`, `--version`, `version`, `doctor`, and
  `config validate` behavior without printing secrets

This feature must not include content publishing, comment mutation, moderation,
reply, or delete operations. Those belong to the writer feature and binary.

## External API Basis

The implementation targets Meta's Instagram Platform / Instagram Graph API
surface documented by Meta for Developers:

- Instagram Platform overview:
  `https://developers.facebook.com/documentation/instagram-platform/overview`
- Instagram API with Facebook Login:
  `https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-facebook-login`
- IG Media reference:
  `https://developers.facebook.com/documentation/instagram-platform/reference/instagram-media`
- Business Discovery:
  `https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-facebook-login/business-discovery`
- Content Publishing is out of this reader scope but informs binary separation:
  `https://developers.facebook.com/documentation/instagram-platform/content-publishing`

Design decisions below intentionally isolate provider-controlled shape changes
behind typed DTOs, API-version configuration, and fixture-driven transport tests.

## Package And Target Shape

Use the mail-gateway package layout as the UX reference while adapting names for
Instagram:

- `InstagramGatewayCore`: public SDK models, config, transport, pagination,
  reader service, JSON diagnostics, and shared CLI runtime
- `InstagramGatewayReader`: executable target for `instagram-gateway-reader`
- `InstagramGatewayCoreTests`: unit and fixture tests for reader behavior
- `InstagramGatewayCLITests`: subprocess-style tests for help/version/config
  commands where practical

Reader-only public SDK entry points:

```swift
public struct InstagramGatewayClient: Sendable {
    public let reader: InstagramReaderService
}

public struct InstagramReaderService: Sendable {
    public func listPages(...) async throws -> Page<FacebookPage>
    public func listInstagramAccounts(...) async throws -> Page<InstagramAccount>
    public func getAccount(id: String, fields: Set<AccountField>) async throws -> InstagramAccount
    public func businessDiscovery(username: String, fields: BusinessDiscoveryFields) async throws -> BusinessProfile
    public func listMedia(accountId: String, request: MediaListRequest) async throws -> Page<InstagramMedia>
    public func getMedia(id: String, fields: Set<MediaField>) async throws -> InstagramMedia
    public func listComments(mediaId: String, request: CommentListRequest) async throws -> Page<InstagramComment>
    public func getComment(id: String, fields: Set<CommentField>) async throws -> InstagramComment
    public func getAccountInsights(accountId: String, request: AccountInsightsRequest) async throws -> InsightsResponse
    public func getMediaInsights(mediaId: String, request: MediaInsightsRequest) async throws -> InsightsResponse
}
```

Provider-owned identifiers, usernames, captions, URLs, metric names returned
from the provider, and cursors remain strings. Provider-controlled closed sets
with stable documented values use `Codable & Sendable` enums with unknown-value
preservation where compatibility matters.

## CLI UX

The reader binary follows the mail-gateway command conventions:

```bash
instagram-gateway-reader [--config <path>] [--pretty] <command>
instagram-gateway-reader --help
instagram-gateway-reader --version
instagram-gateway-reader version
```

`--config <path>` overrides default config discovery. `INSTAGRAM_GATEWAY_CONFIG`
is honored when the flag is omitted. `--pretty` formats command JSON without
changing field names or exit behavior.

Reader commands:

```bash
instagram-gateway-reader doctor
instagram-gateway-reader config validate
instagram-gateway-reader accounts pages [--limit <n>] [--after <cursor>]
instagram-gateway-reader accounts instagram [--page-id <id>] [--limit <n>] [--after <cursor>]
instagram-gateway-reader accounts get --account-id <id> [--fields <csv>]
instagram-gateway-reader accounts business-discovery --username <name> [--fields <csv>]
instagram-gateway-reader media list --account-id <id> [--limit <n>] [--after <cursor>] [--fields <csv>]
instagram-gateway-reader media get --media-id <id> [--fields <csv>]
instagram-gateway-reader comments list --media-id <id> [--limit <n>] [--after <cursor>] [--fields <csv>]
instagram-gateway-reader comments get --comment-id <id> [--fields <csv>]
instagram-gateway-reader insights account --account-id <id> --metric <csv> [--period <period>]
instagram-gateway-reader insights media --media-id <id> --metric <csv>
```

The command parser should reject writer-only verbs with an explicit
least-privilege error:

```json
{
  "ok": false,
  "error": {
    "code": "unsupportedByReaderBinary",
    "message": "This command is not available in instagram-gateway-reader.",
    "retryable": false
  }
}
```

## JSON Output Contract

All successful commands return an object with `ok: true`, a command-specific
`data` value, and optional `paging`. All failures return `ok: false` and a
redacted `error` object. No command prints tokens, app secrets, authorization
codes, raw request headers, or config secret values.

Paginated responses:

```json
{
  "ok": true,
  "data": [],
  "paging": {
    "before": "opaque-provider-cursor",
    "after": "opaque-provider-cursor",
    "next": "https://graph.facebook.com/..."
  }
}
```

The SDK keeps provider cursor strings opaque. CLI output may include provider
`next` URLs only after stripping access-token query parameters.

## Authentication And Configuration

Reader configuration supports environment and kinko-backed secret references,
never inline secrets in generated examples:

```toml
[meta]
graph_api_version = "v23.0"

[[credentials]]
id = "sandbox-reader"
app_id_env = "INSTAGRAM_GATEWAY_META_APP_ID"
app_secret_env = "INSTAGRAM_GATEWAY_META_APP_SECRET"
access_token_env = "INSTAGRAM_GATEWAY_READER_ACCESS_TOKEN"
default_page_id_env = "INSTAGRAM_GATEWAY_DEFAULT_PAGE_ID"
default_ig_user_id_env = "INSTAGRAM_GATEWAY_DEFAULT_IG_USER_ID"
```

Recommended kinko secret names and export commands for the parent credential
provisioning step:

```bash
kinko secret set INSTAGRAM_GATEWAY_META_APP_ID
kinko secret set INSTAGRAM_GATEWAY_META_APP_SECRET
kinko secret set INSTAGRAM_GATEWAY_READER_ACCESS_TOKEN
kinko secret set INSTAGRAM_GATEWAY_DEFAULT_PAGE_ID
kinko secret set INSTAGRAM_GATEWAY_DEFAULT_IG_USER_ID
```

The `doctor` command validates presence, source selection, API version syntax,
token presence, configured default ids, and binary capability mode. Networked
identity checks are optional behind `doctor --live` so deterministic diagnostics
remain non-secret and offline-safe.

Reader scopes to document for the Meta app/token setup are read-only and should
be requested only as needed for smoke coverage, such as page/account discovery,
basic Instagram account data, comments, and insights. Exact scope names must be
confirmed during the browser developer-console setup because Meta can rename or
gate permissions by app type, API version, or review state.

## Transport And Error Model

`InstagramHTTPTransport` is an injected async dependency:

```swift
public protocol InstagramHTTPTransport: Sendable {
    func send(_ request: InstagramHTTPRequest) async throws -> InstagramHTTPResponse
}
```

The default implementation uses `URLSession` and applies:

- request timeout configuration
- bearer-token authorization from a token provider
- URL query construction through `URLComponents`
- JSON decoding with stable date/string handling
- response-body size limits suitable for CLI usage
- error redaction before values reach CLI diagnostics

Public errors:

- `configurationInvalid`
- `credentialUnavailable`
- `authenticationRequired`
- `permissionDenied`
- `notFound`
- `rateLimited`
- `providerRejected`
- `providerUnavailable`
- `decodingFailed`
- `transportFailed`
- `unsupportedOperation`

Each error is `Codable`, `Sendable`, and carries `code`, redacted `message`,
`retryable`, optional provider request id, optional HTTP status, and optional
safe details.

## Pagination

Model Graph API cursors as:

```swift
public struct Page<Element: Codable & Sendable>: Codable, Sendable {
    public var data: [Element]
    public var paging: Paging?
}

public struct Paging: Codable, Sendable {
    public var before: String?
    public var after: String?
    public var next: String?
}
```

CLI commands accept `--limit` and `--after` where the endpoint supports them.
The implementation does not auto-drain pages by default. Future fanout can add
`--all` with explicit max-item safeguards.

## DTO Decisions

Core reader DTOs:

- `FacebookPage`: `id`, `name`, optional `accessTokenAvailable`, optional linked
  `instagramBusinessAccount`
- `InstagramAccount`: `id`, `username`, `name`, `biography`, `website`,
  `profilePictureURL`, `followersCount`, `followsCount`, `mediaCount`
- `BusinessProfile`: public/professional account metadata and optional nested
  media summaries
- `InstagramMedia`: `id`, `caption`, `mediaType`, `mediaProductType`,
  `mediaURL`, `permalink`, `thumbnailURL`, `timestamp`, `username`,
  `commentsCount`, `likeCount`
- `InstagramComment`: `id`, `text`, `username`, `timestamp`, `likeCount`,
  `hidden`
- `InsightsResponse`: `data: [InsightMetric]`

Enums:

- `InstagramMediaType`: `image`, `video`, `carouselAlbum`, `unknown(String)`
- `InstagramMediaProductType`: `feed`, `reels`, `story`, `ad`, `unknown(String)`
- `InsightPeriod`: `day`, `week`, `days28`, `lifetime`, `unknown(String)`

## Verification

Deterministic verification commands for this feature:

```bash
swift build
swift test
swift run instagram-gateway-reader --help
swift run instagram-gateway-reader --version
swift run instagram-gateway-reader version
swift run instagram-gateway-reader config validate --config Tests/Fixtures/reader-valid.toml
swift run instagram-gateway-reader doctor --config Tests/Fixtures/reader-valid.toml
```

Live smoke commands after credentials are provisioned:

```bash
swift run instagram-gateway-reader doctor --live
swift run instagram-gateway-reader accounts pages --limit 5 --pretty
swift run instagram-gateway-reader accounts instagram --limit 5 --pretty
swift run instagram-gateway-reader media list --account-id "$INSTAGRAM_GATEWAY_DEFAULT_IG_USER_ID" --limit 5 --pretty
swift run instagram-gateway-reader insights account --account-id "$INSTAGRAM_GATEWAY_DEFAULT_IG_USER_ID" --metric impressions,reach --period day --pretty
```

Live commands must be run with environment populated by kinko or another
non-logging secret mechanism. Documentation and tests must avoid real token
values.

## Review Checklist

- Reader binary has no writer command implementations or write scopes.
- CLI outputs are JSON-only except help/version text.
- Provider errors are redacted.
- URLs printed in JSON do not include `access_token`.
- Public DTOs are `Codable` and `Sendable`.
- Transport is injectable and tests do not require network access.
- Pagination cursors remain opaque strings.
- API-version config defaults are documented and overridable.

## Open Questions

- Which exact Meta app product path will be approved for the sandbox account:
  Instagram API with Facebook Login or Instagram API with Instagram Login?
- Which exact read-only permission names are available for the app at setup
  time and which require app review for `taco-dev-sandbox@mutvar.com`?
- Are account insights expected to cover only owned professional accounts, or
  should business-discovery metrics be exposed when Meta permits them?

## Risks

- Meta permission names, review gates, and metric support change over time; the
  implementation must keep unsupported metrics as provider errors rather than
  hard-coded assumptions.
- Business Discovery does not imply direct access to every returned media id;
  the SDK must preserve endpoint context and avoid follow-up calls that Meta
  rejects.
- Insights availability varies by account type, media type, age, and permission
  state, so tests should validate request construction and error mapping with
  fixtures instead of assuming live metric availability.
