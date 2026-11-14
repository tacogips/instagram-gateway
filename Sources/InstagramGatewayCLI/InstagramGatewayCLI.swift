import Darwin
import Foundation
import InstagramGatewayCore

public enum InstagramGatewayCLI {
  public struct Runtime: Sendable {
    public var loader: ConfigLoader
    public var resolver: SecretResolver
    public var transport: @Sendable (CredentialProfile) -> any HTTPTransport

    public init(
      loader: ConfigLoader = ConfigLoader(),
      resolver: SecretResolver = SecretResolver(),
      transport: @escaping @Sendable (CredentialProfile) -> any HTTPTransport = { profile in
        URLSessionHTTPTransport(baseURL: try! URLSessionHTTPTransport.baseURL(loginType: profile.loginType))
      }
    ) {
      self.loader = loader
      self.resolver = resolver
      self.transport = transport
    }
  }

  public static func run(binary: BinaryKind, arguments: [String]) async -> Never {
    do {
      let output = try await handle(binary: binary, arguments: arguments)
      print(output.text)
      Darwin.exit(output.status)
    } catch let error as InstagramGatewayError {
      let json = encode(ErrorEnvelope(error: error), pretty: arguments.contains("--pretty"))
      fputs(json + "\n", stderr)
      Darwin.exit(error.exitStatus)
    } catch {
      let envelope = ErrorEnvelope(error: .transportFailed(error.localizedDescription))
      fputs(encode(envelope, pretty: arguments.contains("--pretty")) + "\n", stderr)
      Darwin.exit(5)
    }
  }

  public static func handle(binary: BinaryKind, arguments: [String], runtime: Runtime = Runtime()) async throws -> (status: Int32, text: String) {
    var parser = ArgumentParser(arguments)
    if parser.consume("--help") || arguments.isEmpty {
      return (0, help(binary: binary))
    }
    let pretty = parser.consume("--pretty") || parser.consume("--format", value: "json")
    let configPath = parser.consumeValue("--config")
    let credentialId = parser.consumeValue("--credential")
    if parser.consume("--version") {
      return (0, encode(SuccessEnvelope(data: ["version": instagramGatewayVersion]), pretty: pretty))
    }
    guard let command = parser.next() else { return (0, help(binary: binary)) }
    if command == "version" {
      return (0, encode(SuccessEnvelope(data: ["version": instagramGatewayVersion]), pretty: pretty))
    }
    if command == "config", parser.next() == "validate" {
      let record = try diagnostic(binary: binary, configPath: configPath, credentialId: credentialId, loader: runtime.loader)
      return (record.ok ? 0 : 3, encode(SuccessEnvelope(data: record), pretty: pretty))
    }
    if command == "doctor" {
      _ = parser.consume("--offline")
      let record = try diagnostic(binary: binary, configPath: configPath, credentialId: credentialId, loader: runtime.loader)
      return (record.ok ? 0 : 3, encode(SuccessEnvelope(data: record), pretty: pretty))
    }
    if binary == .reader, ["media", "comments"].contains(command), parser.peekWriterVerb() {
      throw InstagramGatewayError.unsupportedOperation("Writer command is unsupported by reader binary")
    }
    if binary == .writer, parser.isMutation(command: command), !parser.has("--yes") {
      throw InstagramGatewayError.confirmationRequired("State-changing writer command requires --yes")
    }
    let loaded = try runtime.loader.load(explicitPath: configPath)
    let requiredMode: AccessMode = binary == .reader ? .read : .write
    let profile = try loaded.config.profile(id: credentialId, requiredMode: requiredMode)
    if case .unknown = profile.loginType { throw InstagramGatewayError.configurationInvalid("Unsupported Instagram login type") }
    let tokenReference: SecretReference
    if binary == .reader, command == "oembed" {
      guard profile.features.contains("oembed"), let oEmbedToken = profile.oEmbedAccessToken, oEmbedToken != profile.accessToken else {
        throw InstagramGatewayError.permissionDenied("oEmbed requires a dedicated oembed_access_token_ref credential profile")
      }
      tokenReference = oEmbedToken
    } else {
      tokenReference = profile.accessToken
    }
    let token = try runtime.resolver.resolve(tokenReference)
    let client = InstagramGatewayClient(transport: runtime.transport(profile), token: token)
    let webhookAppSecret = try profile.appSecret.map { try runtime.resolver.resolve($0) }
    if binary == .reader {
      let service = InstagramReaderService(client: client, messagingAuthorization: InstagramMessagingAuthorization(profile: profile))
      return try await handleReader(command: command, parser: &parser, service: service, profile: profile, webhookAppSecret: webhookAppSecret, pretty: pretty)
    }
    if binary == .writer {
      let service = InstagramWriterService(client: client, messagingAuthorization: InstagramMessagingAuthorization(profile: profile))
      return try await handleWriter(command: command, parser: &parser, service: service, profile: profile, pretty: pretty)
    }
    throw InstagramGatewayError.unsupportedOperation("Unsupported command")
  }

  static func diagnostic(binary: BinaryKind, configPath: String?, credentialId: String?, loader: ConfigLoader = ConfigLoader()) throws -> DiagnosticRecord {
    let loaded = try loader.load(explicitPath: configPath)
    let credentials = loaded.config.profiles.map { profile in
      CredentialDiagnostic(
        id: profile.id,
        accessMode: profile.accessMode,
        compatible: binary == .reader ? profile.accessMode == .read : profile.accessMode == .write,
        appIdRef: profile.appId?.description,
        appSecretRef: profile.appSecret?.description,
        accessTokenRef: profile.accessToken.description,
        instagramUserIdPresent: profile.instagramUserId != nil,
        pageIdPresent: profile.pageId != nil,
        scopes: profile.scopes
      )
    }
    let selectedProfile = try? loaded.config.profile(id: credentialId, requiredMode: binary == .reader ? .read : .write)
    let ok = selectedProfile != nil
    return DiagnosticRecord(
      ok: ok,
      binary: binary,
      configPath: loaded.path,
      credentials: credentials,
      checks: [
        DiagnosticCheck(name: "config", status: "ok", message: "Config parsed"),
        DiagnosticCheck(name: "credentialCompatibility", status: ok ? "ok" : "failed", message: ok ? "Compatible credential found" : "No compatible credential found")
      ]
    )
  }

