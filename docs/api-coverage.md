# Instagram Platform API coverage

Checked against Meta's official Instagram API collection and Graph API v26.0 on 2026-08-13. The scope is the public Instagram Platform API for professional accounts. Threads, Marketing API/ads, the Research API, private/mobile endpoints, and consumer-account automation are separate products and are not included.

Legend: **Yes** is exposed by both the Swift SDK and the appropriate CLI, **SDK** is library-only, **No** is not implemented, and **Provider gap** means Meta exposes no supported endpoint.

| Area | Public API capability | Coverage | Notes |
|---|---|---:|---|
| Authentication | Facebook Login for Business token use | Yes | Bearer tokens referenced through kinko/env; interactive OAuth remains a provisioning operation. |
| Discovery | Managed Pages and linked Instagram accounts | Yes | `accounts pages`, `accounts instagram` |
| Profiles | Own professional profile | Yes | `account get` |
| Profiles | Business Discovery for another professional account | Yes | `accounts business-discovery` |
| Media read | List/get feed media | Yes | Cursor pagination and typed media/product types |
| Media read | Stories | Yes | `stories` |
| Media read | Live media | Yes | `live-media` |
| Media read | Media tagging the account | Yes | `tagged-media` |
| Publishing | Image feed post | Yes | Live-tested |
| Publishing | Standalone video/Reel | Yes | Meta publishes standalone videos as Reels; live-tested |
| Publishing | Image Story | Yes | Business accounts only; live-tested |
| Publishing | Video Story | Yes | Business accounts only; live-tested |
| Publishing | Image/video carousel children and carousel publish | Yes | Image carousel live-tested; mixed/video children supported by SDK/CLI |
| Publishing | Container status and publish | Yes | Live-tested |
| Publishing | Publishing quota | Yes | `publishing-limit` |
| Publishing options | Caption and `share_to_feed` | Yes | Reels `share_to_feed` supported |
| Publishing options | User tags, collaborators, location, cover/frame, alt text | SDK/CLI partial | Typed options and repeatable writer flags are available; media-specific compatibility remains in progress. |
| Publishing | Resumable video upload | SDK/CLI partial | Writer commands stream validated local file slices to the allowlisted upload host and deny redirects; live/provider verification remains blocked. |
| Publishing | Delete a published post or Story | Provider gap | Meta's supported API does not provide published-media deletion. The live tests were deleted through Instagram UI. |
| Comments | List/get comments | Yes | |
| Comments | Reply | Yes | Confirmation required |
| Comments | Hide/unhide/delete comment | Yes | Confirmation required |
| Comments | Enable/disable comments on media | Yes | `media-comments enable|disable` |
| Comments | Private reply to commenter | Yes | Instagram Login requires `instagram_business_basic` and `instagram_business_manage_comments`; Facebook Login requires `instagram_basic`, `instagram_manage_comments`, and `pages_read_engagement`. Live use remains provider-gated and irreversible. |
| Insights | Account and media insights | Yes | Caller supplies current metric/period names. |
| Mentions | Mentioned media/comment lookup and reply | SDK | Typed identifier-specific SDK and `mentions media|comment` CLI surfaces include nested comment-media decoding; live owned-fixture verification remains META_BLOCKED. |
| Hashtags | Hashtag search, top/recent media, recently searched | Yes | Typed reader SDK and `hashtags` commands; searches consume Meta's rolling query quota. |
| Messaging | Conversations, messages, consent-gated user profiles, Send API (text/media/reusable attachment/MEDIA_SHARE/sticker/quick replies/templates), reactions, sender actions, image attachments, Messenger Profile controls | Yes | Deterministic SDK/CLI coverage is complete. Instagram Login requires `instagram_business_basic` plus `instagram_business_manage_messages` (or `instagram_business_manage_comments` for private replies). Facebook Login requires `instagram_basic`, `instagram_manage_messages`, and `pages_manage_metadata` (or `instagram_manage_comments` and `pages_read_engagement` for private replies); owned-fixture verification remains META_BLOCKED. |
| Webhooks | Signature verification, typed event normalization, subscriptions | SDK/CLI partial | Exact-byte HMAC-SHA256, raw-file decode, and subscription adapters exist; callback delivery and remaining event variants remain in progress. |
| Shopping | Product tags, catalogs, product search/appeals | SDK/CLI partial | Facebook-Login tagging is gated; Commerce/catalog ownership and live prerequisites remain blocked. |
| oEmbed | Instagram post/Reel embedding metadata | SDK/CLI partial | Typed `oembed get` requires `oembed` plus a distinct `oembed_access_token_ref`; current provider verification remains blocked. |

### Messaging operation status

| Operation | Code status | Live status | Prerequisites |
| --- | --- | --- | --- |
| Conversations, messages, consent-gated profile | implemented_and_unit_tested | meta_prerequisite_blocked | Declared login-specific scopes and owned consent fixture. |
| Send, reactions, sender actions, attachment upload, private reply | implemented_and_unit_tested | not_live_tested_irreversible_write | `--yes`, declared scopes, and provider policy windows. |
| Ice breakers and persistent menu | implemented_and_unit_tested | meta_prerequisite_blocked | Owned account plus snapshot/restore evidence before mutation. |

Official source: [Meta Instagram API collection](https://www.postman.com/meta/instagram/collection/6yqw8pt/instagram-api) and [Meta Instagram workspace](https://www.postman.com/meta/instagram/overview).

## Live verification — 2026-08-13

Against Instagram Business account `dduea4d`:

| Operation | Result |
|---|---:|
| Publish and read back an image feed post | Pass |
| Publish, poll, and read back a Reel | Pass |
| Publish an image Story | Pass |
| Publish, poll, and read back a video Story | Pass |
| Create children, publish, and read back an image carousel | Pass |
| Delete the image, Reel, carousel, and earlier feed smoke post through Instagram UI | Pass; subsequent `/media` returned zero items |
| Delete a video Story through Instagram UI | Pass |
| Delete published media through Graph API | Unsupported; live `DELETE /{ig-media-id}` was rejected with Graph error code 10 |
| Hashtag search and Shopping eligibility after this implementation | Blocked: the configured kinko-backed Meta access token had expired before the final read-only smoke run |
| Messaging conversations after this implementation | Blocked locally before transport: the configured profile does not declare the required messaging scopes |

The final SDK/CLI verification still passed independently of provider state:
`swift test` passed 65 deterministic tests and `swift build -c release` passed.
Renew the Meta token and complete App Review/owned-fixture prerequisites before
rerunning the new provider-backed operations; no third-party messages or
Commerce mutations were attempted.
