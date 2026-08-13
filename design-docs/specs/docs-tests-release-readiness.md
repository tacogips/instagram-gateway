# Docs, Tests, And Release Readiness

## Feature Contract

- Feature ID: `docs-tests-release-readiness`
- Workflow mode: `issue-resolution`
- Issue reference: `workflow-input:<workspace>#Build a Swift Instagram/Meta SDK and permission-separated CLI`
- Implementation plan: `impl-plans/docs-tests-release-readiness.md`
- Reference repository: `../mail-gateway`
- Scope: README onboarding, Meta setup guide, live smoke-test commands, deterministic tests, CLI help checks, lint/build/test verification, and optional Homebrew-style packaging.

This design covers the repository readiness layer for a new Swift Instagram/Meta SDK and permission-separated CLI. It does not own the core SDK surface or CLI command behavior, but it defines the documentation, verification, and release contracts that must make those features usable and auditable.

## Goals

1. Make first-run onboarding complete for both Swift library users and CLI users.
2. Keep reader and writer setup visibly separate so required Meta scopes and binaries remain least-privileged.
3. Document safe credential provisioning for the test Instagram account `taco-dev-sandbox@mutvar.com` without placing secrets in source, fixtures, logs, examples, shell history, or generated artifacts.
4. Provide deterministic local verification that runs without Meta credentials.
5. Provide live smoke-test commands that can be copied after credentials are provisioned.
6. Align build, diagnostics, JSON output expectations, and optional Homebrew-style packaging with `../mail-gateway`.

## Documentation Deliverables

### `README.md`

The README must be the entry point for:

- Package overview and supported API areas.
- SwiftPM library usage for the core SDK module.
- Split CLI binaries:
  - `instagram-gateway-reader` for read-only discovery, profile, media, comments, insights, config, and doctor operations.
  - `instagram-gateway-writer` for publishing, replies, comment moderation, config, and doctor operations.
- Development commands:
  - `swift build`
  - `swift test`
  - `swift run instagram-gateway-reader --help`
  - `swift run instagram-gateway-writer --help`
- JSON output conventions, including stable success envelopes, stable error envelopes, pagination fields, and redaction guarantees.
- Secret handling rules and supported environment variables.
- Links to Meta setup, live verification, and packaging docs.

The README should follow the concise structure used by `mail-gateway`: short project purpose, development commands, target layout, and packaging pointers.

### `docs/meta-setup.md`

This guide must document exact setup steps for a Meta app suitable for a test Instagram account without embedding credentials. It should include:

- Required Meta product setup for Instagram Graph API use.
- Test user/account expectations for `taco-dev-sandbox@mutvar.com`.
- Redirect URI conventions for local token flows, if implemented by the auth feature.
- Reader scope names and writer scope names in separate sections.
- Token type and expiration caveats.
- Kinko/environment secret names and safe command patterns.
- Parent-agent browser tasks that may need Brave developer-console access.

Initial scope split to document and validate against the reader and writer
feature docs:

- Reader baseline:
  - `instagram_basic`
  - `pages_show_list`
  - `pages_read_engagement`
- Reader insights extension:
  - `instagram_manage_insights`
- Reader comments extension:
  - `instagram_manage_comments`
- Writer baseline:
  - `instagram_basic`
  - `instagram_content_publish`
  - `instagram_manage_comments`
  - `pages_show_list`
  - `pages_read_engagement`
- Writer optional insights validation:
  - `instagram_manage_insights`

`docs/meta-setup.md` must explain that Meta may gate permissions by app type,
API version, account type, app review state, and selected login product. If Meta
renames or replaces a permission during browser developer-console setup, the
docs must record the current Meta name, date checked, and related reader or
writer command that requires it instead of silently broadening requested scopes.

Safe secret names:

- `INSTAGRAM_GATEWAY_APP_ID`
- `INSTAGRAM_GATEWAY_APP_SECRET`
- `INSTAGRAM_GATEWAY_ACCESS_TOKEN`
- `INSTAGRAM_GATEWAY_REDIRECT_URI`
- `INSTAGRAM_GATEWAY_TEST_IG_USER_ID`
- `INSTAGRAM_GATEWAY_TEST_PAGE_ID`

Examples must use placeholders such as `<meta-app-id>` and must not include real credentials, real access tokens, or values copied from a browser session.

### `docs/live-smoke-tests.md`

Live smoke tests must be explicit but opt-in. They should assume credentials have already been provisioned and should never echo secret values.

Required command families:

