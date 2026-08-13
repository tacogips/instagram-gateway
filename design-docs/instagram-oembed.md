# Instagram oEmbed

## Status

Accepted feature-local design for `instagram-oembed` after self-review and an
independent second-pass review.

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference: `workflow-input:codex-design-and-implement-review-loop-session-695`
- Feature id: `instagram-oembed`
- Feature title: Instagram oEmbed
- Feature summary: Add typed oEmbed SDK and reader CLI coverage with token,
  URL, and provider-prerequisite documentation.
- Implementation plan: `impl-plans/instagram-oembed.md`
- Codex agent references: none

The runtime fanout supplied legacy paths under `docs/`. The worker contract
requires feature designs under `design-docs/` and implementation plans under
`impl-plans/`, so the bounded feature artifacts use the paths above and do not
modify the legacy path declarations.

## Scope

Add read-only Instagram oEmbed support to the public Swift SDK and
`instagram-gateway-reader`:

- retrieve embed HTML and typed metadata for a caller-supplied public Instagram
  content URL through Meta's versioned `GET /instagram_oembed` endpoint
- model supported request options without a raw provider-fields escape hatch
- decode the stable oEmbed fields while tolerating provider-omitted optional
  metadata
- select a read credential through the existing `--credential` mechanism and
  send its access token only in the `Authorization: Bearer` header
- validate URL shape and option ranges before a network request
- preserve stable JSON envelopes, token redaction, kinko secret references,
  deterministic tests, and the reader/writer binary boundary
- document provider prerequisites and distinguish implemented code from Meta
  approval, app-mode, content-eligibility, and token availability

## Non-Goals

- rendering or executing returned HTML or Instagram `embed.js`
- scraping Instagram pages, resolving private/mobile APIs, or downloading media
- persisting oEmbed HTML or metadata for analytics or unrelated reuse
- accepting arbitrary hosts, redirects, inline access tokens, or token query
  parameters
- adding oEmbed to `instagram-gateway-writer`
- claiming live success when Meta prerequisites are absent

## Provider Contract And Prerequisites

Implementation targets the version selected by `metaGraphAPIVersion` (currently
`v26.0`) and the documented endpoint:

```text
GET /{graph-version}/instagram_oembed
Authorization: Bearer {app-or-client-access-token}

url={percent-encoded-public-instagram-url}
maxwidth={integer}            # optional
hidecaption={true|false}      # optional
omitscript={true|false}       # optional
```

Primary references to re-check immediately before implementation and live
verification:

- `https://developers.facebook.com/docs/instagram-platform/oembed/`
- `https://developers.facebook.com/docs/features-reference/meta-oembed-read/`
- `https://developers.facebook.com/docs/graph-api/overview/rate-limiting/`

The endpoint is a Meta oEmbed capability, not proof of professional-account
Graph API authorization. Production availability can depend on a registered
Meta app, the oEmbed product/Meta oEmbed Read feature, appropriate access level
or App Review, business verification where Meta requires it, app Live mode, and
an accepted app/client access token. Public content can still be rejected when
the account or content is private, inactive, age-restricted, removed, or
otherwise ineligible. Meta's dashboard and current official documentation are
authoritative because prerequisites and field availability change over time.

Unauthenticated endpoint behavior observed in a particular Graph version is not
treated as a supported contract. The SDK and CLI retain the documented bearer
token path. The token is an oEmbed app/client credential, not the professional
account user/Page token used by other reader commands. Operators should create a
separate read profile, for example:

```toml
[[credentials]]
id = "taco-dev-sandbox-oembed"
provider = "meta-instagram"
access_mode = "read"
access_token_ref = "kinko:INSTAGRAM_GATEWAY_META_OEMBED_ACCESS_TOKEN"
```

Do not invent a permission string for `scopes`: it is diagnostic documentation,
not local authorization enforcement, and Meta exposes oEmbed through a
dashboard feature/access level rather than necessarily through a user-token
scope. If a current official token scope exists at implementation time, record
its exact checked label; otherwise leave `scopes` empty and document the Meta
oEmbed Read feature separately.

## Public SDK Contract

Add public `Codable`, `Equatable`, and `Sendable` request/response types:

```swift
public struct InstagramOEmbedRequest: Codable, Equatable, Sendable {
  public var url: URL
  public var maxWidth: Int?
  public var hideCaption: Bool?
  public var omitScript: Bool?
}

public enum OEmbedResourceType: Codable, Equatable, Sendable {
  case rich
  case photo
  case video
  case link
  case unknown(String)
}

public struct InstagramOEmbed: Codable, Equatable, Sendable {
  public var version: String
  public var providerName: String
  public var providerURL: URL?
  public var type: OEmbedResourceType
  public var width: Int?
  public var height: Int?
  public var html: String
  public var title: String?
  public var authorName: String?
  public var authorURL: URL?
  public var cacheAge: String?
  public var thumbnailURL: URL?
  public var thumbnailWidth: Int?
  public var thumbnailHeight: Int?
}

extension InstagramReaderService {
  public func oEmbed(_ request: InstagramOEmbedRequest) async throws
    -> InstagramOEmbed
}
```

Public initializers provide source compatibility with the package's existing
DTO style. Provider snake-case fields map through explicit `CodingKeys`.
`version`, `provider_name`, `type`, and `html` are required because a response
without the embed payload is not useful; historically present author and
thumbnail fields remain optional because Meta may omit or retire them.
Unknown resource types preserve their raw value instead of breaking decoding.

