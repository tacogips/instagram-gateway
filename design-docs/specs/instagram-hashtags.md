# Hashtag Discovery Design

## Status

Feature-local design for `instagram-hashtags`. Acceptance requires both design
and implementation-plan review; this document does not claim implementation.

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference:
  `workflow-input:codex-design-and-implement-review-loop-session-695`
- Feature id: `instagram-hashtags`
- Feature title: `Hashtag discovery`
- Feature summary: cover hashtag search, top media, recent media, and recently
  searched hashtags with typed results and reader commands.
- Requested design path: `docs/design/instagram-hashtags.md`
- Canonical design path: `design-docs/specs/instagram-hashtags.md`
- Requested implementation-plan path: `docs/plans/instagram-hashtags.md`
- Canonical implementation-plan path: `impl-plans/instagram-hashtags.md`
- Codex agent references: `/root/instagram_hashtags_design_review`.

The workflow instruction requiring design documents under `design-docs/` and
implementation plans under `impl-plans/` takes precedence over the legacy paths
carried by the fanout item. No duplicate legacy-path documents are created.

## Scope

Add the official Instagram Platform hashtag discovery surface for professional
accounts using Facebook Login:

- resolve a hashtag query to an Instagram hashtag id;
- get top media for a resolved hashtag id;
- get recent media for a resolved hashtag id;
- list hashtags recently searched on behalf of an Instagram professional
  account;
- expose explicit public Swift DTOs and async reader-service methods;
- expose all four capabilities in `instagram-gateway-reader` with the existing
  stable JSON envelope and cursor-pagination conventions;
- document Meta permissions, account eligibility, App Review/Advanced Access,
  query quota, result limitations, and live-test prerequisites.

All operations in this feature are reads. They belong only in the reader
service and reader binary. They do not require destructive confirmation and do
not broaden the writer binary.

## Non-Goals

- Instagram consumer-account or private/mobile API search.
- Keyword, caption, username, location, audio, or general Explore search.
- Scraping, browser automation, or reconstructing results omitted by Meta.
- Historical hashtag archives, continuous monitoring, local quota accounting,
  or automatic polling.
- Automatic resolution of a query inside top/recent commands. That would spend
  a unique-hashtag query quota entry as a hidden side effect.
- Publishing, messaging, commenting, or any other mutation.
- Treating provider ordering, completeness, or media attribution as a stable
  public contract.

## Official API Basis

Checked on 2026-08-13 against Meta's Instagram Platform documentation and
official Instagram Postman collection:

- Hashtag Search guide:
  `https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-facebook-login/hashtag-search`
- IG Hashtag reference:
  `https://developers.facebook.com/documentation/instagram-platform/instagram-graph-api/reference/ig-hashtag`
- Recently searched hashtags edge:
  `https://developers.facebook.com/documentation/instagram-platform/instagram-graph-api/reference/ig-user/recently_searched_hashtags`
- Official Instagram API collection:
  `https://www.postman.com/meta/instagram/collection/6yqw8pt/instagram-api`

The implementation must use the repository's configured versioned Graph API
base URL rather than hard-code a second API version. Exact permissions and
review gates remain provider-controlled and must be rechecked when live
credentials are provisioned.

## Provider Operations

### Search

```http
GET /ig_hashtag_search?user_id={ig-user-id}&q={hashtag}
```

The provider returns a data collection of hashtag nodes. The SDK preserves the
collection because a valid request can return zero results; it does not throw
`notFound` merely because `data` is empty.

### Top Media

```http
GET /{ig-hashtag-id}/top_media
  ?user_id={ig-user-id}
  &fields=id,caption,media_type,media_url,permalink,timestamp,children{id,media_type,media_url},comments_count,like_count
  [&limit={limit}]
  [&after={cursor}]
```

### Recent Media

```http
GET /{ig-hashtag-id}/recent_media
  ?user_id={ig-user-id}
  &fields=id,caption,media_type,media_url,permalink,timestamp,children{id,media_type,media_url},comments_count,like_count
  [&limit={limit}]
  [&after={cursor}]
```

### Recently Searched Hashtags

```http
GET /{ig-user-id}/recently_searched_hashtags
  ?fields=id,name
  [&limit={limit}]
  [&after={cursor}]
```

`user_id` is always the configured or explicit professional-account id acting
for the request. A hashtag id is an opaque provider id and is never inferred
from the hashtag text by top/recent methods.

## Public Swift Contract

Add dedicated DTOs instead of overloading owned-media DTOs with public hashtag
result semantics:

```swift
public struct InstagramHashtag: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
}

public struct InstagramHashtagMediaChild: Codable, Equatable, Sendable {
    public var id: String
    public var mediaType: MediaType?
    public var mediaURL: String?
}

public struct InstagramHashtagMedia: Codable, Equatable, Sendable {
    public var id: String
    public var caption: String?
    public var mediaType: MediaType?
    public var mediaURL: String?
    public var permalink: String?
    public var timestamp: String?
    public var children: Page<InstagramHashtagMediaChild>?
    public var commentsCount: Int?
    public var likeCount: Int?
}
```

