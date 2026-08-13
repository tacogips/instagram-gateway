# Webhooks And Subscriptions Design

## Status

Accepted feature-local design for `instagram-webhooks` after self-review and a
separate independent review pass.

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference:
  `workflow-input:codex-design-and-implement-review-loop-session-695`
- Feature id: `instagram-webhooks`
- Feature title: Webhooks and subscriptions
- Requested design path: `docs/design/instagram-webhooks.md`
- Resolved design path: `design-docs/specs/instagram-webhooks.md`
- Implementation plan: `impl-plans/instagram-webhooks.md`
- Codex agent references: none

The worker contract requires design documents under `design-docs/` and
implementation plans under `impl-plans/`; the resolved paths follow the
repository's existing feature-document convention.

## Scope

This feature adds the reusable webhook boundary for the public Instagram
Platform APIs for professional accounts:

- typed decoding of Instagram change and messaging notifications
- verification of `X-Hub-Signature-256` against the exact received body bytes
- pure callback-challenge validation suitable for an HTTPS server adapter
- list, subscribe, and delete operations for the officially documented
  Instagram Login professional-account `subscribed_apps` edge
- permission-separated CLI commands for offline delivery verification/decoding
  and subscription management
- deterministic fixtures, request-construction tests, security tests, and
  prerequisite documentation

The implementation supports payloads produced by both Instagram Login and
Facebook Login where their documented notification envelopes differ. It does
not claim that the same programmatic subscription endpoint applies to both
login types.

## Non-Goals

- Running a public HTTP server, daemon, queue, or persistence layer.
- Provisioning a domain, TLS certificate, reverse proxy, or Meta App Dashboard.
- Registering the app-level callback URL or fields through undocumented API
  calls.
- Guaranteeing delivery order or exactly-once processing.
- Implementing Messaging Send API behavior; the messaging feature consumes
  the DTOs defined here.
- Subscribing Facebook Login/Page accounts through the Instagram Login-only
  professional-account edge.
- Logging full production payloads, signatures, app secrets, verify tokens, or
  attachment URLs.

## Official API Boundary

The current Meta Instagram API collection documents these professional-account
subscription operations for Instagram Login:

- `GET /{ig-user-id}/subscribed_apps`
- `POST /{ig-user-id}/subscribed_apps` with `subscribed_fields`
- `DELETE /{ig-user-id}/subscribed_apps`

The endpoint host is `graph.instagram.com` and the request uses the Instagram
user access token. The documented subscribable set currently includes
`messages`, `messaging_postbacks`, `messaging_seen`, `messaging_handover`,
`messaging_referral`, `message_reactions`, `standby`, `comments`,
`live_comments`, `mentions`, and `story_insights`.

The app-level callback URL, verify token, Instagram webhook object, and fields
must first be configured in the Meta App Dashboard. Facebook Login retains its
existing `graph.facebook.com` configuration and documented Dashboard/Page
installation flow; this feature will document that prerequisite instead of
routing it through the Instagram Login edge.

Primary references:

- `https://www.postman.com/meta/instagram/collection/6yqw8pt/instagram-api`
- `https://www.postman.com/meta/instagram/request/23987686-0223707a-7035-46a2-8015-1fdf7249278f`
- `https://www.postman.com/meta/instagram/request/23987686-27309084-5d59-42b6-9b81-379cf9b1e61d`
- `https://www.postman.com/meta/instagram/request/23987686-3007ee3f-182d-48f9-9942-eb61f1ab106e`
- `https://www.postman.com/meta/instagram/folder/23987686-5049585f-09b2-4775-a11a-debe5956e09a`
- `https://www.postman.com/meta/messenger-platform-api/folder/22794852-b5d97624-14d8-4e67-a2e4-529add49ca58`

Exact fields, permissions, access levels, and endpoint versions remain
provider-controlled and must be rechecked during implementation and live
verification.

## Module And Public API Shape

Webhook types stay in `InstagramGatewayCore`; HTTP-server frameworks remain
outside the package. The intended public surface is additive:

