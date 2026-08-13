# Implementation Plan: Messaging And Private Replies

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
- Requested plan path: `docs/plans/instagram-messaging.md`
- Canonical plan path: `impl-plans/instagram-messaging.md`
- Accepted design: `design-docs/specs/instagram-messaging.md`
- Codex agent references: none

The requested path is normalized to the repository's established `impl-plans/`
layout, as required by the workflow instruction that implementation plans remain
under `impl-plans/`.

## Decision Status

Accepted for implementation. Plan self-review and an independent second-pass
review found no unaddressed high- or mid-severity findings. Implementation has
not started in this planning worker.

## Objective

Implement typed Instagram professional-account conversation reads, message
sends, reactions, private replies, message attachment reuse, messaging-profile
configuration, permission/login-mode routing, permission-separated CLI
commands, deterministic fixtures, and safety documentation from the accepted
design without messaging third parties or claiming Meta-controlled readiness.

## Accepted Design Decisions

- Instagram Login uses `graph.instagram.com` and an Instagram User token.
- Facebook Login uses `graph.facebook.com` and a linked Page token for normal
  messaging; normal DM/conversation/profile endpoints use the Page actor, while
  private reply remains an Instagram-user-owned endpoint.
- Reader CLI owns non-mutating conversation, message, profile, ice-breaker, and
  persistent-menu reads. Writer CLI owns every mutation.
- Nested payloads are strict typed JSON bodies; no messaging `providerFields`
  escape hatch is permitted.
- Normal messages, reactions, private replies, and attachment uploads are not
  live-tested in this workflow because they are irreversible. Safe live reads
  use owned self fixtures only. Messenger Profile mutations are optional and
  require snapshot/restore.
- Welcome Message Flows are an explicit parent-scope exclusion because their
  documented purpose is advertising.
- Existing public error cases are reused; external readiness is expressed in
  coverage status rather than new public error enum cases.

## Deliverables

1. Backward-compatible login-mode, feature, and host routing.
2. Public typed messaging DTOs and service methods.
3. Reader commands for conversations, messages, messaging profiles, ice
   breakers, and persistent menus.
4. Writer commands for message variants, reactions, mark-seen/typing sender
   actions, private replies, attachment upload/reuse, and Messenger Profile
   mutations.
5. Central permission and Human Agent feature enforcement.
6. Confirmation, strict payload, privacy, and live-fixture safety checks.
7. Synthetic unit/integration fixtures covering every implemented operation.
8. README, setup, live-test, and per-operation API-coverage updates.
9. Passing `swift test` and release build, plus explicit Meta-blocked/live-skipped
   records.

## Dependencies

- Existing `InstagramGatewayCore`, `InstagramGatewayCLI`, reader, and writer
  targets.
- Existing injected `HTTPTransport`, redactor, `Page`, `Paging`, JSON envelope,
  access-mode, and confirmation behavior.
- Webhook feature for production receipt of IGSIDs, comment IDs, messaging
  events, and self-fixture discovery. Deterministic messaging implementation is
  not blocked by the webhook feature because tests use synthetic IDs.
- Configured Meta app/account/token outside source control for optional live
  reads.
- Meta external prerequisites: correct login product, permissions, account/Page
  roles, access level, App Review, business verification where required,
  consent, active policy window, and owned fixtures.

No external prerequisite blocks deterministic implementation or release-build
verification.

## Progress Tracking

- [x] P1 Revalidate official endpoint and permission assumptions.
- [x] P2 Add backward-compatible config and host routing.
- [x] P3 Add public typed DTOs, validation, and JSON body encoding.
- [x] P4 Implement conversation/message/profile reader services.
- [x] P5 Implement send/reaction/private-reply/attachment writer services.
- [x] P6 Implement ice-breaker and persistent-menu services.
- [x] P7 Add permission-separated CLI command trees and strict input files.
- [x] P8 Add permission, confirmation, privacy, and third-party safety guards.
- [x] P9 Add deterministic SDK and CLI tests with synthetic fixtures.
- [x] P10 Update README and coverage/setup/live-verification docs.
- [x] P11 Run deterministic verification and resolve regressions.
- [x] P12 Record live verification as blocked/skipped; controlled credentials,
  permissions, and owned fixtures are unavailable.
