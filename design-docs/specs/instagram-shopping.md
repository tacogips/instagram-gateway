# Shopping And Product Tagging

## Workflow Contract

- Workflow mode: `issue-resolution`
- Issue reference:
  `workflow-input:codex-design-and-implement-review-loop-session-695`
- Feature id: `instagram-shopping`
- Feature title: `Shopping and product tagging`
- Fanout group: `feature-local-planning`
- Fanout index: `4`
- Implementation plan: `impl-plans/instagram-shopping.md`
- Codex agent references: none

The runtime contract supplied legacy paths under `docs/`. This repository's
workflow requires feature designs under `design-docs/` and plans under
`impl-plans/`, so this design uses the existing `design-docs/specs/` convention
without changing source, tests, or general documentation in the planning step.

## Objective

Add the official Instagram Shopping product-tagging surface for professional
accounts to the public Swift SDK and permission-separated CLIs. Cover Commerce
eligibility, available-catalog discovery, tag-eligible product search, product
tag reads, appeal status and submission, typed tags during container creation,
and additive tag updates on already-published owned media.

The design must preserve current public SDK contracts, writer confirmation
gates, read/write credential separation, secret redaction, and the rule that
live verification must not mutate unowned media, catalogs, products, Shops, or
other Commerce assets.

## Official API Basis

The primary reference is Meta's Product Tagging guide:

`https://developers.facebook.com/docs/instagram-platform/instagram-api-with-facebook-login/product-tagging`

The supported flow and endpoints are:

1. `GET /{ig-user-id}?fields=shopping_product_tag_eligibility`
2. `GET /{ig-user-id}/available_catalogs`
3. `GET /{ig-user-id}/catalog_product_search`
4. `POST /{ig-user-id}/media` with `product_tags`
5. `POST /{ig-user-id}/media_publish`
6. `GET /{ig-media-id}/product_tags`
7. `POST /{ig-media-id}/product_tags` with `updated_tags`
8. `GET /{ig-user-id}/product_appeal`
9. `POST /{ig-user-id}/product_appeal`
10. `GET /{ig-media-id}/children` when resolving carousel child media.

Meta prerequisites are not code coverage. Product tagging requires an eligible
Instagram Business account, an approved Shop and catalog, appropriate Business
Manager administration, required permissions and App Review/Advanced Access,
and products whose review state permits visible tags. Creator accounts, Stories,
Live, unsupported checkout/Shop configurations, collaborative catalogs, and
unapproved products can remain provider-blocked even when the SDK and CLI are
complete.

This surface is specifically the Instagram API with Facebook Login flow. Meta's
Instagram Login flow does not support tagging, so the implementation must not
route Shopping commands to `graph.instagram.com` or imply that an
Instagram-Login-only token can satisfy these operations.

Exact permission availability must be verified against the selected Graph API
version during implementation. The documented Commerce permissions include
`instagram_shopping_tag_products` and `catalog_management`; publishing also
uses the existing Instagram basic/content-publish and Page-linked account
permissions for the Facebook Login flow. Permission names remain configured
strings, not a closed Swift enum.

## Scope

### Reader SDK and CLI

Expose non-mutating operations through `InstagramReaderService` and
`instagram-gateway-reader`:

- get the account's shopping product-tag eligibility
- list available catalogs
- search or enumerate tag-eligible products in one available catalog, with
  cursor pagination
- list product tags on published media
- get product appeal eligibility and review status
- list carousel children needed to inspect tags per child

### Writer SDK and CLI

Expose state-changing operations through `InstagramWriterService` and
`instagram-gateway-writer`:

- create image, Reel, or carousel-child containers with typed product tags;
  the existing standalone `.video` publishing type maps to Reels, not a
  separate feed-video contract
- publish tagged containers through the existing publish operation
- add or update tags on already-published owned media
- submit an appeal for a rejected product in an owned/administered catalog

Every CLI mutation requires the existing write credential boundary and `--yes`.
The SDK remains non-interactive and documents ownership/authorization as caller
preconditions.

### Non-goals

- Create, edit, delete, or reassign catalogs, products, variants, Shops, or
  checkout settings.
- Use Marketing/Ads, Commerce catalog-management endpoints outside the
  Instagram product-tagging guide, private/mobile APIs, or consumer automation.