  static func handleReader(command: String, parser: inout ArgumentParser, service: InstagramReaderService, profile: CredentialProfile, webhookAppSecret: String?, pretty: Bool) async throws -> (status: Int32, text: String) {
    switch command {
    case "accounts":
      guard let subcommand = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Missing accounts subcommand") }
      switch subcommand {
      case "pages":
        let page = try await service.facebookPages(limit: parser.intValue("--limit"), after: parser.consumeValue("--after"))
        return (0, encode(SuccessEnvelope(data: page.data, paging: page.paging), pretty: pretty))
      case "instagram":
        let page = try await service.facebookPages(limit: parser.intValue("--limit"), after: parser.consumeValue("--after"))
        let accounts = page.data.compactMap(\.instagramBusinessAccount)
        return (0, encode(SuccessEnvelope(data: accounts, paging: page.paging), pretty: pretty))
      case "business-discovery":
        let username = try parser.requiredValue("--username")
        let accountId = try parser.optionalValue("--account-id") ?? profile.instagramUserId.required("account id")
        return (0, encode(SuccessEnvelope(data: try await service.businessDiscovery(accountId: accountId, username: username)), pretty: pretty))
      default:
        throw InstagramGatewayError.unsupportedOperation("Unsupported accounts subcommand '\(subcommand)'")
      }
    case "account":
      guard parser.next() == "get" else { throw InstagramGatewayError.unsupportedOperation("Unsupported account command") }
      let id = try parser.optionalValue("--account-id") ?? profile.instagramUserId.required("account id")
      return (0, encode(SuccessEnvelope(data: try await service.account(id: id)), pretty: pretty))
    case "media":
      guard let subcommand = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Missing media subcommand") }
      switch subcommand {
      case "list":
        let accountId = try parser.optionalValue("--account-id") ?? profile.instagramUserId.required("account id")
        let page = try await service.media(accountId: accountId, limit: parser.intValue("--limit"), after: parser.consumeValue("--after"))
        return (0, encode(SuccessEnvelope(data: page.data, paging: page.paging), pretty: pretty))
      case "get":
        let id = try parser.requiredValue("--media-id")
        return (0, encode(SuccessEnvelope(data: try await service.media(id: id)), pretty: pretty))
      default:
        throw InstagramGatewayError.unsupportedOperation("Writer command is unsupported by reader binary")
      }
    case "stories", "live-media", "tagged-media":
      let accountId = try parser.optionalValue("--account-id") ?? profile.instagramUserId.required("account id")
      let page: Page<InstagramMedia>
      switch command {
      case "stories": page = try await service.stories(accountId: accountId, limit: parser.intValue("--limit"), after: parser.consumeValue("--after"))
      case "live-media": page = try await service.liveMedia(accountId: accountId, limit: parser.intValue("--limit"), after: parser.consumeValue("--after"))
      default: page = try await service.taggedMedia(accountId: accountId, limit: parser.intValue("--limit"), after: parser.consumeValue("--after"))
      }
      return (0, encode(SuccessEnvelope(data: page.data, paging: page.paging), pretty: pretty))
    case "comments":
      guard let subcommand = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Missing comments subcommand") }
      switch subcommand {
      case "list":
        let mediaId = try parser.requiredValue("--media-id")
        let page = try await service.comments(mediaId: mediaId, limit: parser.intValue("--limit"), after: parser.consumeValue("--after"))
        return (0, encode(SuccessEnvelope(data: page.data, paging: page.paging), pretty: pretty))
      case "get":
        let id = try parser.requiredValue("--comment-id")
        let comment: InstagramComment = try await service.client.request(HTTPRequest(method: .get, path: id, query: [("fields", "id,text,username,timestamp,hidden")]), as: InstagramComment.self)
        return (0, encode(SuccessEnvelope(data: comment), pretty: pretty))
      default:
        throw InstagramGatewayError.unsupportedOperation("Writer command is unsupported by reader binary")
      }
    case "insights":
      guard let subcommand = parser.next(), ["account", "media"].contains(subcommand) else {
        throw InstagramGatewayError.unsupportedOperation("Unsupported insights command")
      }
      let id = try parser.requiredValue(subcommand == "account" ? "--account-id" : "--media-id")
      let metrics = try parser.requiredValue("--metric")
      let period = parser.consumeValue("--period")
      return (0, encode(SuccessEnvelope(data: try await service.insights(nodeId: id, metrics: metrics, period: period)), pretty: pretty))
    case "publishing-limit":
      let id = try parser.optionalValue("--account-id") ?? profile.instagramUserId.required("account id")
      return (0, encode(SuccessEnvelope(data: try await service.contentPublishingLimit(accountId: id)), pretty: pretty))
    case "hashtags":
      guard let subcommand = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Missing hashtags subcommand") }
      let accountId = try parser.optionalValue("--account-id") ?? profile.instagramUserId.required("account id")
      switch subcommand {
      case "search":
        return (0, encode(SuccessEnvelope(data: try await service.searchHashtags(accountId: accountId, query: try parser.requiredValue("--query"))), pretty: pretty))
      case "top", "recent":
        let hashtagId = try parser.requiredValue("--hashtag-id")
        let limit = try parser.positiveIntValue("--limit")
        let after = try parser.safeCursorValue("--after")
        let page: Page<InstagramHashtagMedia>
        if subcommand == "top" {
          page = try await service.topHashtagMedia(hashtagId: hashtagId, accountId: accountId, limit: limit, after: after)
        } else {
          page = try await service.recentHashtagMedia(hashtagId: hashtagId, accountId: accountId, limit: limit, after: after)
        }
        return (0, encode(SuccessEnvelope(data: page.data, paging: page.paging), pretty: pretty))
      case "recently-searched":
        let page = try await service.recentlySearchedHashtags(accountId: accountId, limit: try parser.positiveIntValue("--limit"), after: try parser.safeCursorValue("--after"))
        return (0, encode(SuccessEnvelope(data: page.data, paging: page.paging), pretty: pretty))
      default: throw InstagramGatewayError.unsupportedOperation("Unsupported hashtags subcommand '\(subcommand)'")
      }
    case "oembed":
      guard parser.next() == "get" else { throw InstagramGatewayError.unsupportedOperation("Unsupported oembed command") }
      guard profile.features.contains("oembed"), profile.oEmbedAccessToken != nil else { throw InstagramGatewayError.permissionDenied("Selected credential must declare oembed and provide oembed_access_token_ref") }
      let maxWidth = try parser.positiveIntValue("--max-width")
      let embed = try await service.oEmbed(InstagramOEmbedRequest(url: try parser.requiredValue("--url"), maxWidth: maxWidth, hideCaption: parser.consume("--hide-caption") ? true : nil, omitScript: parser.consume("--omit-script") ? true : nil))
      return (0, encode(SuccessEnvelope(data: embed), pretty: pretty))
    case "mentions":
      guard let subcommand = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Missing mentions subcommand") }
      let accountId = try parser.optionalValue("--account-id") ?? profile.instagramUserId.required("account id")
      switch subcommand {
      case "media":
        let result = try await service.mentionedMedia(MentionedMediaLookup(accountId: accountId, mediaId: try parser.requiredValue("--media-id"), commentsLimit: try parser.positiveIntValue("--comments-limit"), commentsAfter: try parser.safeCursorValue("--comments-after")))
        return (0, encode(SuccessEnvelope(data: result), pretty: pretty))
      case "comment":
        let result = try await service.mentionedComment(MentionedCommentLookup(accountId: accountId, commentId: try parser.requiredValue("--comment-id")))
        return (0, encode(SuccessEnvelope(data: result), pretty: pretty))
      default: throw InstagramGatewayError.unsupportedOperation("Unsupported mentions subcommand '\(subcommand)'")
      }
    case "shopping":
      guard let subcommand = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Missing shopping subcommand") }
      let account = try parser.optionalValue("--account-id") ?? profile.instagramUserId.required("account id")
      switch subcommand {
      case "eligibility": return (0, encode(SuccessEnvelope(data: try await service.shoppingEligibility(accountId: account)), pretty: pretty))
      case "catalogs": let page = try await service.availableCatalogs(accountId: account, limit: try parser.positiveIntValue("--limit"), after: try parser.safeCursorValue("--after")); return (0, encode(SuccessEnvelope(data: page.data, paging: page.paging), pretty: pretty))
      case "products": let page = try await service.searchCatalogProducts(accountId: account, catalogId: try parser.requiredValue("--catalog-id"), query: try parser.optionalValue("--query"), limit: try parser.positiveIntValue("--limit"), after: try parser.safeCursorValue("--after")); return (0, encode(SuccessEnvelope(data: page.data, paging: page.paging), pretty: pretty))
      case "product-tags": let page = try await service.productTags(mediaId: try parser.requiredValue("--media-id"), limit: try parser.positiveIntValue("--limit"), after: try parser.safeCursorValue("--after")); return (0, encode(SuccessEnvelope(data: page.data, paging: page.paging), pretty: pretty))
      case "media-children": let page = try await service.mediaChildren(mediaId: try parser.requiredValue("--media-id"), limit: try parser.positiveIntValue("--limit"), after: try parser.safeCursorValue("--after")); return (0, encode(SuccessEnvelope(data: page.data, paging: page.paging), pretty: pretty))
      case "appeal-status": return (0, encode(SuccessEnvelope(data: try await service.productAppealStatus(accountId: account, productId: try parser.requiredValue("--product-id"))), pretty: pretty))
      default: throw InstagramGatewayError.unsupportedOperation("Unsupported shopping subcommand '\(subcommand)'")
      }
    case "messaging":
      guard let subcommand = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Missing messaging subcommand") }
      let actor = profile.loginType == .facebook ? try profile.pageId.required("Page messaging actor") : try profile.instagramUserId.required("Instagram messaging actor")
      try requireMessagingPermission(profile, operation: .read)
      switch subcommand {
      case "conversations":
        let leaf = parser.next() ?? "list"
        let page: Page<InstagramConversation>
        switch leaf {
        case "list": page = try await service.conversations(actorId: actor, limit: try parser.positiveIntValue("--limit"), after: try parser.safeCursorValue("--after"))
        case "find": page = try await service.conversations(actorId: actor, instagramScopedUserId: try parser.requiredValue("--recipient-igsid"), limit: try parser.positiveIntValue("--limit"), after: try parser.safeCursorValue("--after"))
        default: throw InstagramGatewayError.unsupportedOperation("Unsupported messaging conversations command")
        }
        return (0, encode(SuccessEnvelope(data: page.data, paging: page.paging), pretty: pretty))
      case "conversation":
        guard parser.next() == "find" else { throw InstagramGatewayError.unsupportedOperation("Unsupported messaging conversation command") }
        let page = try await service.conversations(actorId: actor, instagramScopedUserId: try parser.requiredValue("--instagram-scoped-user-id"), limit: try parser.positiveIntValue("--limit"), after: try parser.safeCursorValue("--after"))
        return (0, encode(SuccessEnvelope(data: page.data, paging: page.paging), pretty: pretty))
      case "messages":
        let leaf = parser.next() ?? "list"
        switch leaf {
        case "list": let page = try await service.conversationMessages(conversationId: try parser.requiredValue("--conversation-id"), limit: try parser.positiveIntValue("--limit"), after: try parser.safeCursorValue("--after")); return (0, encode(SuccessEnvelope(data: page.data, paging: page.paging), pretty: pretty))
        case "get": return (0, encode(SuccessEnvelope(data: try await service.message(id: try parser.requiredValue("--message-id"))), pretty: pretty))
        default: throw InstagramGatewayError.unsupportedOperation("Unsupported messaging messages command")
        }
      case "get": return (0, encode(SuccessEnvelope(data: try await service.message(id: try parser.requiredValue("--message-id"))), pretty: pretty))
      case "user-profile":
        guard parser.next() == "get" else { throw InstagramGatewayError.unsupportedOperation("Unsupported messaging user-profile command") }
        return (0, encode(SuccessEnvelope(data: try await service.messagingUserProfile(instagramScopedUserId: try parser.requiredValue("--instagram-scoped-user-id"))), pretty: pretty))
      case "profile":
        guard parser.next() == "get" else { throw InstagramGatewayError.unsupportedOperation("Unsupported messaging profile command") }
        if let igsid = try parser.optionalValue("--recipient-igsid") { return (0, encode(SuccessEnvelope(data: try await service.messagingUserProfile(instagramScopedUserId: igsid)), pretty: pretty)) }
        return (0, encode(SuccessEnvelope(data: try await service.messagingProfile(actorId: actor)), pretty: pretty))
      case "ice-breakers":
        guard parser.next() == "get" else { throw InstagramGatewayError.unsupportedOperation("Unsupported messaging ice-breakers command") }
        return (0, encode(SuccessEnvelope(data: try await service.iceBreakers(accountId: actor)), pretty: pretty))
      case "persistent-menu":
        guard parser.next() == "get" else { throw InstagramGatewayError.unsupportedOperation("Unsupported messaging persistent-menu command") }
        return (0, encode(SuccessEnvelope(data: try await service.persistentMenu(accountId: actor)), pretty: pretty))
      default: throw InstagramGatewayError.unsupportedOperation("Unsupported messaging subcommand '\(subcommand)'")
      }
    case "webhooks":
      guard let subcommand = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Missing webhooks subcommand") }
      switch subcommand {
      case "decode":
        guard let webhookAppSecret else { throw InstagramGatewayError.credentialUnavailable("Webhook decoding requires app_secret_ref") }
        let path = try parser.requiredValue("--body-file")
        let body = try Data(contentsOf: URL(fileURLWithPath: path))
        let payload = try InstagramWebhookDecoder().verifyAndDecode(body: body, signatureHeader: try parser.requiredValue("--signature"), appSecret: webhookAppSecret)
        return (0, encode(SuccessEnvelope(data: payload), pretty: pretty))
      case "subscriptions":
        let account = try parser.optionalValue("--account") ?? profile.instagramUserId.required("account id")
        let subscriptions = try await InstagramWebhookSubscriptionService(client: service.client, loginType: profile.loginType).list(accountId: account)
        return (0, encode(SuccessEnvelope(data: subscriptions.data, paging: subscriptions.paging), pretty: pretty))
      default: throw InstagramGatewayError.unsupportedOperation("Unsupported webhooks subcommand '\(subcommand)'")
      }
    default:
      throw InstagramGatewayError.unsupportedOperation("Unsupported reader command '\(command)'")
    }
  }