All public stored properties receive explicit public initializers with defaults
for optional provider fields. `MediaType` retains its existing unknown-value
preservation. Provider ids, text, URLs, timestamps, and cursors remain strings.
Counts are optional because availability can depend on media ownership, type,
privacy, and API behavior. `InstagramHashtag.name` also remains optional: the
search response can contain only `id`, while recently searched explicitly asks
for `name`; fixtures cover both shapes instead of making one endpoint's field
selection a universal decoding requirement.

Extend `InstagramReaderService` with explicit async methods:

```swift
public func searchHashtags(
    accountId: String,
    query: String
) async throws -> Page<InstagramHashtag>

public func topHashtagMedia(
    hashtagId: String,
    accountId: String,
    limit: Int? = nil,
    after: String? = nil
) async throws -> Page<InstagramHashtagMedia>

public func recentHashtagMedia(
    hashtagId: String,
    accountId: String,
    limit: Int? = nil,
    after: String? = nil
) async throws -> Page<InstagramHashtagMedia>

public func recentlySearchedHashtags(
    accountId: String,
    limit: Int? = nil,
    after: String? = nil
) async throws -> Page<InstagramHashtag>
```

`searchHashtags` returns the provider collection rather than picking a first
result. This keeps zero/multiple-result behavior explicit and avoids an
unstable convenience contract.

## Input Validation

- `accountId`, `hashtagId`, and the normalized query must be non-empty.
- The CLI accepts `--query taco` or `--query '#taco'`; it trims surrounding
  whitespace and removes one leading `#` before sending `q`.
- Internal whitespace is rejected locally because the endpoint accepts a
  hashtag, not a free-text search phrase.
- Unicode hashtag text is preserved and encoded through the existing
  `URLComponents` transport path.
- `--limit` must be positive. Provider maximums remain provider-controlled; a
  provider rejection maps through the existing typed error model.
- `--after` is opaque and must not be parsed or logged beyond redaction-safe
  JSON output.

No validation fabricates a hashtag id, retries with spelling variants, or
silently issues additional searches.

## Reader CLI Contract

Add one command family:

```bash
instagram-gateway-reader hashtags search \
  --query <hashtag> [--account-id <id>]

instagram-gateway-reader hashtags top-media \
  --hashtag-id <id> [--account-id <id>] [--limit <n>] [--after <cursor>]

instagram-gateway-reader hashtags recent-media \
  --hashtag-id <id> [--account-id <id>] [--limit <n>] [--after <cursor>]

instagram-gateway-reader hashtags recently-searched \
  [--account-id <id>] [--limit <n>] [--after <cursor>]
```

When `--account-id` is omitted, commands use the selected reader credential's
configured Instagram user id. Search never accepts `--hashtag-id`; top/recent
never accept `--query`, making quota-consuming resolution explicit.

Success uses the existing envelope:

```json
{
  "ok": true,
  "data": [
    {"id": "opaque-hashtag-id", "name": "taco"}
  ],
  "paging": null
}
```

Top/recent/recently-searched return the same envelope with typed arrays and
optional paging. Before serialization, `paging.next` and `paging.previous` pass
through the existing secret redactor. CLI failures use the existing redacted
typed error envelope and nonzero status. Help lists the four reader commands.
The writer CLI does not advertise or route this family.

## Permissions And Meta Prerequisites

For the Facebook Login path used by this repository, document at minimum:

- a Facebook Page linked to an eligible Instagram professional account;
- an access token for a user who can act on the linked Page/account;
- `instagram_basic` as the hashtag endpoint permission, with Advanced Access
  and App Review when Meta requires the app to serve professional accounts not
  owned by an app-role user;
- `pages_read_engagement` only when the repository's separate Page/account
  discovery flow needs it; it is not represented as a hashtag-edge permission,
  and its own Advanced Access/App Review state is documented separately;
- Live mode and account-role/ownership prerequisites for non-development
  assets.

Permissions are configuration metadata and diagnostics, never compiled token
values. Implementation must update the centralized scope assumptions and setup
docs only after checking the active Graph API version. Missing permission,
eligibility, and review prerequisites are reported as Meta-blocked; they are not
reported as code failures or bypassed.

## Provider Limitations And Quota

- Meta limits hashtag discovery to 30 unique hashtags on behalf of an Instagram
  professional account in a rolling seven-day window. Repeating an already
  searched hashtag does not create a new unique query, subject to provider
  behavior.
- Recently searched hashtags represents provider state for the recent
  seven-day window; it is not a complete history or a local cache.
- Recent media is limited by Meta's documented recent window, currently the
  preceding 24 hours.
- Results can omit media Meta does not make available. Completeness, ordering,
  ranking, and continued availability are not guaranteed.
- Hashtag media must not promise an author's username or other attribution not
  returned by this API surface.
- Searching an unsupported, restricted, or unused hashtag can return an empty
  collection or provider error.

The SDK exposes provider results without attempting to scrape missing data.
Tests use fixtures so development does not consume the unique-hashtag quota.

## Error And Security Behavior

- The four calls reuse `InstagramGatewayClient.request` and its typed mapping
  for authentication, permission, rate-limit, provider, decoding, and transport
  failures.
