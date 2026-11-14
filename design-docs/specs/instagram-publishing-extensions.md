# Resumable Upload And Typed Publishing Options

## Feature Contract

- Workflow mode: `issue-resolution`
- Issue reference: `workflow-input:codex-design-and-implement-review-loop-session-695`
- Feature ID: `instagram-publishing-extensions`
- Feature title: `Resumable upload and typed publishing options`
- Fanout group/index: `feature-local-planning/5`
- Implementation plan: `impl-plans/instagram-publishing-extensions.md`
- Codex agent references: `/root/design_review`

This feature extends the existing `InstagramGatewayCore` writer service and
`instagram-gateway-writer` media commands. It replaces known
`providerFields`-only publishing knobs with source-compatible typed Swift and
CLI surfaces and adds the official resumable video-upload sequence. It does not
change the reader binary or broaden the parent issue beyond the public
Instagram Platform API for professional accounts.

## Baseline And Scope

The current implementation already creates and publishes image, Reel, Story,
carousel-child, and carousel containers; polls container status; supports
`share_to_feed`; and retains `[String: String] providerFields` as an SDK escape
hatch. Its HTTP request model supports in-memory `Data` bodies and one Graph API
base URL. It does not stream local files, address the `rupload.facebook.com`
host, or expose typed user tags, collaborators, location, cover/frame, and alt
text.

This feature owns:

- Typed publishing-option DTOs, validation, provider encoding, and writer CLI
  flags.
- Resumable container creation and local-file upload to the official Instagram
  rupload endpoint.
- Transport support for an explicit trusted endpoint override and a streamed
  file slice without loading a large video into memory.
- Deterministic tests and feature-specific documentation/coverage updates.

This feature does not own URL-fetch publishing already implemented, container
publish semantics, published-media deletion, OAuth provisioning, app review,
Commerce, Messaging, or any private/mobile upload protocol.

## Provider Workflow

The resumable sequence remains explicit and observable:

1. Create a video container through `POST /{ig-user-id}/media`, using the
   existing media-type mapping plus `upload_type=resumable` and no `video_url`.
2. Preserve the versioned HTTPS upload `uri` returned with the container; do
   not reconstruct an unversioned upload path from the container ID.
3. Query `/{container-id}?fields=id,status_code,status,video_status` and read
   `video_status.uploading_phase.bytes_transferred` as the provider-confirmed
   resume offset.
4. Upload the local file remainder beginning at that confirmed offset to the
   returned `uri`, whose normalized target must be
   `https://rupload.facebook.com/ig-api-upload/...`. Send the access token as
   `Authorization: OAuth <token>`, total `file_size`, current `offset`,
   `application/octet-stream`, and a streamed file body.
5. Check container status until it is `FINISHED`.
6. Publish through the existing confirmation-gated `media publish` command.

Container creation, upload, status, and publish are separate SDK methods and
CLI commands. Rupload success only confirms that the request succeeded; it does
not establish a byte offset. The SDK must not infer progress from bytes read or
sent. After success or an ambiguous transport interruption, the caller queries
`video_status` again and resumes only from Meta's returned
`bytes_transferred`. Caller-selected chunk length is not part of this contract.
Automatic status polling, retry, and publish are out of scope.

Only video-capable container types accepted by Meta may use resumable upload:
Reels/standalone video, video Stories, and video carousel children. Resumable
container creation rejects `image`, `storyImage`, `carouselImage`, and the
top-level `carousel` type before a request is sent.

## Public SDK Contract

Add public, `Codable`, `Equatable`, and `Sendable` values:

```swift
public struct InstagramTagPosition {
  public var x: Double
  public var y: Double
}

public struct InstagramUserTag {
  public var username: String
  public var position: InstagramTagPosition?
}

public enum InstagramVideoCover {
  case url(String)
  case frameOffsetMilliseconds(Int)
}

public struct InstagramPublishingOptions {
  public var userTags: [InstagramUserTag]
  public var collaborators: [String]
  public var locationId: String?
  public var videoCover: InstagramVideoCover?
  public var altText: String?
}

public struct CreateResumableVideoContainerInput {
  public var accountId: String
  public var mediaType: PublishingMediaType
  public var caption: String?
  public var options: InstagramPublishingOptions
  public var providerFields: [String: String]
}

public struct UploadResumableVideoInput {
  public var containerId: String
  public var uploadURI: URL
  public var fileURL: URL
  public var offset: UInt64
}

public struct ResumableVideoUploadResult {
  public var containerId: String
  public var fileSize: UInt64
  public var offset: UInt64
  public var success: Bool
  public var message: String?
}
```

`MediaContainer` gains an optional `uploadURI` decoded from Meta's `uri` field.
`MediaContainerStatus` gains a typed optional `videoStatus`, including
`uploadingPhase.bytesTransferred`. Both additions use custom decoding defaults
so responses and persisted values lacking the new keys still decode. Custom
encoding omits the new keys when they are nil/default so existing DTOs retain
their legacy serialized key set; exact encoding fixtures protect this policy.