- Bypass Commerce eligibility, product review, App Review, Business Manager,
  or account-type restrictions.
- Claim that an accepted appeal was approved; submission success only confirms
  provider receipt.
- Automatically publish after container creation or automatically appeal a
  rejected product.
- Tag Stories, Live media, Creator-account media, or unowned media.
- Remove published Instagram media; Meta exposes no supported deletion endpoint.

## Public Swift Contracts

All new public models are `Codable`, `Equatable`, and `Sendable`. Provider IDs
are represented as `String`, including IDs that Meta serializes as JSON numbers.
A shared lossless identifier decoder accepts a JSON string or integer token and
stores its exact decimal representation; it must never route IDs through
`Double`.

```swift
public struct ShoppingEligibility: Codable, Equatable, Sendable {
    public var accountId: String
    public var eligible: Bool
}

public struct ShoppingCatalog: Codable, Equatable, Sendable {
    public var catalogId: String
    public var catalogName: String?
    public var shopName: String?
    public var productCount: Int?
}

public enum ProductReviewStatus: Codable, Equatable, Sendable {
    case approved
    case outdated
    case pending
    case rejected
    case noReview
    case unknown(String)
}

public struct ShoppingProductVariant: Codable, Equatable, Sendable {
    public var productId: String
    public var variantName: String?
}

public struct ShoppingProduct: Codable, Equatable, Sendable {
    public var productId: String
    public var merchantId: String?
    public var productName: String?
    public var imageURL: String?
    public var retailerId: String?
    public var reviewStatus: ProductReviewStatus
    public var isCheckoutFlow: Bool?
    public var productVariants: [ShoppingProductVariant]
}

public struct ProductTagInput: Codable, Equatable, Sendable {
    public var productId: String
    public var x: Double?
    public var y: Double?
}

public struct PublishedProductTag: Codable, Equatable, Sendable {
    public var productId: String
    public var merchantId: String?
    public var name: String?
    public var priceString: String?
    public var strippedPriceString: String?
    public var salePriceString: String?
    public var imageURL: String?
    public var reviewStatus: ProductReviewStatus
    public var isCheckout: Bool?
    public var x: Double?
    public var y: Double?
}

public struct ProductAppealStatus: Codable, Equatable, Sendable {
    public var productId: String
    public var reviewStatus: ProductReviewStatus
    public var eligibleForAppeal: Bool
}

public struct UpdateProductTagsInput: Codable, Equatable, Sendable {
    public var accountId: String
    public var mediaId: String
    public var tags: [ProductTagInput]
}

public struct SubmitProductAppealInput: Codable, Equatable, Sendable {
    public var accountId: String
    public var productId: String
    public var reason: String
}

public struct ShoppingMutationResult: Codable, Equatable, Sendable {
    public var success: Bool
}
```

Provider evolution is preserved through `ProductReviewStatus.unknown(String)`.
The provider's empty review-status value and `no_review` both decode to
`.noReview`, while encoding uses `no_review`. Product arrays default to empty
only when the provider omits the optional variants field; required identifiers
must fail decoding when absent or not losslessly representable.

Reader service additions:

```swift
public func shoppingEligibility(accountId: String) async throws -> ShoppingEligibility
public func availableCatalogs(accountId: String, limit: Int?, after: String?) async throws -> Page<ShoppingCatalog>
public func searchCatalogProducts(accountId: String, catalogId: String, query: String?, limit: Int?, after: String?) async throws -> Page<ShoppingProduct>
public func productTags(mediaId: String, limit: Int?, after: String?) async throws -> Page<PublishedProductTag>
public func productAppealStatus(accountId: String, productId: String) async throws -> Page<ProductAppealStatus>
public func mediaChildren(mediaId: String, limit: Int?, after: String?) async throws -> Page<InstagramMedia>
```

Writer service additions:

```swift
public func addOrUpdateProductTags(_ input: UpdateProductTagsInput) async throws -> ShoppingMutationResult
public func submitProductAppeal(_ input: SubmitProductAppealInput) async throws -> ShoppingMutationResult
```

`CreateMediaContainerInput` gains a source-compatible property and initializer
argument with a default:

