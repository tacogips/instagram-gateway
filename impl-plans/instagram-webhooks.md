# Webhooks And Subscriptions Implementation Plan

## Status

Accepted feature-local implementation plan for `instagram-webhooks` after
self-review and a separate independent review pass. Implementation has not
started in this planning branch.

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference:
  `workflow-input:codex-design-and-implement-review-loop-session-695`
- Feature id: `instagram-webhooks`
- Feature title: Webhooks and subscriptions
- Design reference: `design-docs/specs/instagram-webhooks.md`
- Requested plan path: `docs/plans/instagram-webhooks.md`
- Resolved plan path: `impl-plans/instagram-webhooks.md`
- Codex agent references: none

## Accepted Design Input

The accepted design requires:

- exact-byte HMAC-SHA256 verification before decode or side effects
- callback challenge validation without an embedded HTTP server
- typed, unknown-preserving decoding for change and messaging payload variants
- programmatic professional-account subscription management only for the
  documented Instagram Login `graph.instagram.com` edge
- reader ownership of offline verification/decoding and subscription listing
- writer ownership of subscribe/delete mutations with `--yes`
- additive config/public API changes that preserve Facebook Login defaults
- deterministic synthetic tests and separately reported live prerequisites

No unresolved high or mid design findings carry into implementation.

## Deliverables

### 1. Login type and profile-aware transport

Files:

- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`
- `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift`
- `Tests/InstagramGatewayCoreTests/CoreTests.swift`
- `Tests/InstagramGatewayCLITests/CLITests.swift`
- `Examples/config.example.toml`

Work:

- Add unknown-preserving `InstagramLoginType` with Facebook Login and Instagram
  Login cases.
- Add defaulted `loginType` to `CredentialProfile` public initialization and
  optional `login_type` TOML parsing; omission remains Facebook Login.
- Add optional `webhook_verify_token_ref` parsing as a `SecretReference`.
- Make the default CLI transport factory select `graph.facebook.com` or
  `graph.instagram.com` from the profile while preserving dependency injection.
- Reject unknown login types before network calls.

Completion criteria:

- Existing configs and public initializer call sites compile unchanged.
- Config tests cover explicit values, default behavior, invalid/unknown outbound
  use, secret reference parsing, and redacted diagnostics.
- Recorded requests demonstrate the correct versioned host for each login type.

### 2. Typed webhook DTOs and normalization

Files:

- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`
- `Tests/InstagramGatewayCoreTests/CoreTests.swift`
- `Tests/Fixtures/Webhooks/*.json`

Work:

- Add root object, entry, change, actor, media, comment/live-comment, mention,
  story-insight, sender/recipient, message, attachment, quick-reply, referral,
  reply-to, postback, reaction, seen, handover, standby, and message-edit DTOs.
- Add unknown-preserving enums and explicit public initializers.
- Normalize `entry.changes[]` and direct `entry.field`/`entry.value` into the
  same `[InstagramWebhookChange]` API.
- Preserve forward-compatible unknown provider content only in explicit
  `JSONValue` extension fields.
- Ensure diagnostic/debug descriptions do not include body content.

Completion criteria:

- Every documented payload family in the design has a synthetic fixture and
  decode assertion.
- Unknown root objects, fields, enum values, and payload variants round-trip
  without losing their raw names/extension data.
- Public DTO initializer tests compile from the library boundary.

### 3. Exact-byte signature verification

Files:

- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`
- `Tests/InstagramGatewayCoreTests/CoreTests.swift`

Work:

- Import CryptoKit and implement HMAC-SHA256 over the exact input `Data`.
- Strictly parse one `sha256=` header value with a 32-byte hex digest.
- Add a fixed-work byte comparison with no data-dependent early return for
  equal-length candidates.
- Expose `InstagramWebhookSignatureVerifier` and
  `InstagramWebhookDecoder.verifyAndDecode`.
- Add stable, non-sensitive errors for missing, malformed, and mismatched
  signatures and oversized payloads.
- Apply a maximum body-size check before decoding; keep the limit explicit and
  testable.

Completion criteria:

- Fixed known vector succeeds; wrong secret, body mutation, missing/wrong
  prefix, invalid hex, wrong length, and mismatched digest fail.
- A valid-JSON body with an invalid signature fails as a signature error without
  producing a decoded event, while a correctly signed malformed body passes
  authentication and then fails as a payload-decoding error. This proves the
  verify-before-decode ordering.
- Raw UTF-8 versus JSON-escaped Unicode fixtures prove verification does not
  decode/re-encode first.
- Tests instrument the comparison helper to prove every byte is processed for
  equal-length inputs.
- Failure JSON and descriptions contain no body, app secret, supplied
  signature, or expected digest.

### 4. Callback challenge adapter

Files:

- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`
- `Tests/InstagramGatewayCoreTests/CoreTests.swift`