  static func handleWriter(command: String, parser: inout ArgumentParser, service: InstagramWriterService, profile: CredentialProfile, pretty: Bool) async throws -> (status: Int32, text: String) {
    switch command {
    case "media":
      guard let subcommand = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Missing media subcommand") }
      switch subcommand {
      case "create-container":
        try parser.requireConfirmation()
        let account = try parser.requiredValue("--account")
        let kind = parser.consumeValue("--type") ?? "image"
        let mediaType: PublishingMediaType
        switch kind {
        case "image": mediaType = .image
        case "reel", "video": mediaType = .video
        case "story-image": mediaType = .storyImage
        case "story-video": mediaType = .storyVideo
        case "carousel-image": mediaType = .carouselImage
        case "carousel-video": mediaType = .carouselVideo
        case "carousel": mediaType = .carousel
        default: throw InstagramGatewayError.configurationInvalid("Unsupported publishing type '\(kind)'")
        }
        let imageURL = parser.consumeValue("--image-url")
        let videoURL = parser.consumeValue("--video-url")
        let children = (parser.consumeValue("--children") ?? "").split(separator: ",").map(String.init)
        let caption = parser.consumeValue("--caption")
        let productTags = try parser.has("--product-tags-json") ? parser.productTagsValue("--product-tags-json") : []
        if !productTags.isEmpty {
          guard profile.loginType == .facebook else {
            throw InstagramGatewayError.unsupportedOperation("Product tagging requires Facebook Login")
          }
          try requireOwnedCommerceFixture(profile)
        }
        let publishingOptions = try parser.publishingOptions()
        var providerFields: [String: String] = [:]
        if parser.consume("--share-to-feed") { providerFields["share_to_feed"] = "true" }
        let input = CreateMediaContainerInput(
          accountId: account,
          mediaType: mediaType,
          imageURL: imageURL,
          videoURL: videoURL,
          caption: caption,
          children: children,
          providerFields: providerFields,
          productTags: productTags,
          publishingOptions: publishingOptions
        )
        return (0, encode(SuccessEnvelope(data: try await service.createMediaContainer(input)), pretty: pretty))
      case "container-status":
        _ = parser.consumeValue("--account")
        let containerId = try parser.requiredValue("--container-id")
        return (0, encode(SuccessEnvelope(data: try await service.containerStatus(containerId: containerId)), pretty: pretty))
      case "create-resumable-container":
        try parser.requireConfirmation()
        let account = try parser.requiredValue("--account")
        let options = InstagramPublishingOptions(
          userTags: try parser.userTagsValue(),
          collaborators: parser.consumeValues("--collaborator"),
          locationId: try parser.optionalValue("--location-id"),
          cover: InstagramVideoCover(url: try parser.optionalValue("--cover-url"), thumbnailOffsetMilliseconds: try parser.nonNegativeIntValue("--thumb-offset-ms")),
          altText: try parser.optionalValue("--alt-text")
        )
        return (0, encode(SuccessEnvelope(data: try await service.createResumableVideoContainer(CreateResumableVideoContainerInput(accountId: account, options: options))), pretty: pretty))
      case "upload-resumable":
        try parser.requireConfirmation()
        let result = try await service.uploadResumableVideo(UploadResumableVideoInput(uploadURI: try parser.requiredValue("--upload-uri"), filePath: try parser.requiredValue("--file"), offset: Int64(try parser.nonNegativeIntValue("--offset") ?? 0)))
        return (0, encode(SuccessEnvelope(data: result), pretty: pretty))
      case "resumable-status":
        let id = try parser.requiredValue("--container-id")
        return (0, encode(SuccessEnvelope(data: try await service.containerStatus(containerId: id)), pretty: pretty))
      case "publish":
        try parser.requireConfirmation()
        let account = try parser.requiredValue("--account")
        let containerId = try parser.requiredValue("--container-id")
        return (0, encode(SuccessEnvelope(data: try await service.publish(accountId: account, containerId: containerId)), pretty: pretty))
      default:
        throw InstagramGatewayError.unsupportedOperation("Unsupported writer media subcommand '\(subcommand)'")
      }
    case "media-comments":
      guard let subcommand = parser.next() else {
        throw InstagramGatewayError.unsupportedOperation("Missing media comments operation")
      }
      try parser.requireConfirmation()
      let mediaId = try parser.requiredValue("--media-id")
      switch subcommand {
      case "enable": return (0, encode(SuccessEnvelope(data: try await service.setCommentsEnabled(mediaId: mediaId, enabled: true)), pretty: pretty))
      case "disable": return (0, encode(SuccessEnvelope(data: try await service.setCommentsEnabled(mediaId: mediaId, enabled: false)), pretty: pretty))
      default: throw InstagramGatewayError.unsupportedOperation("Unsupported media comments operation '\(subcommand)'")
      }
    case "comments":
      guard let subcommand = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Missing comments subcommand") }
      try parser.requireConfirmation()
      let account = try parser.requiredValue("--account")
      let commentId = try parser.requiredValue("--comment-id")
      switch subcommand {
      case "reply":
        let message = try parser.requiredValue("--message")
        return (0, encode(SuccessEnvelope(data: try await service.reply(accountId: account, commentId: commentId, message: message)), pretty: pretty))
      case "hide":
        return (0, encode(SuccessEnvelope(data: try await service.moderate(accountId: account, commentId: commentId, action: .hide)), pretty: pretty))
      case "unhide":
        return (0, encode(SuccessEnvelope(data: try await service.moderate(accountId: account, commentId: commentId, action: .unhide)), pretty: pretty))
      case "delete":
        return (0, encode(SuccessEnvelope(data: try await service.moderate(accountId: account, commentId: commentId, action: .delete)), pretty: pretty))
      default:
        throw InstagramGatewayError.unsupportedOperation("Unsupported writer comments subcommand '\(subcommand)'")
      }
    case "mentions":
      guard parser.next() == "reply" else { throw InstagramGatewayError.unsupportedOperation("Unsupported mentions command") }
      try parser.requireConfirmation()
      let accountId = try parser.requiredValue("--account")
      let mediaId = try parser.requiredValue("--media-id")
      let target: MentionTarget
      if let commentId = try parser.optionalValue("--comment-id") { target = .comment(mediaId: mediaId, commentId: commentId) }
      else { target = .caption(mediaId: mediaId) }
      let result = try await service.replyToMention(ReplyToMentionInput(accountId: accountId, target: target, message: try parser.requiredValue("--message")))
      return (0, encode(SuccessEnvelope(data: result), pretty: pretty))
    case "shopping":
      guard let subcommand = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Missing shopping subcommand") }
      try parser.requireConfirmation()
      let account = try parser.requiredValue("--account")
      guard profile.instagramUserId == nil || profile.instagramUserId == account else { throw InstagramGatewayError.permissionDenied("Configured Instagram account does not match --account") }
      try requireOwnedCommerceFixture(profile)
      switch subcommand {
      case "update-product-tags":
        guard profile.loginType == .facebook else { throw InstagramGatewayError.unsupportedOperation("Product tagging requires Facebook Login") }
        let tags = try parser.productTagsValue("--product-tags-json")
        return (0, encode(SuccessEnvelope(data: try await service.addOrUpdateProductTags(UpdateProductTagsInput(accountId: account, mediaId: try parser.requiredValue("--media-id"), tags: tags))), pretty: pretty))
      case "appeal":
        let result = try await service.submitProductAppeal(SubmitProductAppealInput(accountId: account, productId: try parser.requiredValue("--product-id"), reason: try parser.requiredValue("--reason")))
        return (0, encode(SuccessEnvelope(data: result), pretty: pretty))
      default: throw InstagramGatewayError.unsupportedOperation("Unsupported shopping subcommand '\(subcommand)'")
      }
    case "messaging":
      guard let subcommand = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Missing messaging subcommand") }
      try parser.requireConfirmation()
      let actor = profile.loginType == .facebook ? try profile.pageId.required("Page messaging actor") : try profile.instagramUserId.required("Instagram messaging actor")
      switch subcommand {
      case "send":
        let content: InstagramMessageContent
        let leaf = parser.consumePositional(oneOf: ["text", "media", "attachment", "published-post", "sticker", "quick-replies", "generic-template", "button-template"])
        switch leaf {
        case "attachment": content = .uploadedImage(attachmentId: try parser.requiredValue("--attachment-id"))
        case "published-post": content = .publishedPost(mediaId: try parser.requiredValue("--owned-media-id"))
        case "sticker": content = .heartSticker
        case "quick-replies":
          let flag = parser.has("--input") ? "--input" : "--quick-replies-input"
          let replies: [InstagramQuickReply] = try parser.strictJSONFileValue(flag, schema: .quickReplies)
          content = .quickReplies(text: try parser.requiredValue("--text"), replies: replies)
        case "generic-template":
          let flag = parser.has("--input") ? "--input" : "--template-input"
          content = .template(.generic(try parser.strictJSONFileValue(flag, schema: .genericTemplate)))
        case "button-template":
          let flag = parser.has("--input") ? "--input" : "--template-input"
          let template: ButtonTemplateInput = try parser.strictJSONFileValue(flag, schema: .buttonTemplate)
          content = .template(.button(text: template.text, buttons: template.buttons))
        case "text": content = .text(try parser.requiredValue("--text"))
        case "media":
          if let url = try parser.optionalValue("--image-url") { content = .imageURL(url) }
          else if let url = try parser.optionalValue("--audio-url") { content = .audioURL(url) }
          else { content = .videoURL(try parser.requiredValue("--video-url")) }
        case nil:
          if let attachmentId = try parser.optionalValue("--attachment-id") { content = .uploadedImage(attachmentId: attachmentId) }
          else if let mediaId = try parser.optionalValue("--owned-media-id") { content = .publishedPost(mediaId: mediaId) }
          else if parser.consume("--heart-sticker") { content = .heartSticker }
          else if parser.has("--quick-replies-input") {
            let replies: [InstagramQuickReply] = try parser.strictJSONFileValue("--quick-replies-input", schema: .quickReplies)
            content = .quickReplies(text: try parser.requiredValue("--text"), replies: replies)
          }
          else if let text = try parser.optionalValue("--text") { content = .text(text) }
          else if let url = try parser.optionalValue("--image-url") { content = .imageURL(url) }
          else if let url = try parser.optionalValue("--audio-url") { content = .audioURL(url) }
          else if let url = try parser.optionalValue("--video-url") { content = .videoURL(url) }
          else if parser.has("--template-input") {
            switch try parser.requiredValue("--template-kind") {
            case "generic": content = .template(.generic(try parser.strictJSONFileValue("--template-input", schema: .genericTemplate)))
            case "button": let template: ButtonTemplateInput = try parser.strictJSONFileValue("--template-input", schema: .buttonTemplate); content = .template(.button(text: template.text, buttons: template.buttons))
            default: throw InstagramGatewayError.configurationInvalid("--template-kind must be generic or button")
            }
          } else { throw InstagramGatewayError.configurationInvalid("One message content option is required") }
        default: throw InstagramGatewayError.configurationInvalid("Unsupported messaging send leaf")
        }
        let humanAgent = parser.consume("--human-agent")
        try requireMessagingPermission(profile, operation: .send, humanAgent: humanAgent)
        let result = try await service.sendMessage(actorId: actor, input: SendInstagramMessageInput(recipientId: try parser.messagingRecipientID(), content: content, humanAgent: humanAgent))
        return (0, encode(SuccessEnvelope(data: result), pretty: pretty))
      case "private-reply":
        try requireMessagingPermission(profile, operation: .privateReply)
        let result = try await service.privateReply(PrivateReplyInput(accountId: try profile.instagramUserId.required("Instagram account"), commentId: try parser.requiredValue("--comment-id"), text: try parser.requiredValue("--text")))
        return (0, encode(SuccessEnvelope(data: result), pretty: pretty))
      case "react", "unreact":
        try requireMessagingPermission(profile, operation: .react)
        guard try parser.requiredValue("--reaction") == "love" else { throw InstagramGatewayError.configurationInvalid("--reaction must be love") }
        let action: InstagramReactionAction = subcommand == "react" ? .react : .unreact
        let result = try await service.reactToMessage(ReactToInstagramMessageInput(accountId: actor, recipientId: try parser.messagingRecipientID(), messageId: try parser.requiredValue("--message-id"), action: action))
        return (0, encode(SuccessEnvelope(data: result), pretty: pretty))
      case "sender-action", "action":
        try requireMessagingPermission(profile, operation: .senderAction)
        let actionValue: String
        if subcommand == "action" { guard let value = parser.next() else { throw InstagramGatewayError.configurationInvalid("Missing sender action") }; actionValue = value }
        else { actionValue = try parser.requiredValue("--action") }
        let action: InstagramSenderAction
        switch actionValue { case "mark-seen": action = .markSeen; case "typing-on": action = .typingOn; case "typing-off": action = .typingOff; default: throw InstagramGatewayError.configurationInvalid("--action must be mark-seen, typing-on, or typing-off") }
        return (0, encode(SuccessEnvelope(data: try await service.performSenderAction(PerformInstagramSenderActionInput(accountId: actor, recipientId: try parser.messagingRecipientID(), action: action))), pretty: pretty))
      case "upload-attachment", "attachments":
        try requireMessagingPermission(profile, operation: .uploadAttachment)
        if subcommand == "attachments", parser.next() != "upload" { throw InstagramGatewayError.unsupportedOperation("Unsupported messaging attachments command") }
        return (0, encode(SuccessEnvelope(data: try await service.uploadMessageAttachment(UploadInstagramMessageAttachmentInput(accountId: actor, recipientId: try parser.messagingRecipientID(), imageURL: try parser.requiredValue("--image-url"), reusable: !parser.consume("--not-reusable")))), pretty: pretty))
      case "set-ice-breakers", "ice-breakers":
        try requireMessagingPermission(profile, operation: .profile)
        if subcommand == "ice-breakers" {
          guard let leaf = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Unsupported messaging ice-breakers command") }
          if leaf == "delete" { return (0, encode(SuccessEnvelope(data: try await service.deleteIceBreakers(actorId: actor)), pretty: pretty)) }
          guard leaf == "set" else { throw InstagramGatewayError.unsupportedOperation("Unsupported messaging ice-breakers command") }
        }
        let values: [InstagramIceBreaker] = try parser.strictJSONFileValue("--input", schema: .iceBreakers)
        return (0, encode(SuccessEnvelope(data: try await service.setIceBreakers(actorId: actor, iceBreakers: values)), pretty: pretty))
      case "delete-ice-breakers":
        try requireMessagingPermission(profile, operation: .profile)
        return (0, encode(SuccessEnvelope(data: try await service.deleteIceBreakers(actorId: actor)), pretty: pretty))
      case "set-persistent-menu", "persistent-menu":
        try requireMessagingPermission(profile, operation: .profile)
        if subcommand == "persistent-menu" {
          guard let leaf = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Unsupported messaging persistent-menu command") }
          if leaf == "delete" { return (0, encode(SuccessEnvelope(data: try await service.deletePersistentMenu(actorId: actor)), pretty: pretty)) }
          guard leaf == "set" else { throw InstagramGatewayError.unsupportedOperation("Unsupported messaging persistent-menu command") }
        }
        let values: [InstagramPersistentMenuItem] = try parser.strictJSONFileValue("--input", schema: .persistentMenu)
        return (0, encode(SuccessEnvelope(data: try await service.setPersistentMenu(actorId: actor, items: values)), pretty: pretty))
      case "delete-persistent-menu":
        try requireMessagingPermission(profile, operation: .profile)
        return (0, encode(SuccessEnvelope(data: try await service.deletePersistentMenu(actorId: actor)), pretty: pretty))
      default: throw InstagramGatewayError.unsupportedOperation("Unsupported messaging subcommand '\(subcommand)'")
      }
    case "subscriptions":
      guard let subcommand = parser.next() else { throw InstagramGatewayError.unsupportedOperation("Missing subscriptions subcommand") }
      try parser.requireConfirmation()
      let account = try parser.requiredValue("--account")
      let subscriptions = InstagramWebhookSubscriptionService(client: service.client, loginType: profile.loginType)
      switch subcommand {
      case "subscribe":
        let fields = try parser.consumeValues("--field").map(InstagramGatewayCLI.webhookField)
        return (0, encode(SuccessEnvelope(data: try await subscriptions.subscribe(accountId: account, fields: fields)), pretty: pretty))
      case "delete":
        return (0, encode(SuccessEnvelope(data: try await subscriptions.delete(accountId: account)), pretty: pretty))
      default: throw InstagramGatewayError.unsupportedOperation("Unsupported subscriptions subcommand '\(subcommand)'")
      }
    default:
      throw InstagramGatewayError.unsupportedOperation("Unsupported writer command '\(command)'")
    }
  }