```swift
public var productTags: [ProductTagInput]
// initializer: productTags: [ProductTagInput] = []
```

`providerFields` remains available for source compatibility and unrelated
provider extensions. `product_tags` is reserved for the typed field: supplying
that key through `providerFields` is rejected so callers cannot bypass typed
validation or produce duplicate query parameters.

## Request Encoding And Validation

The transport continues using the existing Graph host, API-version selection,
Bearer authorization, `URLComponents`, error mapping, and secret redaction.
Typed product tags and updated tags are JSON-encoded once and sent as query/body
parameters using existing request conventions; code must not hand-build JSON.

Local validation occurs before transport invocation:

- every account, catalog, media, product ID, and appeal reason is non-empty
- product IDs are unique within one tag request
- `x` and `y` either both exist or are both absent
- coordinates are finite and within the closed interval `0.0...1.0`
- image and existing-image tag requests require coordinates
- Reel and carousel-video-child tags omit coordinates
- Stories and Live reject product tags
- a create-container request rejects more than the documented limit for its
  media type; an existing-media update rejects more than five tags
- carousel child requests validate their own tag count; Meta remains the final
  authority for the aggregate album limit because the parent receives only
  opaque child container IDs
- the tags collection is non-empty for `addOrUpdateProductTags`; the operation
  is explicitly additive/update-only and must not be presented as replacement
  or tag removal
- appeal submission rejects empty or whitespace-only reasons

Current documented limits are captured as named internal constants and tested,
not scattered literals. Provider rejections remain typed/redacted even if Meta
changes a limit before the local contract is updated.

## CLI Contract

Reader commands:

```bash
instagram-gateway-reader shopping eligibility --account-id <ig-user-id>
instagram-gateway-reader shopping catalogs --account-id <ig-user-id> [--limit <n>] [--after <cursor>]
instagram-gateway-reader shopping products --account-id <ig-user-id> --catalog-id <catalog-id> [--query <text>] [--limit <n>] [--after <cursor>]
instagram-gateway-reader shopping product-tags --media-id <ig-media-id> [--limit <n>] [--after <cursor>]
instagram-gateway-reader shopping appeal-status --account-id <ig-user-id> --product-id <product-id>
instagram-gateway-reader media children --media-id <ig-media-id> [--limit <n>] [--after <cursor>]
```

Writer commands:

```bash
instagram-gateway-writer media create-container --account <ig-user-id> ... --product-tags-json <json-array> --yes
instagram-gateway-writer shopping update-product-tags --account <ig-user-id> --media-id <ig-media-id> --product-tags-json <json-array> --yes
instagram-gateway-writer shopping appeal --account <ig-user-id> --product-id <product-id> --reason <text> --yes
```

`--product-tags-json` decodes strictly into `[ProductTagInput]`; malformed JSON,
unknown keys, duplicate IDs, invalid coordinates, or incompatible media types
fail before any request. A future file flag is not part of this bounded feature.
CLI output uses the existing success/error envelopes and paging sanitization.
Tokens, app secrets, and secret-bearing URLs never appear in JSON or errors.

Read commands require a read profile. Mutation commands require a write profile
and `--yes`; confirmation must fail before config loading or network I/O when it
is absent. The reader binary does not register mutation verbs, and the writer
binary does not make shopping reads the recommended path.

## Ownership And Live-Safety Boundary

The Graph API scopes product-tag and appeal operations to the authenticated
Instagram Business/Commerce relationship, but provider authorization is not a
substitute for local live-test discipline.

- SDK mutation inputs include `accountId` as an explicit ownership/audit anchor.
- CLI mutations require `--account` and must reject a value that conflicts with
  a configured `instagram_user_id` for the selected write profile.
- The update endpoint must be named `addOrUpdateProductTags` because provider
  behavior is additive until its limit; no false replacement/removal semantics.
- No implementation or test may create/edit/delete catalogs, products, variants,
  Shops, checkout settings, or Business Manager relationships.
- Deterministic tests use injected transports and synthetic IDs only.
- Live catalog/product/appeal reads are safe only for the configured sandbox
  account. Live tag updates or appeals run only when an operator has documented
  an owned disposable media/product fixture and explicitly supplies `--yes`.
