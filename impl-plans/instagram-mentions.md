# Instagram Mentions Implementation Plan

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference:
  `workflow-input:codex-design-and-implement-review-loop-session-695`
- Feature id: `instagram-mentions`
- Feature title: Mentions
- Requested design path: `docs/design/instagram-mentions.md`
- Accepted design path: `design-docs/specs/instagram-mentions.md`
- Requested implementation-plan path: `docs/plans/instagram-mentions.md`
- Canonical implementation-plan path: `impl-plans/instagram-mentions.md`
- Codex agent references: `/root/mentions_design_review`

The canonical paths follow the worker requirement and existing repository
layout. This plan is implementation-ready but does not mark implementation
tasks complete.

## Accepted Design Review Input

Independent design review initially reported three mid defects and one low
defect:

- mentioned-media `comments` expansion was omitted
- selectable nested-media fields exceeded the nested response DTO
- public SDK request/response types lacked public initializers
- webhook time was modeled as an ISO-8601 string instead of Meta's Unix seconds

The revised design added typed nested comments with cursor paging, aligned the
nested-media field enum and DTO, specified public initializers/defaults, and
preserved webhook `entry.time` as `providerTimestamp: Int?`. A follow-up mid
finding about unsafe nested cursor interpolation was addressed with a
conservative cursor grammar and a required malicious-cursor test. Final design
decision: accepted with zero unresolved high or mid findings.

## Deliverables

### 1. Public mention types and decoding

Edit `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`:

- Add `MentionTarget` with a stable, explicit Codable discriminator:
  `caption` carries `media_id`; `comment` carries `media_id` and `comment_id`.
- Add `MentionDiscoveryReference` with `accountId`, `target`, and optional
  `providerTimestamp` in Unix seconds.
- Add request field enums and lookup/input structs from the accepted design:
  `MentionedMediaField`, `MentionedMediaCommentField`,
  `MentionedCommentField`, `MentionedCommentMediaField`,
  `MentionedMediaLookup`, `MentionedCommentLookup`, and
  `ReplyToMentionInput`.
- Add response DTOs `MentionedMediaComment`, `MentionedMedia`,
  `MentionedCommentMedia`, `MentionedComment`, `MentionedMediaResponse`, and
  `MentionedCommentResponse` with explicit `CodingKeys` for snake_case fields.
- Give every public struct a public initializer with the accepted deterministic
  defaults. Encode field sets as raw-value-sorted arrays so public Codable
  output is stable; decode them with duplicate rejection where applicable.
- Implement a private tolerant optional-count decoder accepting an integer or
  an ASCII numeric string while preserving missing values as `nil` and rejecting
  non-numeric strings.
- Reuse `MediaType` unknown-value preservation and `Page`/`Paging` for nested
  mentioned-media comments.

Completion criteria:

- External SDK users can construct every public input without `@testable`.
- Fixtures decode numeric and numeric-string counts, nested comment cursors,
  nested comment media, absent/hidden counts, and unknown media types.
- Codable round trips preserve the explicit target kind and provider timestamp.

### 2. Safe field-expression builder

Edit `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`:

- Add a focused internal builder for the two Graph `fields` expressions rather
  than concatenating unvalidated CLI strings in service methods.
- Validate `accountId`, `mediaId`, and `commentId` as one or more ASCII decimal
  digits before any transport call.
- Sort requested top-level and nested fields by provider raw value.
- Render mentioned-media comments only when `.comments` is selected. Apply a
  positive `commentsLimit`, optional `commentsAfter`, and typed nested fields.
- Reject nested comment options when `.comments` is absent.
- Accept `commentsAfter` only when non-empty and matching
  `[A-Za-z0-9_=-]+`; keep it otherwise opaque and never decode or log it.
- Expand `media{...}` only when `.media` is selected in a mentioned-comment
  lookup.
- Reject empty field selections, structural delimiters, and invalid enum input
  before transport use.

Completion criteria:

- Exact request strings match accepted endpoint syntax.
- Identifiers or cursors containing braces, parentheses, commas, whitespace, or
  other delimiters fail locally with `configurationInvalid` and issue zero
  transport requests.

### 3. Reader service lookups

Edit `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`:

- Add
  `InstagramReaderService.mentionedMedia(_:) -> MentionedMediaResponse`.