  static func help(binary: BinaryKind) -> String {
    switch binary {
    case .reader:
      """
      instagram-gateway-reader \(instagramGatewayVersion)
      Usage: instagram-gateway-reader [--config <path>] [--pretty] <command>

      Commands:
        version
        doctor [--offline]
        config validate
        accounts pages
        accounts instagram
        accounts business-discovery
        media list|get
        stories
        live-media
        tagged-media
        hashtags search|top|recent|recently-searched
        mentions media|comment
        oembed get --url <https-url>
        shopping eligibility|catalogs|products|product-tags|media-children|appeal-status
        messaging conversations list|find|messages list|get|profile get|ice-breakers get|persistent-menu get
        webhooks decode --body-file <path> --signature <sha256=...>
        webhooks subscriptions --account <id>
        comments list|get
        insights account|media
        publishing-limit
      """
    case .writer:
      """
      instagram-gateway-writer \(instagramGatewayVersion)
      Usage: instagram-gateway-writer [--config <path>] [--pretty] <command>

      Commands:
        version
        doctor [--offline]
        config validate
        media create-container --type image|reel|story-image|story-video|carousel-image|carousel-video|carousel --yes
        media publish --yes
        media container-status
        media create-resumable-container --account <id> --yes
        media resumable-status --container-id <id>
        media upload-resumable --upload-uri <uri> --file <path> --offset <bytes> --yes
        subscriptions subscribe|delete --account <id> --yes
        messaging send text|media|attachment|published-post|sticker|quick-replies|generic-template|button-template --yes
        messaging send --text|--image-url|--audio-url|--video-url|--attachment-id|--owned-media-id|--heart-sticker|--quick-replies-input|--template-input --yes
        messaging react|unreact --recipient-igsid <id> --message-id <id> --reaction love --yes
        messaging action mark-seen|typing-on|typing-off --recipient-igsid <id> --yes
        messaging attachments upload --recipient-igsid <id> --image-url <https-url> --yes
        messaging private-reply --comment-id <id> --text <text> --yes
        messaging ice-breakers set|delete --yes
        messaging persistent-menu set|delete --yes
        media-comments enable|disable --yes
        comments reply|hide|unhide|delete --yes
        mentions reply --account <id> --media-id <id> [--comment-id <id>] --message <text> --yes
        shopping update-product-tags|appeal --yes
      """
    }
  }

