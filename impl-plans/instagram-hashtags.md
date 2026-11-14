# Hashtag Discovery Implementation Plan

## Status

Feature-local implementation plan for `instagram-hashtags`. All implementation
tasks are pending; this document records no code-completion claim.

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference:
  `workflow-input:codex-design-and-implement-review-loop-session-695`
- Feature id: `instagram-hashtags`
- Feature title: `Hashtag discovery`
- Feature summary: cover hashtag search, top media, recent media, and recently
  searched hashtags with typed results and reader commands.
- Accepted design: `design-docs/specs/instagram-hashtags.md`
- Requested plan path: `docs/plans/instagram-hashtags.md`
- Canonical plan path: `impl-plans/instagram-hashtags.md`
- Codex agent references:
  `/root/instagram_hashtags_design_review`,
  `/root/instagram_hashtags_plan_review`

The canonical path follows the workflow requirement to keep implementation
plans under `impl-plans/`; no duplicate legacy-path plan is created.

## Accepted Design Review Input

The design was self-reviewed and independently accepted on 2026-08-13 after
these design defects were corrected:

- replaced obsolete/malformed Meta documentation links with canonical
  `/documentation/instagram-platform/` and `instagram-graph-api` paths;
- separated the hashtag edge's `instagram_basic` permission from the
  repository's conditional `pages_read_engagement` Page/account-discovery
  prerequisite;
- added `swift test` and `swift build -c release` to acceptance criteria;
- documented why `InstagramHashtag.name` is optional across search and recently
  searched response shapes.

Residual design risk carried into implementation: Meta permissions, fields,
limits, eligibility, and App Review behavior must be rechecked against the
configured Graph API version before docs or live results are finalized.

## Objective

Implement all four official hashtag discovery operations as explicit public
Swift reader APIs and `instagram-gateway-reader` commands, with typed results,
cursor pagination, stable redacted JSON, deterministic tests, release-build
verification, and documentation that separates code coverage from Meta
prerequisites and live verification.

## Deliverables

### 1. Revalidate The Provider Contract

Files consulted or updated:

- `design-docs/specs/instagram-hashtags.md`
- `docs/meta-setup.md`
- `docs/api-coverage.md`

Tasks:

- Check the accepted design's four request shapes against Meta's current
  Facebook Login hashtag-search guide, IG Hashtag reference, and recently
  searched edge for the repository's configured Graph API version.
- Confirm the supported media field expansion, pagination inputs, current
  recent-media time window, 30-unique-hashtags rolling-seven-day limit, and
  `instagram_basic` requirement.
- Record `pages_read_engagement` only as a conditional dependency of separate
  Page/account discovery, not as an endpoint permission.
- Record Advanced Access/App Review, linked Page, professional-account,
  app-role/ownership, and Live-mode prerequisites without claiming that Meta
  granted them.

Completion criteria:

- Any provider drift is reconciled in design/docs before code request builders
  are frozen.
- Provider-controlled prerequisites remain distinct from SDK/CLI coverage.

### 2. Add Public Typed DTOs

Primary file:

- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`

Tasks:

- Add `InstagramHashtag` with `id` and optional `name`.
- Add `InstagramHashtagMediaChild` with `id`, optional `mediaType`, and optional
  `mediaURL`.
- Add `InstagramHashtagMedia` with id, optional caption/media type/media URL/
  permalink/timestamp, optional nested children page, and optional comment/like
  counts.
- Add explicit public initializers for every DTO and map provider snake-case
  keys through explicit `CodingKeys`.
- Reuse `MediaType` so unknown provider values remain preserved.
- Keep provider ids, text, URLs, timestamps, and cursors as `String`.

Completion criteria:

- DTOs conform to `Codable`, `Equatable`, and `Sendable`.
- Public initializers construct every accepted shape.
- Search responses that omit `name` and media responses that omit counts or
  children decode without loss or false failure.

### 3. Add Reader Service Request Builders

Primary file:

- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`

Tasks:

- Add `searchHashtags(accountId:query:)` returning
  `Page<InstagramHashtag>` from `GET /ig_hashtag_search` with explicit
  `user_id` and normalized `q` query items.