The service builds an `HTTPRequest` at `instagram_oembed`. It relies on the
existing `InstagramGatewayClient` to inject and redact the bearer token, map
provider errors, and decode JSON. It does not place the token in query items or
return request headers in errors.

## Input Validation

Before transport execution:

- require `https`
- require a normalized host of `instagram.com` or `www.instagram.com`
- reject user-info, fragments, embedded credentials, and an empty path
- accept documented public-content paths such as `/p/{shortcode}/`,
  `/reel/{shortcode}/`, and `/tv/{shortcode}/`; reject profile, Explore,
  Stories, and direct-message URLs
- require a nonempty shortcode segment composed only of URL-safe characters
- require `maxWidth`, when supplied, to be positive and within the range stated
  by current official Meta documentation; encode it only after validation

Validation reports `configurationInvalid` with a safe message containing no
token. Meta remains the final authority on whether a syntactically valid URL is
eligible.

## Reader CLI Contract

Add the reader-only command:

```bash
instagram-gateway-reader \
  --credential taco-dev-sandbox-oembed \
  oembed get \
  --url "https://www.instagram.com/p/<shortcode>/" \
  [--max-width <pixels>] \
  [--hide-caption] \
  [--omit-script] \
  [--pretty]
```

The command requires `oembed get` and `--url`; option spelling remains CLI
kebab-case while SDK properties remain Swift camelCase. Success uses the
existing `SuccessEnvelope<InstagramOEmbed>` and includes the returned HTML as a
JSON string. The CLI must never evaluate, sanitize, or render it. Failures use
the existing redacted error envelope and exit-status mapping.

`instagram-gateway-reader --help` lists `oembed get`. The writer help and writer
router do not expose or accept the command. No `--yes` gate is needed because
the operation is read-only.

## Security And Privacy

- Resolve the oEmbed token from `env:` or `kinko:` secret references; examples
  use `kinko:INSTAGRAM_GATEWAY_META_OEMBED_ACCESS_TOKEN`.
- Send the token in the bearer header only. Tests assert it is absent from the
  request query and all JSON/error output.
- Do not echo the input URL in diagnostics when a provider error could append
  secret query data; ordinary success may return provider content but not the
  request token.
- Treat returned `html` as untrusted provider content. Consumers must apply
  their own rendering isolation and content-security policy.
- Do not persist provider metadata or use it outside Meta's documented embed
  presentation use case.

## Documentation And Coverage Changes

Implementation updates these parent-owned documentation surfaces as part of the
feature implementation, not this planning worker:

- `README.md`: SDK/reader example and separate oEmbed credential selection
- `docs/meta-setup.md`: token kind, kinko key, Meta product/feature, access
  level/App Review, business verification, Live mode, and eligibility caveats
- `docs/live-smoke-tests.md`: safe public-URL read command and blocked-result
  recording rules
- `docs/api-coverage.md`: code status separate from provider prerequisites and
  live verification status

No documentation may embed a real token or claim provider approval.

## Test Strategy

Deterministic tests use the existing recording transport:

- decode a current minimal response and a legacy/expanded response with optional
  author and thumbnail fields
- preserve an unknown `type`
- verify endpoint path, percent-safe URL query construction, each optional
  parameter, bearer header, and token absence from query items
- reject invalid scheme, host, path, shortcode, and `maxWidth` without sending
  a request
- verify provider error and decoding error mapping remains redacted
- route the reader CLI command, return stable JSON, and prove help visibility
- prove the writer binary does not advertise or route oEmbed
- prove raw token values never appear in CLI output

Live verification is a safe read only. It requires an operator-owned credential
profile and a public Instagram URL approved for the test. A Meta prerequisite
failure is recorded as blocked with the provider code and redacted message; it
is not a code failure or a successful live result.

## Design Review Record

### Self-review

Decision: `accepted-after-revision`.

- Mid design defect: the first draft implicitly reused the professional-account
  reader token. Addressed by requiring a separate read credential profile whose
  `access_token_ref` is an oEmbed app/client token.
- Mid design defect: response fields that Meta has removed or may omit were
  initially required. Addressed by requiring only the useful core embed payload
  and making author/thumbnail/auxiliary fields optional.
- Low risk retained: exact provider feature labels, approval gates, and
  `maxWidth` bounds are version-sensitive and must be rechecked before code and
  live verification.

### Independent second-pass review

Decision: `accepted`.

- No high or mid design findings remain.
- Confirmed reader/writer separation, explicit token provenance, URL validation,
  DTO compatibility, provider-blocked semantics, redaction, deterministic tests,
  and documentation obligations.
- Low risk retained: Meta may change unauthenticated behavior, accepted URL
  forms, response fields, or feature prerequisites independently of Graph API
  versioning.

## Acceptance Criteria

- Typed public request/response models and a reader service method cover the
  documented Instagram oEmbed read operation.
- The reader CLI exposes `oembed get`; the writer binary remains unchanged.
- A dedicated read profile supplies an oEmbed app/client token via kinko/env,
  and no token appears in query strings, output, docs, or errors.
- URL and option validation prevents unsupported local requests without
  overclaiming provider eligibility.
- Tests are deterministic and network-free; live checks remain explicitly
  prerequisite-gated.
- README and coverage/setup/smoke docs distinguish code coverage from Meta
  approval, Live mode, token, and public-content prerequisites.
