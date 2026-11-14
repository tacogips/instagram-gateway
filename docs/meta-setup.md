# Meta Setup

This guide is for provisioning a test Instagram account for `taco-dev-sandbox@mutvar.com`. Do not paste credentials, access tokens, auth codes, app secrets, or signed requests into source, docs, logs, or shell history.

## Safe Secret Names

Use kinko or environment references:

```bash
kinko set-key INSTAGRAM_GATEWAY_META_SANDBOX_APP_ID
kinko set-key INSTAGRAM_GATEWAY_META_SANDBOX_APP_SECRET
kinko set-key INSTAGRAM_GATEWAY_META_SANDBOX_READER_ACCESS_TOKEN
kinko set-key INSTAGRAM_GATEWAY_META_SANDBOX_WRITER_ACCESS_TOKEN
kinko set-key INSTAGRAM_GATEWAY_META_SANDBOX_IG_USER_ID
kinko set-key INSTAGRAM_GATEWAY_META_SANDBOX_PAGE_ID
```

Repository examples use:

- `INSTAGRAM_GATEWAY_META_SANDBOX_APP_ID`
- `INSTAGRAM_GATEWAY_META_SANDBOX_APP_SECRET`
- `INSTAGRAM_GATEWAY_META_SANDBOX_READER_ACCESS_TOKEN`
- `INSTAGRAM_GATEWAY_META_SANDBOX_WRITER_ACCESS_TOKEN`
- `INSTAGRAM_GATEWAY_META_SANDBOX_IG_USER_ID`
- `INSTAGRAM_GATEWAY_META_SANDBOX_PAGE_ID`

## Meta App Checklist

1. Create or choose a Meta developer app suitable for Instagram Graph API testing.
2. Add the Instagram/Facebook products required by the current Meta developer console.
3. Connect the test Instagram account to a Facebook Page when the API surface requires it.
4. Configure redirect URI from `INSTAGRAM_GATEWAY_REDIRECT_URI`.
5. Provision separate reader and writer tokens.
6. Record dated notes if Meta renames permissions, app types, or setup paths during browser setup.

## Scope Intent

Reader baseline: `instagram_basic`, `pages_show_list`, and `pages_read_engagement` where the current Meta app setup requires Page engagement access for Page-to-Instagram account discovery.

Reader extensions: `instagram_manage_insights` where supported.

Reader comments extension: `instagram_manage_comments` only when comment read behavior requires it for the configured account/API version.

Writer baseline: reader baseline plus `instagram_content_publish` and `instagram_manage_comments` where available.

Optional writer insights: include reader insight scopes only when a write workflow also needs account/media validation.

## Messaging Scopes And Fixtures

Instagram Login messaging requires `instagram_business_basic` and
`instagram_business_manage_messages`; private replies instead require
`instagram_business_manage_comments`. Facebook Login messaging requires
`instagram_basic`, `instagram_manage_messages`, and `pages_manage_metadata`;
private replies require `instagram_basic`, `instagram_manage_comments`, and
`pages_read_engagement`. Do not substitute a deprecated Page-messaging scope
for this matrix.

Only configure a self-owned IGSID/conversation fixture for transient reader
verification. Do not provision this workflow to send DMs, reactions, private
replies, sender actions, or attachments. Messenger Profile mutations require a
separate owned account and a snapshot/restore procedure.

Meta may gate or rename permissions by app type, API version, login product,
account type, and app review state. During browser setup, record the current
Meta permission name, date checked, and the reader or writer command that needs
it instead of broadening scopes silently.