- [x] P13 Review the final diff for public-contract and scope safety.

Each item is checked only after its completion criteria and verification are
satisfied. Meta-blocked live checks remain unchecked only if code work is also
incomplete; otherwise P12 is complete with an explicit
`meta_prerequisite_blocked` or `not_live_tested_irreversible_write` record.

## Implementation Tasks

### P1. Revalidate Official Contracts

Files:

- `design-docs/specs/instagram-messaging.md`
- `docs/api-coverage.md`

Actions:

1. Compare the accepted operation list with the official Meta Instagram and
   Messenger Platform collections for the repository's pinned Graph version.
2. Confirm actor IDs, host, token type, fields, JSON keys, limits, permission
   names, Human Agent requirements, and policy windows for both login modes.
3. Record the check date and direct primary-source links.
4. If Meta has changed a contract, revise this feature's design and plan before
   code; do not silently implement a materially different API.

Completion criteria:

- Every in-scope operation has a dated primary-source reference.
- Welcome Message Flows remains `excluded_parent_scope`, not `missing`.
- Unverified or contradictory samples are called out and covered with tolerant
  decoding rather than guessed fields.

### P2. Add Backward-Compatible Config And Host Routing

Files:

- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`
- `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift`
- `Tests/InstagramGatewayCoreTests/CoreTests.swift`
- `Tests/Fixtures/reader-valid.toml`
- `Examples/config.placeholder.toml`

Actions:

1. Add public `InstagramLoginMode` with `.facebook` and `.instagram`.
2. Add `loginMode` and declared `features` to `CredentialProfile`; append
   defaulted initializer parameters so current source calls continue compiling.
3. Parse optional `login_mode` and `features` TOML keys. Omission defaults to
   `.facebook` and an empty feature list.
4. Add a shared base-URL factory for the pinned version. It accepts the typed
   login mode, never a CLI-provided URL.
5. Change the CLI runtime's default transport closure to construct the correct
   host from the selected profile while preserving injected transports in
   tests.
6. Centralize actor resolution:
   - Instagram Login normal messaging actor: `instagramUserId`;
   - Facebook Login normal messaging actor: `pageId`;
   - private reply actor for both modes: `instagramUserId`.
7. Fail before transport when a required actor ID is absent.
8. Extend doctor output with login mode, declared features, missing
   operation-specific prerequisites, and
   `providerVerification: "not_performed"`; never imply the configured strings
   prove access.

Completion criteria:

- Existing configs and public initializer call sites still compile and retain
  Facebook-host behavior.
- Both hosts and all actor routes have deterministic tests.
- No command can inject or override a base URL.

### P3. Add Typed DTOs, Validation, And Body Encoding

Files:

- `Sources/InstagramGatewayCore/InstagramMessaging.swift`
- `Tests/InstagramGatewayCoreTests/InstagramMessagingTests.swift`
- `Tests/Fixtures/Messaging/Responses/`
- `Tests/Fixtures/Messaging/Requests/`

Actions:

1. Add public conversation, message summary/detail, participant, attachment,
   messaging profile, send receipt, attachment receipt, and mutation DTOs.
2. Add public input enums/structs for text, URL media, uploaded image,
   published post, heart sticker, quick replies, generic templates, button
   templates, reactions, Human Agent, private replies, ice breakers, and
   persistent menus.
3. Implement explicit snake-case coding keys and custom associated-enum
   encoding. Provider response enums retain unknown values; input enums do not.
4. Add an internal JSON request encoder that sets
   `Content-Type: application/json` and places bytes in `HTTPRequest.body`.
5. Add nested conversation-messages response adapters so Meta's
   `{messages:{data,paging}}` response becomes the public `Page` contract.
6. Validate IDs/text, absolute HTTPS media URLs, 13 quick-reply maximum,
   20-character quick-reply titles, 3 button-template maximum, 4 ice-breaker
   maximum, image-only upload, owned-post ID presence, and Human Agent
   text-only use before transport.
7. Keep `InstagramSendReceipt` tolerant of optional `recipient_id`,
   `message_id`, and inconsistent documented `flow_id` responses without
   exposing a raw provider dictionary.

Completion criteria:

- All public DTOs are `Codable`, `Equatable`, and `Sendable`.
- No messaging input exposes `providerFields`, arbitrary JSON, endpoint, host,
  token, or credential fields.
- Request snapshot tests prove nested payloads are body JSON and secrets are not
  present.

### P4. Implement Reader Services

Files:

- `Sources/InstagramGatewayCore/InstagramMessaging.swift`
- `Tests/InstagramGatewayCoreTests/InstagramMessagingTests.swift`

Actions:

1. Extend `InstagramReaderService` with list/find conversations.
2. Add message-summary listing and message-detail lookup with the documented
   fields and nested paging adapter.
3. Add messaging-profile lookup by IGSID.
4. Add ice-breaker and persistent-menu reads through Messenger Profile API.
5. Reuse `Paging.redacted`; never return token-bearing paging URLs unredacted.
6. Treat optional/missing provider fields as optional, but do not hide malformed
   required IDs.

Completion criteria:

- Exact paths differ correctly for Instagram and Facebook Login actors.
- List/find and nested paging have synthetic success/empty/error tests.
- Provider limitations for recent messages and inactive Requests conversations
  are documented rather than converted to false empty-success claims.

### P5. Implement Writer Messaging Services

Files:

- `Sources/InstagramGatewayCore/InstagramMessaging.swift`
- `Tests/InstagramGatewayCoreTests/InstagramMessagingTests.swift`

Actions:

1. Implement send JSON for text; image/GIF, audio, and video URLs; uploaded image
   attachment ID; owned `MEDIA_SHARE` post; heart sticker; quick replies;
   generic template; and button template.
2. Add optional typed `HUMAN_AGENT` tag only for text requests.
3. Implement reaction/unreaction with `sender_action`, message ID, and typed
   `love` payload.
4. Implement closed mark-seen, typing-on, and typing-off sender actions.
5. Include the documented `messaging_type: "RESPONSE"` for Facebook Login
   normal responses where required; do not add it to Instagram Login payloads
   without current primary-source support.
6. Implement image attachment upload with `is_reusable` and typed receipt.
7. Implement private reply at the Instagram account's `/messages` endpoint with
   `recipient.comment_id` and `message.text`.
8. Keep public comment reply (`/<comment-id>/replies`) unchanged and distinct.
9. Map provider errors through the existing redacted error categories.

Completion criteria:

- Each variant has an exact body snapshot and host/actor test.
- Private-reply tests fail if the implementation targets the public comment
  reply endpoint or requires messaging permissions instead of comment
  permissions.
- No SDK call claims to validate consent/window eligibility locally.

### P6. Implement Messenger Profile Mutations

Files:

- `Sources/InstagramGatewayCore/InstagramMessaging.swift`
- `Tests/InstagramGatewayCoreTests/InstagramMessagingTests.swift`

Actions:

1. Implement typed set/delete ice breakers.
2. Implement typed set/delete persistent menu.
3. Encode `platform=instagram`, locale containers, postback actions, and HTTPS
   web actions exactly as documented.
4. Validate limits and nonempty payload/title/question values before transport.
5. Return typed mutation results and preserve unknown response fields by
   ignoring them, not exposing them.

Completion criteria:

- GET/POST/DELETE request tests cover both login modes.
- Invalid configuration sends no HTTP request.
- Delete targets only the selected Messenger Profile field and does not delete
  the entire account/app subscription.

### P7. Add Permission-Separated CLI Commands

Files:

- `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift`
- `Tests/InstagramGatewayCLITests/InstagramMessagingCLITests.swift`
- `Tests/Fixtures/Messaging/Inputs/`

Actions:

1. Add the accepted `messaging` reader command tree and help text.
2. Add the accepted writer send, reaction, sender-action, private-reply,
   attachment, ice-breaker, and persistent-menu command tree and help text.
3. Use flags for simple payloads and `--input <path>` for quick replies and
   template/profile payloads.
4. Add a strict input loader capped at 256 KiB. Validate top-level and nested key
   allowlists before decoding because Swift's default decoder ignores unknown
   keys. Do not echo file contents in errors.
5. Resolve account/Page actors from the selected credential plus explicit
   account option according to P2; never accept host or token flags.
6. Emit the existing sorted JSON envelopes.

Completion criteria:

- Writer verbs are absent/rejected in the reader; read-only messaging verbs are
  not silently routed to writer mutations.
- Unknown, oversized, malformed, or policy-incompatible input fails before
  transport with redacted structured JSON.
- CLI tests cover every leaf command, help, required flags, and output shape.

### P8. Add Permission, Confirmation, Privacy, And Safety Guards

Files:

- `Sources/InstagramGatewayCore/InstagramMessaging.swift`
- `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift`
- `Tests/InstagramGatewayCoreTests/InstagramMessagingTests.swift`
- `Tests/InstagramGatewayCLITests/InstagramMessagingCLITests.swift`

Actions:

1. Add a centralized operation-to-permission matrix for both login modes.
2. Check declared OAuth scopes before transport and the separately declared
   `human_agent` feature when tagged.
3. Require `--yes` for every send, reaction, sender action, private reply,
   upload, set, and delete before loading config. Expand the current early
   writer-verb detector without changing read-only container-status behavior.
4. Ensure errors/debug descriptions never include request bodies, DM text,
   template payloads, recipient IDs, comment IDs, profile data, tokens, or app
   secrets.
5. Add synthetic owned/self fixture policy tests that reject absent/mismatched
   live fixture metadata before an HTTP request.
6. Keep live fixture environment/kinko names in docs only; never commit real
   IDs or payloads.
7. Ensure normal product commands remain usable for consented customer
   conversations while this workflow's verification harness refuses
   third-party targets.

Completion criteria:

- Missing confirmation, scope, feature, actor, or fixture metadata produces no
  request.
- Normal messaging permissions do not authorize private reply and comment
  permissions do not authorize normal DM.
- Redaction/privacy tests search stdout, stderr, diagnostics, and error text.

### P9. Add Deterministic Tests And Fixtures

Files:

- `Tests/InstagramGatewayCoreTests/InstagramMessagingTests.swift`
- `Tests/InstagramGatewayCLITests/InstagramMessagingCLITests.swift`
- `Tests/Fixtures/Messaging/`

Actions:

1. Add only fabricated IDs, names, URLs, text, and provider errors.
2. Cover every DTO, operation, login mode, permission family, actor selection,
   and CLI leaf.
3. Cover empty pages, optional fields, unknown response enum cases,
   token-bearing paging links, non-2xx errors, and inconsistent send receipts.
4. Assert request method/path/query/header/body and that authorization is sent
   only through the injected client.
5. Assert confirmation and all validation failures leave
   `RecordingHTTPTransport.requests` empty.
6. Add regressions for private-vs-public reply, Page-vs-IG actor routing,
   `HUMAN_AGENT` feature separation, and no `providerFields`.

Completion criteria:

- Tests are network-free, deterministic, and parallel-safe.
- Fixture search finds no real token pattern, email address, account identifier,
  or live conversation content.
- Full existing tests continue to pass.

### P10. Update Documentation And Coverage

Files:

- `README.md`
- `docs/api-coverage.md`
- `docs/meta-setup.md`
- `docs/live-smoke-tests.md`
- `Examples/config.placeholder.toml`

Actions:

1. Document both login variants, hosts, token types, actor IDs, and permission
   matrices.
2. Document consent, normal 24-hour, Human Agent 7-day, private reply 7-day/Live,
   one-private-reply, owned-media, attachment TTL, and inactive Requests/recent
   message limitations.
3. Add reader/writer command examples with placeholders only.
4. Add safe kinko/environment names:
   `INSTAGRAM_GATEWAY_META_SANDBOX_SELF_IGSID`,
   `INSTAGRAM_GATEWAY_META_SANDBOX_SELF_CONVERSATION_ID`, and
   `INSTAGRAM_GATEWAY_META_SANDBOX_SELF_MESSAGE_ID`.
5. Add per-operation coverage rows using only:
   `implemented_and_unit_tested`, `live_verified_owned_fixture`,
   `meta_prerequisite_blocked`, `not_live_tested_irreversible_write`, or
   `excluded_parent_scope`.
6. Mark Welcome Message Flows excluded and explain the parent Ads boundary.
7. State that webhook receipt/subscription/signature work is tracked by the
   webhook feature.

Completion criteria:

- No doc claims App Review, Advanced Access, Human Agent approval, consent,
  fixture availability, or live success without evidence.
- Secret values and live customer data are absent.
- Every operation maps to code status, prerequisites, and live status.

### P11. Run Deterministic Verification

Required commands from the repository root:

```bash
swift test --filter InstagramMessaging
swift test
swift build -c release
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
git diff --check
```

Required structural checks:

```bash
rg -n "messaging|private-reply|human-agent|ice-breakers|persistent-menu" Sources Tests README.md docs
rg -n "instagram_business_manage_messages|instagram_manage_messages|instagram_business_manage_comments|instagram_manage_comments" Sources Tests docs
```

Review `Sources/InstagramGatewayCore/InstagramMessaging.swift` manually to prove
there is no `providerFields` property and review all messaging request snapshots
to prove body-only nested payloads. Do not turn the absence check into a command
whose expected no-match exit code is mistaken for a failed build.

Completion criteria:

- All required commands pass.
- Release binaries contain the correct separate help surfaces.
- No unrelated user changes are modified.
- Any unavailable optional tool is recorded as not configured, not as passed.

### P12. Run Eligible Owned Live Verification

Preflight, without printing values:

1. Resolve the configured `taco-dev-sandbox` profile through kinko/environment.
2. Verify account ownership/app role and the selected login mode.
3. Verify messaging permissions or record the exact Meta prerequisite block.
4. Use only a self-messaging IGSID/conversation/message obtained from an
   `is_self` webhook or an explicitly owned secondary test account.
5. Confirm no output will be persisted to fixtures, docs, commits, or issue
   comments.

Allowed live reads:

- find the owned self conversation;
- list its message metadata;
- fetch one owned self message transiently;
- fetch the owned self messaging profile;
- get current ice breakers and persistent menu.

Conditionally allowed reversible writes:

- set and restore an owned temporary ice-breaker configuration;
- set and restore an owned temporary persistent-menu configuration.

The reversible write runner must capture exact original JSON in memory, install
temporary state, verify it, restore original state, and verify restoration in a
defer/finally cleanup path. If any of these capabilities is missing, do not
mutate and record `meta_prerequisite_blocked`.

Forbidden live operations for this workflow:

- text/media/template/sticker/published-post/Human Agent send;
- react or unreact;
- mark seen, typing on, or typing off;
- private reply;
- attachment upload;
- any third-party conversation, profile, message, comment, or media access;
- any operation that cannot restore original state.

Completion criteria:

- Each safe live read is either `live_verified_owned_fixture` with date and
  non-sensitive evidence, or `meta_prerequisite_blocked` with the exact external
  prerequisite.
- Irreversible operations are
  `not_live_tested_irreversible_write`, not failed and not passed.
- Any profile mutation ends with verified restoration; cleanup failure is
  reported immediately and the feature is not accepted as live-clean.

### P13. Final Scope And Contract Review

Files:

- all files changed by P1-P12

Actions:

1. Review the diff against `design-docs/specs/instagram-messaging.md`.
2. Confirm public initializers remain source-compatible and public types meet
   `Codable`/`Equatable`/`Sendable` requirements.
3. Confirm reader/writer separation, exact permission matrices, actor routing,
   confirmation ordering, strict payload handling, and coverage statuses.
4. Confirm no Ads/Marketing, webhook server/signature implementation, Threads,
   or unrelated publishing work entered the diff.
5. Confirm all real credentials, private IDs, and live message/profile data are
   absent.
6. Hand the accepted feature changes to the parent workflow for combined review,
   commit, and push after repository-wide checks pass.

Completion criteria:

- No high- or mid-severity review finding remains.
- Design, plan, code, tests, docs, and recorded verification agree.
- Commit/push occurs only in the parent integration path, not this planning
  worker.

## Verification Matrix

| Operation family | Deterministic verification | Permitted live verification |
| --- | --- | --- |
| conversations/messages/profile | fixtures, path/body/DTO/CLI tests | owned self reads only |
| text/media/sticker/post/template sends | body/permission/confirmation tests | no; irreversible |
| reaction/unreaction | body/permission/confirmation tests | no; irreversible |
| mark-seen/typing sender actions | action/permission/confirmation tests | no; user-visible state/UI mutation |
| Human Agent | tag/feature/policy/confirmation tests | no; irreversible and approval-gated |
| private reply | endpoint/body/comment-scope/confirmation tests | no; one-shot irreversible |
| attachment upload/reuse | endpoint/body/TTL/confirmation tests | no; provider asset persists |
| ice breakers/persistent menu reads | endpoint/DTO/CLI tests | owned account reads |
| ice breakers/persistent menu mutations | POST/DELETE/validation/confirmation tests | only snapshot-set-restore with verified cleanup |

## Completion Criteria

### Step 6 rerun update — 2026-08-13

- Implemented the shared operation-to-permission policy for Instagram Login
  and Facebook Login in both reader and writer SDK service boundaries; CLI
  preflight reuses the same policy. Missing, unknown, and mismatched login
  contexts reject before transport.
- Added typed conversation lookup by Instagram-scoped user ID and
  consent-gated messaging-user profile lookup, with reader CLI leaves.
- Added typed uploaded-image reuse, owned `MEDIA_SHARE`, heart-sticker, and
  quick-reply sends plus strict quick-reply input validation and writer CLI
  options. `MEDIA_SHARE` requires an explicitly declared
  `owned_messaging_media_fixture` feature before transport.
- Updated coverage documentation for implemented private replies and the
  accepted Facebook Login scope matrix. Deterministic tests now cover 60 cases;
  `swift test` passed on 2026-08-13. Provider-dependent live checks remain
  `META_BLOCKED` because controlled credentials, permissions, callbacks,
  catalogs, and owned fixtures are unavailable.

- All in-scope official operations from the accepted design have public typed
  DTOs and service methods.
- All nested messaging requests use JSON bodies and no `providerFields` escape
  hatch.
- Both login variants route to the correct host and actor without breaking
  current configs/callers.
- Permission and Human Agent feature checks are centralized, operation-specific,
  and tested.
- Reader and writer command surfaces remain separate; every mutation requires
  `--yes` before config or transport.
- Tests cover request construction, decoding, validation, redaction/privacy,
  command routing, actor selection, and provider errors with synthetic fixtures.
- `swift test` and `swift build -c release` pass.
- README and `docs/api-coverage.md` distinguish code coverage, live status, and
  Meta prerequisites per operation.
- No third party is messaged or inspected during live checks; no irreversible
  messaging write is live-tested.
- Any live profile mutation is restored exactly or acceptance is withheld.
- No high- or mid-severity design or plan finding remains.

## Plan Review Record

### Self-review

Decision: `accepted_after_corrections`.

Addressed plan-only findings:

- High: the initial sequence could have added messaging services before the
  host/actor abstraction, risking requests to the wrong graph host. Moved
  backward-compatible login-mode, base-URL, and actor routing to P2 and made all
  later service work depend on it.
- Mid: Swift `JSONDecoder` normally ignores unknown keys, so saying input files
  were typed did not enforce the design. Added explicit recursive key-allowlist
  validation, size cap, and no-echo requirements in P7.
- Mid: confirmation coverage listed sends but not every profile/attachment
  mutation. P8 now enumerates all mutation families and requires confirmation
  before config resolution.
- Mid: the initial live section treated self messaging as sufficient safety but
  did not account for irreversible history. P12 now forbids all live sends,
  reactions, private replies, and uploads even for self fixtures.

### Independent second-pass review

Decision: `accepted_after_corrections`.

Addressed plan-only findings:

- High: Facebook Login normal messaging and private reply require different
  actors. Added a centralized actor resolver, explicit missing-Page failure, and
  regressions for Page-vs-Instagram actor selection.
- Mid: reversible Messenger Profile checks lacked rollback acceptance criteria.
  Added in-memory snapshot, defer/finally restoration, restoration verification,
  and acceptance withholding on cleanup failure.
- Mid: progress tracking did not say how Meta-blocked verification could finish.
  Defined P12 completion through explicit blocked/skipped statuses without
  conflating them with code failure.
- Mid: the plan could have introduced public error cases despite the accepted
  compatibility decision. P8 and completion criteria now require reuse of the
  existing error enum.
- Mid: Facebook Login response encoding could have been assumed identical to
  Instagram Login. P5 now requires a documented `RESPONSE` messaging type only
  for the variant that requires it, with per-login request snapshots.

Design defects addressed before this plan: host/login-mode ambiguity,
third-party live-send safety, private-vs-public reply distinction, external
prerequisite status, outbound reaction/attachment/Human Agent coverage, strict
typed payload boundaries, Ads exclusion, Page-vs-Instagram actor routing, Human
Agent feature-vs-scope separation, and public error compatibility. They are not
reclassified as plan-only findings. The scoped post-plan design correction also
added omitted official mark-seen/typing sender actions; P5, P7-P10, P12, and the
verification matrix now cover them.

Remaining low findings: none.

## Risks

- Meta permissions, API fields, limits, login-product routing, and approval
  requirements can change after the revalidation date.
- Adding defaulted public struct initializer parameters preserves ordinary
  source calls but still requires a full source-compatibility build and API diff
  review.
- Facebook and Instagram Login actor differences are easy to regress because
  both profiles may contain Page and Instagram IDs.
- Complex template payload validation can drift from provider limits; local
  validation must reject only documented invalid states and leave evolving
  provider policy to typed errors.
- Live DMs and profiles contain private data; even read-only evidence must not be
  persisted.
- The configured sandbox may lack self-message fixtures or Meta permission even
  when deterministic coverage is complete.
- Messenger Profile rollback can fail due provider availability or concurrent
  edits; live mutation must be skipped unless isolation and restoration are
  credible.
- Existing unrelated uncommitted files may be present from parallel feature
  planning; implementation must scope its diff and never overwrite them.

## Step 6 Implementation Update — 2026-08-13

- Status: deterministic implementation verified. `swift test` passed 65 tests
  and `swift build -c release` passed after this rerun; the prior 60-test
  result is not used as final evidence.
- Corrected Facebook conversation listing with `platform=instagram`; message
  listing now requests the documented nested `messages{...}` field and adapts
  `{messages:{data,paging}}` to `Page<InstagramMessage>`. Message DTOs include
  typed `to` and `is_unsupported` fields.
- Restored public typed inputs and methods for private replies, reactions,
  sender actions, attachment uploads, profile mutations, and
  `InstagramMutationResult`; `InstagramSendReceipt` includes optional
  `flowId`. Reaction action (`react` or `unreact`) is separate from the closed
  `love` kind.
- Completed reader leaves for conversation list/find, message list/get,
  consent-gated profile, ice-breakers, and persistent menu; completed writer
  leaves for sends, private replies, react/unreact, all sender actions,
  attachment upload, and nested profile set/delete operations. Synthetic tests
  assert every corrected path, query, body, DTO adaptation, and zero-request
  rejection.
- README, `docs/api-coverage.md`, `docs/meta-setup.md`, and
  `docs/live-smoke-tests.md` now distinguish deterministic code coverage from
  `META_BLOCKED` owned-fixture/live prerequisites. No live messaging operation
  was performed.