- Add
  `InstagramReaderService.mentionedComment(_:) -> MentionedCommentResponse`.
- Send both as `GET /{account-id}` with exactly one typed `fields` query value.
- Continue using configured API version/base URL and bearer authorization from
  the existing client; do not copy the version from Meta's examples.
- Do not add a polling/list operation for `/{account-id}/mentions` because Meta
  supports no read edge there.

Completion criteria:

- Recording-transport tests prove path, method, authorization, and exact field
  expression for default and expanded requests.
- Provider failures continue through the existing typed/redacted error mapping.

### 4. Writer mention replies

Edit `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`:

- Add
  `InstagramWriterService.replyToMention(_:) -> CommentReply`.
- Validate account/target identifiers through the same safe builder.
- Trim-check the message and reject an empty value locally.
- Map caption targets to `POST /{account-id}/mentions` with `media_id,message`.
- Map comment targets to the same path with
  `media_id,comment_id,message`.
- Do not route this operation through the existing
  `POST /{comment-id}/replies` service because mentioned media may be unowned.
- Extend the request-specific redactor with the outbound message before sending
  so provider and transport failures cannot echo message content.

Completion criteria:

- Recording-transport tests verify both target mappings and result decoding.
- Empty messages and malformed IDs produce no transport request.
- A fixture provider error containing the outbound message is redacted.

### 5. Permission-separated CLI commands

Edit `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift`:

- Add reader routes:
  - `mentions media get [--account-id] --media-id [--fields]
    [--comment-fields] [--comments-limit] [--comments-after]`
  - `mentions comment get [--account-id] --comment-id [--fields]
    [--media-fields]`
- Default reader account ID from the selected read credential's
  `instagram_user_id` only when `--account-id` is omitted.
- Parse field CSV against the exact typed enum, trim tokens, and reject empty,
  unknown, or duplicate entries before network access.
- Add writer routes:
  - `mentions reply-caption --account --media-id --message --yes`
  - `mentions reply-comment --account --media-id --comment-id --message --yes`
- Extend pre-credential confirmation detection so both reply verbs require
  `--yes` before loading secrets or sending a request.
- Keep writer `--account` explicit, matching existing mutation commands.
- Reject reply commands in the reader and lookup commands in the writer with
  `unsupportedOperation`.
- Update binary-specific help: reader lists only lookup commands; writer lists
  only reply commands.
- Return existing JSON envelopes and never place outbound message text in
  diagnostics or error details.

Completion criteria:

- Reader routes select a read credential; writer routes select a write
  credential.
- Missing confirmation, malformed CSV, invalid IDs/cursors, and cross-binary
  verbs fail without transport calls.
- Help and success/error envelopes remain deterministic.

### 6. Deterministic core and CLI tests

Edit `Tests/InstagramGatewayCoreTests/CoreTests.swift`:

- Test target/discovery Codable round trips and public initializers.
- Decode mentioned-media and mentioned-comment fixtures with nested values,
  numeric-string counts, missing counts, stripped `@`, and unknown media type.
- Test default and fully expanded field expressions, stable sorting, nested
  `before`/`after` decoding, and reconstruction using `commentsAfter`.
- Test malformed IDs and malicious cursors including `cursor){owner}` and
  `cursor,comments` issue zero requests.
- Test caption/comment reply mapping, empty-message rejection, response
  decoding, and outbound-message redaction on provider error.

Edit `Tests/InstagramGatewayCLITests/CLITests.swift`:

- Test reader/writer help separation.
- Test both reader lookups with injected recording transport and JSON output.
- Test default account selection plus explicit account override.
- Test field parsing, duplicate rejection, nested pagination flags, and
  pre-transport validation failures.
- Test both writer replies, `--yes`, write-credential selection, and
  cross-binary rejection.

Prefer inline deterministic JSON fixtures unless reuse warrants mention-specific
files under `Tests/Fixtures/`. No deterministic test may require network access
or real credentials.

Completion criteria:

- Every public operation has request-construction, decoding, validation, and CLI
  routing coverage.
- Tests prove zero transport requests for each local rejection path.

### 7. Permission, eligibility, and coverage documentation

Edit `README.md` and `docs/api-coverage.md` only after code and tests pass:

- Document the two reader lookup commands and two confirmed writer reply
  commands.
- Keep tagged media (`/{ig-user-id}/tags`) distinct from `@mention` lookup.
- State that discovery requires a subscribed `mentions` webhook and stored IDs;
  there is no mention list/replay API.
- Document Facebook Login, a linked Page, Facebook User token,
  `instagram_basic`, `instagram_manage_comments`, `pages_read_engagement`, Page
  task `MANAGE`/`CREATE_CONTENT`/`MODERATE`, and `pages_show_list` for comment
  mention replies.
- Document conditional `ads_management` or `ads_read` for Business
  Manager-granted Page roles, plus Standard versus Advanced Access/App Review.
- Document Story/private-account/disabled-comment/hidden-like/tag-reply limits
  and possible stripped `@` caption text.
- Mark code coverage separately from Meta prerequisites and live outcomes. Do
  not mark live pass when the webhook or controlled fixture is absent.

Completion criteria:

- Coverage says `Yes` only after SDK and appropriate CLI routes pass
  deterministic tests.
- Documentation names every Meta-blocked condition and contains no credentials,
  uncontrolled account identifiers, or claim of third-party interaction.

### 8. Safe live verification and evidence

After deterministic checks pass, inspect prerequisites without printing secret
values. Use only the configured `taco-dev-sandbox` professional account and a
mention created by a second account controlled by the operator.

Safe reads:

```bash
swift run instagram-gateway-reader --config <config> mentions media get \
  --media-id <controlled-mentioned-media-id> --pretty
swift run instagram-gateway-reader --config <config> mentions comment get \
  --comment-id <controlled-mentioned-comment-id> --pretty
```

Owned reversible writes, only when the fixture exists:

```bash
swift run instagram-gateway-writer --config <config> mentions reply-caption \
  --account <owned-ig-id> --media-id <controlled-mentioned-media-id> \
  --message <approved-smoke-message> --yes --pretty
swift run instagram-gateway-writer --config <config> mentions reply-comment \
  --account <owned-ig-id> --media-id <controlled-mentioned-media-id> \
  --comment-id <controlled-mentioned-comment-id> \
  --message <approved-smoke-message> --yes --pretty
```

Record the created comment ID and delete it through the supported comment
moderation command when ownership and provider behavior permit. If permissions,
Page tasks, App Review, public webhook subscription, a controlled second
account, or eligible IDs are missing, record `META_BLOCKED` and the exact
prerequisite. Do not create interactions on unowned assets or message third
parties.

Completion criteria:

- Each attempted live operation has a redacted `PASS`, `FAIL`, or
  `META_BLOCKED` record.
- Reversible writes have cleanup evidence or an explicit provider-blocked
  cleanup result.

## Dependencies And Sequencing

1. The accepted design is the source of truth.
2. Public models and safe expression building precede service methods.
3. Reader/writer services precede CLI routing.
4. Deterministic tests precede documentation status changes and live calls.
5. The separate webhook feature owns raw payload decoding, subscriptions,
   callback transport, persistence, and signature verification; it may construct
   this feature's `MentionDiscoveryReference`.
6. Existing `HTTPTransport`, `InstagramGatewayClient`, `Page`, `Paging`,
   `MediaType`, `CommentReply`, configuration, credential modes, confirmation,
   and redaction behavior are reused rather than duplicated.

Work that can proceed in parallel after public contracts settle:

- Response fixture decoding and safe expression-builder tests.
- Reader CLI parsing and writer CLI confirmation tests.
- Permission documentation drafting and live-prerequisite inventory.

## Progress Tracking

Planning branch:

- [x] Create feature-local design.
- [x] Self-review design.
- [x] Independently review design and resolve all high/mid findings.
- [x] Create feature-local implementation plan.
- [x] Self-review implementation plan.
- [x] Independently review implementation plan and resolve all high/mid findings.

Implementation branch:

- [ ] Add public mention types, initializers, CodingKeys, and tolerant counts.
- [ ] Add validated deterministic Graph field-expression builder.
- [ ] Add reader mention lookup services.
- [ ] Add writer mention reply service and message redaction.
- [ ] Add permission-separated CLI routes, help, and confirmation gates.
- [ ] Add deterministic core and CLI tests.
- [ ] Run focused tests, full tests, and release build.
- [ ] Update README and API coverage with prerequisites and limits.
- [ ] Run eligible safe live reads and owned reversible writes, or record
      `META_BLOCKED` with exact prerequisites.