- Reader diagnostics:
  - `swift run instagram-gateway-reader doctor --format json`
  - `swift run instagram-gateway-reader accounts list --format json`
  - `swift run instagram-gateway-reader media list --ig-user-id "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --limit 2 --format json`
- Writer diagnostics:
  - `swift run instagram-gateway-writer doctor --format json`
- Writer dry-run or validation-only commands where supported:
  - `swift run instagram-gateway-writer publish validate --ig-user-id "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --format json`

Any mutating smoke command must be isolated in a clearly labeled section and require the operator to provide a throwaway media/container/comment target.

### `docs/release.md`

Release documentation should describe local release readiness and optional Homebrew-style packaging. It must align with `mail-gateway` conventions while preserving the two-binary split.

Expected package artifacts:

- `dist/homebrew/instagram-gateway-reader-<version>-darwin-arm64.tar.gz`
- `dist/homebrew/instagram-gateway-reader-<version>-darwin-x64.tar.gz`
- `dist/homebrew/instagram-gateway-writer-<version>-darwin-arm64.tar.gz`
- `dist/homebrew/instagram-gateway-writer-<version>-darwin-x64.tar.gz`
- Matching `.sha256` files.

Expected verification:

- `ruby -c Formula/instagram-gateway-reader.rb`
- `ruby -c Formula/instagram-gateway-writer.rb`
- `brew audit --strict --formula tacogips/tap/instagram-gateway-reader`
- `brew audit --strict --formula tacogips/tap/instagram-gateway-writer`

If Homebrew packaging is deferred, `docs/release.md` must still document the decision and the minimum release checklist.

## Test Strategy

Deterministic tests must not require network access or Meta credentials. The SDK should use dependency-injected async HTTP transport so tests can run against fixtures and scripted responses.

Required deterministic coverage:

- Codable round trips for public DTOs, including account, media, comments, insights, publishing, pagination, and API error models.
- Typed provider-controlled closed-set enums with unknown/fallback handling where the Meta API may add values.
- Pagination parsing and next-page request construction.
- Error decoding, HTTP status mapping, and secret redaction.
- Reader CLI JSON success and error envelope snapshots.
- Writer CLI JSON success and error envelope snapshots.
- CLI help output for both binaries.
- Config and doctor behavior with missing credentials.
- Permission separation checks proving writer-only commands are absent from `instagram-gateway-reader`.

Recommended test layout:

- `Tests/InstagramGatewayCoreTests/`
- `Tests/InstagramGatewayCLITests/`
- `Tests/InstagramGatewayTestSupport/`
- `Tests/Fixtures/`

CLI tests should invoke parser entry points or executable subprocesses without relying on live Meta credentials.

## Verification Commands

The implementation branch must run and record:

```bash
swift build
swift test
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
swift run instagram-gateway-reader doctor --format json
swift run instagram-gateway-writer doctor --format json
```

If lint is configured, run the repository lint command. If no lint command exists, record that lint was not configured.

Optional packaging verification:

```bash
scripts/build-homebrew-release.sh darwin-arm64 darwin-x64
scripts/render-homebrew-formula.sh <version> ../homebrew-tap/Formula
```

## Decisions

- Keep onboarding documentation in the repository root README and deeper operational docs under `docs/`.
- Use two CLI binaries only: `instagram-gateway-reader` and `instagram-gateway-writer`.
- Treat live smoke tests as credential-gated operator commands, not as part of default `swift test`.
- Require all non-live verification commands to be deterministic and secret-free.
- Use environment and kinko-compatible secret names that are specific to `instagram-gateway`.
- Model release packaging after `mail-gateway` but generate two formulae instead of three.
- Make doctor/config commands available in both binaries so each binary can diagnose its own credential and permission posture.

## Open Questions

- The final Meta OAuth redirect URI depends on the authentication feature's selected local callback strategy.
- The exact writer validation command name may change if the publishing feature chooses a different subcommand taxonomy.
- Homebrew packaging may be implemented immediately or documented as deferred, depending on available release-script time in the implementation branch.

## Risks

- Meta's API permissions and app-review behavior can change; docs must identify setup dates and avoid promising app-review outcomes.
- Live writer smoke tests can mutate Instagram state; docs must keep those commands opt-in and require throwaway targets.
- Help-output snapshots can become brittle if command text changes frequently; tests should assert stable command availability and critical flags rather than every paragraph.
- Examples that include shell exports can leak into shell history if they encourage inline secrets; docs must prefer kinko or placeholder-only environment examples.
