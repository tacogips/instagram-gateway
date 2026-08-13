# Messaging And Private Replies

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference:
  `workflow-input:codex-design-and-implement-review-loop-session-695`
- Feature id: `instagram-messaging`
- Feature title: `Messaging and private replies`
- Feature summary: Design typed DM and private-reply operations, writer
  commands, permission controls, owned fixtures, and third-party safety rules.
- Fanout group: `feature-local-planning`
- Fanout index: `2`
- Requested design path: `docs/design/instagram-messaging.md`
- Canonical design path: `design-docs/specs/instagram-messaging.md`
- Codex agent references: none

The requested path is normalized to the repository's established
`design-docs/specs/` layout, as required by the workflow instruction that
design documentation remain under `design-docs/`.

## Decision Status

Accepted for implementation planning. Design self-review and an independent
second-pass review found no unaddressed high- or mid-severity findings. The
review record at the end of this document distinguishes design corrections from
later plan-only corrections.

## Scope

Add official Instagram professional-account messaging coverage to the public
Swift SDK and permission-separated CLIs:

- list conversations, find a conversation by Instagram-scoped user ID, list
  message summaries, and fetch message details;
- fetch the consent-gated messaging profile for an Instagram-scoped user;
- send text, image/GIF, audio, video, reusable uploaded-image, owned published
  post, heart sticker, quick-reply, generic-template, and button-template
  messages;
- react or unreact to a message;
- mark a message seen and turn the typing indicator on or off through typed
  sender actions;
- send a `HUMAN_AGENT` response through an explicit typed policy tag;
- send one private reply to an eligible media comment;
- get, set, and delete ice breakers and persistent-menu configuration;
- expose every operation through the correct reader or writer binary;
- enforce declared permission, login-mode, confirmation, payload-validation,
  and live-verification safety boundaries.

The design uses current Meta documentation checked on 2026-08-13. Provider
eligibility remains a runtime prerequisite, not a code-completion claim.

## Official Baseline

The implementation must re-check these primary Meta references against the
pinned Graph API version before coding and record the date in
`docs/api-coverage.md`:

- Instagram API official Postman collection:
  <https://www.postman.com/meta/instagram/documentation/6yqw8pt/instagram-api>
- Conversations API:
  <https://www.postman.com/meta/instagram/folder/23987686-6a91368f-1fa8-4614-9ed6-7d1e08c21e62>
- Send API:
  <https://www.postman.com/meta/instagram/folder/23987686-f05b6c9f-a4be-4511-9f88-1cd94828fdf3>
- Instagram User Profile API:
  <https://www.postman.com/meta/instagram/folder/23987686-22b3a5b0-4a51-449a-9299-e3667d69b182>
- Private Replies:
  <https://www.postman.com/meta/instagram/request/23987686-189d7215-22b3-403f-b2f5-a46c7e66a514>
- Messenger Platform API, needed for the Facebook Login variant:
  <https://www.postman.com/meta/messenger-platform-api/documentation/iyp204x/messenger-platform-api>

Where the hosted collection contains contradictory samples, the implementation
must prefer the prose contract and successful schema used by the endpoint,
capture the ambiguity in a fixture test, and avoid inventing fields.

## Goals

- Make the SDK surface explicit, typed, `Codable`, `Equatable`, and `Sendable`.
- Preserve existing public SDK initializers and behavior while adding messaging.
- Preserve the reader/writer executable boundary.
- Use JSON request bodies for nested messaging payloads; never flatten them into
  query parameters or `providerFields`.
- Model both supported login variants and route each to the correct Graph host.
- Fail before transport when a configured profile is incompatible or omits a
  declared required scope.
- Make every mutation confirmation-gated in the writer CLI.
- Prevent implementation verification from messaging a third party or claiming
  success for an App Review, access-level, consent, account-role, callback, or
  conversation-window prerequisite that Meta has not granted.

## Non-Goals

- Threads, consumer/private/mobile APIs, Basic Display, Marketing/Ads, Research,
  and consumer automation are excluded.
- Welcome Message Flows are excluded because their documented purpose is
  Click-to-Messenger/Click-to-Instagram advertising and the parent request
  explicitly excludes Marketing/Ads. This exclusion must be visible in
  `docs/api-coverage.md`, not mislabeled as an implementation gap.
