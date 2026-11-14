# Instagram Mentions

## Status

Feature-local design for `instagram-mentions`.

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference:
  `workflow-input:codex-design-and-implement-review-loop-session-695`
- Feature id: `instagram-mentions`
- Feature title: Mentions
- Requested design path: `docs/design/instagram-mentions.md`
- Canonical design path: `design-docs/specs/instagram-mentions.md`
- Requested implementation-plan path: `docs/plans/instagram-mentions.md`
- Canonical implementation-plan path: `impl-plans/instagram-mentions.md`
- Codex agent references: `/root/mentions_design_review`

The canonical paths apply the worker requirement that designs live under
`design-docs/` and implementation plans live under `impl-plans/`, following the
repository's existing feature-local convention.

## Scope

Add an explicit, typed mentions surface for Instagram professional accounts:

- represent webhook-discovered caption and comment mention identifiers without
  making the SDK own webhook storage
- look up a media object whose caption mentions the app user's professional
  account
- look up a comment that mentions the app user's professional account
- reply publicly to a caption mention or a comment mention
- expose lookups only in `instagram-gateway-reader`
- expose replies only in `instagram-gateway-writer`, with the existing `--yes`
  confirmation gate
- document permissions, Page tasks, access-review gates, account eligibility,
  provider limitations, and honest live-verification outcomes

Existing `GET /{ig-user-id}/tags` support remains the tagged-media discovery
operation. A tag and an `@mention` are distinct provider concepts and must not
share a DTO or command merely because the guide documents them together.

Out of scope:

- raw webhook envelope decoding, callback serving, subscriptions, persistence,
  and `X-Hub-Signature-256` verification; those belong to the webhook feature
- private replies and direct messages; those belong to the messaging feature
- background polling, auto-replies, moderation policy, or durable mention state
- consumer/private APIs, Story mention access, and consumer accounts
- interaction with mentions or media owned by an uncontrolled third party

## Official API Basis

This design uses Meta's Instagram API with Facebook Login surface and the
current repository Graph API default. Authoritative references:

- Mentions guide:
  `https://developers.facebook.com/documentation/instagram-platform/instagram-api-with-facebook-login/mentions`
- Mentioned media reference:
  `https://developers.facebook.com/documentation/instagram-platform/instagram-graph-api/reference/ig-user/mentioned_media`
- Mentioned comment reference:
  `https://developers.facebook.com/documentation/instagram-platform/instagram-graph-api/reference/ig-user/mentioned_comment`
- Mention reply reference:
  `https://developers.facebook.com/documentation/instagram-platform/instagram-graph-api/reference/ig-user/mentions`
- Official Instagram API collection:
  `https://www.postman.com/meta/instagram/collection/6yqw8pt/instagram-api`

The endpoints are:

```http
GET /{ig-user-id}?fields=mentioned_media.media_id({media-id}){fields}
GET /{ig-user-id}?fields=mentioned_comment.comment_id({comment-id}){fields}
POST /{ig-user-id}/mentions?media_id={media-id}&message={message}
POST /{ig-user-id}/mentions?media_id={media-id}&comment_id={comment-id}&message={message}
```

There is no supported read/list operation on `/{ig-user-id}/mentions`. Mention
discovery is event-driven: subscribe to the Instagram `mentions` webhook field,
store the delivered media/comment identifiers, and pass those identifiers to
the lookup operations. Meta does not retain webhook notifications for later
retrieval. The CLI therefore does not invent a `mentions list` command.

## Provider Eligibility And Prerequisites

This feature targets a Business or Creator account using Instagram API with
Facebook Login, a linked Facebook Page, and `graph.facebook.com`. Do not claim
support through the Instagram Login host unless Meta documents equivalent
mention endpoints.

For mention lookups and caption replies, document:

- Facebook User access token
- `instagram_basic`
- `instagram_manage_comments`
- `pages_read_engagement`
- Page task `MANAGE`, `CREATE_CONTENT`, or `MODERATE`

For comment-mention replies, also document `pages_show_list`, as required by
the current mention-reply reference.

If the Page role was granted through Business Manager, Meta also requires one
of `ads_management` or `ads_read`. Standard Access is sufficient only for
professional accounts the app owns/manages and that are configured as app
roles/test assets; serving other professional accounts requires the relevant
Advanced Access and App Review approvals. These are Meta prerequisites, not
code-completeness criteria.

Unsupported or provider-limited cases:

