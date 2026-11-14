# Docs, Tests, And Release Readiness Implementation Plan

## Feature Contract

- Feature ID: `docs-tests-release-readiness`
- Workflow mode: `issue-resolution`
- Issue reference: `workflow-input:<workspace>#Build a Swift Instagram/Meta SDK and permission-separated CLI`
- Design reference: `design-docs/specs/docs-tests-release-readiness.md`
- Codex agent references: none
- Scope: README onboarding, Meta setup guide, live smoke-test commands, deterministic tests, CLI help checks, lint/build/test verification, and optional Homebrew-style packaging aligned with `../mail-gateway`.

## Deliverables

1. Root onboarding documentation in `README.md`.
   - Describe the Swift SDK, supported Instagram Graph API areas, reader/writer binary split, least-privilege permission posture, JSON output envelopes, error redaction, development commands, and links to deeper docs.
   - Match the concise structure and release/build orientation used by `../mail-gateway`.

2. Meta credential and app setup guide in `docs/meta-setup.md`.
   - Document setup for the test Instagram account `taco-dev-sandbox@mutvar.com` without recording credentials.
   - Separate reader baseline, reader extensions, writer baseline, and optional writer insights scopes.
   - Include kinko/environment secret names: `INSTAGRAM_GATEWAY_APP_ID`, `INSTAGRAM_GATEWAY_APP_SECRET`, `INSTAGRAM_GATEWAY_ACCESS_TOKEN`, `INSTAGRAM_GATEWAY_REDIRECT_URI`, `INSTAGRAM_GATEWAY_TEST_IG_USER_ID`, and `INSTAGRAM_GATEWAY_TEST_PAGE_ID`.
   - Explain redirect URI dependency on the auth implementation and require dated notes if Meta renames or replaces permissions during browser setup.

3. Live verification guide in `docs/live-smoke-tests.md`.
   - Provide opt-in reader diagnostics, account listing, media listing, writer diagnostics, and writer validation commands.
   - Keep mutating writer commands in a separate throwaway-target section.
   - Avoid commands that echo secrets or place real tokens in shell history examples.

4. Release readiness guide in `docs/release.md`.
   - Document expected Homebrew-style artifacts for both `instagram-gateway-reader` and `instagram-gateway-writer` on `darwin-arm64` and `darwin-x64`.
   - Include formula syntax/audit checks and a minimum checklist if packaging scripts are deferred.

5. Deterministic test coverage.
   - Add or verify tests under `Tests/InstagramGatewayCoreTests/`, `Tests/InstagramGatewayCLITests/`, `Tests/InstagramGatewayTestSupport/`, and `Tests/Fixtures/` as the package layout becomes available.
   - Cover Codable DTO round trips, enum unknown handling, pagination, API error mapping, redaction, JSON envelopes, CLI help, missing-credential doctor/config behavior, and reader/writer command separation.

6. Verification and progress record.
   - Run and record `swift build`, `swift test`, reader/writer `--help`, reader/writer `doctor --format json`, and lint when configured.
   - Record packaging verification if scripts are implemented; otherwise record the documented deferral.

## Dependencies

- Core SDK DTOs, pagination, API error types, transport injection, and redaction behavior from the SDK implementation feature.
- Reader CLI commands and parser entry points for read-only discovery, profile, media, comments, insights, config, and doctor operations.
- Writer CLI commands and parser entry points for publishing, replies, comment moderation, config, doctor, and validation-only publishing behavior.
- Auth/config feature decisions for redirect URI strategy, token loading, and kinko integration.
- `../mail-gateway` for CLI UX, package layout, JSON conventions, diagnostics, documentation style, release/build structure, and permission-oriented binary separation.

## Task Breakdown

1. Inspect reference conventions.
   - Read the relevant `mail-gateway` README, docs, package manifest, CLI target layout, test layout, and release scripts.
   - Capture only conventions needed by this feature.

2. Draft user-facing docs.
   - Create or update `README.md`, `docs/meta-setup.md`, `docs/live-smoke-tests.md`, and `docs/release.md`.
   - Use placeholders only for credentials and identifiers.
   - Keep reader and writer scopes in separate sections.

3. Add deterministic test scaffolding.
   - Add fixtures and test support utilities only where needed by the implemented SDK/CLI.
   - Prefer parser entry point tests for CLI behavior; use subprocess tests only where executable behavior must be verified.