- Webhook HTTP serving, subscription CRUD, payload-envelope decoding, and
  `X-Hub-Signature-256` verification belong to the webhook feature. Messaging
  owns reusable message-domain DTOs only; the webhook feature may compose them.
- The SDK does not infer consent, fabricate an inbound interaction, extend a
  response window, or bypass Meta policy enforcement.
- Group messaging is not supported by the provider and is not emulated.
- Sending or deleting published Instagram media is outside this feature.
- The implementation does not persist DM content, customer profiles, or
  conversation state.

## Existing-System Constraints

The current package has one shared `InstagramGatewayCore` target, separate
reader and writer executables, injected `HTTPTransport`, bearer-token redaction,
and only a `graph.facebook.com` default transport. Messaging must fit those
contracts without weakening them.

Expected implementation locations:

- `Sources/InstagramGatewayCore/InstagramMessaging.swift` for messaging DTOs,
  validation, and service extensions;
- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift` only for the small
  shared config/transport changes required for login-mode routing;
- `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift` for reader/writer
  command routing and help;
- `Tests/InstagramGatewayCoreTests/InstagramMessagingTests.swift` and
  `Tests/InstagramGatewayCLITests/InstagramMessagingCLITests.swift` for focused
  deterministic coverage;
- `Tests/Fixtures/Messaging/` for synthetic Meta response/request fixtures;
- `README.md`, `docs/api-coverage.md`, `docs/meta-setup.md`, and
  `docs/live-smoke-tests.md` for status and prerequisites.

No source file layout is itself a public contract; public type and method names
are.

## Login Mode, Host, Token, And Permission Contract

Add a public closed login-mode enum and an optional configuration key:

```swift
public enum InstagramLoginMode: String, Codable, Equatable, Sendable {
  case facebook
  case instagram
}
```

`CredentialProfile` gains `loginMode` with a default of `.facebook` so existing
source callers and TOML remain valid. Config accepts
`login_mode = "facebook" | "instagram"`; omission preserves current behavior.
The transport base URL is selected by the profile, never by untrusted command
input:

| Login mode | Host | Required token for messaging |
| --- | --- | --- |
| `instagram` | `https://graph.instagram.com/<version>` | Instagram User access token |
| `facebook` | `https://graph.facebook.com/<version>` | Page access token for the linked professional account |

Endpoint ownership differs by login mode and operation. With Instagram Login,
`instagram_user_id` owns conversations, sends, attachment uploads, and Messenger
Profile calls. With Facebook Login, `page_id` owns those Messenger Platform
calls and `instagram_user_id` remains required for Instagram-object operations,
including private reply. The Facebook Login variant additionally requires the
linked Page, the Page `MESSAGING` task, and a verified-business-owned app where
Meta requires it. Missing `page_id` fails before transport for Facebook Login
messaging operations.

Add an optional `features = ["human_agent"]` configuration declaration. Meta's
Human Agent approval is a product feature, not an OAuth scope, so it must not be
smuggled into `scopes`.

Declared permission sets are operation-specific:

| Operation family | Instagram Login | Facebook Login |
| --- | --- | --- |
| conversations, message details, user profile, Send API, reactions, attachments, ice breakers, persistent menu | `instagram_business_basic`, `instagram_business_manage_messages` | `instagram_basic`, `instagram_manage_messages`, `pages_manage_metadata` |
| private reply | `instagram_business_basic`, `instagram_business_manage_comments` | `instagram_basic`, `instagram_manage_comments`, `pages_read_engagement` |
| human-agent response | messaging scopes plus approved `Human Agent` feature | messaging scopes plus approved `Human Agent` feature |

For the Facebook Login private-reply variant, accounts managed through Business
Manager roles can also require `ads_management` and `ads_read`; these remain a
conditional Meta prerequisite and do not bring Marketing API commands into
scope.

Configured scope strings are declarations, not proof of provider grant. Missing
declared scopes fail locally with `permissionDenied`; present declarations allow
the request, but provider denial remains authoritative. `doctor` reports
`declared`, `missing`, and `providerVerification: "not_performed"` rather than
claiming access. Advanced Access/App Review and Standard Access eligibility are
documented separately from code coverage.