- Add `topHashtagMedia(hashtagId:accountId:limit:after:)` returning
  `Page<InstagramHashtagMedia>` from `/{hashtag-id}/top_media`.
- Add `recentHashtagMedia(hashtagId:accountId:limit:after:)` returning
  `Page<InstagramHashtagMedia>` from `/{hashtag-id}/recent_media`.
- Add `recentlySearchedHashtags(accountId:limit:after:)` returning
  `Page<InstagramHashtag>` from
  `/{account-id}/recently_searched_hashtags`.
- Centralize the top/recent media field string so both methods request the same
  accepted typed shape, including child expansion when current Meta docs allow
  it.
- Reuse `InstagramGatewayClient.request` for bearer auth, decoding, redaction,
  and typed provider errors; do not add endpoint-specific token transport.

Completion criteria:

- Each method emits exactly one HTTP request and never performs hidden hashtag
  resolution or retry-by-variant behavior.
- Search preserves empty and multiple-element collections.
- Top/recent and recently-searched preserve provider paging.

### 4. Implement Local Validation And Query Normalization

Primary files:

- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`
- `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift`

Tasks:

- Reject empty account ids and hashtag ids before transport execution.
- Trim surrounding query whitespace and remove exactly one leading `#`.
- Reject an empty normalized query and internal whitespace while preserving
  Unicode hashtag text.
- Require positive `limit` values before transport execution.
- Parse `--limit` presence-aware and strictly: a missing value, nonnumeric
  value, zero, or negative value is a local configuration error rather than an
  absent limit.
- Treat `after` as opaque and pass it unchanged to URL construction.
- After consuming the accepted options for a hashtag subcommand, require no
  arguments to remain. This rejects unknown options and forbidden cross-command
  flags instead of silently ignoring them.
- Use existing typed configuration/unsupported errors and redacted envelopes;
  do not introduce command-only fatal exits.

Completion criteria:

- Invalid local input produces no recorded HTTP request.
- Valid Unicode and leading-`#` queries are URL-encoded by the existing
  transport instead of manually concatenated.

### 5. Add Reader CLI Routing And Help

Primary file:

- `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift`

Commands:

```text
hashtags search --query <hashtag> [--account-id <id>]
hashtags top-media --hashtag-id <id> [--account-id <id>] [--limit <n>] [--after <cursor>]
hashtags recent-media --hashtag-id <id> [--account-id <id>] [--limit <n>] [--after <cursor>]
hashtags recently-searched [--account-id <id>] [--limit <n>] [--after <cursor>]
```

Tasks:

- Route the `hashtags` reader family to the four new reader-service methods.
- Resolve omitted `--account-id` from the selected credential's configured
  Instagram user id using existing required-value behavior.
- Require `--query` only for search and `--hashtag-id` only for top/recent;
  reject missing or unknown subcommands/options deterministically.
- Explicitly reject `search --hashtag-id`, `top-media --query`, and
  `recent-media --query`, and reject every leftover positional/flag token after
  command-specific parsing.
- Encode results with the existing `SuccessEnvelope` and apply
  `Paging.redacted` before serialization.
- Add reader help entries and examples without adding writer help or writer
  routing.
- Do not require `--yes`; every operation is read-only.

Completion criteria:

- Reader CLI returns stable `ok`, typed `data`, and optional `paging` JSON for
  all four commands.
- Writer help and mutation confirmation behavior are byte-for-byte unchanged
  except for unrelated concurrent work.
- No command prints access tokens, app secrets, or token-bearing paging URLs.

### 6. Add Deterministic Core Tests

Primary file:

- `Tests/InstagramGatewayCoreTests/CoreTests.swift`

Tasks:

- Decode hashtag fixtures with and without `name`.
- Decode hashtag image, video, unknown media type, carousel children, absent
  children, and absent count fields.
- Assert exact search path/query and leading-`#`/Unicode normalization.
- Assert exact top/recent paths, `user_id`, accepted field string, positive
  `limit`, and opaque `after`.
