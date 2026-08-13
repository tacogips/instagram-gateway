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
      transport: @escaping @Sendable (CredentialProfile) -> any HTTPTransport = { _ in URLSessionHTTPTransport() }
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
    if binary == .writer, ((command == "media" && parser.peekAny(["create-container", "publish"])) || command == "comments"), !parser.has("--yes") {
      throw InstagramGatewayError.confirmationRequired("State-changing writer command requires --yes")
    }
    let loaded = try runtime.loader.load(explicitPath: configPath)
    let requiredMode: AccessMode = binary == .reader ? .read : .write
    let profile = try loaded.config.profile(id: credentialId, requiredMode: requiredMode)
    let token = try runtime.resolver.resolve(profile.accessToken)
    let client = InstagramGatewayClient(transport: runtime.transport(profile), token: token)
    if binary == .reader {
      let service = InstagramReaderService(client: client)
      return try await handleReader(command: command, parser: &parser, service: service, profile: profile, pretty: pretty)
    }
    if binary == .writer {
      let service = InstagramWriterService(client: client)
      return try await handleWriter(command: command, parser: &parser, service: service, pretty: pretty)
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

  static func handleReader(command: String, parser: inout ArgumentParser, service: InstagramReaderService, profile: CredentialProfile, pretty: Bool) async throws -> (status: Int32, text: String) {
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
    default:
      throw InstagramGatewayError.unsupportedOperation("Unsupported reader command '\(command)'")
    }
  }

  static func handleWriter(command: String, parser: inout ArgumentParser, service: InstagramWriterService, pretty: Bool) async throws -> (status: Int32, text: String) {
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
        var providerFields: [String: String] = [:]
        if parser.consume("--share-to-feed") { providerFields["share_to_feed"] = "true" }
        let input = CreateMediaContainerInput(
          accountId: account,
          mediaType: mediaType,
          imageURL: imageURL,
          videoURL: videoURL,
          caption: caption,
          children: children,
          providerFields: providerFields
        )
        return (0, encode(SuccessEnvelope(data: try await service.createMediaContainer(input)), pretty: pretty))
      case "container-status":
        _ = parser.consumeValue("--account")
        let containerId = try parser.requiredValue("--container-id")
        return (0, encode(SuccessEnvelope(data: try await service.containerStatus(containerId: containerId)), pretty: pretty))
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
        media-comments enable|disable --yes
        comments reply|hide|unhide|delete --yes
      """
    }
  }

  static func encode<T: Encodable>(_ value: T, pretty: Bool = false) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    let data = (try? encoder.encode(value)) ?? Data(#"{"ok":false,"error":{"code":"ENCODING_FAILED","message":"Failed to encode JSON"}}"#.utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
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
}

extension Optional where Wrapped == String {
  func required(_ name: String) throws -> String {
    guard let self, !self.isEmpty else {
      throw InstagramGatewayError.configurationInvalid("Missing required \(name)")
    }
    return self
  }
}