## Reader And Writer Boundary

The reader binary owns operations that do not change provider state:

```text
messaging conversations list
messaging conversations find
messaging messages list
messaging messages get
messaging profile get
messaging ice-breakers get
messaging persistent-menu get
```

The writer binary owns all sends, reactions, attachment uploads, and Messenger
Profile mutations:

```text
messaging send text|media|attachment|published-post|sticker|quick-replies|generic-template|button-template
messaging react|unreact
messaging action mark-seen|typing-on|typing-off
messaging private-reply
messaging attachments upload
messaging ice-breakers set|delete
messaging persistent-menu set|delete
```

Read credentials cannot run writer commands. Write credentials cannot be used
through the reader under the existing strict access-mode rule. Operators who
need both surfaces configure separate least-privilege profiles even when Meta
issued the same underlying permissions.

## Public SDK Domain Model

Add public response DTOs with explicit `CodingKeys` for Meta's snake-case JSON:

- `InstagramConversation`: `id`, optional `updatedTime`.
- `InstagramMessageSummary`: `id`, optional `createdTime`, optional
  `isUnsupported`.
- `InstagramMessage`: `id`, optional `createdTime`, optional `from`, `to`,
  optional `message`, optional typed attachments, optional `isUnsupported`.
- `InstagramMessageParticipant`: `id`, optional `username`.
- `InstagramMessagingUserProfile`: `id`, optional `name`, `username`,
  `profilePictureURL`, `followerCount`, `isVerifiedUser`,
  `isUserFollowingBusiness`, and `isBusinessFollowingUser`.
- `InstagramSendReceipt`: optional `recipientId`, `messageId`, and `flowId` to
  tolerate currently inconsistent provider samples without a raw dictionary.
- `InstagramAttachmentReceipt`: `attachmentId`.
- `InstagramMutationResult`: `success`.

Provider-controlled response enums use an `.unknown(String)` fallback. Input
enums are closed and validated:

- `InstagramOutboundAttachmentType`: `image`, `audio`, `video`.
- `InstagramReactionAction`: `react`, `unreact`.
- `InstagramReactionKind`: `love`.
- `InstagramSenderAction`: `markSeen`, `typingOn`, `typingOff`.
- `InstagramQuickReplyContentType`: `text`, `userPhoneNumber`, `userEmail`.
- `InstagramTemplateButtonType`: `webURL`, `postback`.
- `InstagramMessageTag`: `humanAgent`.

Typed inputs:

- `ListInstagramConversationsInput`: account ID, optional `limit`, `after`, and
  optional recipient Instagram-scoped ID.
- `ListInstagramMessagesInput`: conversation ID and optional pagination.
- `GetInstagramMessageInput`: message ID.
- `GetInstagramMessagingProfileInput`: Instagram-scoped user ID.
- `SendInstagramMessageInput`: account ID, recipient Instagram-scoped ID,
  `InstagramOutboundMessage`, optional `InstagramMessageTag`.
- `ReactToInstagramMessageInput`: account ID, recipient Instagram-scoped ID,
  message ID, action, and reaction.
- `PerformInstagramSenderActionInput`: account ID, recipient Instagram-scoped
  ID, and sender action.
- `SendInstagramPrivateReplyInput`: account ID, comment ID, and text.
- `UploadInstagramMessageAttachmentInput`: account ID, image URL, reusable flag.
- typed ice-breaker and persistent-menu get/set/delete inputs.

`InstagramOutboundMessage` is an explicitly encoded enum, not a provider field
bag:

```swift
public enum InstagramOutboundMessage: Codable, Equatable, Sendable {
  case text(String)
  case media(type: InstagramOutboundAttachmentType, url: URL)
  case uploadedImage(attachmentId: String)
  case publishedPost(mediaId: String)
  case heartSticker
  case quickReplies(text: String, replies: [InstagramQuickReply])
  case genericTemplate(elements: [InstagramGenericTemplateElement])
  case buttonTemplate(text: String, buttons: [InstagramTemplateButton])
}
```