- Assert exact recently-searched path/fields/pagination.
- Assert empty search results remain a successful empty page.
- Assert empty ids/query, internal-whitespace query, and zero/negative limits
  fail without transport calls.
- Reuse representative client tests for provider-error mapping and redaction;
  add a feature-specific assertion only where new behavior is introduced.

Completion criteria:

- Tests are deterministic, network-free, and use invented provider data.
- Request assertions fail if hidden extra calls or query drift are introduced.

### 7. Add Deterministic CLI Tests

Primary file:

- `Tests/InstagramGatewayCLITests/CLITests.swift`

Tasks:

- Assert reader help advertises all four operations and writer help does not.
- Route all four commands through `RecordingHTTPTransport` and assert exact
  outgoing paths/query items.
- Cover configured default account id and explicit override.
- Cover leading-`#` normalization, Unicode query, missing required options,
  unknown subcommand, unknown/leftover options, and forbidden cross-command
  flags (`search --hashtag-id`, `top-media --query`, and
  `recent-media --query`).
- Cover presence-aware strict limit parsing for missing values, nonnumeric
  values, zero, and negative values; every invalid case must record no
  transport call.
- Decode or inspect stable JSON field names for hashtag/media/children/counts.
- Include paging URLs containing invented `access_token`/`client_secret`
  values and prove the raw values never appear in output.
- Prove the reader commands run without `--yes`.

Completion criteria:

- All command routes have success coverage and representative local/provider
  failure coverage.
- CLI output remains valid JSON and secret-free.

### 8. Update Configuration And User Documentation

Primary files:

- `README.md`
- `docs/meta-setup.md`
- `docs/api-coverage.md`
- `Examples/config.example.toml` only if centralized scope examples require a
  current, scoped correction.

Tasks:

- Add concise reader command examples that resolve an id explicitly before
  top/recent calls and warn that a new unique search consumes provider quota.
- Document `instagram_basic` for hashtag calls and separately describe when
  Page discovery needs `pages_read_engagement`.
- Document linked Page/professional-account, role/ownership, Advanced Access/
  App Review, Live-mode, 30-unique/seven-day quota, recent-media window, public
  result incompleteness, and missing attribution limitations.
- Split the coverage row into explicit search, top media, recent media, and
  recently searched operations, each with SDK/CLI status and separate live/
  provider-prerequisite notes.
- Preserve kinko/env secret references; never add literal credentials or
  provider ids from the sandbox.

Completion criteria:

- Documentation distinguishes deterministic code completion, live result,
  permission/review status, and provider limitation for every operation.
- Examples do not imply automatic resolution, unlimited search, complete
  results, or third-party mutation.

### 9. Run Deterministic Verification

Commands:

```bash
swift test
swift build -c release
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
git diff --check
git diff HEAD -- Sources/InstagramGatewayCore/InstagramGatewayCore.swift Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift Tests/InstagramGatewayCoreTests/CoreTests.swift Tests/InstagramGatewayCLITests/CLITests.swift README.md docs/meta-setup.md docs/api-coverage.md Examples/config.example.toml design-docs/specs/instagram-hashtags.md impl-plans/instagram-hashtags.md
git status --short -- Sources/InstagramGatewayCore/InstagramGatewayCore.swift Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift Tests/InstagramGatewayCoreTests/CoreTests.swift Tests/InstagramGatewayCLITests/CLITests.swift README.md docs/meta-setup.md docs/api-coverage.md Examples/config.example.toml design-docs/specs/instagram-hashtags.md impl-plans/instagram-hashtags.md
git ls-files --others --exclude-standard -- Sources/InstagramGatewayCore/InstagramGatewayCore.swift Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift Tests/InstagramGatewayCoreTests/CoreTests.swift Tests/InstagramGatewayCLITests/CLITests.swift README.md docs/meta-setup.md docs/api-coverage.md Examples/config.example.toml design-docs/specs/instagram-hashtags.md impl-plans/instagram-hashtags.md
rg -n '(Bearer [A-Za-z0-9._-]{12,}|access_token=[^<[:space:]]+|client_secret=[^<[:space:]]+)' Sources/InstagramGatewayCore/InstagramGatewayCore.swift Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift Tests/InstagramGatewayCoreTests/CoreTests.swift Tests/InstagramGatewayCLITests/CLITests.swift README.md docs/meta-setup.md docs/api-coverage.md Examples/config.example.toml design-docs/specs/instagram-hashtags.md impl-plans/instagram-hashtags.md
```