## Verification Commands

Focused and full deterministic verification:

```bash
swift test --filter Mention
swift test
swift build -c release
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
swift run instagram-gateway-reader config validate --config Tests/Fixtures/reader-valid.toml
git diff --check
git diff -- Sources/InstagramGatewayCore/InstagramGatewayCore.swift \
  Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift \
  Tests/InstagramGatewayCoreTests/CoreTests.swift \
  Tests/InstagramGatewayCLITests/CLITests.swift \
  README.md docs/api-coverage.md \
  design-docs/specs/instagram-mentions.md impl-plans/instagram-mentions.md
git status --short
```

Feature-local planning verification:

```bash
git diff --check -- design-docs/specs/instagram-mentions.md impl-plans/instagram-mentions.md
rg -n "instagram-mentions|Mention|mentions|META_BLOCKED" \
  design-docs/specs/instagram-mentions.md impl-plans/instagram-mentions.md
```

## Completion Criteria

### Step 6 implementation update — 2026-08-13

- Implemented typed caption/comment mention targets, discovery references,
  mentioned-media/comment DTOs, reader lookups, and a writer-only reply path.
- Reader and writer boundaries remain preserved; mention replies require `--yes`.
- Nested expandable comments and live fixture verification remain pending.

### Step 6 rerun update — 2026-08-13

- Added identifier-specific mention lookup inputs, controlled nested comments
  expansion with pagination cursor validation, and CLI identifier flags.

- The accepted typed lookup and reply contracts are implemented with public
  initializers and stable Codable behavior.
- Mention discovery is described honestly as webhook-driven; no unsupported
  list API exists in SDK or CLI.
- Reader and writer binary boundaries and credential modes are enforced.
- Public replies require `--yes`; no outbound message appears in diagnostics or
  provider/transport errors.
- Field expressions accept only typed fields and validated IDs/cursors.
- Deterministic tests, full `swift test`, and release build pass.
- README and coverage distinguish code completion from Meta permissions,
  Advanced Access/App Review, Page tasks, callback setup, and fixture ownership.
- Live results are redacted and never overstate Meta-blocked operations.

## Plan Self-Review

- Design-plan consistency: each accepted DTO, lookup, reply, CLI command,
  permission, provider limitation, and live-safety boundary maps to a deliverable.
- Deliverables: exact source, test, and documentation files are named with
  per-deliverable completion criteria.
- Dependencies: model/builder/service/CLI/test/docs/live ordering and the webhook
  ownership boundary are explicit.
- Completion criteria: code, binary separation, security, tests, docs, and live
  evidence are independently checkable.
- Progress tracking: planning and later implementation states are separated; no
  implementation work is falsely marked complete.
- Verification: focused tests, full tests, release build, help/config smoke,
  diff checks, and live commands are explicit.
- Plan defects found: none high or mid in self-review.
- Low/open item: live verification may remain `META_BLOCKED` until the webhook
  feature and a controlled second-account fixture exist.

## Independent Plan Review

- Reviewer: `/root/mentions_design_review`
- Decision: accepted
- Design defects: none
- Plan-only defects: no high or mid findings
- Addressed low finding: progress tracking now marks the completed plan
  self-review and independent review steps accurately.
- Consistency, deliverables, dependencies, completion criteria, verification,
  binary boundaries, permissions, confirmation/redaction, and live safety all
  passed independent review.

## Risks

- Meta permission and field behavior can change with Graph API versions.
- Field-expanded comment cursors are opaque provider values but require a safe
  grammar because they are embedded in a Graph expression.
- The sandbox may not have a controlled mention fixture, so deterministic code
  completion may precede live verification.
- Public mention replies are externally visible and cleanup may itself be
  provider- or ownership-gated.

## Step 6 Implementation Update — 2026-08-13

- Status: partial. Identifier-safe media/comment expressions and cursor
  validation are implemented and tested. Selectable typed fields, duplicate
  rejection, tolerant integer/string count decoding, and nested comment-media
  DTO fixture coverage are deterministic; live mention fixtures remain
  META_BLOCKED.
