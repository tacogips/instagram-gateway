# instagram-gateway

Swift SDK and command-line gateway for practical Meta Instagram Graph API work.

The package builds one reusable library and two least-privileged binaries:

- `InstagramGatewayCore`: async SDK, DTOs, pagination, typed errors, injected HTTP transport, config loading, diagnostics, and redaction.
- `instagram-gateway-reader`: read-only discovery, profile, media, comments, and supported insights commands.
- `instagram-gateway-writer`: publishing workflow and comment reply/moderation commands that require write-compatible credentials and confirmation for state changes.

## Swift Library

Add the package through SwiftPM and import `InstagramGatewayCore`. Construct
`InstagramGatewayClient` with an injected `HTTPTransport` and a token loaded
outside source control. The SDK exposes stable `Codable`/`Sendable` DTOs,
`InstagramReaderService`, `InstagramWriterService`, `Page<T>`, typed
`InstagramGatewayError` values, and a `ConfigLoader` for TOML credential
profiles.

## Development

```bash
swift build
swift test
swift run instagram-gateway-reader --help
swift run instagram-gateway-writer --help
swift run instagram-gateway-reader config validate --config Examples/config.example.toml
swift run instagram-gateway-writer doctor --config Examples/config.placeholder.toml --offline --pretty
```

Responses use JSON envelopes: `{"ok":true,"data":...}` for success and `{"ok":false,"error":...}` for failures. Diagnostics and errors redact access tokens, app secrets, auth codes, `client_secret`, `appsecret_proof`, authorization headers, and known secret values.

## Configuration

Config discovery checks `--config`, `INSTAGRAM_GATEWAY_CONFIG`, `$XDG_CONFIG_HOME/instagram-gateway/config.toml`, then `~/.config/instagram-gateway/config.toml`.

Use only secret references in source-controlled files:

```toml
access_token_ref = "kinko:INSTAGRAM_GATEWAY_META_SANDBOX_READER_ACCESS_TOKEN"
app_secret_ref = "kinko:INSTAGRAM_GATEWAY_META_SANDBOX_APP_SECRET"
```

Use separate credential profiles for `access_mode = "read"` and
`access_mode = "write"`. The reader binary selects read profiles only; the
writer binary selects write profiles only.

See `Examples/config.example.toml`, `docs/meta-setup.md`, and
`docs/live-smoke-tests.md`. The complete public API coverage matrix is in
`docs/api-coverage.md`.

## Reader

```bash
swift run instagram-gateway-reader accounts pages --pretty
swift run instagram-gateway-reader accounts business-discovery --username "<business-username>" --pretty
swift run instagram-gateway-reader media list --account-id "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --limit 5 --pretty
swift run instagram-gateway-reader insights account --account-id "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --metric impressions,reach --period day --pretty
```

Reader commands require a `read` credential profile. Writer verbs are rejected by the reader binary.

## Writer

```bash
swift run instagram-gateway-writer media create-container --account "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --image-url https://example.com/public-test-image.jpg --caption "instagram-gateway smoke test" --yes --pretty
swift run instagram-gateway-writer media publish --account "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --container-id "<container-id>" --yes --pretty
swift run instagram-gateway-writer comments hide --account "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --comment-id "<comment-id>" --yes --pretty
```

Writer mutation commands require a `write` credential profile and `--yes`.
Use throwaway media, containers, and comments for live writer smoke tests.

## Release

Packaging is documented in `docs/release.md`. Homebrew-style distribution should publish both `instagram-gateway-reader` and `instagram-gateway-writer` artifacts for `darwin-arm64` and `darwin-x64`.