4. Add readiness tests.
   - Assert CLI help exposes expected command families and critical flags.
   - Assert `doctor --format json` returns stable, redacted, non-secret JSON for missing or placeholder credentials.
   - Assert writer-only commands are absent from `instagram-gateway-reader`.

5. Add release documentation and optional scripts.
   - If release scripts are in scope, implement `scripts/build-homebrew-release.sh` and `scripts/render-homebrew-formula.sh` for two binaries.
   - If deferred, document the exact minimum release checklist in `docs/release.md`.

6. Run verification.
   - Execute required build, test, CLI help, and doctor commands.
   - Run lint if configured.
   - Run optional packaging verification only if packaging scripts/formulae are present.

## Parallelizable Tasks

- README and `docs/meta-setup.md` drafting can proceed after the scope split is stable.
- `docs/live-smoke-tests.md` can proceed in parallel with deterministic test planning.
- `docs/release.md` can proceed in parallel with CLI/API docs as long as binary names remain `instagram-gateway-reader` and `instagram-gateway-writer`.
- DTO/pagination/error fixture tests can proceed in parallel with CLI help and doctor tests once package targets exist.

## Progress Tracking

- [x] Reference repository conventions inspected.
- [x] `README.md` completed.
- [x] `docs/meta-setup.md` completed.
- [x] `docs/live-smoke-tests.md` completed.
- [x] `docs/release.md` completed.
- [x] Deterministic SDK tests added or confirmed.
- [x] CLI help and JSON envelope tests added or confirmed.
- [x] Reader/writer separation tests added or confirmed.
- [x] Verification commands run and recorded.
- [x] Packaging implemented or deferral documented.

## Implementation Record

- Added README onboarding, Meta setup guide, live smoke-test guide, release readiness guide, placeholder examples, deterministic fixtures, SDK tests, and CLI separation tests.
- Packaging scripts are deferred and documented in `docs/release.md`.
- Verification run: `swift build`, `swift test`, reader/writer `--help`, reader/writer offline doctor/config diagnostics.

## Revision Record

- Added CLI execution tests for reader media listing and writer moderation through injected transports, plus config-parser validation coverage for unsupported TOML keys.
- Confirmed Step 6 self-review high and mid findings are addressed in source and tests before independent review.

## Verification

Required commands:

```bash
swift build
swift test
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
swift run instagram-gateway-reader doctor --format json
swift run instagram-gateway-writer doctor --format json
```

Lint handling:

```bash
# Run the repository lint command if one is configured.
```

Optional packaging commands:

```bash
scripts/build-homebrew-release.sh darwin-arm64 darwin-x64
scripts/render-homebrew-formula.sh <version> ../homebrew-tap/Formula
ruby -c Formula/instagram-gateway-reader.rb
ruby -c Formula/instagram-gateway-writer.rb
brew audit --strict --formula tacogips/tap/instagram-gateway-reader
brew audit --strict --formula tacogips/tap/instagram-gateway-writer
```

## Completion Criteria

- `README.md` gives a new SDK or CLI user enough information to build, test, run help, understand reader/writer separation, and find setup/release docs.
- `docs/meta-setup.md` documents exact safe setup steps and permission scopes without secrets.
- `docs/live-smoke-tests.md` provides opt-in live commands and isolates any mutating writer operation behind explicit throwaway-target requirements.
- `docs/release.md` documents two-binary release readiness and either implemented packaging checks or a clear packaging deferral.
- Deterministic tests run without Meta network access or credentials.
- Required verification commands are run and their outcomes are recorded by the implementation branch.
- No source, fixture, documentation, generated artifact, log, or command example contains real credentials or access tokens.

## Addressed Feedback

- Scope specificity is preserved through concrete README, Meta setup, live smoke-test, deterministic test, CLI help, verification, and packaging deliverables.
- Reader baseline, reader extensions, writer baseline, and optional writer insights scopes are carried into the implementation tasks.
- Open questions about OAuth redirect URI, writer validation taxonomy, and packaging timing are represented as dependencies or conditional tasks rather than blockers.

## Risks

- Meta permission names, app-review gates, API version behavior, and login product setup may change during credential provisioning.
- Live writer smoke tests can mutate Instagram state unless kept opt-in with throwaway targets.
- Concurrent untracked feature plans under `impl-plans/` and design docs under `design-docs/` may require later reconciliation.
- CLI help snapshot tests may become brittle if they assert full prose instead of stable command availability and critical flags.