Supporting types include `InstagramQuickReply`, `InstagramTemplateButton`,
`InstagramTemplateDefaultAction`, `InstagramGenericTemplateElement`,
`InstagramIceBreaker`, `InstagramPersistentMenu`, and locale-scoped menu/ice
breaker containers. They must expose no `providerFields` escape hatch.

The SDK extends the existing services rather than introducing an unrelated
client hierarchy:

```swift
extension InstagramReaderService {
  public func conversations(_ input: ListInstagramConversationsInput) async throws -> Page<InstagramConversation>
  public func messages(_ input: ListInstagramMessagesInput) async throws -> Page<InstagramMessageSummary>
  public func message(_ input: GetInstagramMessageInput) async throws -> InstagramMessage
  public func messagingProfile(_ input: GetInstagramMessagingProfileInput) async throws -> InstagramMessagingUserProfile
  public func iceBreakers(accountId: String) async throws -> InstagramIceBreakerProfile
  public func persistentMenu(accountId: String) async throws -> InstagramPersistentMenuProfile
}

extension InstagramWriterService {
  public func sendMessage(_ input: SendInstagramMessageInput) async throws -> InstagramSendReceipt
  public func reactToMessage(_ input: ReactToInstagramMessageInput) async throws -> InstagramSendReceipt
  public func performSenderAction(_ input: PerformInstagramSenderActionInput) async throws -> InstagramSendReceipt
  public func sendPrivateReply(_ input: SendInstagramPrivateReplyInput) async throws -> InstagramSendReceipt
  public func uploadMessageAttachment(_ input: UploadInstagramMessageAttachmentInput) async throws -> InstagramAttachmentReceipt
  public func setIceBreakers(_ input: SetInstagramIceBreakersInput) async throws -> InstagramMutationResult
  public func deleteIceBreakers(accountId: String) async throws -> InstagramMutationResult
  public func setPersistentMenu(_ input: SetInstagramPersistentMenuInput) async throws -> InstagramMutationResult
  public func deletePersistentMenu(accountId: String) async throws -> InstagramMutationResult
}
```

## Endpoint And Encoding Contract

All nested send payloads use `Content-Type: application/json` and
`HTTPRequest.body`. Authorization remains the shared redacted bearer header.

| SDK operation | Request |
| --- | --- |
| list/find conversations | Instagram Login: `GET /<ig-user-id>/conversations`; Facebook Login: `GET /<page-id>/conversations?platform=instagram`; either may add `user_id` where supported |
| list messages | `GET /<conversation-id>?fields=messages{id,created_time,is_unsupported}` |
| message detail | `GET /<message-id>?fields=id,created_time,from,to,message,attachments,is_unsupported` |
| messaging profile | `GET /<igsid>?fields=id,name,username,profile_pic,follower_count,is_verified_user,is_user_follow_business,is_business_follow_user` |
| normal send/reaction | Instagram Login: `POST /<ig-user-id>/messages`; Facebook Login: `POST /<page-id>/messages` |
| private reply | `POST /<ig-user-id>/messages` on the configured login mode's host |
| upload reusable image | Instagram Login: `POST /<ig-user-id>/message_attachments`; Facebook Login: `POST /<page-id>/message_attachments` |
| ice breakers/menu | `GET`, `POST`, or `DELETE /<ig-user-id>/messenger_profile` for Instagram Login or `/<page-id>/messenger_profile` for Facebook Login |

Conversation list and nested message paging must map into the existing `Page`
and `Paging` types without returning token-bearing `next` URLs unredacted.
Message detail is provider-limited to recent messages; documentation currently
states details are available only for the 20 most recent messages in a
conversation. Requests-folder conversations inactive for 30 days may not be
returned.

Local validation occurs before transport:

- reject empty account, recipient, conversation, message, comment, media, and
  attachment IDs;
- reject empty text and button/payload strings where the provider requires
  content;
- quick replies: at most 13; text titles at most 20 characters;
- button template: at most 3 buttons;
- ice breakers: at most 4 questions;
- media URLs must be absolute HTTPS URLs;
- `HUMAN_AGENT` is permitted only with text content and a profile declaring the
  feature; it is never inferred;
- published-post messages require an explicit media ID and documentation that
  the app user must own the post;
- attachment uploads in this feature are image-only because that is the
  documented Instagram Platform upload operation; direct URL sends remain
  typed for image/GIF, audio, and video.