- Story mentions are not supported.
- A tag does not authorize commenting on the tagged photo.
- Mentioned-comment lookup fails when comments are disabled on its media.
- A mention on media created by a private account does not generate a webhook.
- Caption text from media the app user did not create may omit the leading `@`.
- Hidden like-count behavior can cause `like_count` to be absent.

## Public SDK Contract

### Discovery And Targets

Use a normalized value that the webhook feature can construct after validating
and decoding a provider notification:

```swift
public enum MentionTarget: Codable, Equatable, Sendable {
    case caption(mediaId: String)
    case comment(mediaId: String, commentId: String)
}

public struct MentionDiscoveryReference: Codable, Equatable, Sendable {
    public var accountId: String
    public var target: MentionTarget
    public var providerTimestamp: Int?

    public init(accountId: String, target: MentionTarget, providerTimestamp: Int? = nil)
}
```

`providerTimestamp` preserves Meta's webhook `entry.time` Unix timestamp in
seconds when available. This feature does not invent a timestamp for manually
supplied identifiers and does not persist these values. `MentionTarget` uses an
explicit `kind` discriminator (`caption` or `comment`) in its Codable contract
instead of relying on Swift's synthesized associated-value representation.

### Request Models

```swift
public enum MentionedMediaField: String, Codable, CaseIterable, Sendable {
    case id, caption, commentsCount = "comments_count", likeCount = "like_count"
    case comments, mediaType = "media_type", mediaURL = "media_url"
    case owner, timestamp, username
}

public enum MentionedMediaCommentField: String, Codable, CaseIterable, Sendable {
    case id, likeCount = "like_count", text, timestamp, username
}

public enum MentionedCommentField: String, Codable, CaseIterable, Sendable {
    case id, likeCount = "like_count", media, text, timestamp
}

public enum MentionedCommentMediaField: String, Codable, CaseIterable, Sendable {
    case id, caption, mediaType = "media_type", mediaURL = "media_url"
    case timestamp, username
}

public struct MentionedMediaLookup: Codable, Equatable, Sendable {
    public var accountId: String
    public var mediaId: String
    public var fields: Set<MentionedMediaField>
    public var commentFields: Set<MentionedMediaCommentField>
    public var commentsLimit: Int?
    public var commentsAfter: String?

    public init(
        accountId: String,
        mediaId: String,
        fields: Set<MentionedMediaField> = [.id, .caption, .mediaType, .timestamp, .username],
        commentFields: Set<MentionedMediaCommentField> = [.id, .text, .timestamp],
        commentsLimit: Int? = nil,
        commentsAfter: String? = nil
    )
}

public struct MentionedCommentLookup: Codable, Equatable, Sendable {
    public var accountId: String
    public var commentId: String
    public var fields: Set<MentionedCommentField>
    public var mediaFields: Set<MentionedCommentMediaField>

    public init(
        accountId: String,
        commentId: String,
        fields: Set<MentionedCommentField> = [.id, .text, .timestamp, .media],
        mediaFields: Set<MentionedCommentMediaField> = [.id]
    )
}

public struct ReplyToMentionInput: Codable, Equatable, Sendable {
    public var accountId: String
    public var target: MentionTarget
    public var message: String

    public init(accountId: String, target: MentionTarget, message: String)
}
```

Default fields are deterministic and documented. Media defaults are `id`,
`caption`, `mediaType`, `timestamp`, and `username`. When `comments` is selected,
the nested comment defaults are `id`, `text`, and `timestamp`; `commentsLimit`
and the opaque `commentsAfter` cursor render Graph field-expansion arguments.
The limit must be positive. Comment defaults are `id`, `text`, `timestamp`, and
`media`, with only media `id` expanded. Callers may request only fields
represented by the typed enums; no raw field-expansion string or
`providerFields` escape hatch is added.

Nested comment options without the `comments` field fail locally instead of
being ignored. Because `commentsAfter` is embedded in a Graph field expression,
it is accepted only when non-empty and composed of ASCII letters, digits, `_`,
`-`, or `=`; the value otherwise remains opaque and is never decoded. This
conservative validation prevents field-expression injection while supporting
Meta's emitted base64/base64url-style cursors.

All account, media, and comment identifiers used inside Graph field expansion
must pass a shared Meta identifier validator before request construction. The
accepted grammar is one or more ASCII decimal digits. Empty, signed,
whitespace-bearing, delimited, or brace-containing values fail locally with
`configurationInvalid`; this prevents field-expression injection.