```swift
public struct InstagramWebhookDecoder: Sendable {
  public func decode(_ body: Data) throws -> InstagramWebhookEnvelope
  public func verifyAndDecode(
    _ body: Data,
    signatureHeader: String,
    appSecret: Data
  ) throws -> InstagramWebhookEnvelope
}

public struct InstagramWebhookSignatureVerifier: Sendable {
  public func verify(
    body: Data,
    signatureHeader: String,
    appSecret: Data
  ) throws
}

public struct InstagramWebhookChallengeValidator: Sendable {
  public func validate(
    mode: String?,
    verifyToken: String?,
    challenge: String?,
    expectedVerifyToken: String
  ) throws -> String
}

public struct InstagramWebhookSubscriptionService: Sendable {
  public func list(accountId: String) async throws -> Page<WebhookSubscription>
  public func subscribe(
    accountId: String,
    fields: Set<InstagramWebhookField>
  ) async throws -> WebhookSubscriptionMutationResult
  public func delete(accountId: String) async throws -> WebhookSubscriptionMutationResult
}
```

`InstagramWebhookSubscriptionService` uses an injected
`InstagramGatewayClient` whose transport base URL is explicitly
`https://graph.instagram.com/{api-version}`. It does not silently switch an
existing Facebook Login client to a different host. CLI construction validates
that the selected credential declares Instagram Login before issuing a request.

## Credential And Host Selection

Add an unknown-preserving `InstagramLoginType` with documented cases
`facebookLogin` and `instagramLogin`. Extend `CredentialProfile` and TOML with
an optional `login_type`; omitting it defaults to `facebook_login` to preserve
the existing public initializer and checked-in configuration behavior.

Transport selection becomes profile-aware:

- `facebook_login` -> `https://graph.facebook.com/{api-version}`
- `instagram_login` -> `https://graph.instagram.com/{api-version}`

The subscription service rejects `.facebookLogin` and unknown login types with
`unsupportedOperation` before network access. This avoids presenting an
Instagram Login subscription edge as a supported Facebook Login operation.
Payload verification and decoding are login-type independent.

## Typed Notification Model

The root payload is modeled without erasing provider values:

```swift
public struct InstagramWebhookEnvelope: Codable, Equatable, Sendable {
  public var object: InstagramWebhookObject
  public var entries: [InstagramWebhookEntry]
}

public struct InstagramWebhookEntry: Codable, Equatable, Sendable {
  public var id: String
  public var time: Int64?
  public var changes: [InstagramWebhookChange]
  public var messaging: [InstagramMessagingEvent]
}
```

The decoder normalizes both documented change forms:

- `entry.changes[]` containing `field` and `value`
- legacy/direct `entry.field` and `entry.value`

The model uses unknown preservation rather than lossy rejection:

- `InstagramWebhookObject`: `.instagram`, `.page`, `.unknown(String)`
- `InstagramWebhookField`: all documented subscription fields plus
  `.unknown(String)`
- `InstagramWebhookChangeValue`: typed comment/live-comment, mention, and
  story-insights values plus `.unknown(field:raw:)`
- `InstagramMessagingPayload`: message, postback, reaction, seen/read,
  referral, handover, standby, message-edit, and `.unknown(raw:)`
- provider-owned ids, usernames, text, URLs, payload strings, cursors, and
  timestamps remain provider values rather than local enums
- attachment and media types use unknown-preserving enums

Comment values include the comment id, actor id/username/self-scoped id, text,
media id, and media product/location metadata when present. Mention values keep
the mentioned media/comment identifiers and text supplied by Meta. Messaging
values include sender, recipient, timestamp, message id, text, echo/self/deleted
flags, quick-reply/referral/reply-to data, attachments, postback, reaction,
seen, and message-edit data where present.

Unknown keys required for forward compatibility are retained as `JSONValue`
only inside explicitly named `extensions` properties. They are never included
in diagnostic descriptions. Public DTOs provide explicit initializers and are
`Codable`, `Equatable`, and `Sendable`.

## Signature Verification

The security boundary operates on `Data`, not parsed JSON or a re-encoded
string:

1. Require exactly the `sha256=<64 hex characters>` scheme.
2. Decode the supplied digest without normalizing the payload.
3. Compute HMAC-SHA256 over the exact request body bytes using the Meta app
   secret.
4. Compare expected and supplied digest bytes with a constant-time routine that
   does not exit early on a mismatching byte.
5. Reject missing, duplicate/combined, malformed, wrong-algorithm, wrong-length,
   or mismatched signatures before JSON decoding or side effects.

