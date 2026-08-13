# Divedra Implementation Workflow

Use this skill when refreshing user-facing documentation for the Divedra
design-and-implement review loop in this repository.

## Current Contract

- Workflow mode: `issue-resolution`
- Issue reference: `workflow-input:<workspace>#Build a Swift Instagram/Meta SDK and permission-separated CLI`
- Codex agent references: none
- Step 7 review decision: accepted
- Step 7 revision state: `needs_revision = false`

## Repository Surfaces

Refresh user-facing documentation before commit generation when implementation
review is accepted. Mandatory surfaces for this repository are:

- `README.md`
- `docs/meta-setup.md`
- `docs/live-smoke-tests.md`
- `docs/release.md`
- `.agents/skills/divedra-impl-workflow/SKILL.md`

Do not reopen design or implementation scope in this step. Documentation must
describe shipped behavior only.

## Shipped Behavior To Preserve

- Swift package product: `InstagramGatewayCore`
- Reader binary: `instagram-gateway-reader`
- Writer binary: `instagram-gateway-writer`
- Reader commands: `accounts pages`, `accounts instagram`,
  `accounts business-discovery`, `account get`, `media list|get`,
  `comments list|get`, `insights account|media`, `doctor`,
  `config validate`, and `version`
- Writer commands: `media create-container`, `media container-status`,
  `media publish`, `comments reply`, `comments hide`, `comments unhide`,
  `comments delete`, `doctor`, `config validate`, and `version`
- Shared flags: `--config`, `--credential`, `--pretty`, `--help`, and
  `--version`
- Writer state-changing commands require `--yes`
- CLI output uses JSON success and error envelopes
- Diagnostics and errors redact tokens, app secrets, auth codes,
  `client_secret`, `appsecret_proof`, authorization headers, and known secret
  values
- Configuration discovers `--config`, `INSTAGRAM_GATEWAY_CONFIG`,
  `$XDG_CONFIG_HOME/instagram-gateway/config.toml`, then
  `~/.config/instagram-gateway/config.toml`
- Credential profiles use `access_mode = "read"` or `access_mode = "write"`

## Verification Record

Accepted verification before this documentation refresh:

- `swift build`: build completed; wrapper timed out during environment wait
- `swift test`: passed; 24 Swift Testing tests passed
- `.build/debug/instagram-gateway-reader --help`: reader help listed read
  command families; wrapper timeout matched prior environment behavior
- `.build/debug/instagram-gateway-writer media create-container --account ig --image-url https://example.test/image.jpg`:
  passed negative check with exit 4 and `CONFIRMATION_REQUIRED`
- `swift run instagram-gateway-reader --help`: passed
- `swiftlint`: not rerun; prior run reported unavailable or timed out on PATH

## Residual Risks

- Meta permission names, app setup paths, app-review gates, and API version
  behavior require live verification before credential provisioning.
- Live reader/writer API execution requires external credentials and
  Instagram/Facebook asset state.
- Token refresh and `appsecret_proof` policy remain open implementation
  boundaries.
- Live mutating writer smoke tests must remain opt-in with throwaway targets.