  static func encode<T: Encodable>(_ value: T, pretty: Bool = false) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    let data = (try? encoder.encode(value)) ?? Data(#"{"ok":false,"error":{"code":"ENCODING_FAILED","message":"Failed to encode JSON"}}"#.utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  static func webhookField(_ value: String) throws -> InstagramWebhookField {
    switch value {
    case "comments": return .comments
    case "mentions": return .mentions
    case "messages": return .messages
    case "messaging_postbacks": return .messagingPostbacks
    case "story_insights": return .storyInsights
    default: throw InstagramGatewayError.configurationInvalid("Unsupported webhook field '\(value)'")
    }
  }
}

struct ArgumentParser {
  private var values: [String]

  init(_ values: [String]) {
    self.values = values
  }

  mutating func next() -> String? {
    values.isEmpty ? nil : values.removeFirst()
  }

  mutating func consumePositional(oneOf candidates: [String]) -> String? {
    guard let index = values.firstIndex(where: { candidates.contains($0) }) else { return nil }
    return values.remove(at: index)
  }

  mutating func consume(_ flag: String) -> Bool {
    if let index = values.firstIndex(of: flag) {
      values.remove(at: index)
      return true
    }
    return false
  }

  mutating func consume(_ flag: String, value: String) -> Bool {
    if let index = values.firstIndex(of: flag), values.indices.contains(index + 1), values[index + 1] == value {
      values.remove(at: index + 1)
      values.remove(at: index)
      return true
    }
    return false
  }

