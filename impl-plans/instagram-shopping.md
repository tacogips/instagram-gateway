# Shopping And Product Tagging Implementation Plan

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference:
  `workflow-input:codex-design-and-implement-review-loop-session-695`
- Feature id: `instagram-shopping`
- Feature title: `Shopping and product tagging`
- Fanout group: `feature-local-planning`
- Fanout index: `4`
- Accepted design: `design-docs/specs/instagram-shopping.md`
- Implementation plan: `impl-plans/instagram-shopping.md`
- Codex agent references: none

The runtime contract supplied legacy paths under `docs/`. This repository's
workflow requires plans under `impl-plans/`; this file follows that rule and the
existing repository convention. The planning worker changes only the accepted
design and this plan.

## Objective

Implement the accepted Instagram Shopping surface in the public Swift SDK,
reader CLI, writer CLI, deterministic tests, and coverage documentation while
preserving public source compatibility and preventing any live mutation of
unowned media or Commerce assets.

## Accepted Design Review Input

The design is accepted with no remaining high or mid findings. Implementation
must carry forward these corrected design defects:

- Existing-media product tagging is additive/update-only, not replacement or
  removal.
- Provider authorization alone is insufficient as a live-safety statement;
  writer commands require an account ownership anchor and live writes require
  documented owned disposable fixtures.
- Shopping/product tagging is bound to the Instagram API with Facebook Login;
  the Instagram Login flow does not support tagging.
- Tagged standalone video follows the existing `.video`-as-Reel contract; this
  feature does not introduce a separate feed-video publishing type.

Low residual design risks remain: provider/version drift, numeric JSON IDs,
asynchronous Commerce review, imperfect local proof of asset ownership, and
source-compatible coexistence with `providerFields`.

## Dependencies And Sequencing

- `design-docs/specs/instagram-shopping.md` is the behavioral source of truth.
- Existing shared implementation in
  `Sources/InstagramGatewayCore/InstagramGatewayCore.swift` provides config,
  transport, error mapping, redaction, pagination, reader/writer services, and
  media-container publishing.
- Existing CLI routing in
  `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift` provides credential
  mode checks, confirmation handling, argument parsing, and JSON envelopes.
- Existing tests in `Tests/InstagramGatewayCoreTests/CoreTests.swift` and
  `Tests/InstagramGatewayCLITests/CLITests.swift` establish injected-transport
  and command-test patterns.
- Commerce permissions, App Review/Advanced Access, eligible Business account,
  approved Shop/catalog, catalog administration, approved products, and owned
  media fixtures are external Meta prerequisites. They do not block
  deterministic implementation or count as code defects.
- DTO/fixture work precedes service and CLI work. Reader and writer request
  construction may proceed independently after DTO names and coding keys are
  stable. Documentation follows accepted command names and verified tests.

## Deliverables And Work Packages

### 1. Confirm the versioned provider contract

Files:

- `design-docs/specs/instagram-shopping.md` only if official current-version
  facts require a scoped design correction
- implementation notes in `docs/api-coverage.md`

Tasks:

- Recheck Meta's official Product Tagging guide against the configured Graph
  API version before coding.
- Record endpoint paths, response wrappers, field coding keys, tag limits,
  Business-only restrictions, Facebook Login restriction, and exact permission
  prerequisites.
- Treat missing permissions, disabled Shopping, ineligible checkout/Shop setup,
  and unavailable fixtures as provider prerequisites, not reasons to weaken the
  typed API or fabricate live success.

Completion criteria:

- Every implemented endpoint maps to an official operation in the accepted
  design.
- Any current-version drift is documented and reflected in fixtures/tests.
- No Marketing/Ads or general catalog-management mutation enters scope.

### 2. Add Shopping DTOs and lossless provider-ID coding

Files:

- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`
- `Tests/InstagramGatewayCoreTests/CoreTests.swift`
- new JSON fixtures under `Tests/Fixtures/` where fixture decoding is clearer

Tasks:

- Add public `Codable`, `Equatable`, `Sendable` types:
  `ShoppingEligibility`, `ShoppingCatalog`, `ProductReviewStatus`,
  `ShoppingProductVariant`, `ShoppingProduct`, `ProductTagInput`,
  `PublishedProductTag`, `ProductAppealStatus`, `UpdateProductTagsInput`,
  `SubmitProductAppealInput`, and `ShoppingMutationResult`.
- Add coding keys for snake-case provider fields.
- Add one internal reusable lossless ID decoder that accepts strings or integer
  JSON tokens and produces exact decimal `String` values without `Double`.
- Normalize `""` and `no_review` to `.noReview`; preserve other unknown review
  strings through `.unknown(String)`.
- Add `productTags: [ProductTagInput] = []` to
  `CreateMediaContainerInput` without removing or reordering existing labeled
  initializer arguments in a source-breaking way.

Completion criteria:

- Public DTO round-trip tests pass for known and unknown review states.
- Numeric and string product/catalog/merchant IDs decode to exact strings.
- Existing construction of `CreateMediaContainerInput` continues to compile and
  behave unchanged when `productTags` is omitted.

### 3. Implement validation and typed JSON parameter encoding

Files:

- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`
- `Tests/InstagramGatewayCoreTests/CoreTests.swift`

Tasks:

- Add centralized tag validation for non-empty/unique IDs, paired coordinates,
  finite values, range `0.0...1.0`, per-media coordinate rules, non-empty
  update sets, and documented count limits.
- Reject product tags for Story/Live publishing types and reject incompatible
  coordinates for feed video/Reel requests.
- JSON-encode `product_tags` and `updated_tags` from `[ProductTagInput]`; never
  interpolate JSON strings manually.
- Reserve `providerFields["product_tags"]` and reject it before sending a
  request. Leave other provider fields source-compatible.
- Keep named internal limits so a future API-version correction changes one
  tested definition.

Completion criteria:

- Invalid inputs fail before the injected transport records a request.
- Encoded JSON decodes back to the expected tag array and appears exactly once
  in the provider request.
- Boundary tests cover zero/one, maximum, maximum-plus-one, `NaN`, infinities,
  out-of-range coordinates, duplicate IDs, and media-type mismatches.

### 4. Implement reader Shopping operations

Files:

- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`
- `Tests/InstagramGatewayCoreTests/CoreTests.swift`

Tasks:

- Add `shoppingEligibility(accountId:)`.
- Add paginated `availableCatalogs(accountId:limit:after:)`.
- Add paginated
  `searchCatalogProducts(accountId:catalogId:query:limit:after:)`; omit `q`
  when no query is supplied so the endpoint enumerates eligible products.
- Add paginated `productTags(mediaId:limit:after:)`.
- Add `productAppealStatus(accountId:productId:)`.
- Add paginated `mediaChildren(mediaId:limit:after:)` for carousel inspection.
- Reuse current paging and provider-error/redaction paths.

Completion criteria:

- Injected-transport tests assert method, path, query fields, optional query
  omission, cursor parameters, and response DTOs for every operation.
- Pagination remains caller-controlled and token-bearing next URLs are
  sanitized before CLI output.
- All operations are registered only on the reader service surface.

### 5. Implement writer Shopping operations and tagged containers

Files:

- `Sources/InstagramGatewayCore/InstagramGatewayCore.swift`
- `Tests/InstagramGatewayCoreTests/CoreTests.swift`

Tasks:

- Extend `createMediaContainer(_:)` to send validated typed `product_tags` for
  supported images, Reels, and carousel children. Preserve the existing
  standalone `.video`-as-Reel mapping.
- Preserve the existing container-status and publish workflow; do not add
  automatic publishing.
- Add `addOrUpdateProductTags(_:)` using
  `POST /{ig-media-id}/product_tags` with `updated_tags`.
- Add `submitProductAppeal(_:)` using
  `POST /{ig-user-id}/product_appeal` with `product_id` and `appeal_reason`.
- Decode provider `success` into `ShoppingMutationResult`; do not interpret an
  accepted appeal as approval.
- Validate the non-empty account audit anchor in both mutation inputs even when
  the provider request path uses the media ID.

Completion criteria:

- Request-construction tests cover each supported tagged container type,
  existing-media tag updates, and appeal submissions.
- Story/Live, empty tags/reasons, and invalid coordinates send zero requests.
- No operation creates, edits, deletes, or reassigns catalogs/products/Shops.

### 6. Add permission-separated CLI commands

Files:

- `Sources/InstagramGatewayCLI/InstagramGatewayCLI.swift`
- `Tests/InstagramGatewayCLITests/CLITests.swift`

Tasks:

- Register reader commands:
  `shopping eligibility`, `shopping catalogs`, `shopping products`,
  `shopping product-tags`, `shopping appeal-status`, and `media children`.
- Register writer commands:
  `shopping update-product-tags` and `shopping appeal`.
- Extend writer `media create-container` with `--product-tags-json`.
- Decode `--product-tags-json` strictly: first reject object keys outside
  `product_id`, `x`, and `y`, then decode `[ProductTagInput]` and run shared
  semantic validation. Synthesized `Decodable` alone is not sufficient because
  it ignores unknown keys.
- Require `--yes` for tagged container creation, existing-media tag updates,
  and appeal submission before config loading or transport invocation.
- Require write profiles for mutations and read profiles for reads.
- Require `--account` for writer Shopping commands and reject mismatch with a
  selected profile's configured `instagram_user_id`.
- Keep mutation verbs absent from reader routing and update deterministic help.

Completion criteria:

- CLI tests cover command parsing, stable JSON, help text, pagination flags,
  malformed/unknown-key tag JSON, missing arguments, missing confirmation,
  wrong credential mode, configured-account mismatch, and redaction.
- Confirmation/profile/account failures record no transport request.
- Reader attempts to invoke Shopping mutations return the existing structured
  unsupported-operation error.

### 7. Add deterministic regression coverage

Files:

- `Tests/InstagramGatewayCoreTests/CoreTests.swift`
- `Tests/InstagramGatewayCLITests/CLITests.swift`
- `Tests/Fixtures/*shopping*.json` as needed

Tasks:

- Add fixtures for eligibility, catalogs, products/variants, published tags,
  appeal status, and success responses.
- Add focused SDK and CLI tests from the accepted design test matrix.
- Add regression assertions for existing untagged create-container requests and
  source-compatible DTO initialization.
- Scan captured diagnostics/output for access tokens, app secrets,
  `client_secret`, `appsecret_proof`, Authorization values, and token-bearing
  paging URLs.

Completion criteria:

- `swift test` passes deterministically without network access.
- Tests prove both successful request construction and fail-before-send safety.
- Existing reader, writer, config, publishing, moderation, and redaction tests
  remain green.

### 8. Update documentation and coverage status

Files:

- `README.md`
- `docs/api-coverage.md`
- `docs/meta-setup.md`
- `docs/live-smoke-tests.md`

Tasks:

- Document command examples with placeholders only and `--yes` on all mutations.
- Split code coverage from Meta prerequisites and live results for eligibility,
  catalogs, product search, tag reads, typed tagged publishing, existing-media
  tag updates, appeal status, and appeal submission.
- Document Facebook Login, Business account, approved Shop/catalog, Business
  Manager admin role, required permissions/App Review/Advanced Access, product
  review status, tag limits, and owned-fixture rules.
- State that tag updates are additive and appeal receipt is not approval.
- Preserve the provider limitation for deleting published Instagram media.

Completion criteria:

- No documentation contains credentials, private URLs, real catalog/product
  IDs, or examples targeting unowned assets.
- Every operation has an explicit SDK/CLI status, deterministic status, live
  status, and prerequisite note.
- Provider-blocked operations are labeled blocked/not-run, never passed.

### 9. Perform safe live verification only when prerequisites exist

Files:

- `docs/live-smoke-tests.md`
- `docs/api-coverage.md`

Tasks:

- Run safe reads against the configured `taco-dev-sandbox` Business account:
  eligibility, available catalogs, product search, product tags on owned media,
  and appeal status for an owned product when such IDs exist.
- Before any mutation, document that the selected account, media, catalog, and
  product are owned/administered sandbox fixtures and that the effect is
  acceptable. Require explicit `--yes`.
- Do not submit an appeal merely to prove code coverage. Run it only for an
  actually rejected owned product where the account owner intentionally wants
  the appeal.
- Do not update tags on existing media unless the media is owned/disposable and
  the desired additive change is known. Do not touch collaborative/unowned
  Commerce assets.
- Record missing eligibility, permissions, Advanced Access/App Review, Shop,
  catalog, products, or fixtures as `blockedByMetaPrerequisite`.

Completion criteria:

- Safe reads are recorded with date/API version and redacted identifiers.
- Every live mutation has an explicit owned-fixture record, or is not run.
- No third party is messaged and no unowned Commerce asset is mutated.

### 10. Run full verification and prepare parent-workflow handoff

Files:

- all feature implementation files above
- no release artifact or secret file is committed

Tasks:

- Run deterministic debug tests and release build.
- Run CLI help and representative offline/parser checks.
- Inspect diffs for scope, public API compatibility, credentials, private URLs,
  and machine-local paths.
- Update this plan's progress and implementation record with actual results.
- Commit and push only after the parent review loop accepts the combined changes
  and all required checks pass.

Completion criteria:

- Required verification commands pass, or each external-only block is recorded
  precisely without claiming success.
- Git diff contains only accepted feature work and coordinated shared docs.
- Parent workflow receives explicit file paths, test commands/results, live
  results/blocks, and residual risks.

## Progress Tracking

- [x] Create feature-local design.
- [x] Self-review feature-local design and correct high/mid defects.
- [x] Independently cold-review feature-local design and correct high/mid
  defects.
- [x] Create feature-local implementation plan from accepted design.
- [x] Self-review plan for consistency, deliverables, dependencies, completion
  criteria, tracking, and verification.
- [x] Independently cold-review plan and correct high/mid defects.
- [ ] Confirm current Graph API Shopping contract during implementation.
- [ ] Implement DTOs, lossless IDs, validation, and typed tag encoding.
- [ ] Implement reader Shopping operations.
- [ ] Implement writer Shopping operations and tagged containers.
- [ ] Implement permission-separated CLI commands.
- [ ] Add deterministic SDK/CLI fixtures and tests.
- [ ] Update README, setup, live-smoke, and coverage documentation.
- [ ] Perform safe live reads and only eligible owned/reversible writes.
- [ ] Run full test/release verification and parent review.
- [ ] Commit and push accepted combined changes.

## Verification Commands

Planning artifact checks:

```bash
git diff --check -- design-docs/specs/instagram-shopping.md impl-plans/instagram-shopping.md
rg -n "workflow-input:codex-design-and-implement-review-loop-session-695|instagram-shopping|accepted|high|mid|blockedByMetaPrerequisite" design-docs/specs/instagram-shopping.md impl-plans/instagram-shopping.md
git status --short -- design-docs/specs/instagram-shopping.md impl-plans/instagram-shopping.md
```

Required deterministic implementation checks:

```bash
swift test
swift build -c release
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
swift run instagram-gateway-reader config validate --config Tests/Fixtures/reader-valid.toml --pretty
swift run instagram-gateway-writer config validate --config Examples/config.placeholder.toml --pretty
git diff --check
git status --short
```

Focused tests to add and run (final test names may follow Swift Testing naming
conventions, but each behavior remains mandatory):

```bash
swift test --filter shopping
swift test --filter productTag
swift test --filter productAppeal
swift test --filter shoppingConfirmation
swift test --filter shoppingAccountMismatch
swift test --filter shoppingRedaction
```

Safe live reads only after configured prerequisites exist:

```bash
swift run instagram-gateway-reader shopping eligibility --account-id "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --pretty
swift run instagram-gateway-reader shopping catalogs --account-id "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --limit 5 --pretty
swift run instagram-gateway-reader shopping products --account-id "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --catalog-id "<owned-catalog-id>" --limit 5 --pretty
swift run instagram-gateway-reader shopping product-tags --media-id "<owned-media-id>" --pretty
swift run instagram-gateway-reader shopping appeal-status --account-id "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --product-id "<owned-product-id>" --pretty
```

Mutation commands are documentation templates, not automatic verification.
Run only after the owned-fixture gate in work package 9 is satisfied:

```bash
swift run instagram-gateway-writer media create-container --account "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --image-url "<owned-public-test-image-url>" --product-tags-json '[{"product_id":"<owned-approved-product-id>","x":0.5,"y":0.5}]' --yes --pretty
swift run instagram-gateway-writer shopping update-product-tags --account "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --media-id "<owned-disposable-media-id>" --product-tags-json '[{"product_id":"<owned-approved-product-id>","x":0.5,"y":0.5}]' --yes --pretty
swift run instagram-gateway-writer shopping appeal --account "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --product-id "<owned-rejected-product-id>" --reason "<intentional-appeal-reason>" --yes --pretty
```

## Completion Criteria

### Step 6 rerun update — 2026-08-13

- Added typed Shopping DTOs, lossless integer/string IDs, reader eligibility,
  catalog/product/tag/appeal operations, typed product tags on containers, and
  guarded writer update/appeal CLI routes.
- Commerce ownership cannot be proven locally; live Commerce operations remain
  META_BLOCKED pending eligible owned catalog/product fixtures.
- Added deterministic lossless-ID and fail-before-send tag validation tests.

- All accepted reader and writer operations exist as typed public Swift APIs
  and in the correct permission-separated CLI.
- New DTOs are public, `Codable`, `Equatable`, `Sendable`, resilient to unknown
  review states, and lossless for string/numeric provider IDs.
- Typed tag validation prevents malformed, duplicate, out-of-range,
  over-limit, unsupported-media, and pass-through-conflict requests.
- Existing public initializer call sites remain source-compatible.
- All CLI mutations require write credentials, `--yes`, explicit account IDs,
  and configured-account consistency before transport use.
- Deterministic tests cover every endpoint, DTO, validation branch, binary
  boundary, confirmation gate, ownership anchor, and redaction behavior.
- Documentation separates code coverage, deterministic verification, live
  verification, and named Meta prerequisites per operation.
- Safe live reads may pass; writes run only against documented owned fixtures.
  Missing provider prerequisites remain explicit blocks, not failures hidden by
  claims of completion.
- `swift test` and `swift build -c release` pass before accepted changes are
  committed and pushed by the parent workflow.

## Plan Review Record

### Self-review decision

Accepted after checking design-plan consistency, all design deliverables,
file-level dependencies, completion criteria, progress state, deterministic and
live verification, public API compatibility, and ownership safety. One
mid-severity plan-only defect was corrected: synthesized Swift decoding does not
reject unknown JSON keys, so the CLI task now requires an explicit allowed-key
check before decoding `--product-tags-json`.

### Independent review decision

Accepted in a separate cold review with no remaining high or mid findings. One
mid-severity plan-only defect was corrected: the initial verification section
could be read as authorizing every listed mutation. The accepted plan labels
mutation commands as templates and gates them on documented owned fixtures and
intentional effects. A second mid-severity plan-only defect was corrected by
requiring configured-account mismatch rejection before transport use.

## Addressed Feedback

Design defects addressed before planning:

- Corrected replacement/removal semantics to additive tag updates.
- Added account ownership anchors, owned-fixture live gates, and fail-closed
  handling for uncertain ownership or reversibility.
- Bound the feature to Facebook Login and excluded the unsupported Instagram
  Login tagging path.
- Aligned tagged standalone video with the existing Reel publishing contract.

Plan-only defects addressed during plan review:

- Added strict allowed-key checking for CLI tag JSON.
- Marked live mutations as conditional templates rather than routine checks.
- Added configured-account mismatch rejection and no-request assertions.

## Risks

- Meta permission names, tag limits, response wrappers, and eligibility policy
  can drift by Graph API version; current official docs must be checked at
  implementation time.
- Numeric provider IDs require careful custom decoding to avoid precision loss.
- Account-ID consistency plus provider authorization cannot independently prove
  ownership of every media/product; live fixture provenance remains mandatory.
- Product review and appeals are asynchronous and may be impossible to exercise
  safely in the configured sandbox.
- Shared one-file core/CLI implementations increase merge-conflict risk with
  other fanout features; edits must be narrow and tests must cover neighboring
  behavior.
- Preserving `providerFields` while reserving `product_tags` requires explicit
  conflict validation and regression coverage.
- Meta may require broadly named Commerce permissions for read endpoints; the
  reader binary stays non-mutating even when provider permission granularity is
  coarser than the local read/write boundary.

## Step 6 Implementation Update — 2026-08-13

- Status: partial. Facebook-Login product-tag gating and media-children reader
  routing are implemented; 1...5 tag-count validation is deterministic. Owned
  Commerce mutations, including tagged container creation, now fail closed
  unless the selected profile declares the `owned_commerce_fixture` feature;
  configured-account mismatch and missing ownership metadata are rejected
  before transport. `swift test` (53 tests)
  and `swift build -c release` passed. Owned Commerce live evidence remains
  META_BLOCKED.