- If ownership, Business Manager administration, eligibility, product state, or
  reversibility is uncertain, record `blockedByMetaPrerequisite` and do not send
  the mutation.
- A provider permission or eligibility failure is reported, not bypassed and
  not counted as successful live coverage.

## Errors And Result Semantics

Reuse `InstagramGatewayError` and existing redacted provider-error mapping.
Local invalid tag shapes map to `configurationInvalid`; authentication,
permission, eligibility, ownership, catalog, and review failures map through the
provider status/error contract without leaking request credentials.

Both tag update and appeal submission decode Meta's boolean result into
`ShoppingMutationResult`. Appeal success means only that Meta
received the request. Eligibility and final status are observed through the
reader operation.

## Deterministic Tests

Tests must cover:

- decoding string and numeric catalog/product/merchant IDs without precision
  loss
- every known review status, empty/no-review normalization, and unknown status
  round trips
- eligibility, catalogs, product search, product tags, appeal status, and media
  children request paths, parameters, pagination, and response decoding
- typed `product_tags` and `updated_tags` JSON encoding without duplicate or
  hand-built JSON fields
- image/video/Reel/carousel-child validation, coordinate bounds, finiteness,
  uniqueness, empty values, documented count limits, and Story/Live rejection
- rejection of `providerFields["product_tags"]`
- additive tag-update and appeal request construction
- reader/writer command registration boundaries
- confirmation failure before config/transport, write-profile enforcement, and
  configured-account mismatch rejection
- stable redacted JSON envelopes and paging URL sanitization
- public DTO encoding and existing source-compatible initializer behavior

No deterministic test contacts Meta. Live tests are separately recorded with
account eligibility, permissions, catalog/product ownership, and reversibility.

## Documentation And Coverage Outcomes

Implementation updates `README.md`, `docs/meta-setup.md`,
`docs/live-smoke-tests.md`, and `docs/api-coverage.md` in the parent
implementation branch, not in this planning worker. The coverage matrix must
separate:

- implemented SDK/CLI operation
- deterministic test result
- live result: pass, not run, or blocked by a named Meta prerequisite
- required account type, Shop/catalog eligibility, permissions/App Review, and
  owned-fixture constraints

No documentation may claim Commerce setup, product approval, appeal approval,
or live mutation success from code coverage alone.

## Design Review Record

### Self-review decision

Accepted after checking the feature contract, official endpoint flow, binary
separation, SDK source compatibility, explicit ownership limits, confirmation
gates, provider prerequisites, testability, and non-goals. One mid-severity
draft defect was corrected: the initial scope treated existing-media tag updates
as replacement. The accepted design names and documents the endpoint as
additive/update-only and does not promise removal.

### Independent review decision

Accepted in a separate cold review with no remaining high or mid findings. One
mid-severity safety defect was corrected: relying only on Meta authorization did
not make the unowned-asset boundary explicit. The accepted design now requires
an account ownership anchor, configured-account mismatch rejection, owned
disposable live fixtures, and fail-closed handling when ownership or
reversibility is uncertain. A second mid-severity ambiguity was corrected by
binding this feature to the Facebook Login API flow; Meta's Instagram Login flow
does not support tagging. A third mid-severity consistency defect was corrected
by aligning tagged standalone video with the existing SDK contract: standalone
video publishes as a Reel rather than introducing a new feed-video type. Low
residual findings are tracked as risks.

## Risks

- Meta can change permissions, account eligibility, checkout/Shop policy, review
  states, tag limits, and Graph API fields; implementation must validate against
  the selected API version and preserve unknown response states.
- Catalog/product identifiers may arrive as JSON numbers despite being opaque
  IDs; incorrect numeric decoding could silently corrupt them.
- A configured account match cannot prove ownership of every supplied media or
  product ID; provider authorization and owned-fixture discipline remain
  necessary.
- Product approval and appeal outcomes are asynchronous provider state and may
  remain unavailable in the sandbox.
- Existing public `providerFields` must remain source-compatible while preventing
  `product_tags` from bypassing the typed contract.
- Some read endpoints may require provider permissions with broader names such
  as `catalog_management`; the reader binary remains non-mutating, but Meta's
  permission granularity can limit token-level least privilege.