Messages must be non-empty after trimming and must not be logged. Provider
length/policy rejection remains a redacted `providerRejected` error rather than
duplicated SDK policy.

### Response Models

```swift
public struct MentionedMedia: Codable, Equatable, Sendable {
    public var id: String
    public var caption: String?
    public var comments: Page<MentionedMediaComment>?
    public var commentsCount: Int?
    public var likeCount: Int?
    public var mediaType: MediaType?
    public var mediaURL: String?
    public var ownerId: String?
    public var timestamp: String?
    public var username: String?

    public init(
        id: String,
        caption: String? = nil,
        comments: Page<MentionedMediaComment>? = nil,
        commentsCount: Int? = nil,
        likeCount: Int? = nil,
        mediaType: MediaType? = nil,
        mediaURL: String? = nil,
        ownerId: String? = nil,
        timestamp: String? = nil,
        username: String? = nil
    )
}

public struct MentionedMediaComment: Codable, Equatable, Sendable {
    public var id: String
    public var likeCount: Int?
    public var text: String?
    public var timestamp: String?
    public var username: String?

    public init(
        id: String,
        likeCount: Int? = nil,
        text: String? = nil,
        timestamp: String? = nil,
        username: String? = nil
    )
}

public struct MentionedCommentMedia: Codable, Equatable, Sendable {
    public var id: String
    public var caption: String?
    public var mediaURL: String?
    public var mediaType: MediaType?
    public var timestamp: String?
    public var username: String?

    public init(
        id: String,
        caption: String? = nil,
        mediaURL: String? = nil,
        mediaType: MediaType? = nil,
        timestamp: String? = nil,
        username: String? = nil
    )
}

public struct MentionedComment: Codable, Equatable, Sendable {
    public var id: String
    public var likeCount: Int?
    public var media: MentionedCommentMedia?
    public var text: String?
    public var timestamp: String?

    public init(
        id: String,
        likeCount: Int? = nil,
        media: MentionedCommentMedia? = nil,
        text: String? = nil,
        timestamp: String? = nil
    )
}

public struct MentionedMediaResponse: Codable, Equatable, Sendable {
    public var mentionedMedia: MentionedMedia
    public var id: String

    public init(mentionedMedia: MentionedMedia, id: String)
}

public struct MentionedCommentResponse: Codable, Equatable, Sendable {
    public var mentionedComment: MentionedComment
    public var id: String

    public init(mentionedComment: MentionedComment, id: String)
}
```

Counts decode from either a JSON number or a numeric string because Meta's
reference types and examples are inconsistent. Missing counts remain `nil`.
Unknown `media_type` values use the existing `MediaType.unknown(String)` path.
The outer `id` is retained because it identifies the queried professional
account and makes mismatched fixtures observable.

### Services

```swift
public struct InstagramReaderService: Sendable {
    public func mentionedMedia(_ lookup: MentionedMediaLookup) async throws -> MentionedMediaResponse
    public func mentionedComment(_ lookup: MentionedCommentLookup) async throws -> MentionedCommentResponse
}

public struct InstagramWriterService: Sendable {
    public func replyToMention(_ input: ReplyToMentionInput) async throws -> CommentReply
}
```

The comment lookup field expression expands `media{...}` only when `media` is
selected. Mentioned-media lookup renders
`comments.limit(...).after(...){...}` only when `comments` is selected and
returns its data and cursor-only `Paging`; Meta does not return `next` or
`previous` URLs for this field-expanded edge, so callers reconstruct the next
lookup with the opaque `after` cursor. Field names and nested fields are sorted
by raw value so request fixtures are stable. The top-level lookups are
single-object responses, not `Page` results.

`replyToMention` maps caption targets to `media_id,message` and comment targets
to `media_id,comment_id,message` on `POST /{account-id}/mentions`. It must not be
implemented through the existing `POST /{comment-id}/replies` method: Meta
documents the professional-account mentions edge for replying to mentions on
media the account does not own.

## CLI Contract

Reader commands:

```bash
instagram-gateway-reader mentions media get \
  [--account-id <id>] --media-id <id> [--fields <csv>] \
  [--comment-fields <csv>] [--comments-limit <n>] [--comments-after <cursor>]
instagram-gateway-reader mentions comment get \
  [--account-id <id>] --comment-id <id> [--fields <csv>] [--media-fields <csv>]
```

Writer commands:

```bash
instagram-gateway-writer mentions reply-caption \
  --account <id> --media-id <id> --message <text> --yes
instagram-gateway-writer mentions reply-comment \
  --account <id> --media-id <id> --comment-id <id> --message <text> --yes
```

Reader commands may use the selected credential's `instagram_user_id` when
`--account-id` is omitted. Writer commands keep the current explicit `--account`
requirement. Unknown/duplicate fields and missing values fail before network
access. Writer reply verbs without `--yes` fail with `confirmationRequired`.
The reader rejects reply verbs with `unsupportedOperation`; the writer does not
expose lookup commands.

Success uses the existing JSON envelope. Lookups return the typed response
under `data`; replies return the created comment `id`. Errors and any request
description remain secret-redacted. Caption/comment text is output data and is
not included in diagnostics or error details.

## Integration Boundaries

- The webhook feature decodes raw `mentions` notifications and may normalize
  them into `MentionDiscoveryReference`; this feature owns the normalized type
  and API operations, not callback transport or storage.
- The existing `taggedMedia(accountId:limit:after:)` operation remains the
  supported `/{ig-user-id}/tags` reader surface.
- The existing writer confirmation and access-mode checks apply unchanged.
- Coverage documentation must distinguish SDK/CLI completion from webhook
  setup, App Review, Page tasks, private-account behavior, and availability of
  a controlled mention fixture.

## Deterministic Verification Design

Core tests must cover:

- `MentionTarget` and `MentionDiscoveryReference` Codable round trips
- decoding mentioned media/comment fixture responses, including nested media,
  nested comment data/cursors, stripped `@`, absent like counts, numeric-string
  counts, and unknown media types
- exact field-expansion request construction and deterministic field sorting
- local rejection of malicious or malformed identifiers before transport use
- local rejection of empty or delimiter-bearing nested comment cursors before
  transport use
- caption and comment reply query mapping
- provider error propagation and secret redaction through existing transport

CLI tests must cover:

- reader help contains lookup commands but no reply commands
- writer help contains reply commands but no lookup commands
- reader lookup JSON and exact recorded request
- writer caption/comment replies require `--yes` and use write credentials
- cross-binary command rejection
- malformed field CSV and identifiers fail without issuing a request

Required deterministic commands:

```bash
swift test --filter Mention
swift test
swift build -c release
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
git diff --check -- design-docs/specs/instagram-mentions.md impl-plans/instagram-mentions.md
```

## Live Verification Policy

Safe lookups may be attempted against `taco-dev-sandbox` only when a mention
webhook fixture supplies a media/comment ID from an account controlled by the
operator. A reply may be live-tested only on such an owned, reversible fixture,
with explicit confirmation, and the created comment ID must be recorded for
cleanup where Meta permits comment deletion.

If the app lacks permissions, Advanced Access, Page tasks, a public subscribed
webhook, a controlled second account, or an eligible mention fixture, record
the operation as `META_BLOCKED` with the exact prerequisite. Do not create a
mention from or reply to an unowned account, message a third party, or claim a
blocked operation passed.

## Self-Review

- Initial self-review found no high or mid defects after checking endpoint
  ownership, binary separation, typed request/response shape, confirmation
  behavior, permissions, provider limitations, testability, and parent scope.
- Independent review by `/root/mentions_design_review` found three mid defects:
  omitted typed `comments` expansion, nested-media field/model mismatch, and
  missing public initializers. All were corrected by adding typed nested comment
  expansion with cursor paging, restricting nested media selection to its full
  response model, and specifying public initializers with deterministic defaults.
- The same review found one low timestamp defect; `providerTimestamp` now
  preserves Meta's numeric webhook `entry.time` value accurately.
- Accepted after correction: zero unresolved high or mid design findings.
- Low/open item: Meta's static references currently show an older example API
  version while the repository defaults to `v26.0`; requests must continue to
  use the configured version rather than copying example URLs.
- Low/open item: live mention discovery depends on a webhook and controlled
  second-account fixture that may not exist in the sandbox.

## Risks

- Meta can revise mention fields, permissions, and review requirements between
  Graph API versions.
- The official field type tables disagree with examples for count fields;
  tolerant decoding is required to avoid false failures.
- Webhook loss or private-account suppression means the API cannot reconstruct
  a complete mention history.
- Public replies are externally visible mutations even when the source mention
  is owned; confirmation, fixture ownership, and cleanup evidence are required.