Normal Facebook Login sends include the documented `messaging_type: "RESPONSE"`
where required. Instagram Login encoding follows its endpoint contract and does
not gain Facebook-only keys by assumption. Sender actions use
`sender_action: "mark_seen" | "typing_on" | "typing_off"`; reactions use their
separate typed action plus payload.

## Policy Windows And Provider Prerequisites

The SDK and CLI must preserve, document, and never weaken these provider rules:

- A normal conversation begins only after the Instagram user messages the
  professional account; normal responses are constrained to the standard
  24-hour window.
- `HUMAN_AGENT` permits a human response within 7 days only for unresolved user
  inquiries. It requires separate approval and must not be used for automation
  or unrelated content.
- Messaging profile access requires user consent created by a message, ice
  breaker, or persistent-menu interaction. A comment alone is insufficient.
- Private reply permits one message per eligible comment, within 7 days; for
  Live comments it is allowed only while the broadcast is active. Follow-up is
  allowed only after the recipient responds and is then subject to the 24-hour
  window.
- Private reply may land in Requests if the commenter does not follow the
  professional account.
- Uploaded reusable attachment IDs expire according to Meta's documented TTL;
  current Messenger documentation states 90 days.
- Advanced Access is required for accounts the app does not own/manage;
  Standard Access is sufficient only for eligible app-role/owned test accounts.
- The provider may additionally require App Review, a verified business,
  account/Page roles, a linked Page for Facebook Login, and webhook setup.

These are surfaced in error/help/docs as prerequisites. Code tests cannot prove
them. A Meta rejection caused by a missing prerequisite is reported as
`providerBlocked`/`permissionDenied` with redacted provider detail and is not a
failed SDK coverage claim.

## CLI Contract

Reader examples:

```bash
instagram-gateway-reader messaging conversations list --account <ig-id> --limit 25
instagram-gateway-reader messaging conversations find --account <ig-id> --recipient-igsid <igsid>
instagram-gateway-reader messaging messages list --conversation-id <id>
instagram-gateway-reader messaging messages get --message-id <id>
instagram-gateway-reader messaging profile get --recipient-igsid <igsid>
instagram-gateway-reader messaging ice-breakers get --account <ig-id>
instagram-gateway-reader messaging persistent-menu get --account <ig-id>
```

Writer examples:

```bash
instagram-gateway-writer messaging send text --account <ig-id> --recipient-igsid <igsid> --text <text> --yes
instagram-gateway-writer messaging send media --account <ig-id> --recipient-igsid <igsid> --type image|audio|video --url <https-url> --yes
instagram-gateway-writer messaging send attachment --account <ig-id> --recipient-igsid <igsid> --attachment-id <id> --yes
instagram-gateway-writer messaging send published-post --account <ig-id> --recipient-igsid <igsid> --media-id <owned-id> --yes
instagram-gateway-writer messaging send sticker --account <ig-id> --recipient-igsid <igsid> --yes
instagram-gateway-writer messaging send quick-replies --account <ig-id> --recipient-igsid <igsid> --input <typed-json-file> --yes
instagram-gateway-writer messaging send generic-template --account <ig-id> --recipient-igsid <igsid> --input <typed-json-file> --yes
instagram-gateway-writer messaging send button-template --account <ig-id> --recipient-igsid <igsid> --input <typed-json-file> --yes
instagram-gateway-writer messaging send text --account <ig-id> --recipient-igsid <igsid> --text <text> --tag human-agent --yes
instagram-gateway-writer messaging react --account <ig-id> --recipient-igsid <igsid> --message-id <id> --reaction love --yes
instagram-gateway-writer messaging unreact --account <ig-id> --recipient-igsid <igsid> --message-id <id> --reaction love --yes
instagram-gateway-writer messaging action mark-seen --account <ig-id> --recipient-igsid <igsid> --yes
instagram-gateway-writer messaging action typing-on --account <ig-id> --recipient-igsid <igsid> --yes
instagram-gateway-writer messaging action typing-off --account <ig-id> --recipient-igsid <igsid> --yes
instagram-gateway-writer messaging private-reply --account <ig-id> --comment-id <id> --text <text> --yes
instagram-gateway-writer messaging attachments upload --account <ig-id> --type image --url <https-url> --reusable --yes
instagram-gateway-writer messaging ice-breakers set --account <ig-id> --input <typed-json-file> --yes
instagram-gateway-writer messaging ice-breakers delete --account <ig-id> --yes
instagram-gateway-writer messaging persistent-menu set --account <ig-id> --input <typed-json-file> --yes
instagram-gateway-writer messaging persistent-menu delete --account <ig-id> --yes
```

