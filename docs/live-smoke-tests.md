# Live Smoke Tests

Run these only after credentials are provisioned through kinko or environment references. Commands must not echo real secrets.

## Reader

```bash
swift run instagram-gateway-reader doctor --credential taco-dev-sandbox-reader --pretty
swift run instagram-gateway-reader accounts pages --limit 5 --pretty
swift run instagram-gateway-reader accounts instagram --limit 5 --pretty
swift run instagram-gateway-reader accounts business-discovery --username "<business-username>" --pretty
swift run instagram-gateway-reader media list --account-id "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --limit 5 --pretty
swift run instagram-gateway-reader insights account --account-id "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --metric impressions,reach --period day --pretty
```

## Writer Diagnostics

```bash
swift run instagram-gateway-writer doctor --credential taco-dev-sandbox-writer --pretty
swift run instagram-gateway-writer config validate --config Examples/config.placeholder.toml --pretty
```

## Mutating Writer Tests

Use throwaway media and comments only.

```bash
swift run instagram-gateway-writer media create-container --account "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --image-url https://example.com/public-test-image.jpg --caption "instagram-gateway smoke test" --yes --pretty
swift run instagram-gateway-writer media container-status --account "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --container-id "<container-id>" --pretty
swift run instagram-gateway-writer media publish --account "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --container-id "<container-id>" --yes --pretty
swift run instagram-gateway-writer comments hide --account "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --comment-id "<comment-id>" --yes --pretty
swift run instagram-gateway-writer comments unhide --account "$INSTAGRAM_GATEWAY_TEST_IG_USER_ID" --comment-id "<comment-id>" --yes --pretty
```
