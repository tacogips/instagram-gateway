# Instagram oEmbed Implementation Plan

## Status

Accepted feature-local implementation plan after self-review and an independent
second-pass review. Implementation has not started in this planning worker.

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference: `workflow-input:codex-design-and-implement-review-loop-session-695`
- Feature id: `instagram-oembed`
- Feature title: Instagram oEmbed
- Accepted design: `design-docs/instagram-oembed.md`
- Implementation plan: `impl-plans/instagram-oembed.md`
- Codex agent references: none

## Accepted Design Decisions

- oEmbed is a read-only SDK and `instagram-gateway-reader` capability.
- Use `GET /instagram_oembed` through the project Graph API version and send a
  dedicated app/client oEmbed token only as a bearer header.
- Reuse the existing read-profile and `--credential` selection contract; create
  a separate oEmbed credential profile instead of reusing a professional
  account user/Page token or changing config schema.
- Validate HTTPS Instagram public-content URLs and typed request options before
  transport execution.
- Decode required core embed fields and optional provider-controlled auxiliary
  fields; preserve unknown oEmbed resource types.
- Treat Meta approval, token, app mode, and content eligibility as provider
  prerequisites separate from code completion and live verification.

## Dependencies And Preconditions

- Source of truth: `design-docs/instagram-oembed.md`.
- Existing implementation surfaces:
  - `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`
  - `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift`
  - `Tests/InstagramGatewayCoreTests/CoreTests.swift`
  - `Tests/InstagramGatewayCLITests/CLITests.swift`
- Existing shared contracts to preserve: `InstagramGatewayClient`,
  `InstagramReaderService`, `CredentialProfile`, `SecretResolver`,
  `HTTPRequest`, `SuccessEnvelope`, `InstagramGatewayError`, and
  `RecordingHTTPTransport`.
- Before coding, re-check Meta's current oEmbed endpoint, request options,
  accepted URL formats, `maxwidth` bounds, response fields, token types, Meta
  oEmbed Read access requirements, business verification, and Live-mode rules
  against the official references in the design.
- Do not block deterministic implementation on Meta dashboard access. Do block
  any live-success claim until the required provider state is observed.

## Deliverables

### 1. Freeze The Versioned Provider Contract

Files:

- `design-docs/instagram-oembed.md` only if current official documentation
  requires a scoped design correction
- `impl-plans/instagram-oembed.md` for progress/evidence updates

Work:

- Record the checked date, current project Graph API version, endpoint, token
  type, accepted URL forms, request options, response fields, and provider
  prerequisites.
- If official documentation conflicts with the accepted design, revise the
  design first and repeat design review before implementation.
- Do not adopt observed tokenless behavior unless official documentation makes
  it a supported contract; preserve authenticated behavior otherwise.

Completion criteria:

- The implementation has an explicit, current provider contract and no guessed
  field, range, permission, or token requirement.

### 2. Add Typed DTOs And Validation

File: `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`

Work:

- Add public `InstagramOEmbedRequest`, `InstagramOEmbed`, and
  `OEmbedResourceType` with public initializers and the conformances required by
  the design.
- Add explicit snake-case `CodingKeys` and unknown-value preservation for
  `OEmbedResourceType`.
- Keep author, thumbnail, dimensions, title, author URL, and cache age optional
  when the provider may omit them.
- Implement a small internal request validator for HTTPS host, public-content
  path/shortcode, absence of user-info/fragment, and documented `maxWidth`
  bounds.
- Avoid a raw `providerFields` dictionary and avoid accepting token-bearing
  source URLs.

Completion criteria:

- Public initializer tests compile.
- Current-minimal and expanded/legacy fixtures decode.
- Unknown resource types round-trip.
- Invalid inputs fail with `configurationInvalid` before transport execution.

### 3. Add The Reader SDK Operation

File: `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`

Work:

- Add `InstagramReaderService.oEmbed(_:)`.
- Build `HTTPRequest(method: .get, path: "instagram_oembed", query: ...)` with
  required `url` and only supplied, validated `maxwidth`, `hidecaption`, and
  `omitscript` values.
