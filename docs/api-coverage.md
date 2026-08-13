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
| Publishing options | User tags, collaborators, location, cover/frame, alt text | SDK | Pass-through `providerFields` is available in the SDK; dedicated typed CLI flags are not yet present. |
| Publishing | Resumable video upload | No | URL-based server fetch is implemented; resumable binary upload is not. |
| Publishing | Delete a published post or Story | Provider gap | Meta's supported API does not provide published-media deletion. The live tests were deleted through Instagram UI. |
| Comments | List/get comments | Yes | |
| Comments | Reply | Yes | Confirmation required |
| Comments | Hide/unhide/delete comment | Yes | Confirmation required |
| Comments | Enable/disable comments on media | Yes | `media-comments enable|disable` |
| Comments | Private reply to commenter | No | Messaging permission and Send API implementation required. |
| Insights | Account and media insights | Yes | Caller supplies current metric/period names. |
| Mentions | Mentioned media/comment lookup and reply | No | |
| Hashtags | Hashtag search, top/recent media, recently searched | No | |
| Messaging | Conversations, messages, profile lookup, Send API, reactions/templates/icebreakers | No | Requires `instagram_manage_messages` and webhook-driven conversation handling. |
| Webhooks | Instagram fields, comments, mentions, messaging events | No | No webhook server or signature-verification module yet. |
| Shopping | Product tags, catalogs, product search/appeals | No | Requires Commerce/catalog permissions and review. |
| oEmbed | Instagram post/Reel embedding metadata | No | Separate oEmbed flow/app review. |

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