Complex `--input` files decode to the exact public typed DTO and reject unknown
keys. They are capped at 256 KiB, are not echoed in parser errors, and cannot
select a host, token, credential, endpoint, or arbitrary provider field. Simple
messages remain flags for ergonomic and shell-testable use.

Every writer command above requires `--yes` before config loading or transport.
The writer does not prompt in non-interactive use. Missing confirmation produces
the existing structured `CONFIRMATION_REQUIRED` error and no request.

## Privacy, Redaction, And Third-Party Safety

DM text, usernames, profile data, IDs, payloads, and URLs are customer data even
when they are not credentials. The CLI returns requested data to stdout but
does not log or persist it. Errors must not include request bodies. Debug request
descriptions must show only method and templated path; they must not print
message/profile payloads or recipient identifiers.

The shared secret redactor continues to remove tokens, app secrets,
authorization headers, signed material, and token-bearing paging URLs. Synthetic
fixtures use fake IDs and text only.

Live verification follows stricter rules than the general product surface:

- no command may send, react, unreact, perform a sender action, private-reply,
  or upload an attachment during this workflow's live checks because these
  writes leave irreversible message/thread, read-state, UI, or provider-asset
  history;
- no third-party recipient, comment, conversation, profile, message, or media
  may be used as a live fixture;
- safe live reads are limited to the configured professional account's
  self-messaging conversation/profile after that account has messaged itself in
  the Instagram app, or to an explicitly owned secondary test account;
- live fixture IDs are resolved from kinko/environment references and never
  committed; use
  `INSTAGRAM_GATEWAY_META_SANDBOX_SELF_IGSID`,
  `INSTAGRAM_GATEWAY_META_SANDBOX_SELF_CONVERSATION_ID`, and
  `INSTAGRAM_GATEWAY_META_SANDBOX_SELF_MESSAGE_ID` names;
- ice-breaker or persistent-menu mutation may be live-tested only if the exact
  current state is first captured in memory, the temporary state is owned, and
  cleanup restores the original state in the same run. If snapshot or restore
  cannot be proven, skip and record `meta_prerequisite_blocked`;
- live output is inspected transiently and must not be copied into fixtures,
  docs, commits, or issue comments.

Self messaging is an official testing path, but its 24-hour exception does not
make the resulting send reversible. It therefore does not authorize a live send
under this workflow.

## Error And Output Contract

Success uses the existing single JSON envelope on stdout. Failures use the
existing redacted error envelope on stderr and nonzero exit status. Preserve the
public error enum: missing declared permission or Human Agent feature uses the
existing `permissionDenied`; missing policy-sensitive arguments use
`configurationInvalid`; Meta prerequisite rejection uses `permissionDenied` or
`providerRejected` according to the response. Continue using existing
`confirmationRequired`, `rateLimited`, `transportFailed`, and `decodingFailed`
categories. Coverage documentation, not a new public error case, records
`meta_prerequisite_blocked`.

Do not map every provider message into a new public enum case. Preserve stable
error categories and redacted provider code/trace metadata.

## Deterministic Test Contract

Required tests use injected transports and synthetic fixtures:

- snake-case decoding for every response DTO, optional fields, unknown provider
  values, paging, and inconsistent send receipts;
- exact host selection for both login modes;
- exact method/path/query/header/body for every operation family;
- body snapshots proving no nested send payload is flattened into query items;
- permission matrix tests for both login modes and private reply's comment-scope
  distinction;
- reader/writer command availability and credential-mode rejection;
- confirmation happens before config resolution and before transport for every
  writer verb;
- quick reply, button, ice-breaker, HTTPS URL, empty-ID/text, human-agent, and
  strict input-file validation;