The package currently targets macOS 14, so the implementation uses CryptoKit's
HMAC-SHA256 primitive and a locally reviewed constant-time byte comparison. No
secret, body, digest, or computed HMAC appears in errors. Signature failures map
to a dedicated safe `webhookSignatureInvalid` error code or an equivalently
stable typed error added without changing existing cases.

`decode(_:)` remains public for deterministic fixture inspection. Production
callback documentation and the default CLI path use `verifyAndDecode`; unsigned
decode requires the explicit `--allow-unsigned` CLI acknowledgement.

## Callback Challenge Validation

The SDK exposes a pure adapter for Meta's verification GET request. It accepts
the raw values for `hub.mode`, `hub.verify_token`, and `hub.challenge`, requires
mode `subscribe`, compares the supplied and configured verify tokens without an
early-exit byte comparison, and returns the challenge unchanged. It never logs
or returns either token.

The verify token is distinct from the Meta app secret. Add an optional
`webhook_verify_token_ref` to credential configuration, resolved through the
existing env/kinko secret mechanism. Literal examples remain prohibited.

## Callback Deployment Prerequisites

Documentation must state that production delivery requires all of the
following external state:

- a publicly reachable HTTPS callback with a valid CA-issued certificate;
  self-signed certificates are unsupported
- a GET handler that validates the verify token and returns `hub.challenge`
- a POST handler that retains exact raw bytes, validates the signature before
  parsing, and acknowledges valid deliveries with HTTP 200 within Meta's
  documented response window
- fast acknowledgement plus asynchronous durable processing for workloads that
  may exceed the callback deadline
- idempotency/deduplication, retry handling, and timestamp-based ordering
  because deliveries can be retried or arrive out of order
- App Dashboard webhook object/field configuration and installation on the
  owned professional account/Page
- Standard Access only for app-role accounts; Advanced Access/App Review for
  notifications involving non-role accounts
- the permissions and account eligibility required by the subscribed field,
  including messaging or comment permissions where applicable

The SDK does not store notifications, and Meta does not provide this feature a
historical-notification retrieval fallback. Consumers own durable capture and
retention policy.

## Subscription DTOs And Validation

```swift
public struct WebhookSubscription: Codable, Equatable, Sendable {
  public var appId: String
  public var subscribedFields: [InstagramWebhookField]
}

public struct WebhookSubscriptionMutationResult: Codable, Equatable, Sendable {
  public var success: Bool
}
```

Outbound subscribe validation requires a nonempty set containing only fields
known to be officially subscribable for the selected API version. Unknown
values decode from provider responses but cannot be sent. Fields are serialized
in deterministic raw-value order for repeatable requests and tests.

`GET` returns the provider page envelope. `POST` and `DELETE` decode the
provider `success` response. Delete removes the app's professional-account
webhook subscription and is treated as destructive because it stops delivery.

## Permission-Separated CLI

Reader-only, offline/read operations:

```text
instagram-gateway-reader webhooks verify-decode \
  --body-file <path> --signature <sha256=hex>
instagram-gateway-reader webhooks decode \
  --body-file <path> --allow-unsigned
instagram-gateway-reader webhooks subscriptions list --account <ig-id>
```

Writer-only subscription mutations:

```text
instagram-gateway-writer webhooks subscriptions subscribe \
  --account <ig-id> --fields <csv> --yes
instagram-gateway-writer webhooks subscriptions delete \
  --account <ig-id> --yes
```

Rules:

- `verify-decode` resolves the app secret from the selected credential's
  `app_secret_ref`; there is no `--app-secret` argument.
- The signature is accepted as metadata but never echoed in output or errors.
- Body files are bounded by a documented maximum before allocation/decoding.
- Unsigned decoding is visibly opt-in and intended for checked-in fixtures.
- Reader rejects subscription mutations before credential resolution or
  network access.
- Writer requires a write credential and `--yes` for both subscribe and delete;
  delete receives an explicit message that delivery will stop.
- List is available only from the reader, maintaining the binary boundary.
- JSON output uses the existing success/error envelopes and redaction layer.

## Error And Privacy Behavior

Add stable failures for malformed payload, unsupported root object, invalid
signature, challenge rejection, oversized body, unsupported login type, and
invalid outbound subscription fields. Errors may name a safe field or coding
path but must not interpolate payload values, attachment URLs, message text,
tokens, secrets, signatures, or raw decoder diagnostics that contain them.