- Continue using `InstagramGatewayClient.request` for bearer authorization,
  decoding, provider error mapping, and redaction.
- Ensure no `access_token` query item is created.

Completion criteria:

- Recording-transport tests prove exact method/path/options, bearer header, and
  token absence from query and errors.
- Existing reader operations and public client initialization remain source
  compatible.

### 4. Add The Reader-Only CLI Command

File: `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift`

Work:

- Route `oembed get` in `handleReader`.
- Require `--url`; parse `--max-width`, `--hide-caption`, and `--omit-script`
  into `InstagramOEmbedRequest`.
- Return the existing stable success/error JSON envelopes without rendering or
  executing returned HTML.
- Add `oembed get` to reader help.
- Leave writer routing and help unchanged; writer invocation must fail as an
  unsupported writer command.

Completion criteria:

- Reader CLI fixture tests produce typed JSON and use the selected read
  credential.
- Reader help advertises the command, writer help does not, and no destructive
  confirmation gate is introduced.

### 5. Add Deterministic Unit And CLI Coverage

Files:

- `Tests/InstagramGatewayCoreTests/CoreTests.swift`
- `Tests/InstagramGatewayCLITests/CLITests.swift`

Core test cases:

- minimal current response decoding
- expanded response decoding with optional legacy fields
- unknown `type` preservation
- public DTO initializer construction
- exact endpoint/query construction for default and fully populated requests
- bearer header presence and token absence from query/output
- invalid scheme, host, content path, shortcode, fragment/user-info, and
  `maxWidth` rejection without a recorded request
- provider and decode failures remain typed and redacted

CLI test cases:

- `oembed get --url ...` request routing and stable JSON
- option mapping for `--max-width`, `--hide-caption`, and `--omit-script`
- required subcommand/URL failures
- explicit `--credential` selection of a read oEmbed profile
- reader help inclusion and writer help exclusion
- writer command rejection
- token redaction from all output, including provider-error text

Completion criteria:

- Tests are network-free, deterministic, and fail if a raw token reaches a URL,
  JSON envelope, error, or help text.

### 6. Document Usage, Setup, Coverage, And Safe Live Checks

Files:

- `README.md`
- `docs/meta-setup.md`
- `docs/live-smoke-tests.md`
- `docs/api-coverage.md`

Work:

- Add SDK and reader CLI examples using a placeholder public URL.
- Add a separate `taco-dev-sandbox-oembed` read profile and the kinko reference
  `INSTAGRAM_GATEWAY_META_OEMBED_ACCESS_TOKEN`; never include a secret value.
- Explain app/client token provenance and explicitly warn against substituting
  the professional-account reader token without provider confirmation.
- List Meta oEmbed product/feature, access level/App Review, business
  verification, Live mode, token, public-content eligibility, and allowed-use
  prerequisites with a checked date.
- Mark SDK and CLI code coverage independently from deterministic test status
  and live provider status.
- Document a safe, read-only smoke command and the rule that a provider block is
  reported as blocked, not passed.

Completion criteria:

- Documentation names per-operation status and prerequisites, contains no token,
  and does not imply that professional-account authorization grants oEmbed.

### 7. Verify And Record Evidence

Deterministic commands:

```bash
swift test --filter oEmbed
swift test
swift build -c release
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
git diff --check -- Sources/InstagramGatewayCore/InstagramGatewayCore.swift Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift Tests/InstagramGatewayCoreTests/CoreTests.swift Tests/InstagramGatewayCLITests/CLITests.swift README.md docs/meta-setup.md docs/live-smoke-tests.md docs/api-coverage.md design-docs/instagram-oembed.md impl-plans/instagram-oembed.md
git status --short
```

Safe live command, only after the dedicated credential and approved public test
URL exist:

```bash
swift run instagram-gateway-reader --credential taco-dev-sandbox-oembed --pretty oembed get --url "https://www.instagram.com/p/<owned-or-approved-public-shortcode>/" --omit-script
```

Evidence to record in this plan during implementation:

- command, exit status, checked Graph version, redacted provider result, and
  whether the result is `passed`, `failed-code`, or `blocked-provider`
- prerequisite availability without credential values
- exact test/build failures and scoped corrections, if any

Completion criteria:

- All deterministic commands pass.
- The release build succeeds.
- Live status is honestly recorded; absence of prerequisites does not block code
  completion but does block a live-success claim.
- Accepted changes are committed and pushed to the existing tracked branch only
  after the parent workflow's full checks pass.

## Execution Order And Parallelism

1. Complete provider-contract verification.
2. Implement DTOs/validation and SDK request construction.
3. Implement CLI routing after the SDK signature is stable.
4. Add tests alongside each code increment.
5. Update documentation after final names and behavior stabilize.
6. Run focused tests, full tests, release build, help checks, then gated live
   verification.

Within one implementation branch, response-fixture tests and documentation
drafting may proceed independently after step 1, but public DTO and CLI names
must not diverge from the accepted design.

## Progress Tracking

- [ ] Re-check and record the official versioned provider contract.
- [ ] Add typed request/response/resource-type models and validation.
- [ ] Add `InstagramReaderService.oEmbed(_:)`.
- [ ] Add reader-only `oembed get` routing and help.
- [ ] Add deterministic core tests.
- [ ] Add deterministic CLI/binary-boundary/redaction tests.
- [ ] Update README, Meta setup, live smoke, and API coverage docs.
- [ ] Run focused tests, full tests, and release build.
- [ ] Run or explicitly block safe live verification.
- [ ] Record evidence and hand off to parent full-suite review.
- [ ] Commit and push only after parent acceptance.

## Implementation-Plan Review Record

### Self-review

Decision: `accepted-after-revision`.

Design defects found: none.

Plan-only defects addressed:

- Mid: the initial task order allowed implementation before current Meta
  contract verification. Added a blocking provider-contract step and a design
  revision loop for official conflicts.
- Mid: initial verification mentioned only focused tests. Added full
  `swift test`, release build, both binary help checks, diff checking, and
  explicit provider-blocked live evidence.
- Mid: token separation lacked a concrete integration task. Added explicit
  credential-selection tests and setup documentation for a dedicated read
  profile.
- Low: completion and progress states were implicit. Added per-deliverable
  criteria and an unchecked progress ledger.

### Independent second-pass review

Decision: `accepted`.

- No high or mid findings remain.
- Design-plan consistency: accepted; every design acceptance criterion maps to
  a deliverable, test, documentation task, or verification command.
- Deliverables and dependencies: accepted; file paths, shared contracts, and
  provider prerequisites are explicit.
- Completion criteria and progress tracking: accepted; implementation remains
  correctly marked not started.
- Verification: accepted; deterministic, release, binary-boundary, redaction,
  documentation, and gated-live checks are explicit.

Low risks retained:

- Meta may change URL forms, response fields, token requirements, feature names,
  or approval gates before implementation.
- The monolithic core and CLI source files increase merge-conflict risk with
  other fanout features; implementation should make narrow edits and rebase or
  reconcile without discarding concurrent work.
- Live oEmbed access may remain provider-blocked even when deterministic code
  and tests are complete.

## Plan Acceptance Criteria

### Step 6 implementation update — 2026-08-13

- Implemented typed oEmbed request/response models, HTTPS and token-query
  preflight validation, the reader SDK operation, reader CLI route, and tests.
- `swift test` passed. Separate oEmbed credential provisioning and gated live
  verification remain META_BLOCKED.

- The accepted design is the source of truth and no unresolved high or mid
  design finding remains.
- Every SDK, CLI, security, documentation, testing, provider-prerequisite, and
  live-verification requirement has an explicit implementation task.
- Dependencies, file paths, completion criteria, progress states, and commands
  are explicit.
- Design defects are separated from plan-only defects.
- No implementation or live-success claim is implied by plan acceptance.

## Step 6 Implementation Update — 2026-08-13

- Status: partial. Reader execution now requires a distinct
  oembed_access_token_ref, tested independently from the account token.
  Current provider-contract and gated live verification remain META_BLOCKED.