- no body, message text, recipient ID, token, or secret appears in diagnostics;
- private reply uses `recipient.comment_id`, not public comment
  `/<comment-id>/replies`;
- reaction uses `sender_action` plus typed payload;
- mark-seen/typing sender actions use a closed action enum and no message
  payload;
- uploaded-attachment send uses `attachment_id`; published-post send uses
  `MEDIA_SHARE` and an owned media ID;
- Meta prerequisite failures remain redacted and are not reported as successful
  live coverage;
- fake owned/self fixtures prove the live-test selector rejects absent,
  mismatched, or third-party IDs without any HTTP call.

## Documentation And Coverage Status

`docs/api-coverage.md` must separate these states per operation:

- `implemented_and_unit_tested`;
- `live_verified_owned_fixture`;
- `meta_prerequisite_blocked`;
- `not_live_tested_irreversible_write`;
- `excluded_parent_scope`.

It must list permissions, host/token variant, access level, App Review/Human
Agent requirements, consent/window rules, owned-media rule, Page/business role
requirements, and the exact reason a live check was skipped. README and setup
docs must never collapse code coverage and provider readiness into one checkmark.

## Design Review Record

### Self-review

Decision: `accepted_after_corrections`.

Addressed design findings:

- High: the initial feature contract did not resolve the current client's fixed
  `graph.facebook.com` host against Instagram Login messaging. Added an explicit
  login-mode/host/token contract with backward-compatible configuration.
- High: ordinary confirmation alone could have allowed workflow live checks to
  message third parties. Added a no-send/no-reaction/no-private-reply live rule,
  owned self-read fixtures, and reversible snapshot/restore rules for profile
  mutations.
- Mid: public comment reply and private reply could be confused because both use
  a comment ID. Added a dedicated DTO, command, permission family, JSON body,
  and test proving private reply targets `/<ig-user-id>/messages` with
  `recipient.comment_id`.
- Mid: code coverage could be mistaken for Meta readiness. Added per-operation
  provider-prerequisite statuses and explicit doctor semantics.

### Independent second-pass review

Decision: `accepted_after_corrections`.

Addressed design findings:

- Mid: outbound coverage originally omitted official message reaction,
  attachment-upload/reuse, and `HUMAN_AGENT` operations. Added typed inputs,
  commands, policy constraints, and deterministic tests.
- Mid: complex CLI payloads could have reintroduced an untyped provider escape
  hatch. Required strict decoding into public DTOs, unknown-key rejection, a
  size cap, and no host/credential/endpoint fields.
- Mid: Marketing/Ads exclusion was ambiguous for Welcome Message Flows. Marked
  that API family explicitly excluded because its documented purpose is
  advertising, while keeping non-ad messaging templates and ice breakers in
  scope.
- High: the first host correction still treated the Instagram user ID as the
  actor for all Facebook Login calls. Split actor routing so normal Facebook
  Login messaging uses the linked Page ID while private reply continues to use
  the Instagram user ID.
- Mid: Human Agent approval was conflated with scopes. Added a distinct
  `features` declaration and local feature check.
- Mid: proposed new public error cases could have broken exhaustive downstream
  switches. Reused existing stable error categories and moved prerequisite
  status to coverage documentation.
- Mid: official sender actions were absent from the operation list. Added typed
  mark-seen/typing-on/typing-off SDK and CLI operations, confirmation, request
  encoding, tests, and no-live-mutation treatment.

Remaining low findings: none.

## Risks

- Meta can rename permissions, move features between login products, or change
  payload limits after the documented check date.
- The configured sandbox may lack messaging permission, a linked/eligible
  account, app roles, Advanced Access, verified-business ownership, Human Agent
  approval, or an owned self conversation.
- Conversation reads expose private data; verification must not serialize live
  content into repository artifacts.
- Message details older than the provider's recent-message window and inactive
  Requests-folder threads may be unavailable even with valid code.
- Self messaging must be initiated in the app first and still produces
  irreversible history when sent through the API.
- Messenger Profile mutation rollback can fail after a successful mutation;
  live checks must skip unless original-state restoration is implementable and
  report cleanup failure prominently.
- Provider sample responses are occasionally inconsistent; tolerant typed
  decoding must not become a general raw-field escape hatch.