Direct executable smoke checks use `--help`; functional command execution stays
inside injected-transport tests unless the explicit live prerequisites in the
next deliverable are satisfied.

Completion criteria:

- `swift test` exits successfully.
- `swift build -c release` exits successfully.
- Both help surfaces preserve reader/writer separation.
- `git diff --check` reports no whitespace errors.
- `git diff HEAD` covers staged and unstaged tracked edits; scoped status and
  untracked-file listing identify every untracked deliverable for manual
  inspection; the scoped credential-pattern scan is reviewed and any fixture
  false positive is proved invented.
- Scoped diff/status/untracked inspection finds no credential material, private
  URLs, unintended provider ids, or unrelated edits.

### 10. Perform Bounded Live Read Verification

Prerequisites:

- configured `taco-dev-sandbox` reader credential;
- linked and eligible professional account;
- current endpoint permissions/Advanced Access/App Review/account-role state;
- an explicitly quota-safe hashtag choice.

Commands, in safe order:

```bash
swift run instagram-gateway-reader --credential taco-dev-sandbox-reader config validate
swift run instagram-gateway-reader --credential taco-dev-sandbox-reader doctor
swift run instagram-gateway-reader --credential taco-dev-sandbox-reader hashtags recently-searched --pretty
swift run instagram-gateway-reader --credential taco-dev-sandbox-reader hashtags top-media --hashtag-id '<existing-id>' --limit 5 --pretty
swift run instagram-gateway-reader --credential taco-dev-sandbox-reader hashtags recent-media --hashtag-id '<existing-id>' --limit 5 --pretty
swift run instagram-gateway-reader --credential taco-dev-sandbox-reader hashtags search --query '<already-searched-term>' --pretty
```

Tasks:

- Run recently searched first and use an already-returned hashtag id/term when
  available.
- Validate and diagnose the explicitly selected
  `taco-dev-sandbox-reader` profile before any quota-affecting read; do not rely
  on whichever credential happens to be configured as the default.
- Do not search a new unique hashtag merely to satisfy a verification checkbox.
- Record status per operation as pass, empty-success, or Meta-blocked with a
  redacted reason.
- Do not persist raw response bodies containing unreviewed third-party public
  media, expose credentials, or contact/mutate any account.

Completion criteria:

- Every attempted operation has a dated, redacted result in coverage docs.
- Skipped or provider-blocked operations remain explicitly unverified; they do
  not prevent accurate deterministic code-coverage claims.

### 11. Final Safety Review And Parent Handoff

Tasks:

- Confirm only reader surfaces gained hashtag commands.
- Confirm no hidden search is made by top/recent calls and no live test spent a
  new unique query without an explicit recorded decision.
- Confirm deterministic tests and release build passed after the final edit.
- Confirm docs do not claim Meta prerequisite or live success that was not
  observed.
- Provide the parent workflow with exact changed paths, test/build commands,
  live outcomes, Meta-blocked operations, remaining risks, and no secrets.

Completion criteria:

- The parent has enough explicit evidence to review, commit, and push accepted
  changes under the parent issue-resolution workflow.
- This feature-local worker does not commit or push planning documents unless
  the parent workflow explicitly delegates that repository mutation.

## Dependencies And Sequencing

1. Provider revalidation precedes final request-field constants and live docs.
2. DTOs precede reader-service decoding.
3. Service methods and validation precede CLI routing.
4. Core request/decode tests can be written alongside service methods.
5. CLI tests follow stable service signatures and command routing.
6. Deterministic verification must pass before any live call.
7. Live verification is last and remains conditional on Meta prerequisites.
8. Documentation/coverage is finalized after deterministic and live outcomes
   are known.

Adjacent fanout work may touch the monolithic core and CLI files. Before each
edit, inspect current contents and preserve unrelated changes; resolve overlap
without resetting or overwriting another worker's work.