Work:

- Implement `InstagramWebhookChallengeValidator` for `hub.mode`,
  `hub.verify_token`, and `hub.challenge`.
- Require `subscribe`, compare verify-token bytes without early exit, and return
  the challenge exactly as supplied.
- Distinguish verify token from app secret in types, docs, and errors.

Completion criteria:

- Success and missing/mismatched mode, token, and challenge tests pass.
- No result, error, debug description, or test output exposes either configured
  or supplied verify token.

### 5. Subscription SDK service

Files:

- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`
- `Tests/InstagramGatewayCoreTests/CoreTests.swift`

Work:

- Implement `InstagramWebhookField`, `WebhookSubscription`, and
  `WebhookSubscriptionMutationResult`.
- Implement list, subscribe, and delete against
  `/{ig-user-id}/subscribed_apps` using an injected Instagram Login client.
- Validate nonempty account id and subscribe fields, reject unknown outbound
  fields, and sort field raw values deterministically.
- Decode unknown fields from list responses without rejecting the response.
- Reject Facebook Login or unknown login types before the transport is invoked.

Completion criteria:

- Recording transport tests cover GET/POST/DELETE method, exact path, bearer
  header, deterministic `subscribed_fields`, success/page decoding, provider
  errors, and host selection.
- Preflight-rejection tests assert zero recorded network requests.
- Mutation tests do not add automatic retries.

### 6. Permission-separated CLI commands

Files:

- `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift`
- `Tests/InstagramGatewayCLITests/CLITests.swift`
- `Sources/InstagramGatewayReader/main.swift`
- `Sources/InstagramGatewayWriter/main.swift`

Work:

- Add reader `webhooks verify-decode`, explicit unsigned `decode`, and
  `subscriptions list` routing.
- Resolve app secret through the selected credential only; do not accept it as
  an argument or print it.
- Read bounded body files as bytes and never normalize newline or Unicode data.
- Add writer `subscriptions subscribe` and `delete`, requiring write mode and
  `--yes` before secret resolution/network access.
- Update help text and reader/writer unsupported-command detection.
- Keep subscription list out of writer and mutations out of reader.

Completion criteria:

- CLI tests cover happy paths, signature failure, unsigned acknowledgement,
  body limit, missing app-secret reference, sorted field parsing, unknown
  outbound field rejection, wrong binary, wrong access mode, and missing
  confirmation.
- CLI ordering tests distinguish invalid-signature/valid-JSON from
  valid-signature/malformed-JSON failures without printing either body.
- Wrong-binary and missing-confirmation tests assert no secret resolution and
  no transport call.
- JSON output is stable and contains no app secret, verify token, signature, or
  body on errors.

### 7. Documentation and coverage accounting

Files:

- `README.md`
- `docs/api-coverage.md`
- `docs/meta-setup.md`
- `docs/live-smoke-tests.md`
- `Examples/config.example.toml`

Work:

- Document callback HTTPS/TLS, GET challenge, raw-body POST verification,
  response deadline, retry/deduplication/order, Dashboard fields, account app
  installation, permissions, access levels, and App Review prerequisites.
- Document Instagram Login versus Facebook Login host/subscription boundaries.
- Add safe env/kinko reference examples for app secret and verify token without
  literal values.
- Add deterministic CLI fixture commands and guarded owned-account live
  commands.
- Update coverage per operation: typed decode, signature verify, challenge
  adapter, list, subscribe, and delete; report code coverage separately from
  callback and Meta account state.

Completion criteria:

- Documentation never suggests that a local CLI is a public callback server.
- Coverage does not mark live notification receipt as passed unless Meta reached
  a qualifying callback with an owned fixture.
- Secret scanning finds no credential values or machine-local absolute paths in
  source-controlled examples.

### 8. Deterministic and live verification

Files:

- `Tests/InstagramGatewayCoreTests/CoreTests.swift`
- `Tests/InstagramGatewayCLITests/CLITests.swift`
- `Tests/Fixtures/Webhooks/*.json`
- `docs/live-smoke-tests.md`

Work:

- Run full unit/integration tests and release build.
- Run targeted webhook security, decoding, service, and CLI tests.
- Inspect diffs for accidental payload, credential, and unrelated changes.
- If an eligible owned Instagram Login credential and public callback exist,
  list current subscriptions, snapshot them, perform a reversible subscribe,
  confirm with list, and restore the prior state.
- Exercise a live owned comment/message/mention only when an owned fixture and
  required review/access state exist; never contact a third party.

Completion criteria:

- Deterministic verification commands pass.
- Every live operation records `pass`, `blocked`, or `not-run` with its exact
  prerequisite; provider-blocked work is never reported as passed.
- Subscription restoration is verified before live mutation is considered
  complete.

## Dependencies And Sequencing

1. Deliverable 1 precedes subscription service and live host routing.
2. Deliverables 2 and 3 can be implemented independently, but production decode
   wiring cannot land until signature-first ordering is tested.
3. Deliverable 4 depends only on shared constant-time comparison/error support.
4. Deliverable 5 depends on Deliverable 1 and shared transport/error contracts.
5. Deliverable 6 depends on Deliverables 2, 3, and 5.
6. Documentation can start from the accepted design, then must be reconciled
   with final CLI names and verified provider behavior.
7. Live verification follows all deterministic checks and requires an explicit
   snapshot/restore path.

Cross-feature dependencies:

- Messaging/DM implementation consumes the messaging webhook DTOs but owns send
  methods and conversation behavior.
- Mentions implementation consumes mention change values but owns Graph lookup
  and reply operations.
- Docs/release readiness owns the final consolidated coverage matrix and release
  gate; this feature supplies accurate per-operation evidence.
- Concurrent feature work may edit the monolithic core/CLI/test files. Rebase or
  merge carefully and preserve unrelated changes.

External dependencies:

- Meta App Dashboard callback/field configuration.
- Public HTTPS callback with a valid certificate.
- Eligible Instagram professional account and matching login/token type.
- Standard or Advanced Access/App Review and field-specific permissions.
- Owned event fixtures and durable consumer infrastructure for delivery tests.

## Progress Tracking

- [ ] Add login type, config references, and profile-aware transport.
- [ ] Add typed webhook DTOs and fixtures.
- [ ] Add strict constant-time HMAC-SHA256 verification.
- [ ] Add callback challenge validator.
- [ ] Add Instagram Login subscription service and DTOs.
- [ ] Add reader verification/decode/list commands.
- [ ] Add writer subscribe/delete commands and confirmation gates.
- [ ] Add deterministic core and CLI tests.
- [ ] Update README, setup, smoke-test, and coverage documentation.
- [ ] Run deterministic verification and inspect security-sensitive diffs.
- [ ] Run only eligible owned live checks and restore subscription state.

## Verification Commands

Deterministic required checks:

```bash
swift test --filter webhook
swift test
swift build -c release
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
swift run instagram-gateway-reader webhooks decode \
  --body-file Tests/Fixtures/Webhooks/comment.json --allow-unsigned
swift run instagram-gateway-reader config validate \
  --config Examples/config.example.toml
rg -n "app_secret|verify_token|X-Hub-Signature-256|subscribed_apps" \
  Sources Tests README.md docs Examples
git diff --check
git diff -- design-docs/specs/instagram-webhooks.md \
  impl-plans/instagram-webhooks.md Package.swift Sources Tests README.md docs Examples
git status --short --untracked-files=all
```

Targeted security cases are test filters selected from the implemented test
names; the implementation record must replace this placeholder with exact
commands:

```bash
swift test --filter InstagramGatewayCoreTests
swift test --filter InstagramGatewayCLITests
```

Conditional owned live checks after prerequisites are confirmed:

```bash
swift run instagram-gateway-reader webhooks subscriptions list \
  --credential <owned-instagram-login-reader> --account <owned-ig-id>
swift run instagram-gateway-writer webhooks subscriptions subscribe \
  --credential <owned-instagram-login-writer> --account <owned-ig-id> \
  --fields comments,mentions --yes
swift run instagram-gateway-reader webhooks subscriptions list \
  --credential <owned-instagram-login-reader> --account <owned-ig-id>
```

The exact restoration command depends on the initial subscription snapshot. Do
not run delete as a cleanup shortcut when it would remove pre-existing fields;
restore the original field set and verify it through list.

## Plan Review Record

### Self-review

Decision: `accept-after-fixes`.

Plan-only defects found and addressed:

- **Mid:** The first breakdown did not identify synthetic fixture paths or
  public initializer tests. Added `Tests/Fixtures/Webhooks/*.json` and explicit
  DTO boundary criteria.
- **Mid:** Subscription tests did not prove preflight gates prevented network
  access. Added zero-request assertions for login type, binary, access mode, and
  confirmation failures.
- **Mid:** Live subscribe verification lacked state restoration. Added
  snapshot, reversible mutation, restoration, and final list confirmation.

### Independent review pass

Decision: `accept-after-fixes`.

Plan-only defects found and addressed:

- **High:** Verification tasks could pass decoding tests without proving
  signature-before-decode ordering. Added malformed-but-correctly-signed and
  invalid-signature/valid-JSON ordering cases to the signature and CLI
  deliverables.
- **Mid:** The plan did not test that CLI body reads preserve exact bytes. Added
  newline and Unicode raw-byte fixtures plus bounded binary file reads.
- **Mid:** The plan risked duplicating messaging business logic. Clarified that
  this feature owns inbound DTOs only and the messaging feature owns send and
  conversation semantics.
- **Mid:** Coverage completion could conflate code with live callback readiness.
  Added separate status requirements and blocked/not-run evidence.

No unresolved high or mid plan findings remain. Design defects are recorded in
the design document and are not repeated as plan-only defects.

## Completion Criteria

### Step 6 implementation update — 2026-08-13

- Implemented exact-byte HMAC-SHA256 verification before decode, typed webhook
  payload entry/change normalization, and callback challenge validation.
- Added deterministic signature-ordering coverage; `swift test` passed.
- Subscription management, CLI body adapters, public HTTPS deployment, and
  controlled live verification remain pending.

### Step 6 rerun update — 2026-08-13

- Added typed subscription fields/models and an Instagram-Login-only
  subscribed_apps SDK service with fail-before-transport login validation.
- Full payload-family modeling and CLI raw-body/subscription adapters remain
  pending.

- Both accepted documents remain consistent with implemented public APIs and
  command names.
- Exact body bytes are authenticated with HMAC-SHA256 before decoding or side
  effects, and comparison does not exit early for equal-length digests.
- Typed payloads cover accepted change and messaging families and preserve
  unknown provider values.
- Callback challenge logic is reusable without making the package a server.
- Official Instagram Login subscription list/subscribe/delete operations are
  exposed through injected SDK services and the correct binaries.
- Existing Facebook Login behavior and public initializer call sites remain
  compatible.
- Reader/writer separation, confirmation gates, kinko/env secret references,
  and redaction tests pass.
- `swift test` and `swift build -c release` pass.
- Documentation and coverage distinguish implemented code from Meta callback,
  access, permission, review, account, and fixture prerequisites.
- Live checks use only owned accounts/reversible state and restore the original
  subscription configuration.

## Risks

- The core and CLI are currently monolithic files, increasing merge-conflict
  risk with other feature branches.
- CryptoKit satisfies the current macOS 14 package target; future Linux support
  would require an explicit cross-platform crypto dependency and review.
- Meta webhook fields and payload variants can change independently of Graph
  read/write response shapes.
- The configured sandbox may be Facebook Login-only and therefore unable to
  exercise the Instagram Login `subscribed_apps` edge.
- No local test can establish public callback reachability, TLS validity, App
  Review approval, or real delivery from non-role accounts.

## Step 6 Implementation Update — 2026-08-13

- Status: partial. Signature-before-decode, typed messaging-event DTOs,
  raw-body decode, and subscription CLI adapters are implemented and tested.
  Typed media/comment/mention/story-insight/referral/handover/standby/edit
  families and Codable round-trip fixtures are deterministic. Live callback
  restoration remains META_BLOCKED.