  mutating func consumeValue(_ flag: String) -> String? {
    guard let index = values.firstIndex(of: flag), values.indices.contains(index + 1) else { return nil }
    let value = values[index + 1]
    values.remove(at: index + 1)
    values.remove(at: index)
    return value
  }

  mutating func requiredValue(_ flag: String) throws -> String {
    guard let value = consumeValue(flag), !value.isEmpty else {
      throw InstagramGatewayError.configurationInvalid("Missing required argument \(flag)")
    }
    return value
  }

  mutating func messagingRecipientID() throws -> String {
    if let value = try optionalValue("--recipient-igsid") { return value }
    return try requiredValue("--recipient-id")
  }

  mutating func optionalValue(_ flag: String) throws -> String? {
    guard let value = consumeValue(flag) else { return nil }
    guard !value.isEmpty else {
      throw InstagramGatewayError.configurationInvalid("Missing required argument \(flag)")
    }
    return value
  }

  mutating func intValue(_ flag: String) -> Int? {
    guard let value = consumeValue(flag) else { return nil }
    return Int(value)
  }

  mutating func positiveIntValue(_ flag: String) throws -> Int? {
    guard let value = consumeValue(flag) else { return nil }
    guard let integer = Int(value), integer > 0 else { throw InstagramGatewayError.configurationInvalid("\(flag) must be a positive integer") }
    return integer
  }