- Access tokens remain bearer headers and never become typed DTO fields, logs,
  fixtures, command examples, or documents.
- Token-bearing pagination URLs are redacted before CLI encoding.
- Hashtag text and ids are not secrets, but error messages still pass through
  the central redactor because provider payloads can echo request data.
- No command contacts, messages, comments on, follows, publishes to, or mutates
  third-party accounts or media.

## Deterministic Test Contract

Core tests must cover:

- hashtag and hashtag-media decoding, including child media and absent optional
  counts/fields;
- known and unknown `MediaType` decoding in hashtag results;
- exact search request path and encoded `user_id`/`q` query;
- exact top/recent paths, `user_id`, field set, `limit`, and `after`;
- exact recently-searched path and pagination;
- empty search data without false `notFound` mapping;
- local validation for empty ids/query, whitespace query, and nonpositive limit;
- provider error mapping and redaction through existing client behavior.

CLI tests must cover:

- help visibility in reader and absence from writer help;
- all four command routes through an injected recording transport;
- default versus explicit account id;
- leading-`#` normalization and Unicode query encoding;
- required option and invalid-limit failures;
- stable JSON DTO field names and redacted paging URLs;
- no destructive `--yes` requirement for these read-only commands.

All deterministic tests are network-free and use invented ids, media, cursors,
URLs, and tokens.

## Live Verification Boundary

After deterministic tests, the parent implementation may live-test against the
configured `taco-dev-sandbox` professional account when credentials and Meta
prerequisites exist:

1. Run `hashtags recently-searched` first.
2. If it returns an existing hashtag id, use that id for top/recent media so no
   new unique search is consumed.
3. Run `hashtags search` only with an explicitly chosen already-searched term,
   or record that quota-safe search verification is unavailable.
4. Record permission, eligibility, empty-result, or quota failures as
   Meta-blocked without claiming endpoint success.

No live step mutates owned or unowned assets, sends a message, or exposes a
credential. Live verification is not a prerequisite for accepting deterministic
code coverage.

## Documentation And Coverage

Implementation must update:

- reader help and README command examples;
- `docs/meta-setup.md` with current scopes, review/account prerequisites, and
  the 30-unique-hashtags/seven-day limit;
- `docs/api-coverage.md` so search, top media, recent media, and recently
  searched each have an explicit code status and separate live/prerequisite
  notes.

Coverage wording must distinguish deterministic SDK/CLI implementation from
live verification and Meta-controlled availability.

## Acceptance Criteria

- Public `Codable & Equatable & Sendable` hashtag DTOs have explicit public
  initializers and preserve provider-owned values.
- `InstagramReaderService` exposes all four operations with exact versioned
  Graph request shapes and cursor pagination where available.
- `instagram-gateway-reader` exposes all four commands with stable redacted JSON
  and credential-default account selection.
- Writer command boundaries and confirmation behavior are unchanged.
- Deterministic request, decode, validation, CLI, redaction, and help tests pass.
- `swift test` and `swift build -c release` pass; any unavailable live endpoint
  check is recorded separately as Meta-blocked and does not weaken the
  deterministic completion claim.
- README, Meta setup, and coverage docs distinguish code coverage from provider
  prerequisites and live results.
- No test or document contains a real token, app secret, private URL, or owned
  provider id.

## Risks

- Meta may change endpoint availability, permission names, result fields,
  limits, or App Review rules after the documented check date.
- Hashtag search consumes scarce provider state, so careless live tests can
  reduce the sandbox's remaining rolling-window quota.
- Public media can disappear or return fewer fields between calls, making live
  fixtures unsuitable for deterministic assertions.
- The current monolithic core/CLI source files increase merge-conflict risk
  while multiple feature fanout workers touch adjacent types and routing.
- The fanout contract's legacy paths conflict with the required canonical
  documentation roots; this design records the mapping to avoid duplicates.

## Design Review Record

- Self-review: accepted on 2026-08-13 with no high or mid findings. It checked
  scope completeness, read/write boundaries, DTO/public-contract stability,
  request shapes, quota visibility, pagination/redaction, deterministic and
  live verification boundaries, documentation obligations, and canonical path
  placement. Low residual: exact provider permission/field availability must be
  rechecked against the configured Graph API version during implementation.
- Independent review: changes requested by
  `/root/instagram_hashtags_design_review` on 2026-08-13: three mid findings
  (obsolete official URLs, conflated endpoint/discovery permissions, and
  missing test/release-build acceptance commands) and one low finding (optional
  hashtag-name rationale).
- Addressed feedback: replaced official links with the canonical
  `/documentation/instagram-platform/` paths; separated `instagram_basic`
  hashtag requirements from `pages_read_engagement` account discovery;
  required `swift test` and `swift build -c release`; documented and tested the
  optional `name` contract. The first re-review found that two reference URLs
  still lacked the `instagram-graph-api` segment; both were corrected to the
  canonical reference paths.
- Independent re-review: accepted by
  `/root/instagram_hashtags_design_review` after the reference-path correction,
  with no remaining high, mid, or low findings.
- Acceptance decision: accepted on 2026-08-13.