Webhook bodies can contain third-party messages, usernames, and media URLs.
CLI output is therefore deliberate command output, not a diagnostic log.
Doctor, debug descriptions, test failure helpers, stderr, and request tracing
must never dump a body. Tests use synthetic owned fixtures only.

## Testing Strategy

Deterministic tests cover:

- envelope decoding for `changes[]` and direct `field`/`value` forms
- comments, live comments, mentions, story insights, messages, echo/self
  messages, attachments, quick replies, referrals, reactions, postbacks, seen,
  handover/standby, message edits, and unknown field/payload preservation
- known and unknown object, field, attachment, and media enum values
- correct HMAC, one-byte body mutation, wrong secret, missing/malformed prefix,
  invalid hex, wrong digest length, and mixed-case hex handling
- a fixed independently generated HMAC-SHA256 vector and raw UTF-8/escaped
  Unicode byte variants proving no JSON re-encoding occurs
- constant-time comparison instrumentation that processes every byte for equal
  length candidates; code review remains required because wall-clock timing
  assertions are nondeterministic
- challenge success and all missing/mismatch cases without token leakage
- list/subscribe/delete request method, path, sorted fields, bearer header, host
  choice, response decoding, and preflight rejection for Facebook Login
- reader/writer routing, confirmation gates, unsigned opt-in, body size limit,
  stable JSON, and secret/body/signature redaction

Live checks are limited to the configured owned taco development professional
account. Listing is safe. Subscribe is an owned reversible write and may run
only when the callback and Instagram Login prerequisites exist. Delete runs
only when the test created or explicitly owns the subscription and restoration
is guaranteed. Provider-blocked checks are recorded as blocked, never passed.

## Documentation And Coverage

Update `README.md`, `docs/meta-setup.md`, `docs/live-smoke-tests.md`, and
`docs/api-coverage.md` to separate:

- SDK/CLI code coverage
- public callback/TLS deployment state
- App Dashboard object/field configuration
- login type, token type, permissions, Standard versus Advanced Access, and App
  Review status
- owned-account subscription state and available delivery fixtures
- deterministic verification from live provider verification

Coverage may become `Yes` only after SDK, correct binary commands, and
deterministic tests exist. Live delivery remains separately marked unverified or
blocked until Meta can reach a qualifying callback and an owned event fixture
is available.

## Design Review Record

### Self-review

Decision: `accept-after-fixes`.

Design defects found and addressed:

- **Mid:** The initial concept treated `subscribed_apps` as login-type neutral.
  Fixed by limiting programmatic professional-account subscription management
  to the documented Instagram Login edge and making host/login selection
  explicit.
- **Mid:** A generic `decode` entry point could encourage parsing before
  authentication. Fixed by making `verifyAndDecode` the production and default
  CLI path, while unsigned decode requires explicit acknowledgement.
- **Mid:** The proposed CLI could have accepted an app secret on the command
  line. Fixed by resolving `app_secret_ref` only through existing env/kinko
  configuration.

### Independent review pass

Decision: `accept-after-fixes`.

Design defects found and addressed:

- **High:** Signature verification did not explicitly require exact pre-parse
  bytes. Fixed by defining raw `Data` as the security boundary and rejecting
  before decoding or side effects.
- **Mid:** The first payload model covered only `changes[]` and would reject a
  documented direct `field`/`value` variant. Fixed with normalization of both
  forms and unknown preservation.
- **Mid:** Subscription deletion could stop production delivery without the
  existing destructive gate. Fixed by assigning mutations to the writer and
  requiring `--yes`, owned targets, and restoration for live tests.
- **Mid:** Callback success criteria omitted retries, ordering, and response
  timing. Fixed in the callback prerequisite contract and testing strategy.

No unresolved high or mid design findings remain.

## Risks

- Meta can change webhook fields, payload variants, permissions, and access
  review requirements by Graph API version.
- Existing configured credentials default to Facebook Login; the documented
  Instagram Login subscription edge may be unavailable to the sandbox until a
  separate eligible credential is provisioned.
- No deterministic timing test can prove constant-time execution on every
  optimizer/CPU; use a fixed-work comparison, deterministic iteration tests,
  and security review.
- Real comment, mention, and message deliveries require owned fixtures and, for
  non-role accounts, Advanced Access/App Review.
- Callback deployment and durable deduplication are external prerequisites and
  are intentionally not supplied by this CLI package.