  mutating func nonNegativeIntValue(_ flag: String) throws -> Int? {
    guard let value = consumeValue(flag) else { return nil }
    guard let integer = Int(value), integer >= 0 else { throw InstagramGatewayError.configurationInvalid("\(flag) must be a non-negative integer") }
    return integer
  }

  mutating func consumeValues(_ flag: String) -> [String] {
    var output: [String] = []
    while let value = consumeValue(flag) { output.append(value) }
    return output
  }

  mutating func safeCursorValue(_ flag: String) throws -> String? {
    guard let value = consumeValue(flag) else { return nil }
    guard value.range(of: "^[A-Za-z0-9_=-]+$", options: .regularExpression) != nil else { throw InstagramGatewayError.configurationInvalid("Invalid cursor") }
    return value
  }

  mutating func productTagsValue(_ flag: String) throws -> [ProductTagInput] {
    let raw = try requiredValue(flag)
    guard let data = raw.data(using: .utf8), let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw InstagramGatewayError.configurationInvalid("\(flag) must be a JSON array") }
    let allowed: Set<String> = ["product_id", "x", "y"]
    guard array.allSatisfy({ Set($0.keys).isSubset(of: allowed) }) else { throw InstagramGatewayError.configurationInvalid("Product tag JSON contains unsupported keys") }
    return try JSONDecoder().decode([ProductTagInput].self, from: data)
  }

  mutating func userTagsValue() throws -> [InstagramUserTag] {
    try consumeValues("--user-tag-at").map { raw in
      let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) else {
        throw InstagramGatewayError.configurationInvalid("--user-tag-at must be username:x:y")
      }
      return InstagramUserTag(username: String(parts[0]), position: InstagramTagPosition(x: x, y: y))
    }
  }

  fileprivate mutating func strictJSONFileValue<T: Decodable>(_ flag: String, schema: JSONInputSchema) throws -> T {
    let path = try requiredValue(flag)
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let value = try JSONSerialization.jsonObject(with: data)
    guard data.count <= 262_144, schema.validates(value) else {
      throw InstagramGatewayError.configurationInvalid("\(flag) must be a JSON array with supported keys only")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  mutating func publishingOptions() throws -> InstagramPublishingOptions {
    InstagramPublishingOptions(
      userTags: try userTagsValue(),
      collaborators: consumeValues("--collaborator"),
      locationId: try optionalValue("--location-id"),
      cover: InstagramVideoCover(
        url: try optionalValue("--cover-url"),
        thumbnailOffsetMilliseconds: try nonNegativeIntValue("--thumb-offset-ms")
      ),
      altText: try optionalValue("--alt-text")
    )
  }

  mutating func requireConfirmation() throws {
    guard consume("--yes") else {
      throw InstagramGatewayError.confirmationRequired("State-changing writer command requires --yes")
    }
  }

  func peekWriterVerb() -> Bool {
    values.contains { ["create-container", "container-status", "publish", "reply", "hide", "unhide", "delete"].contains($0) }
  }

  func peekAny(_ candidates: [String]) -> Bool {
    values.contains { candidates.contains($0) }
  }

  func has(_ flag: String) -> Bool {
    values.contains(flag)
  }

  func isMutation(command: String) -> Bool {
    guard command == "media" || command == "comments" || command == "mentions" || command == "shopping" || command == "messaging" || command == "subscriptions" else { return false }
    return values.contains { ["create-container", "create-resumable-container", "upload-resumable", "publish", "reply", "hide", "unhide", "delete", "update-product-tags", "appeal", "send", "react", "unreact", "sender-action", "action", "private-reply", "upload-attachment", "attachments", "set-ice-breakers", "delete-ice-breakers", "ice-breakers", "set-persistent-menu", "delete-persistent-menu", "persistent-menu", "subscribe"].contains($0) }
  }
}

extension Optional where Wrapped == String {
  func required(_ name: String) throws -> String {
    guard let self, !self.isEmpty else {
      throw InstagramGatewayError.configurationInvalid("Missing required \(name)")
    }
    return self
  }
}

private struct ButtonTemplateInput: Decodable { var text: String; var buttons: [InstagramTemplateButton] }
private enum JSONInputSchema {
  case iceBreakers, persistentMenu, genericTemplate, buttonTemplate, quickReplies
  func validates(_ value: Any) -> Bool {
    switch self {
    case .iceBreakers: return array(value, keys: ["question", "payload"])
    case .persistentMenu: return array(value, keys: ["title", "type", "payload", "url"])
    case .genericTemplate:
      guard let values = value as? [[String: Any]] else { return false }
      return values.allSatisfy { object in
        guard Set(object.keys).isSubset(of: ["title", "subtitle", "image_url", "buttons"]), let buttons = object["buttons"] else { return object["buttons"] == nil }
        return array(buttons, keys: ["type", "title", "payload", "url"])
      }
    case .buttonTemplate:
      guard let object = value as? [String: Any], Set(object.keys).isSubset(of: ["text", "buttons"]), let buttons = object["buttons"] else { return false }
      return array(buttons, keys: ["type", "title", "payload", "url"])
    case .quickReplies:
      return array(value, keys: ["content_type", "title", "payload"])
    }
  }
  private func array(_ value: Any, keys: Set<String>) -> Bool { guard let values = value as? [[String: Any]] else { return false }; return values.allSatisfy { Set($0.keys).isSubset(of: keys) } }
}

private func requireMessagingPermission(_ profile: CredentialProfile, operation: InstagramMessagingOperation, humanAgent: Bool = false) throws {
  try InstagramMessagingAuthorization(profile: profile).validate(operation, humanAgent: humanAgent)
}

private func requireOwnedCommerceFixture(_ profile: CredentialProfile) throws {
  guard profile.features.contains("owned_commerce_fixture") else {
    throw InstagramGatewayError.permissionDenied("Shopping mutations require an owned_commerce_fixture credential feature")
  }
}