`CreateMediaContainerInput` gains
`publishingOptions: InstagramPublishingOptions = .init()` as its last
initializer argument. It uses custom `Codable` decoding with an empty default
when the key is absent and omits the key when options are empty. Every new public
type has an explicit public initializer with source-compatible defaults.
Existing call sites and serialized payload key sets remain compatible.
`providerFields` remains available for future Meta fields but is not the primary
interface for fields this feature types.

`InstagramWriterService` gains:

```swift
func createResumableVideoContainer(
  _ input: CreateResumableVideoContainerInput
) async throws -> MediaContainer

func uploadResumableVideo(
  _ input: UploadResumableVideoInput
) async throws -> ResumableVideoUploadResult
```

The existing `createMediaContainer(_:)` encodes typed options for URL-fetch
publishing. Shared encoding and validation prevent the two creation paths from
drifting.

## Typed Option Encoding And Validation

| Typed value | Provider field | Encoding | Accepted container contexts |
|---|---|---|---|
| positioned `userTags` | `user_tags` | compact JSON array of `{username,x,y}` | feed image and carousel-image item; image and video Stories also permit a position |
| username-only `userTags` | `user_tags` | compact JSON array of `{username}` | Reel/video, video-carousel item, and image/video Story |
| `collaborators` | `collaborators` | compact JSON array of usernames | feed image, Reel, top-level carousel |
| `locationId` | `location_id` | non-empty provider ID | feed image, Reel, top-level carousel |
| `.url` | `cover_url` | absolute HTTPS URL | Reel/resumable Reel |
| `.frameOffsetMilliseconds` | `thumb_offset` | non-negative integer milliseconds | Reel/video, video Story, and video-carousel item |
| `altText` | `alt_text` | non-empty UTF-8 text | image and carousel-image item |

Stories reject collaborators, location, cover URL, and alt text, while accepting
the documented Story form of user tags; video Stories also accept thumbnail
offset. Carousel child containers reject collaborators and location because
those belong on the top-level carousel. Video carousel children accept
username-only user tags and thumbnail offset but reject image-only alt text.
Caption is rejected for Stories and carousel children and accepted for feed
images, Reels, and the top-level carousel. The implementation centralizes this
compatibility matrix so SDK and CLI failures match.

Additional validation:

- Usernames are trimmed, non-empty, and supplied without a leading `@`.
- Feed and carousel images require a position. Feed/Reel and video-carousel
  forms reject a position. Image and video Story tags may include or omit a
  position. Coordinates, when present, must be finite and in the inclusive
  `0...1` range.
- Collaborator usernames are trimmed, non-empty, unique, and limited to the
  current provider maximum documented by Meta; the limit is a named constant
  covered by tests.
- `cover_url` must be an absolute HTTPS URL and is mutually exclusive with
  `thumb_offset` by construction.
- File URLs must be local, readable regular files and `offset <= fileSize`.
  The upload streams the remainder of the file from the provider-confirmed
  offset.
- A typed field colliding with the same key in `providerFields` is rejected as
  ambiguous. Collisions with service-owned keys (`media_type`, `image_url`,
  `video_url`, `is_carousel_item`, `children`, `caption`, and `upload_type`) are
  also rejected. Unknown non-colliding `providerFields` remain sorted and
  encoded after typed validation.

Validation errors are local `CONFIGURATION_INVALID` errors and must not include
file contents, access tokens, or sensitive URL query values.

## Transport Design

Extend `HTTPRequest` source-compatibly with:

- An optional absolute endpoint.
- A new streamed-file-slice representation alongside, not replacing, the
  existing public `Data? body` property and initializer. A compatibility
  initializer/facade preserves current callers.

`InstagramGatewayClient` validates any absolute endpoint before attaching
authorization. Graph requests remain on the configured Graph host with Bearer
authorization. The only alternate target is HTTPS `rupload.facebook.com` under
`/ig-api-upload/`, with no userinfo, explicit port, query, or fragment, which
receives OAuth authorization. Any other scheme, userinfo, host, port, path,
query, or fragment fails locally. `URLSessionHTTPTransport` repeats this
invariant, streams file slices using a file-backed input stream or upload task,
and never calls `Data(contentsOf:)` for the complete video.
`RecordingHTTPTransport` records file metadata, not file contents. Redirects
must be disabled for rupload or independently revalidated before credentials
are forwarded; authorization is never forwarded to a different origin.

The total source file size is sent as `file_size`; `offset` identifies the
first byte in the streamed remainder. Graph authentication remains Bearer;
rupload uses OAuth. Request/error descriptions redact either authorization
scheme and any token-bearing provider text.

## Writer CLI Contract

Existing URL-fetch creation remains:

```bash
instagram-gateway-writer media create-container --account <id> \
  --type image|reel|story-image|story-video|carousel-image|carousel-video|carousel \
  [--image-url <https-url>] [--video-url <https-url>] [--children <ids>] \
  [typed-options] --yes
```

New resumable commands are:

```bash
instagram-gateway-writer media create-resumable-container --account <id> \
  --type reel|story-video|carousel-video [--caption <text>] [typed-options] --yes

instagram-gateway-writer media resumable-status --container-id <id>

instagram-gateway-writer media upload-resumable --container-id <id> \
  --upload-uri <uri-returned-by-create> --file <local-path> \
  --offset <bytes-from-resumable-status> --yes
```

Typed options are:

```text
--user-tag <username>           repeatable username-only tag
--user-tag-at <username:x:y>    repeatable positioned tag
--collaborator <username>       repeatable
--location-id <provider-id>
--cover-url <https-url>
--thumb-offset-ms <integer>
--alt-text <text>
```

The parser must support repeated flags without silently dropping values. It
must reject malformed coordinates, duplicate collaborators, mutually exclusive
cover flags, unsupported positioned/username-only tag combinations, unsupported
option/media combinations, unknown trailing options, and invalid integer ranges
before transport execution.

Creating a container and uploading bytes remain writer-only state-changing
operations and require the existing interactive confirmation or `--yes`.
Reader help and command registration remain unchanged.

## Error And Output Contract

Success and failure retain the existing JSON envelope. Resumable creation
returns the extended `MediaContainer` with the provider upload URI. Status
returns `MediaContainerStatus` with the only confirmed resume offset. Upload
returns `ResumableVideoUploadResult` describing the attempted offset and
provider success; callers query status again rather than treating local byte
counts as confirmed progress.

Graph provider rejections use existing typed status/error mapping. Rupload's
`debug_info` failure envelope receives its own typed DTO and maps nested message,
type, and trace fields into the existing public error categories after recursive
redaction. Local file I/O, invalid offsets, and incompatible options produce
deterministic non-provider errors. Output may contain an operator-supplied file
path only when needed to identify a local validation failure; it must never
contain video bytes, token values, Authorization headers, or an unredacted
token-bearing provider URL.

## Prerequisites And Live Verification Boundaries

Code completion is independent from Meta operational readiness. Live use still
requires an eligible professional account, the correct login product and token,
`instagram_content_publish`, any required Advanced Access/App Review, and
provider-compliant media. Meta currently limits Instagram resumable video upload
to apps implementing Facebook Login for Business; an Instagram Login
configuration with its differently named publishing permission does not make
this upload flow available. Documentation and coverage must state this gate
explicitly rather than treating the login products as interchangeable.

Safe live verification may create an unpublished container and upload a small
owned fixture. Publishing is not considered reversible because provider API
deletion is unavailable; it requires separate explicit operator approval, a
throwaway owned post, and documented manual cleanup in Instagram. No
third-party collaborator invitation, user tag, or unowned location is used in
live tests. Meta-blocked checks are recorded as blocked prerequisites, not
passes.

## Documentation And Test Contract

Update `README.md`, `docs/api-coverage.md`, and
`docs/live-smoke-tests.md` during implementation. The coverage matrix must
separate SDK/CLI code coverage from permission, app-review, account, media, and
owned-fixture prerequisites.

Deterministic tests cover:

- Codable/public initializer coverage for every new DTO and enum.
- Exact query encoding for each typed option and stable JSON key ordering.
- Every accepted and rejected media/option pairing.
- Coordinate, username, cover, offset, local-file, collision, and
  repeated-flag validation.
- Resumable Graph container request, exact rupload host/path/headers, streamed
  body metadata, `video_status` offset decoding, rupload `debug_info` mapping,
  response decoding, and non-advancement on success or failure without a status
  query.
- Credential-host enforcement for malicious absolute URLs and redirects.
- Rejection of rupload URIs containing userinfo, ports, query strings, or
  fragments before OAuth authorization is attached.
- Reader/writer separation, confirmation gates, JSON envelopes, and redaction.
- Source compatibility for existing `CreateMediaContainerInput` callers and
  non-colliding `providerFields`.

## Design Review Decisions

- Self-review: accepted for assigned scope after explicitly separating
  resumable creation/upload/status/publish, defining a typed compatibility
  matrix, preserving `providerFields`, and adding streaming and credential-host
  boundaries.
- Independent review: accepted after four high and five mid design findings
  were addressed before planning. The accepted revision uses Meta-confirmed
  `video_status` offsets and returned upload URIs, correct OAuth rupload auth,
  media-specific tag/thumbnail rules, client-level endpoint enforcement,
  backward-compatible Codable/HTTP body contracts, owned-field collision
  validation, and typed `debug_info` failures.
- Design defects and plan-only defects are tracked separately in the matching
  implementation plan.

## Risks

- Meta can vary parameter availability by API version, login product, account
  type, and rollout; compatibility claims require dated official-doc checks.
- Resumable retry semantics are unsafe if a client guesses server progress
  after an ambiguous transport failure; only confirmed offsets may advance.
- A naïve body implementation can load large videos into memory or forward a
  bearer token across hosts/redirects.
- User tags and collaborator invitations can affect third parties; deterministic
  fixtures are the default, and live checks require explicitly owned targets.
- Adding cases or properties to public Swift contracts can be source-sensitive;
  defaults and exhaustive-switch effects require release-build review.