## Progress Tracking

- [ ] Revalidate current Meta provider contract and permissions.
- [ ] Add public hashtag DTOs and initializers.
- [ ] Add four reader-service operations.
- [ ] Add validation and query normalization.
- [ ] Add reader CLI routing and help.
- [ ] Add deterministic core tests.
- [ ] Add deterministic CLI tests.
- [ ] Update README, setup, coverage, and scoped config examples.
- [ ] Run `swift test`.
- [ ] Run `swift build -c release`.
- [ ] Run help, whitespace, scoped diff, status, and secret-safety checks.
- [ ] Attempt bounded live reads only when prerequisites and quota-safe inputs
  exist.
- [ ] Record exact deterministic/live outcomes and Meta-blocked gaps.
- [ ] Complete final safety review and parent handoff.

## Completion Criteria

### Step 6 implementation update — 2026-08-13

- Implemented typed hashtag DTOs and reader SDK methods for search, top, recent,
  and recently searched media, plus reader CLI routes and strict positive-limit
  and cursor validation.
- Added deterministic core/CLI coverage. `swift test` passed.
- Bounded live verification remains META_BLOCKED pending a configured owned
  account and explicit quota-safe approval.

- The accepted design's four typed service and reader CLI operations are
  implemented without hidden searches or writer-surface leakage.
- Public DTOs and service methods preserve API compatibility, optional provider
  fields, unknown media types, opaque ids, and paging cursors.
- Stable JSON output redacts token-bearing pagination and error content.
- Network-free unit/CLI tests cover request shapes, decoding, validation,
  routing, help boundaries, empty results, and secret redaction.
- `swift test`, `swift build -c release`, help checks, and `git diff --check`
  pass after final edits.
- README/setup/coverage state exact endpoint status, permissions, prerequisites,
  quota/recency limitations, and live result without overstating Meta access.
- No credential, private URL, owned provider id, third-party message, unowned
  asset mutation, destructive behavior, or published-media deletion claim is
  introduced.

## Risks

- Meta can change fields, scopes, time windows, quotas, account eligibility, or
  review gates between planning and implementation.
- A live search can consume scarce rolling-window quota even though it is a read.
- Public top/recent media is unstable and unsuitable as a deterministic fixture.
- Optional counts/children may vary with media type or provider visibility.
- Parallel fanout edits to monolithic Swift files can cause merge conflicts or
  accidental loss of unrelated work.
- Legacy requested doc paths differ from required canonical roots; duplicate
  documents would create conflicting sources of truth.

## Plan Review Record

- Self-review: accepted on 2026-08-13 with no remaining high or mid findings.
  It checked design-plan method/DTO/command consistency, deliverables and file
  ownership, provider and adjacent-feature dependencies, per-deliverable
  completion criteria, all-pending progress tracking, deterministic versus live
  verification, reader/writer safety, and parent handoff. A plan-only defect was
  corrected during self-review: a functional hashtag search was removed from
  deterministic shell verification because it would otherwise be a live,
  quota-consuming network call.
- Independent review: changes requested by
  `/root/instagram_hashtags_plan_review` on 2026-08-13: two mid plan-only
  findings (silent leftover/cross-command options and implicit live credential
  selection) and two low plan-only findings (incomplete invalid-limit matrix
  and incomplete staged/untracked safety inspection). No design defects were
  found.
- Addressed feedback: required zero leftover arguments and explicit forbidden
  cross-command tests; made limit parsing presence-aware for missing,
  nonnumeric, zero, and negative values; selected
  `taco-dev-sandbox-reader` and ran config/doctor before every live sequence;
  changed tracked inspection to `git diff HEAD` and added scoped status,
  untracked-file listing, and credential-pattern scanning.
- Independent re-review: accepted by
  `/root/instagram_hashtags_plan_review` with no remaining design or plan
  findings at high, mid, or low severity.
- Acceptance decision: accepted on 2026-08-13.

## Step 6 Implementation Update — 2026-08-13

- Status: implemented deterministically; live checks remain META_BLOCKED
  pending the configured sandbox credential and provider prerequisites.
