import CryptoKit
import Foundation

public let instagramGatewayVersion = "0.1.0"
public let metaGraphAPIVersion = "v26.0"

public enum AccessMode: String, Codable, Equatable, Sendable {
  case read
  case write
}

/// The Meta login product that issued a credential.  Unknown inbound values are
/// retained for diagnostics but are never accepted for operations that require
/// a known host contract.
public enum InstagramLoginType: Codable, Equatable, Sendable {
  case facebook
  case instagram
  case unknown(String)

  public init(from decoder: Decoder) throws {
    switch try decoder.singleValueContainer().decode(String.self) {
    case "facebook": self = .facebook
    case "instagram": self = .instagram
    case let value: self = .unknown(value)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .facebook: try container.encode("facebook")
    case .instagram: try container.encode("instagram")
    case .unknown(let value): try container.encode(value)
    }
  }
}

public typealias InstagramLoginMode = InstagramLoginType

public enum BinaryKind: String, Codable, Equatable, Sendable {
  case reader
  case writer
}

public enum HTTPMethod: String, Codable, Equatable, Sendable {
  case get = "GET"
  case post = "POST"
  case delete = "DELETE"
}

public enum SecretReference: Equatable, Sendable {
  case env(String)
  case kinko(String)
  case literal(String)

  public var description: String {
    switch self {
    case .env(let name): "env:\(name)"
    case .kinko(let name): "kinko:\(name)"
    case .literal: "literal:<redacted>"
    }
  }
}

public struct CredentialProfile: Equatable, Sendable {
  public var id: String
  public var provider: String
  public var accessMode: AccessMode
  public var appId: SecretReference?
  public var appSecret: SecretReference?
  public var accessToken: SecretReference
  public var instagramUserId: String?
  public var pageId: String?
  public var scopes: [String]
  public var loginType: InstagramLoginType
  public var webhookVerifyToken: SecretReference?
  /// Dedicated app/client token for the oEmbed product. It must not reuse the
  /// selected professional-account token.
  public var oEmbedAccessToken: SecretReference?
  public var features: [String]

  public init(
    id: String,
    provider: String = "meta-instagram",
    accessMode: AccessMode,
    appId: SecretReference? = nil,
    appSecret: SecretReference? = nil,
    accessToken: SecretReference,
    instagramUserId: String? = nil,
    pageId: String? = nil,
    scopes: [String] = [],
    loginType: InstagramLoginType = .facebook,
    webhookVerifyToken: SecretReference? = nil,
    oEmbedAccessToken: SecretReference? = nil,
    features: [String] = []
  ) {
    self.id = id
    self.provider = provider
    self.accessMode = accessMode
    self.appId = appId
    self.appSecret = appSecret
    self.accessToken = accessToken
    self.instagramUserId = instagramUserId
    self.pageId = pageId
    self.scopes = scopes
    self.loginType = loginType
    self.webhookVerifyToken = webhookVerifyToken
    self.oEmbedAccessToken = oEmbedAccessToken
    self.features = features
  }
}

public struct GatewayConfig: Equatable, Sendable {
  public var profiles: [CredentialProfile]
  public var defaultProfileId: String?

  public init(profiles: [CredentialProfile], defaultProfileId: String? = nil) {
    self.profiles = profiles
    self.defaultProfileId = defaultProfileId
  }

  public func profile(id: String? = nil, requiredMode: AccessMode? = nil) throws -> CredentialProfile {
    let selectedId = id ?? defaultProfileId ?? profiles.first?.id
    guard let selectedId else {
      throw InstagramGatewayError.configurationInvalid("No credential profiles are configured")
    }
    guard let profile = profiles.first(where: { $0.id == selectedId }) else {
      throw InstagramGatewayError.credentialUnavailable("Credential profile '\(selectedId)' was not found")
    }
    if let requiredMode, profile.accessMode != requiredMode {
      throw InstagramGatewayError.permissionDenied("Credential '\(profile.id)' is \(profile.accessMode.rawValue), expected \(requiredMode.rawValue)")
    }
    return profile
  }
}

public struct ConfigLoader: Sendable {
  public var environment: @Sendable (String) -> String?
  public var fileReader: @Sendable (String) throws -> String
  public var homeDirectory: String
  public var xdgConfigHome: String?

  public init(
    environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] },
    fileReader: @escaping @Sendable (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) },
    homeDirectory: String = NSHomeDirectory(),
    xdgConfigHome: String? = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
  ) {
    self.environment = environment
    self.fileReader = fileReader
    self.homeDirectory = homeDirectory
    self.xdgConfigHome = xdgConfigHome
  }

  public func discoveryPaths(explicitPath: String?) -> [String] {
    if let explicitPath { return [explicitPath] }
    if let envPath = environment("INSTAGRAM_GATEWAY_CONFIG"), !envPath.isEmpty { return [envPath] }
    var paths: [String] = []
    if let xdgConfigHome, !xdgConfigHome.isEmpty {
      paths.append("\(xdgConfigHome)/instagram-gateway/config.toml")
    }
    paths.append("\(homeDirectory)/.config/instagram-gateway/config.toml")
    return paths
  }

  public func load(explicitPath: String? = nil) throws -> (path: String, config: GatewayConfig) {
    var lastError: Error?
    for path in discoveryPaths(explicitPath: explicitPath) {
      do {
        return (path, try parseTOML(fileReader(path)))
      } catch {
        lastError = error
        if explicitPath != nil { break }
      }
    }
    if let lastError, explicitPath != nil { throw lastError }
    throw InstagramGatewayError.configurationInvalid("No config file found")
  }

  public func parseTOML(_ text: String) throws -> GatewayConfig {
    var defaultProfileId: String?
    var profiles: [CredentialProfile] = []
    var current: [String: String]?
    let rootKeys: Set<String> = ["default_credential"]
    let credentialKeys: Set<String> = [
      "id", "provider", "access_mode", "app_id_ref", "app_secret_ref",
      "access_token_ref", "oembed_access_token_ref", "instagram_user_id", "page_id", "scopes", "login_type", "login_mode", "webhook_verify_token_ref", "features"
    ]

    func flush() throws {
      guard let values = current else { return }
      guard let id = values["id"], !id.isEmpty else {
        throw InstagramGatewayError.configurationInvalid("Credential profile is missing id")
      }
      guard !profiles.contains(where: { $0.id == id }) else {
        throw InstagramGatewayError.configurationInvalid("Duplicate credential profile id '\(id)'")
      }
      guard values["provider", default: "meta-instagram"] == "meta-instagram" else {
        throw InstagramGatewayError.configurationInvalid("Unsupported provider for '\(id)'")
      }
      guard let modeValue = values["access_mode"], let mode = AccessMode(rawValue: modeValue) else {
        throw InstagramGatewayError.configurationInvalid("Credential '\(id)' has invalid access_mode")
      }
      guard let tokenRef = Self.secretReference(values["access_token_ref"]) else {
        throw InstagramGatewayError.configurationInvalid("Credential '\(id)' is missing access_token_ref")
      }
      profiles.append(CredentialProfile(
        id: id,
        accessMode: mode,
        appId: Self.secretReference(values["app_id_ref"]),
        appSecret: Self.secretReference(values["app_secret_ref"]),
        accessToken: tokenRef,
        instagramUserId: values["instagram_user_id"],
        pageId: values["page_id"],
        scopes: Self.array(values["scopes"]),
        loginType: Self.loginType(values["login_type"] ?? values["login_mode"]),
        webhookVerifyToken: Self.secretReference(values["webhook_verify_token_ref"]),
        oEmbedAccessToken: Self.secretReference(values["oembed_access_token_ref"]),
        features: Self.array(values["features"])
      ))
    }

    for rawLine in text.components(separatedBy: .newlines) {
      let line = Self.stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty { continue }
      if line == "[[credentials]]" {
        try flush()
        current = [:]
        continue
      }
      guard !line.hasPrefix("[") else {
        throw InstagramGatewayError.configurationInvalid("Unsupported TOML table '\(line)'")
      }
      guard let equals = line.firstIndex(of: "=") else { continue }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if current == nil {
        guard rootKeys.contains(key) else {
          throw InstagramGatewayError.configurationInvalid("Unsupported root config key '\(key)'")
        }
        if key == "default_credential" { defaultProfileId = Self.scalar(value) }
      } else {
        guard credentialKeys.contains(key) else {
          throw InstagramGatewayError.configurationInvalid("Unsupported credential config key '\(key)'")
        }
        current?[key] = Self.scalar(value)
      }
    }
    try flush()
    return GatewayConfig(profiles: profiles, defaultProfileId: defaultProfileId)
  }

  private static func scalar(_ raw: String) -> String {
    let value = raw.trimmingCharacters(in: .whitespaces)
    if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")), value.count >= 2 {
      return String(value.dropFirst().dropLast())
    }
    return value
  }

  private static func array(_ raw: String?) -> [String] {
    guard let raw else { return [] }
    let value = raw.trimmingCharacters(in: .whitespaces)
    guard value.hasPrefix("["), value.hasSuffix("]") else { return [] }
    return value.dropFirst().dropLast().split(separator: ",").map { scalar(String($0).trimmingCharacters(in: .whitespaces)) }
  }

  private static func loginType(_ raw: String?) -> InstagramLoginType {
    guard let raw else { return .facebook }
    switch raw {
    case "facebook": return .facebook
    case "instagram": return .instagram
    default: return .unknown(raw)
    }
  }

  private static func secretReference(_ raw: String?) -> SecretReference? {
    guard let raw, !raw.isEmpty else { return nil }
    if raw.hasPrefix("env:") { return .env(String(raw.dropFirst(4))) }
    if raw.hasPrefix("kinko:") { return .kinko(String(raw.dropFirst(6))) }
    if raw.hasPrefix("literal:") { return .literal(String(raw.dropFirst(8))) }
    return nil
  }

  private static func stripComment(_ line: String) -> String {
    var result = ""
    var inSingleQuote = false
    var inDoubleQuote = false
    var previous: Character?
    for character in line {
      if character == "'", !inDoubleQuote {
        inSingleQuote.toggle()
      } else if character == "\"", !inSingleQuote, previous != "\\" {
        inDoubleQuote.toggle()
      } else if character == "#", !inSingleQuote, !inDoubleQuote {
        break
      }
      result.append(character)
      previous = character
    }
    return result
  }
}

public struct SecretResolver: Sendable {
  public var environment: @Sendable (String) -> String?
  public var kinko: @Sendable (String) throws -> String

  public init(
    environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] },
    kinko: @escaping @Sendable (String) throws -> String = { name in
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["kinko", "get", name, "--reveal", "--force", "--confirm=false"]
      process.standardOutput = pipe
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw InstagramGatewayError.credentialUnavailable("kinko secret '\(name)' is unavailable")
      }
      let value = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !value.isEmpty else {
        throw InstagramGatewayError.credentialUnavailable("kinko secret '\(name)' is empty")
      }
      return value
    }
  ) {
    self.environment = environment
    self.kinko = kinko
  }

  public func resolve(_ reference: SecretReference) throws -> String {
    switch reference {
    case .env(let name):
      guard let value = environment(name), !value.isEmpty else {
        throw InstagramGatewayError.credentialUnavailable("Environment variable '\(name)' is unavailable")
      }
      return value
    case .kinko(let name):
      return try kinko(name)
    case .literal(let value):
      return value
    }
  }
}

public struct SecretRedactor: Sendable {
  private var explicitSecrets: [String]

  public init(secrets: [String] = []) {
    self.explicitSecrets = secrets.filter { !$0.isEmpty }
  }

  public func including(secrets: [String]) -> SecretRedactor {
    SecretRedactor(secrets: explicitSecrets + secrets)
  }

  public func redacting(_ text: String) -> String {
    var output = text
    for secret in explicitSecrets where !secret.isEmpty {
      output = output.replacingOccurrences(of: secret, with: "<redacted>")
    }
    let patterns = [
      #"(?i)(access_token|client_secret|appsecret_proof|code|signed_request)=([^&\s"]+)"#,
      #"(?i)(Authorization:\s*Bearer\s+)([A-Za-z0-9._~+/\-=]+)()"#,
      #"(?i)("access_token"\s*:\s*")([^"]+)(")"#,
      #"(?i)("app_secret"\s*:\s*")([^"]+)(")"#
    ]
    for pattern in patterns {
      output = output.replacingOccurrences(
        of: pattern,
        with: "$1<redacted>$3",
        options: [.regularExpression]
      )
    }
    return output
  }
}

public enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
    else { self = .object(try container.decode([String: JSONValue].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

public struct Paging: Codable, Equatable, Sendable {
  public var before: String?
  public var after: String?
  public var next: String?
  public var previous: String?

  public init(before: String? = nil, after: String? = nil, next: String? = nil, previous: String? = nil) {
    self.before = before
    self.after = after
    self.next = next
    self.previous = previous
  }

  enum CodingKeys: String, CodingKey { case cursors, before, after, next, previous }
  enum CursorKeys: String, CodingKey { case before, after }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    next = try container.decodeIfPresent(String.self, forKey: .next)
    previous = try container.decodeIfPresent(String.self, forKey: .previous)
    if let cursors = try? container.nestedContainer(keyedBy: CursorKeys.self, forKey: .cursors) {
      before = try cursors.decodeIfPresent(String.self, forKey: .before)
      after = try cursors.decodeIfPresent(String.self, forKey: .after)
    } else {
      before = nil
      after = nil
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(next, forKey: .next)
    try container.encodeIfPresent(previous, forKey: .previous)
    if before != nil || after != nil {
      var cursors = container.nestedContainer(keyedBy: CursorKeys.self, forKey: .cursors)
      try cursors.encodeIfPresent(before, forKey: .before)
      try cursors.encodeIfPresent(after, forKey: .after)
    }
  }

  public func redacted(redactor: SecretRedactor = SecretRedactor()) -> Paging {
    Paging(
      before: before,
      after: after,
      next: next.map(redactor.redacting),
      previous: previous.map(redactor.redacting)
    )
  }
}

public struct Page<Element: Codable & Sendable>: Codable, Equatable, Sendable where Element: Equatable {
  public var data: [Element]
  public var paging: Paging?

  public init(data: [Element], paging: Paging? = nil) {
    self.data = data
    self.paging = paging
  }
}

public enum MediaType: Codable, Equatable, Sendable {
  case image
  case video
  case carouselAlbum
  case unknown(String)

  public init(from decoder: Decoder) throws {
    switch try decoder.singleValueContainer().decode(String.self) {
    case "IMAGE": self = .image
    case "VIDEO": self = .video
    case "CAROUSEL_ALBUM": self = .carouselAlbum
    case let value: self = .unknown(value)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .image: try container.encode("IMAGE")
    case .video: try container.encode("VIDEO")
    case .carouselAlbum: try container.encode("CAROUSEL_ALBUM")
    case .unknown(let value): try container.encode(value)
    }
  }
}

public enum MediaProductType: Codable, Equatable, Sendable {
  case feed
  case reels
  case story
  case unknown(String)

  public init(from decoder: Decoder) throws {
    switch try decoder.singleValueContainer().decode(String.self) {
    case "FEED": self = .feed
    case "REELS": self = .reels
    case "STORY": self = .story
    case let value: self = .unknown(value)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .feed: try container.encode("FEED")
    case .reels: try container.encode("REELS")
    case .story: try container.encode("STORY")
    case .unknown(let value): try container.encode(value)
    }
  }
}

public enum ContainerStatusCode: Codable, Equatable, Sendable {
  case inProgress
  case finished
  case error
  case expired
  case unknown(String)

  public init(from decoder: Decoder) throws {
    switch try decoder.singleValueContainer().decode(String.self) {
    case "IN_PROGRESS": self = .inProgress
    case "FINISHED": self = .finished
    case "ERROR": self = .error
    case "EXPIRED": self = .expired
    case let value: self = .unknown(value)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .inProgress: try container.encode("IN_PROGRESS")
    case .finished: try container.encode("FINISHED")
    case .error: try container.encode("ERROR")
    case .expired: try container.encode("EXPIRED")
    case .unknown(let value): try container.encode(value)
    }
  }
}

public enum ModerationAction: String, Codable, Equatable, Sendable {
  case hide
  case unhide
  case delete
}

public enum PublishingMediaType: String, Codable, Equatable, Sendable {
  case image
  /// Standalone video publishing. Meta publishes standalone videos as Reels.
  case video
  case storyImage
  case storyVideo
  case carouselImage
  case carouselVideo
  case carousel
}

public struct CreateMediaContainerInput: Codable, Equatable, Sendable {
  public var accountId: String
  public var mediaType: PublishingMediaType
  public var imageURL: String?
  public var videoURL: String?
  public var caption: String?
  public var children: [String]
  public var providerFields: [String: String]
  public var productTags: [ProductTagInput]
  public var publishingOptions: InstagramPublishingOptions

  public init(
    accountId: String,
    mediaType: PublishingMediaType = .image,
    imageURL: String? = nil,
    videoURL: String? = nil,
    caption: String? = nil,
    children: [String] = [],
    providerFields: [String: String] = [:],
    productTags: [ProductTagInput] = [],
    publishingOptions: InstagramPublishingOptions = InstagramPublishingOptions()
  ) {
    self.accountId = accountId
    self.mediaType = mediaType
    self.imageURL = imageURL
    self.videoURL = videoURL
    self.caption = caption
    self.children = children
    self.providerFields = providerFields
    self.productTags = productTags
    self.publishingOptions = publishingOptions
  }
}

public struct PublishMediaContainerInput: Codable, Equatable, Sendable {
  public var accountId: String
  public var containerId: String

  public init(accountId: String, containerId: String) {
    self.accountId = accountId
    self.containerId = containerId
  }
}

public struct ReplyToCommentInput: Codable, Equatable, Sendable {
  public var accountId: String
  public var commentId: String
  public var message: String

  public init(accountId: String, commentId: String, message: String) {
    self.accountId = accountId
    self.commentId = commentId
    self.message = message
  }
}

public struct ModerateCommentInput: Codable, Equatable, Sendable {
  public var accountId: String
  public var commentId: String
  public var action: ModerationAction

  public init(accountId: String, commentId: String, action: ModerationAction) {
    self.accountId = accountId
    self.commentId = commentId
    self.action = action
  }
}

// MARK: - Discovery extensions

public struct InstagramHashtag: Codable, Equatable, Sendable {
  public var id: String
  public var name: String?
  public init(id: String, name: String? = nil) { self.id = id; self.name = name }
}

public struct InstagramHashtagMediaChild: Codable, Equatable, Sendable {
  public var id: String
  public var mediaType: MediaType?
  public var mediaURL: String?
  public init(id: String, mediaType: MediaType? = nil, mediaURL: String? = nil) {
    self.id = id; self.mediaType = mediaType; self.mediaURL = mediaURL
  }
  enum CodingKeys: String, CodingKey { case id; case mediaType = "media_type"; case mediaURL = "media_url" }
}

public struct InstagramHashtagMedia: Codable, Equatable, Sendable {
  public var id: String
  public var caption: String?
  public var mediaType: MediaType?
  public var mediaProductType: MediaProductType?
  public var mediaURL: String?
  public var permalink: String?
  public var timestamp: String?
  public var children: Page<InstagramHashtagMediaChild>?
  public init(id: String, caption: String? = nil, mediaType: MediaType? = nil, mediaProductType: MediaProductType? = nil, mediaURL: String? = nil, permalink: String? = nil, timestamp: String? = nil, children: Page<InstagramHashtagMediaChild>? = nil) {
    self.id = id; self.caption = caption; self.mediaType = mediaType; self.mediaProductType = mediaProductType; self.mediaURL = mediaURL; self.permalink = permalink; self.timestamp = timestamp; self.children = children
  }
  enum CodingKeys: String, CodingKey { case id, caption, permalink, timestamp, children; case mediaType = "media_type"; case mediaProductType = "media_product_type"; case mediaURL = "media_url" }
}

public enum OEmbedResourceType: Codable, Equatable, Sendable {
  case rich
  case photo
  case video
  case unknown(String)
  public init(from decoder: Decoder) throws { switch try decoder.singleValueContainer().decode(String.self) { case "rich": self = .rich; case "photo": self = .photo; case "video": self = .video; case let value: self = .unknown(value) } }
  public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); switch self { case .rich: try c.encode("rich"); case .photo: try c.encode("photo"); case .video: try c.encode("video"); case .unknown(let v): try c.encode(v) } }
}

public struct InstagramOEmbedRequest: Codable, Equatable, Sendable {
  public var url: String
  public var maxWidth: Int?
  public var hideCaption: Bool?
  public var omitScript: Bool?
  public init(url: String, maxWidth: Int? = nil, hideCaption: Bool? = nil, omitScript: Bool? = nil) { self.url = url; self.maxWidth = maxWidth; self.hideCaption = hideCaption; self.omitScript = omitScript }
  enum CodingKeys: String, CodingKey { case url; case maxWidth = "maxwidth"; case hideCaption = "hidecaption"; case omitScript = "omitscript" }
}

public struct InstagramOEmbed: Codable, Equatable, Sendable {
  public var version: String?
  public var type: OEmbedResourceType?
  public var html: String?
  public var title: String?
  public var authorName: String?
  public var authorURL: String?
  public var providerName: String?
  public var providerURL: String?
  public var thumbnailURL: String?
  public var thumbnailWidth: Int?
  public var thumbnailHeight: Int?
  public var width: Int?
  public var height: Int?
  public var cacheAge: String?
  public init(version: String? = nil, type: OEmbedResourceType? = nil, html: String? = nil, title: String? = nil, authorName: String? = nil, authorURL: String? = nil, providerName: String? = nil, providerURL: String? = nil, thumbnailURL: String? = nil, thumbnailWidth: Int? = nil, thumbnailHeight: Int? = nil, width: Int? = nil, height: Int? = nil, cacheAge: String? = nil) {
    self.version = version; self.type = type; self.html = html; self.title = title; self.authorName = authorName; self.authorURL = authorURL; self.providerName = providerName; self.providerURL = providerURL; self.thumbnailURL = thumbnailURL; self.thumbnailWidth = thumbnailWidth; self.thumbnailHeight = thumbnailHeight; self.width = width; self.height = height; self.cacheAge = cacheAge
  }
  enum CodingKeys: String, CodingKey { case version, type, html, title, width, height; case authorName = "author_name"; case authorURL = "author_url"; case providerName = "provider_name"; case providerURL = "provider_url"; case thumbnailURL = "thumbnail_url"; case thumbnailWidth = "thumbnail_width"; case thumbnailHeight = "thumbnail_height"; case cacheAge = "cache_age" }
}

public enum MentionTarget: Codable, Equatable, Sendable {
  case caption(mediaId: String)
  case comment(mediaId: String, commentId: String)
  enum CodingKeys: String, CodingKey { case kind, mediaId = "media_id", commentId = "comment_id" }
  enum Kind: String, Codable { case caption, comment }
  public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); let kind = try c.decode(Kind.self, forKey: .kind); let mediaId = try c.decode(String.self, forKey: .mediaId); self = kind == .caption ? .caption(mediaId: mediaId) : .comment(mediaId: mediaId, commentId: try c.decode(String.self, forKey: .commentId)) }
  public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); switch self { case .caption(let mediaId): try c.encode(Kind.caption, forKey: .kind); try c.encode(mediaId, forKey: .mediaId); case .comment(let mediaId, let commentId): try c.encode(Kind.comment, forKey: .kind); try c.encode(mediaId, forKey: .mediaId); try c.encode(commentId, forKey: .commentId) } }
}

public struct MentionDiscoveryReference: Codable, Equatable, Sendable {
  public var accountId: String
  public var target: MentionTarget
  public var providerTimestamp: Int?
  public init(accountId: String, target: MentionTarget, providerTimestamp: Int? = nil) { self.accountId = accountId; self.target = target; self.providerTimestamp = providerTimestamp }
  enum CodingKeys: String, CodingKey { case accountId = "account_id", target; case providerTimestamp = "provider_timestamp" }
}
public enum MentionedMediaField: String, Codable, CaseIterable, Equatable, Sendable {
  case id, caption, mediaType = "media_type", mediaURL = "media_url", permalink, timestamp
}

public enum MentionedCommentField: String, Codable, CaseIterable, Equatable, Sendable {
  case id, text, username, timestamp, hidden, likeCount = "like_count", media
}

public struct MentionedMediaLookup: Codable, Equatable, Sendable {
  public var accountId: String
  public var mediaId: String
  public var fields: [MentionedMediaField]
  public var commentFields: [MentionedCommentField]
  public var commentsLimit: Int?
  public var commentsAfter: String?
  public init(accountId: String, mediaId: String, fields: [MentionedMediaField] = MentionedMediaField.allCases, commentFields: [MentionedCommentField] = MentionedCommentField.allCases, commentsLimit: Int? = nil, commentsAfter: String? = nil) {
    self.accountId = accountId; self.mediaId = mediaId; self.fields = fields; self.commentFields = commentFields; self.commentsLimit = commentsLimit; self.commentsAfter = commentsAfter
  }
}

public struct MentionedCommentLookup: Codable, Equatable, Sendable {
  public var accountId: String
  public var commentId: String
  public var fields: [MentionedCommentField]
  public init(accountId: String, commentId: String, fields: [MentionedCommentField] = MentionedCommentField.allCases) { self.accountId = accountId; self.commentId = commentId; self.fields = fields }
}

public struct MentionedMedia: Codable, Equatable, Sendable {
  public var id: String
  public var caption: String?
  public var mediaType: MediaType?
  public var mediaURL: String?
  public var permalink: String?
  public var timestamp: String?
  public var comments: Page<InstagramComment>?
  public init(id: String, caption: String? = nil, mediaType: MediaType? = nil, mediaURL: String? = nil, permalink: String? = nil, timestamp: String? = nil, comments: Page<InstagramComment>? = nil) { self.id = id; self.caption = caption; self.mediaType = mediaType; self.mediaURL = mediaURL; self.permalink = permalink; self.timestamp = timestamp; self.comments = comments }
  enum CodingKeys: String, CodingKey { case id, caption, permalink, timestamp, comments; case mediaType = "media_type"; case mediaURL = "media_url" }
}

public struct MentionedMediaResponse: Codable, Equatable, Sendable {
  public var mentionedMedia: MentionedMedia?
  public init(mentionedMedia: MentionedMedia? = nil) { self.mentionedMedia = mentionedMedia }
  enum CodingKeys: String, CodingKey { case mentionedMedia = "mentioned_media" }
}

public struct MentionedComment: Codable, Equatable, Sendable {
  public var id: String
  public var text: String?
  public var username: String?
  public var timestamp: String?
  public var hidden: Bool?
  public var likeCount: Int?
  public var media: MentionedCommentMedia?
  public init(id: String, text: String? = nil, username: String? = nil, timestamp: String? = nil, hidden: Bool? = nil, likeCount: Int? = nil, media: MentionedCommentMedia? = nil) { self.id = id; self.text = text; self.username = username; self.timestamp = timestamp; self.hidden = hidden; self.likeCount = likeCount; self.media = media }
  enum CodingKeys: String, CodingKey { case id, text, username, timestamp, hidden, media; case likeCount = "like_count" }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id); text = try c.decodeIfPresent(String.self, forKey: .text); username = try c.decodeIfPresent(String.self, forKey: .username); timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp); hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
    likeCount = try decodeOptionalFlexibleInt(c, .likeCount); media = try c.decodeIfPresent(MentionedCommentMedia.self, forKey: .media)
  }
}

public struct MentionedCommentMedia: Codable, Equatable, Sendable {
  public var id: String; public var mediaType: MediaType?; public var mediaURL: String?; public var permalink: String?
  public init(id: String, mediaType: MediaType? = nil, mediaURL: String? = nil, permalink: String? = nil) { self.id = id; self.mediaType = mediaType; self.mediaURL = mediaURL; self.permalink = permalink }
  enum CodingKeys: String, CodingKey { case id, permalink; case mediaType = "media_type"; case mediaURL = "media_url" }
}

public struct MentionedCommentResponse: Codable, Equatable, Sendable {
  public var mentionedComment: MentionedComment?
  public init(mentionedComment: MentionedComment? = nil) { self.mentionedComment = mentionedComment }
  enum CodingKeys: String, CodingKey { case mentionedComment = "mentioned_comment" }
}

public struct ReplyToMentionInput: Codable, Equatable, Sendable {
  public var accountId: String
  public var target: MentionTarget
  public var message: String
  public init(accountId: String, target: MentionTarget, message: String) { self.accountId = accountId; self.target = target; self.message = message }
}

// MARK: - Shopping

public enum ProductReviewStatus: Codable, Equatable, Sendable {
  case noReview, approved, rejected, pending, unknown(String)
  public init(from decoder: Decoder) throws { switch try decoder.singleValueContainer().decode(String.self) { case "", "no_review": self = .noReview; case "approved": self = .approved; case "rejected": self = .rejected; case "pending": self = .pending; case let value: self = .unknown(value) } }
  public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); switch self { case .noReview: try c.encode("no_review"); case .approved: try c.encode("approved"); case .rejected: try c.encode("rejected"); case .pending: try c.encode("pending"); case .unknown(let value): try c.encode(value) } }
}

public struct ShoppingEligibility: Codable, Equatable, Sendable {
  public var eligible: Bool?; public var reason: String?
  public init(eligible: Bool? = nil, reason: String? = nil) { self.eligible = eligible; self.reason = reason }
}
public struct ShoppingCatalog: Codable, Equatable, Sendable {
  public var id: String; public var name: String?
  public init(id: String, name: String? = nil) { self.id = id; self.name = name }
  public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: Keys.self); id = try decodeLosslessID(c, .id); name = try c.decodeIfPresent(String.self, forKey: .name) }
  enum Keys: String, CodingKey { case id, name }
}
public struct ShoppingProductVariant: Codable, Equatable, Sendable { public var id: String; public var name: String?; public init(id: String, name: String? = nil) { self.id = id; self.name = name }; public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: Keys.self); id = try decodeLosslessID(c, .id); name = try c.decodeIfPresent(String.self, forKey: .name) }; enum Keys: String, CodingKey { case id, name } }
public struct ShoppingProduct: Codable, Equatable, Sendable { public var id: String; public var name: String?; public var reviewStatus: ProductReviewStatus?; public var variants: [ShoppingProductVariant]?; public init(id: String, name: String? = nil, reviewStatus: ProductReviewStatus? = nil, variants: [ShoppingProductVariant]? = nil) { self.id = id; self.name = name; self.reviewStatus = reviewStatus; self.variants = variants }; enum CodingKeys: String, CodingKey { case id, name, variants; case reviewStatus = "review_status" }; public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); id = try decodeLosslessID(c, .id); name = try c.decodeIfPresent(String.self, forKey: .name); reviewStatus = try c.decodeIfPresent(ProductReviewStatus.self, forKey: .reviewStatus); variants = try c.decodeIfPresent([ShoppingProductVariant].self, forKey: .variants) } }
public struct ProductTagInput: Codable, Equatable, Sendable { public var productId: String; public var x: Double?; public var y: Double?; public init(productId: String, x: Double? = nil, y: Double? = nil) { self.productId = productId; self.x = x; self.y = y }; enum CodingKeys: String, CodingKey { case productId = "product_id", x, y } }
public struct PublishedProductTag: Codable, Equatable, Sendable { public var productId: String; public var x: Double?; public var y: Double?; public init(productId: String, x: Double? = nil, y: Double? = nil) { self.productId = productId; self.x = x; self.y = y }; enum CodingKeys: String, CodingKey { case productId = "product_id", x, y }; public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); productId = try decodeLosslessID(c, .productId); x = try c.decodeIfPresent(Double.self, forKey: .x); y = try c.decodeIfPresent(Double.self, forKey: .y) } }
public struct ProductAppealStatus: Codable, Equatable, Sendable { public var status: ProductReviewStatus?; public init(status: ProductReviewStatus? = nil) { self.status = status } }
public struct UpdateProductTagsInput: Codable, Equatable, Sendable { public var accountId: String; public var mediaId: String; public var tags: [ProductTagInput]; public init(accountId: String, mediaId: String, tags: [ProductTagInput]) { self.accountId = accountId; self.mediaId = mediaId; self.tags = tags } }
public struct SubmitProductAppealInput: Codable, Equatable, Sendable { public var accountId: String; public var productId: String; public var reason: String; public init(accountId: String, productId: String, reason: String) { self.accountId = accountId; self.productId = productId; self.reason = reason } }
public struct ShoppingMutationResult: Codable, Equatable, Sendable { public var success: Bool; public init(success: Bool) { self.success = success } }

// MARK: - Typed publishing options and resumable video upload

public struct InstagramTagPosition: Codable, Equatable, Sendable { public var x: Double; public var y: Double; public init(x: Double, y: Double) { self.x = x; self.y = y } }
public struct InstagramUserTag: Codable, Equatable, Sendable { public var username: String; public var position: InstagramTagPosition?; public init(username: String, position: InstagramTagPosition? = nil) { self.username = username; self.position = position } }
public struct InstagramVideoCover: Codable, Equatable, Sendable { public var url: String?; public var thumbnailOffsetMilliseconds: Int?; public init(url: String? = nil, thumbnailOffsetMilliseconds: Int? = nil) { self.url = url; self.thumbnailOffsetMilliseconds = thumbnailOffsetMilliseconds } }
public struct InstagramPublishingOptions: Codable, Equatable, Sendable { public var userTags: [InstagramUserTag]; public var collaborators: [String]; public var locationId: String?; public var cover: InstagramVideoCover?; public var altText: String?; public init(userTags: [InstagramUserTag] = [], collaborators: [String] = [], locationId: String? = nil, cover: InstagramVideoCover? = nil, altText: String? = nil) { self.userTags = userTags; self.collaborators = collaborators; self.locationId = locationId; self.cover = cover; self.altText = altText } }
public struct CreateResumableVideoContainerInput: Codable, Equatable, Sendable { public var accountId: String; public var options: InstagramPublishingOptions; public init(accountId: String, options: InstagramPublishingOptions = InstagramPublishingOptions()) { self.accountId = accountId; self.options = options } }
public struct UploadResumableVideoInput: Equatable, Sendable { public var uploadURI: String; public var filePath: String; public var offset: Int64; public init(uploadURI: String, filePath: String, offset: Int64) { self.uploadURI = uploadURI; self.filePath = filePath; self.offset = offset } }
public struct ResumableVideoUploadResult: Codable, Equatable, Sendable { public var success: Bool?; public var message: String?; public init(success: Bool? = nil, message: String? = nil) { self.success = success; self.message = message } }
public struct RuploadDebugInfo: Codable, Equatable, Sendable { public var message: String?; public var code: Int?; public init(message: String? = nil, code: Int? = nil) { self.message = message; self.code = code } }
public struct RuploadErrorPayload: Codable, Equatable, Sendable { public var debugInfo: RuploadDebugInfo?; public init(debugInfo: RuploadDebugInfo? = nil) { self.debugInfo = debugInfo }; enum CodingKeys: String, CodingKey { case debugInfo = "debug_info" } }

// MARK: - Messaging

public struct InstagramConversationParticipant: Codable, Equatable, Sendable { public var id: String; public var username: String?; public init(id: String, username: String? = nil) { self.id = id; self.username = username } }
public struct InstagramConversation: Codable, Equatable, Sendable { public var id: String; public var updatedTime: String?; public var participants: [InstagramConversationParticipant]?; public init(id: String, updatedTime: String? = nil, participants: [InstagramConversationParticipant]? = nil) { self.id = id; self.updatedTime = updatedTime; self.participants = participants }; enum CodingKeys: String, CodingKey { case id, participants; case updatedTime = "updated_time" } }
public struct InstagramMessageAttachment: Codable, Equatable, Sendable { public var type: String?; public var url: String?; public init(type: String? = nil, url: String? = nil) { self.type = type; self.url = url } }
public struct InstagramMessage: Codable, Equatable, Sendable { public var id: String; public var message: String?; public var createdTime: String?; public var from: InstagramConversationParticipant?; public var to: [InstagramConversationParticipant]?; public var attachments: [InstagramMessageAttachment]?; public var isUnsupported: Bool?; public init(id: String, message: String? = nil, createdTime: String? = nil, from: InstagramConversationParticipant? = nil, to: [InstagramConversationParticipant]? = nil, attachments: [InstagramMessageAttachment]? = nil, isUnsupported: Bool? = nil) { self.id = id; self.message = message; self.createdTime = createdTime; self.from = from; self.to = to; self.attachments = attachments; self.isUnsupported = isUnsupported }; enum CodingKeys: String, CodingKey { case id, message, from, to, attachments; case createdTime = "created_time"; case isUnsupported = "is_unsupported" } }
private struct InstagramConversationMessagesEnvelope: Codable, Equatable, Sendable { var messages: Page<InstagramMessage> }
public struct InstagramMessagingUserProfile: Codable, Equatable, Sendable {
  public var id: String; public var name: String?; public var username: String?; public var profilePictureURL: String?; public var followerCount: Int?; public var isVerifiedUser: Bool?; public var isUserFollowingBusiness: Bool?; public var isBusinessFollowingUser: Bool?
  public init(id: String, name: String? = nil, username: String? = nil, profilePictureURL: String? = nil, followerCount: Int? = nil, isVerifiedUser: Bool? = nil, isUserFollowingBusiness: Bool? = nil, isBusinessFollowingUser: Bool? = nil) { self.id = id; self.name = name; self.username = username; self.profilePictureURL = profilePictureURL; self.followerCount = followerCount; self.isVerifiedUser = isVerifiedUser; self.isUserFollowingBusiness = isUserFollowingBusiness; self.isBusinessFollowingUser = isBusinessFollowingUser }
  enum CodingKeys: String, CodingKey { case id, name, username; case profilePictureURL = "profile_pic"; case followerCount = "follower_count"; case isVerifiedUser = "is_verified_user"; case isUserFollowingBusiness = "is_user_follow_business"; case isBusinessFollowingUser = "is_business_follow_user" }
}
public struct ListInstagramConversationsInput: Codable, Equatable, Sendable { public var accountId: String; public var instagramScopedUserId: String?; public var limit: Int?; public var after: String?; public init(accountId: String, instagramScopedUserId: String? = nil, limit: Int? = nil, after: String? = nil) { self.accountId = accountId; self.instagramScopedUserId = instagramScopedUserId; self.limit = limit; self.after = after } }
public struct ListInstagramMessagesInput: Codable, Equatable, Sendable { public var conversationId: String; public var limit: Int?; public var after: String?; public init(conversationId: String, limit: Int? = nil, after: String? = nil) { self.conversationId = conversationId; self.limit = limit; self.after = after } }
public struct GetInstagramMessageInput: Codable, Equatable, Sendable { public var messageId: String; public init(messageId: String) { self.messageId = messageId } }
public struct GetInstagramMessagingProfileInput: Codable, Equatable, Sendable { public var instagramScopedUserId: String; public init(instagramScopedUserId: String) { self.instagramScopedUserId = instagramScopedUserId } }
public enum InstagramTemplateButtonType: String, Codable, Equatable, Sendable { case postback, webURL = "web_url" }
public struct InstagramTemplateButton: Codable, Equatable, Sendable {
  public var type: InstagramTemplateButtonType; public var title: String; public var payload: String?; public var url: String?
  public init(type: InstagramTemplateButtonType, title: String, payload: String? = nil, url: String? = nil) { self.type = type; self.title = title; self.payload = payload; self.url = url }
}
public struct InstagramGenericTemplateElement: Codable, Equatable, Sendable {
  public var title: String; public var subtitle: String?; public var imageURL: String?; public var buttons: [InstagramTemplateButton]
  public init(title: String, subtitle: String? = nil, imageURL: String? = nil, buttons: [InstagramTemplateButton] = []) { self.title = title; self.subtitle = subtitle; self.imageURL = imageURL; self.buttons = buttons }
  enum CodingKeys: String, CodingKey { case title, subtitle, buttons; case imageURL = "image_url" }
}
public enum InstagramMessageTemplate: Codable, Equatable, Sendable {
  case generic([InstagramGenericTemplateElement])
  case button(text: String, buttons: [InstagramTemplateButton])
}
public enum InstagramQuickReplyContentType: String, Codable, Equatable, Sendable { case text; case userPhoneNumber = "user_phone_number"; case userEmail = "user_email" }
public struct InstagramQuickReply: Codable, Equatable, Sendable { public var contentType: InstagramQuickReplyContentType; public var title: String?; public var payload: String?; public init(contentType: InstagramQuickReplyContentType = .text, title: String? = nil, payload: String? = nil) { self.contentType = contentType; self.title = title; self.payload = payload }; enum CodingKeys: String, CodingKey { case contentType = "content_type", title, payload } }
public enum InstagramMessageContent: Codable, Equatable, Sendable {
  case text(String), imageURL(String), audioURL(String), videoURL(String), uploadedImage(attachmentId: String), publishedPost(mediaId: String), heartSticker, quickReplies(text: String, replies: [InstagramQuickReply]), template(InstagramMessageTemplate)
  enum Keys: String, CodingKey { case kind, value }
  enum Kind: String, Codable { case text, imageURL, audioURL, videoURL, uploadedImage, publishedPost, heartSticker, quickReplies, template }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    switch try c.decode(Kind.self, forKey: .kind) {
    case .text: self = .text(try c.decode(String.self, forKey: .value))
    case .imageURL: self = .imageURL(try c.decode(String.self, forKey: .value))
    case .audioURL: self = .audioURL(try c.decode(String.self, forKey: .value))
    case .videoURL: self = .videoURL(try c.decode(String.self, forKey: .value))
    case .uploadedImage: self = .uploadedImage(attachmentId: try c.decode(String.self, forKey: .value))
    case .publishedPost: self = .publishedPost(mediaId: try c.decode(String.self, forKey: .value))
    case .heartSticker: self = .heartSticker
    case .quickReplies:
      let value = try c.decode(QuickReplyValue.self, forKey: .value); self = .quickReplies(text: value.text, replies: value.replies)
    case .template: self = .template(try c.decode(InstagramMessageTemplate.self, forKey: .value))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    switch self {
    case .text(let value): try c.encode(Kind.text, forKey: .kind); try c.encode(value, forKey: .value)
    case .imageURL(let value): try c.encode(Kind.imageURL, forKey: .kind); try c.encode(value, forKey: .value)
    case .audioURL(let value): try c.encode(Kind.audioURL, forKey: .kind); try c.encode(value, forKey: .value)
    case .videoURL(let value): try c.encode(Kind.videoURL, forKey: .kind); try c.encode(value, forKey: .value)
    case .uploadedImage(let attachmentId): try c.encode(Kind.uploadedImage, forKey: .kind); try c.encode(attachmentId, forKey: .value)
    case .publishedPost(let mediaId): try c.encode(Kind.publishedPost, forKey: .kind); try c.encode(mediaId, forKey: .value)
    case .heartSticker: try c.encode(Kind.heartSticker, forKey: .kind)
    case .quickReplies(let text, let replies): try c.encode(Kind.quickReplies, forKey: .kind); try c.encode(QuickReplyValue(text: text, replies: replies), forKey: .value)
    case .template(let value): try c.encode(Kind.template, forKey: .kind); try c.encode(value, forKey: .value)
    }
  }
  private struct QuickReplyValue: Codable, Equatable, Sendable { var text: String; var replies: [InstagramQuickReply] }
}
public typealias InstagramOutboundMessage = InstagramMessageContent
public struct SendInstagramMessageInput: Codable, Equatable, Sendable { public var recipientId: String; public var content: InstagramMessageContent; public var humanAgent: Bool; public init(recipientId: String, content: InstagramMessageContent, humanAgent: Bool = false) { self.recipientId = recipientId; self.content = content; self.humanAgent = humanAgent } }
public struct InstagramSendReceipt: Codable, Equatable, Sendable { public var recipientId: String?; public var messageId: String?; public var flowId: String?; public init(recipientId: String? = nil, messageId: String? = nil, flowId: String? = nil) { self.recipientId = recipientId; self.messageId = messageId; self.flowId = flowId }; enum CodingKeys: String, CodingKey { case recipientId = "recipient_id", messageId = "message_id", flowId = "flow_id" } }
public struct SendInstagramPrivateReplyInput: Codable, Equatable, Sendable { public var accountId: String; public var commentId: String; public var text: String; public init(accountId: String, commentId: String, text: String) { self.accountId = accountId; self.commentId = commentId; self.text = text } }
public typealias PrivateReplyInput = SendInstagramPrivateReplyInput
public enum InstagramSenderAction: String, Codable, Equatable, Sendable { case markSeen = "mark_seen", typingOn = "typing_on", typingOff = "typing_off" }
public enum InstagramReactionAction: String, Codable, Equatable, Sendable { case react, unreact }
public enum InstagramReactionKind: String, Codable, Equatable, Sendable { case love }
public typealias InstagramReaction = InstagramReactionKind
public struct SendReactionInput: Codable, Equatable, Sendable { public var recipientId: String; public var messageId: String; public var action: InstagramReactionAction; public var reaction: InstagramReactionKind; public init(recipientId: String, messageId: String, action: InstagramReactionAction = .react, reaction: InstagramReactionKind = .love) { self.recipientId = recipientId; self.messageId = messageId; self.action = action; self.reaction = reaction } }
public struct ReactToInstagramMessageInput: Codable, Equatable, Sendable { public var accountId: String; public var recipientId: String; public var messageId: String; public var action: InstagramReactionAction; public var reaction: InstagramReactionKind; public init(accountId: String, recipientId: String, messageId: String, action: InstagramReactionAction = .react, reaction: InstagramReactionKind = .love) { self.accountId = accountId; self.recipientId = recipientId; self.messageId = messageId; self.action = action; self.reaction = reaction } }
public struct SendSenderActionInput: Codable, Equatable, Sendable { public var recipientId: String; public var action: InstagramSenderAction; public init(recipientId: String, action: InstagramSenderAction) { self.recipientId = recipientId; self.action = action } }
public struct PerformInstagramSenderActionInput: Codable, Equatable, Sendable { public var accountId: String; public var recipientId: String; public var action: InstagramSenderAction; public init(accountId: String, recipientId: String, action: InstagramSenderAction) { self.accountId = accountId; self.recipientId = recipientId; self.action = action } }
public struct UploadMessageAttachmentInput: Codable, Equatable, Sendable { public var recipientId: String; public var imageURL: String; public var reusable: Bool; public init(recipientId: String, imageURL: String, reusable: Bool = true) { self.recipientId = recipientId; self.imageURL = imageURL; self.reusable = reusable } }
public struct UploadInstagramMessageAttachmentInput: Codable, Equatable, Sendable { public var accountId: String; public var recipientId: String; public var imageURL: String; public var reusable: Bool; public init(accountId: String, recipientId: String, imageURL: String, reusable: Bool = true) { self.accountId = accountId; self.recipientId = recipientId; self.imageURL = imageURL; self.reusable = reusable } }
public struct InstagramAttachmentReceipt: Codable, Equatable, Sendable { public var attachmentId: String?; public init(attachmentId: String? = nil) { self.attachmentId = attachmentId }; enum CodingKeys: String, CodingKey { case attachmentId = "attachment_id" } }
public struct InstagramMutationResult: Codable, Equatable, Sendable { public var success: Bool; public init(success: Bool) { self.success = success } }
public struct InstagramIceBreaker: Codable, Equatable, Sendable { public var question: String; public var payload: String; public init(question: String, payload: String) { self.question = question; self.payload = payload } }
public struct InstagramPersistentMenuItem: Codable, Equatable, Sendable { public var title: String; public var type: InstagramTemplateButtonType; public var payload: String?; public var url: String?; public init(title: String, type: InstagramTemplateButtonType = .postback, payload: String? = nil, url: String? = nil) { self.title = title; self.type = type; self.payload = payload; self.url = url }; public init(title: String, type: String, payload: String? = nil, url: String? = nil) { self.init(title: title, type: InstagramTemplateButtonType(rawValue: type) ?? .postback, payload: payload, url: url) } }
public struct SetInstagramIceBreakersInput: Codable, Equatable, Sendable { public var accountId: String; public var iceBreakers: [InstagramIceBreaker]; public init(accountId: String, iceBreakers: [InstagramIceBreaker]) { self.accountId = accountId; self.iceBreakers = iceBreakers } }
public struct SetInstagramPersistentMenuInput: Codable, Equatable, Sendable { public var accountId: String; public var items: [InstagramPersistentMenuItem]; public init(accountId: String, items: [InstagramPersistentMenuItem]) { self.accountId = accountId; self.items = items } }
public struct InstagramMessagingProfile: Codable, Equatable, Sendable { public var iceBreakers: [InstagramIceBreaker]?; public var persistentMenu: [InstagramPersistentMenuItem]?; public init(iceBreakers: [InstagramIceBreaker]? = nil, persistentMenu: [InstagramPersistentMenuItem]? = nil) { self.iceBreakers = iceBreakers; self.persistentMenu = persistentMenu }; enum CodingKeys: String, CodingKey { case iceBreakers = "ice_breakers"; case persistentMenu = "persistent_menu" } }

public struct FacebookPage: Codable, Equatable, Sendable {
  public var id: String
  public var name: String?
  public var instagramBusinessAccount: InstagramAccount?

  public init(id: String, name: String? = nil, instagramBusinessAccount: InstagramAccount? = nil) {
    self.id = id
    self.name = name
    self.instagramBusinessAccount = instagramBusinessAccount
  }

  enum CodingKeys: String, CodingKey {
    case id, name
    case instagramBusinessAccount = "instagram_business_account"
  }
}

public struct InstagramAccount: Codable, Equatable, Sendable {
  public var id: String
  public var username: String?
  public var name: String?

  public init(id: String, username: String? = nil, name: String? = nil) {
    self.id = id
    self.username = username
    self.name = name
  }
}

public struct BusinessProfile: Codable, Equatable, Sendable {
  public var id: String
  public var username: String?
  public var name: String?
  public var biography: String?
  public var website: String?
  public var followersCount: Int?
  public var mediaCount: Int?

  public init(
    id: String,
    username: String? = nil,
    name: String? = nil,
    biography: String? = nil,
    website: String? = nil,
    followersCount: Int? = nil,
    mediaCount: Int? = nil
  ) {
    self.id = id
    self.username = username
    self.name = name
    self.biography = biography
    self.website = website
    self.followersCount = followersCount
    self.mediaCount = mediaCount
  }

  enum CodingKeys: String, CodingKey {
    case id, username, name, biography, website
    case followersCount = "followers_count"
    case mediaCount = "media_count"
  }
}

public struct BusinessDiscoveryResponse: Codable, Equatable, Sendable {
  public var businessDiscovery: BusinessProfile

  public init(businessDiscovery: BusinessProfile) {
    self.businessDiscovery = businessDiscovery
  }

  enum CodingKeys: String, CodingKey {
    case businessDiscovery = "business_discovery"
  }
}

public struct InstagramMedia: Codable, Equatable, Sendable {
  public var id: String
  public var caption: String?
  public var mediaType: MediaType?
  public var mediaProductType: MediaProductType?
  public var mediaURL: String?
  public var permalink: String?
  public var timestamp: String?
  public var username: String?

  public init(
    id: String,
    caption: String? = nil,
    mediaType: MediaType? = nil,
    mediaProductType: MediaProductType? = nil,
    mediaURL: String? = nil,
    permalink: String? = nil,
    timestamp: String? = nil,
    username: String? = nil
  ) {
    self.id = id
    self.caption = caption
    self.mediaType = mediaType
    self.mediaProductType = mediaProductType
    self.mediaURL = mediaURL
    self.permalink = permalink
    self.timestamp = timestamp
    self.username = username
  }

  enum CodingKeys: String, CodingKey {
    case id, caption, permalink, timestamp, username
    case mediaType = "media_type"
    case mediaProductType = "media_product_type"
    case mediaURL = "media_url"
  }
}

public struct InstagramComment: Codable, Equatable, Sendable {
  public var id: String
  public var text: String?
  public var username: String?
  public var timestamp: String?
  public var hidden: Bool?

  public init(id: String, text: String? = nil, username: String? = nil, timestamp: String? = nil, hidden: Bool? = nil) {
    self.id = id
    self.text = text
    self.username = username
    self.timestamp = timestamp
    self.hidden = hidden
  }
}

public struct InsightMetric: Codable, Equatable, Sendable {
  public var name: String
  public var period: String?
  public var title: String?
  public var description: String?
  public var values: [InsightValue]

  public init(name: String, period: String? = nil, title: String? = nil, description: String? = nil, values: [InsightValue]) {
    self.name = name
    self.period = period
    self.title = title
    self.description = description
    self.values = values
  }
}

public struct InsightValue: Codable, Equatable, Sendable {
  public var value: JSONValue
  public var endTime: String?

  public init(value: JSONValue, endTime: String? = nil) {
    self.value = value
    self.endTime = endTime
  }

  enum CodingKeys: String, CodingKey {
    case value
    case endTime = "end_time"
  }
}

public struct InsightsResponse: Codable, Equatable, Sendable {
  public var data: [InsightMetric]

  public init(data: [InsightMetric]) {
    self.data = data
  }
}

public struct MediaContainer: Codable, Equatable, Sendable {
  public var id: String

  public init(id: String) {
    self.id = id
  }
}

public struct MediaContainerStatus: Codable, Equatable, Sendable {
  public var id: String?
  public var statusCode: ContainerStatusCode?
  public var status: String?
  public var videoStatus: VideoUploadStatus?

  public init(id: String? = nil, statusCode: ContainerStatusCode? = nil, status: String? = nil, videoStatus: VideoUploadStatus? = nil) {
    self.id = id
    self.statusCode = statusCode
    self.status = status
    self.videoStatus = videoStatus
  }

  enum CodingKeys: String, CodingKey {
    case id, status
    case statusCode = "status_code"
    case videoStatus = "video_status"
  }
}

public struct VideoUploadStatus: Codable, Equatable, Sendable {
  public var uploadingPhase: VideoUploadingPhase?
  public init(uploadingPhase: VideoUploadingPhase? = nil) { self.uploadingPhase = uploadingPhase }
  enum CodingKeys: String, CodingKey { case uploadingPhase = "uploading_phase" }
}

public struct VideoUploadingPhase: Codable, Equatable, Sendable {
  public var bytesTransferred: Int64?
  public init(bytesTransferred: Int64? = nil) { self.bytesTransferred = bytesTransferred }
  enum CodingKeys: String, CodingKey { case bytesTransferred = "bytes_transferred" }
}

public struct PublishedMedia: Codable, Equatable, Sendable {
  public var id: String

  public init(id: String) {
    self.id = id
  }
}

public struct ContentPublishingLimit: Codable, Equatable, Sendable {
  public struct QuotaUsage: Codable, Equatable, Sendable {
    public var quotaUsage: Int?

    public init(quotaUsage: Int? = nil) {
      self.quotaUsage = quotaUsage
    }

    enum CodingKeys: String, CodingKey {
      case quotaUsage = "quota_usage"
    }
  }

  public var data: [QuotaUsage]

  public init(data: [QuotaUsage]) {
    self.data = data
  }
}

public struct CommentReply: Codable, Equatable, Sendable {
  public var id: String

  public init(id: String) {
    self.id = id
  }
}

public struct ModerationResult: Codable, Equatable, Sendable {
  public var success: Bool

  public init(success: Bool) {
    self.success = success
  }
}

public struct HTTPFileBody: Equatable, Sendable {
  public var filePath: String
  public var offset: Int64

  public init(filePath: String, offset: Int64 = 0) {
    self.filePath = filePath
    self.offset = offset
  }
}

public struct HTTPRequest: Sendable {
  public var method: HTTPMethod
  public var path: String
  public var query: [(String, String)]
  public var headers: [String: String]
  public var body: Data?
  /// A file slice is streamed by the URLSession transport. It is intentionally
  /// separate from `body` to preserve existing request construction callers.
  public var fileBody: HTTPFileBody?

  public init(method: HTTPMethod, path: String, query: [(String, String)] = [], headers: [String: String] = [:], body: Data? = nil, fileBody: HTTPFileBody? = nil) {
    self.method = method
    self.path = path
    self.query = query
    self.headers = headers
    self.body = body
    self.fileBody = fileBody
  }

  public func url(baseURL: URL) throws -> URL {
    if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
    let full = baseURL.appendingPathComponent(path)
    guard var components = URLComponents(url: full, resolvingAgainstBaseURL: false) else {
      throw InstagramGatewayError.configurationInvalid("Invalid base URL")
    }
    components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
    guard let url = components.url else {
      throw InstagramGatewayError.configurationInvalid("Invalid request URL")
    }
    return url
  }

  public func redactedDescription(redactor: SecretRedactor = SecretRedactor()) -> String {
    redactor.redacting("\(method.rawValue) \(path)?\(query.map { "\($0.0)=\($0.1)" }.joined(separator: "&")) headers=\(headers)")
  }
}

public struct HTTPResponse: Equatable, Sendable {
  public var statusCode: Int
  public var headers: [String: String]
  public var body: Data

  public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }
}

public protocol HTTPTransport: Sendable {
  func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // OAuth authorization must never be replayed to a redirect destination.
    completionHandler(URLSessionHTTPTransport.redirectRequest(request))
  }
}

public struct URLSessionHTTPTransport: HTTPTransport {
  /// An injectable execution boundary. Production uses URLSession with a
  /// redirect-denying delegate; deterministic tests can inspect the exact
  /// streamed request without installing a URLProtocol on unsupported targets.
  public typealias SessionExecutor = @Sendable (_ request: URLRequest, _ redirectDelegate: RedirectBlockingDelegate) async throws -> (Data, HTTPURLResponse)
  public var baseURL: URL
  public var requestObserver: (@Sendable (URLRequest) -> Void)?
  private let sessionExecutor: SessionExecutor?

  public init(baseURL: URL = URL(string: "https://graph.facebook.com/\(metaGraphAPIVersion)")!, requestObserver: (@Sendable (URLRequest) -> Void)? = nil, sessionExecutor: SessionExecutor? = nil) {
    self.baseURL = baseURL
    self.requestObserver = requestObserver
    self.sessionExecutor = sessionExecutor
  }

  public static func baseURL(loginType: InstagramLoginType) throws -> URL {
    let host: String
    switch loginType {
    case .facebook: host = "graph.facebook.com"
    case .instagram: host = "graph.instagram.com"
    case .unknown: throw InstagramGatewayError.configurationInvalid("Unsupported Instagram login type")
    }
    guard let url = URL(string: "https://\(host)/\(metaGraphAPIVersion)") else {
      throw InstagramGatewayError.configurationInvalid("Invalid Graph base URL")
    }
    return url
  }

  public static func redirectRequest(_ request: URLRequest) -> URLRequest? { nil }

  public static func streamedRequest(url: URL, method: HTTPMethod, headers: [String: String], fileBody: HTTPFileBody) throws -> URLRequest {
    guard fileBody.offset >= 0 else { throw InstagramGatewayError.configurationInvalid("Invalid streamed request body") }
    let attributes = try FileManager.default.attributesOfItem(atPath: fileBody.filePath)
    guard let byteCount = attributes[.size] as? NSNumber, fileBody.offset <= byteCount.int64Value, let stream = InputStream(fileAtPath: fileBody.filePath) else { throw InstagramGatewayError.configurationInvalid("Streamed body offset exceeds file size") }
    var request = URLRequest(url: url); request.httpMethod = method.rawValue
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    stream.setProperty(NSNumber(value: fileBody.offset), forKey: .fileCurrentOffsetKey)
    request.httpBodyStream = stream
    if request.value(forHTTPHeaderField: "Content-Length") == nil { request.setValue(String(byteCount.int64Value - fileBody.offset), forHTTPHeaderField: "Content-Length") }
    return request
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    let url = try request.url(baseURL: baseURL)
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method.rawValue
    for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
    urlRequest.httpBody = request.body
    if let fileBody = request.fileBody { guard request.body == nil else { throw InstagramGatewayError.configurationInvalid("Invalid streamed request body") }; urlRequest = try Self.streamedRequest(url: url, method: request.method, headers: request.headers, fileBody: fileBody) }
    requestObserver?(urlRequest)
    let data: Data
    let http: HTTPURLResponse
    let redirectDelegate = RedirectBlockingDelegate()
    if let sessionExecutor {
      (data, http) = try await sessionExecutor(urlRequest, redirectDelegate)
    } else {
      let session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
      defer { session.invalidateAndCancel() }
      let response: URLResponse
      (data, response) = try await session.data(for: urlRequest)
      guard let resolvedHTTP = response as? HTTPURLResponse else {
        throw InstagramGatewayError.transportFailed("Response was not HTTP")
      }
      http = resolvedHTTP
    }
    return HTTPResponse(statusCode: http.statusCode, headers: http.allHeaderFields.reduce(into: [:]) { result, pair in
      if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
    }, body: data)
  }
}

public actor RecordingHTTPTransport: HTTPTransport {
  public private(set) var requests: [HTTPRequest] = []
  private var responses: [HTTPResponse]

  public init(responses: [HTTPResponse] = []) {
    self.responses = responses
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requests.append(request)
    if responses.isEmpty {
      return HTTPResponse(statusCode: 200, body: Data(#"{"id":"ok"}"#.utf8))
    }
    return responses.removeFirst()
  }
}

public struct MetaAPIErrorPayload: Codable, Equatable, Sendable {
  public var error: MetaAPIErrorDetail
}

public struct MetaAPIErrorDetail: Codable, Equatable, Sendable {
  public var message: String
  public var type: String?
  public var code: Int?
  public var errorSubcode: Int?
  public var fbtraceId: String?

  enum CodingKeys: String, CodingKey {
    case message, type, code
    case errorSubcode = "error_subcode"
    case fbtraceId = "fbtrace_id"
  }
}

public enum InstagramGatewayError: Error, Equatable, Sendable {
  case configurationInvalid(String)
  case credentialUnavailable(String)
  case authenticationRequired(String)
  case permissionDenied(String)
  case notFound(String)
  case rateLimited(String)
  case providerRejected(status: Int, MetaAPIErrorDetail?)
  case providerUnavailable(String)
  case decodingFailed(String)
  case transportFailed(String)
  case unsupportedOperation(String)
  case confirmationRequired(String)

  public var code: String {
    switch self {
    case .configurationInvalid: "CONFIGURATION_INVALID"
    case .credentialUnavailable: "CREDENTIAL_UNAVAILABLE"
    case .authenticationRequired: "AUTHENTICATION_REQUIRED"
    case .permissionDenied: "PERMISSION_DENIED"
    case .notFound: "NOT_FOUND"
    case .rateLimited: "RATE_LIMITED"
    case .providerRejected: "PROVIDER_REJECTED"
    case .providerUnavailable: "PROVIDER_UNAVAILABLE"
    case .decodingFailed: "DECODING_FAILED"
    case .transportFailed: "TRANSPORT_FAILED"
    case .unsupportedOperation: "UNSUPPORTED_OPERATION"
    case .confirmationRequired: "CONFIRMATION_REQUIRED"
    }
  }

  public var message: String {
    switch self {
    case .configurationInvalid(let value), .credentialUnavailable(let value), .authenticationRequired(let value),
        .permissionDenied(let value), .notFound(let value), .rateLimited(let value), .providerUnavailable(let value),
        .decodingFailed(let value), .transportFailed(let value), .unsupportedOperation(let value), .confirmationRequired(let value):
      value
    case .providerRejected(_, let detail):
      detail?.message ?? "Provider rejected the request"
    }
  }

  public var exitStatus: Int32 {
    switch self {
    case .configurationInvalid, .credentialUnavailable: 3
    case .authenticationRequired, .permissionDenied, .confirmationRequired: 4
    default: 5
    }
  }
}

public struct ErrorEnvelope: Codable, Equatable, Sendable {
  public var ok: Bool = false
  public var error: ErrorBody

  public init(error: InstagramGatewayError, redactor: SecretRedactor = SecretRedactor()) {
    self.error = ErrorBody(code: error.code, message: redactor.redacting(error.message))
  }
}

public struct ErrorBody: Codable, Equatable, Sendable {
  public var code: String
  public var message: String
}

public struct SuccessEnvelope<T: Codable & Sendable>: Codable, Sendable {
  public var ok: Bool = true
  public var data: T
  public var paging: Paging?

  public init(data: T, paging: Paging? = nil) {
    self.data = data
    self.paging = paging?.redacted()
  }
}

public struct DiagnosticRecord: Codable, Equatable, Sendable {
  public var ok: Bool
  public var binary: BinaryKind
  public var configPath: String?
  public var credentials: [CredentialDiagnostic]
  public var checks: [DiagnosticCheck]

  public init(
    ok: Bool,
    binary: BinaryKind,
    configPath: String? = nil,
    credentials: [CredentialDiagnostic],
    checks: [DiagnosticCheck]
  ) {
    self.ok = ok
    self.binary = binary
    self.configPath = configPath
    self.credentials = credentials
    self.checks = checks
  }
}

public struct CredentialDiagnostic: Codable, Equatable, Sendable {
  public var id: String
  public var accessMode: AccessMode
  public var compatible: Bool
  public var appIdRef: String?
  public var appSecretRef: String?
  public var accessTokenRef: String
  public var instagramUserIdPresent: Bool
  public var pageIdPresent: Bool
  public var scopes: [String]

  public init(
    id: String,
    accessMode: AccessMode,
    compatible: Bool,
    appIdRef: String? = nil,
    appSecretRef: String? = nil,
    accessTokenRef: String,
    instagramUserIdPresent: Bool,
    pageIdPresent: Bool,
    scopes: [String]
  ) {
    self.id = id
    self.accessMode = accessMode
    self.compatible = compatible
    self.appIdRef = appIdRef
    self.appSecretRef = appSecretRef
    self.accessTokenRef = accessTokenRef
    self.instagramUserIdPresent = instagramUserIdPresent
    self.pageIdPresent = pageIdPresent
    self.scopes = scopes
  }
}

public struct DiagnosticCheck: Codable, Equatable, Sendable {
  public var name: String
  public var status: String
  public var message: String

  public init(name: String, status: String, message: String) {
    self.name = name
    self.status = status
    self.message = message
  }
}

// MARK: - Webhooks

public struct InstagramWebhookActor: Codable, Equatable, Sendable {
  public var id: String?
  public init(id: String? = nil) { self.id = id }
}

public struct InstagramWebhookAttachment: Codable, Equatable, Sendable {
  public var type: String?
  public var payload: JSONValue?
  public init(type: String? = nil, payload: JSONValue? = nil) { self.type = type; self.payload = payload }
}

public struct InstagramWebhookMessageEvent: Codable, Equatable, Sendable {
  public var mid: String?
  public var text: String?
  public var attachments: [InstagramWebhookAttachment]?
  public var quickReply: JSONValue?
  public var isEcho: Bool?
  public init(mid: String? = nil, text: String? = nil, attachments: [InstagramWebhookAttachment]? = nil, quickReply: JSONValue? = nil, isEcho: Bool? = nil) {
    self.mid = mid; self.text = text; self.attachments = attachments; self.quickReply = quickReply; self.isEcho = isEcho
  }
  enum CodingKeys: String, CodingKey { case mid, text, attachments; case quickReply = "quick_reply"; case isEcho = "is_echo" }
}

public struct InstagramWebhookReactionEvent: Codable, Equatable, Sendable {
  public var mid: String?
  public var action: String?
  public var reaction: String?
  public init(mid: String? = nil, action: String? = nil, reaction: String? = nil) { self.mid = mid; self.action = action; self.reaction = reaction }
}

public struct InstagramWebhookPostbackEvent: Codable, Equatable, Sendable {
  public var title: String?
  public var payload: String?
  public var referral: JSONValue?
  public init(title: String? = nil, payload: String? = nil, referral: JSONValue? = nil) { self.title = title; self.payload = payload; self.referral = referral }
}

public struct InstagramWebhookMediaEvent: Codable, Equatable, Sendable { public var id: String?; public var mediaType: MediaType?; public var verb: String?; public init(id: String? = nil, mediaType: MediaType? = nil, verb: String? = nil) { self.id = id; self.mediaType = mediaType; self.verb = verb }; enum CodingKeys: String, CodingKey { case id, verb; case mediaType = "media_type" } }
public struct InstagramWebhookCommentEvent: Codable, Equatable, Sendable { public var id: String?; public var text: String?; public var mediaId: String?; public var parentId: String?; public init(id: String? = nil, text: String? = nil, mediaId: String? = nil, parentId: String? = nil) { self.id = id; self.text = text; self.mediaId = mediaId; self.parentId = parentId }; enum CodingKeys: String, CodingKey { case id, text; case mediaId = "media_id"; case parentId = "parent_id" } }
public struct InstagramWebhookMentionEvent: Codable, Equatable, Sendable { public var mediaId: String?; public var commentId: String?; public init(mediaId: String? = nil, commentId: String? = nil) { self.mediaId = mediaId; self.commentId = commentId }; enum CodingKeys: String, CodingKey { case mediaId = "media_id"; case commentId = "comment_id" } }
public struct InstagramWebhookStoryInsightEvent: Codable, Equatable, Sendable { public var name: String?; public var value: JSONValue?; public init(name: String? = nil, value: JSONValue? = nil) { self.name = name; self.value = value } }
public struct InstagramWebhookReferralEvent: Codable, Equatable, Sendable { public var ref: String?; public var source: String?; public init(ref: String? = nil, source: String? = nil) { self.ref = ref; self.source = source } }
public struct InstagramWebhookThreadControlEvent: Codable, Equatable, Sendable { public var metadata: String?; public var newOwnerAppId: String?; public init(metadata: String? = nil, newOwnerAppId: String? = nil) { self.metadata = metadata; self.newOwnerAppId = newOwnerAppId }; enum CodingKeys: String, CodingKey { case metadata; case newOwnerAppId = "new_owner_app_id" } }
public struct InstagramWebhookMessageEditEvent: Codable, Equatable, Sendable { public var mid: String?; public var text: String?; public init(mid: String? = nil, text: String? = nil) { self.mid = mid; self.text = text } }

public struct InstagramWebhookMessagingEvent: Codable, Equatable, Sendable {
  public var sender: InstagramWebhookActor?
  public var recipient: InstagramWebhookActor?
  public var timestamp: Int?
  public var message: InstagramWebhookMessageEvent?
  public var reaction: InstagramWebhookReactionEvent?
  public var postback: InstagramWebhookPostbackEvent?
  public var referral: InstagramWebhookReferralEvent?
  public var passThreadControl: InstagramWebhookThreadControlEvent?
  public var takeThreadControl: InstagramWebhookThreadControlEvent?
  public var messageEdit: InstagramWebhookMessageEditEvent?
  public init(sender: InstagramWebhookActor? = nil, recipient: InstagramWebhookActor? = nil, timestamp: Int? = nil, message: InstagramWebhookMessageEvent? = nil, reaction: InstagramWebhookReactionEvent? = nil, postback: InstagramWebhookPostbackEvent? = nil, referral: InstagramWebhookReferralEvent? = nil, passThreadControl: InstagramWebhookThreadControlEvent? = nil, takeThreadControl: InstagramWebhookThreadControlEvent? = nil, messageEdit: InstagramWebhookMessageEditEvent? = nil) {
    self.sender = sender; self.recipient = recipient; self.timestamp = timestamp; self.message = message; self.reaction = reaction; self.postback = postback; self.referral = referral; self.passThreadControl = passThreadControl; self.takeThreadControl = takeThreadControl; self.messageEdit = messageEdit
  }
  enum CodingKeys: String, CodingKey {
    case sender, recipient, timestamp, message, reaction, postback, referral
    case passThreadControl = "pass_thread_control"
    case takeThreadControl = "take_thread_control"
    case messageEdit = "message_edit"
  }
}

public struct InstagramWebhookChange: Codable, Equatable, Sendable {
  public var field: String
  public var value: JSONValue?
  public init(field: String, value: JSONValue? = nil) { self.field = field; self.value = value }
}

public struct InstagramWebhookEntry: Codable, Equatable, Sendable {
  public var id: String?
  public var providerTimestamp: Int?
  public var changes: [InstagramWebhookChange]
  public var messaging: [InstagramWebhookMessagingEvent]
  public var standby: [InstagramWebhookMessagingEvent]
  public var media: [InstagramWebhookMediaEvent]
  public var comments: [InstagramWebhookCommentEvent]
  public var mentions: [InstagramWebhookMentionEvent]
  public var storyInsights: [InstagramWebhookStoryInsightEvent]
  public var additionalFields: [String: JSONValue]
  public init(id: String? = nil, providerTimestamp: Int? = nil, changes: [InstagramWebhookChange] = [], messaging: [InstagramWebhookMessagingEvent] = [], standby: [InstagramWebhookMessagingEvent] = [], media: [InstagramWebhookMediaEvent] = [], comments: [InstagramWebhookCommentEvent] = [], mentions: [InstagramWebhookMentionEvent] = [], storyInsights: [InstagramWebhookStoryInsightEvent] = [], additionalFields: [String: JSONValue] = [:]) { self.id = id; self.providerTimestamp = providerTimestamp; self.changes = changes; self.messaging = messaging; self.standby = standby; self.media = media; self.comments = comments; self.mentions = mentions; self.storyInsights = storyInsights; self.additionalFields = additionalFields }
  enum CodingKeys: String, CodingKey, CaseIterable { case id, time, changes, field, value, messaging, standby, media, comments, mentions, unknown; case storyInsights = "story_insights" }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(String.self, forKey: .id)
    providerTimestamp = try c.decodeIfPresent(Int.self, forKey: .time)
    if let changes = try c.decodeIfPresent([InstagramWebhookChange].self, forKey: .changes) { self.changes = changes }
    else if let field = try c.decodeIfPresent(String.self, forKey: .field) { self.changes = [InstagramWebhookChange(field: field, value: try c.decodeIfPresent(JSONValue.self, forKey: .value))] }
    else { self.changes = [] }
    messaging = try c.decodeIfPresent([InstagramWebhookMessagingEvent].self, forKey: .messaging) ?? []
    standby = try c.decodeIfPresent([InstagramWebhookMessagingEvent].self, forKey: .standby) ?? []
    media = try c.decodeIfPresent([InstagramWebhookMediaEvent].self, forKey: .media) ?? []
    comments = try c.decodeIfPresent([InstagramWebhookCommentEvent].self, forKey: .comments) ?? []
    mentions = try c.decodeIfPresent([InstagramWebhookMentionEvent].self, forKey: .mentions) ?? []
    storyInsights = try c.decodeIfPresent([InstagramWebhookStoryInsightEvent].self, forKey: .storyInsights) ?? []
    let raw = try decoder.container(keyedBy: AnyCodingKey.self)
    let known = Set(CodingKeys.allCases.map(\.stringValue))
    additionalFields = Dictionary(uniqueKeysWithValues: try raw.allKeys.filter { !known.contains($0.stringValue) }.map { ($0.stringValue, try raw.decode(JSONValue.self, forKey: $0)) })
  }
  public func encode(to encoder: Encoder) throws { var c = encoder.container(keyedBy: CodingKeys.self); try c.encodeIfPresent(id, forKey: .id); try c.encodeIfPresent(providerTimestamp, forKey: .time); try c.encode(changes, forKey: .changes); try c.encode(messaging, forKey: .messaging); try c.encode(standby, forKey: .standby); try c.encode(media, forKey: .media); try c.encode(comments, forKey: .comments); try c.encode(mentions, forKey: .mentions); try c.encode(storyInsights, forKey: .storyInsights); var raw = encoder.container(keyedBy: AnyCodingKey.self); for (key, value) in additionalFields { try raw.encode(value, forKey: AnyCodingKey(key)) } }
}

public struct InstagramWebhookPayload: Codable, Equatable, Sendable {
  public var object: String?
  public var entries: [InstagramWebhookEntry]
  public init(object: String? = nil, entries: [InstagramWebhookEntry] = []) { self.object = object; self.entries = entries }
  enum CodingKeys: String, CodingKey { case object; case entries = "entry" }
}
public enum InstagramWebhookField: Codable, Equatable, Sendable { case comments, mentions, messages, messagingPostbacks, storyInsights, unknown(String); public init(from decoder: Decoder) throws { switch try decoder.singleValueContainer().decode(String.self) { case "comments": self = .comments; case "mentions": self = .mentions; case "messages": self = .messages; case "messaging_postbacks": self = .messagingPostbacks; case let value: self = .unknown(value) } }; public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); switch self { case .comments: try c.encode("comments"); case .mentions: try c.encode("mentions"); case .messages: try c.encode("messages"); case .messagingPostbacks: try c.encode("messaging_postbacks"); case .storyInsights: try c.encode("story_insights"); case .unknown(let v): try c.encode(v) } } }
public struct WebhookSubscription: Codable, Equatable, Sendable { public var id: String?; public var subscribedFields: [InstagramWebhookField]; public init(id: String? = nil, subscribedFields: [InstagramWebhookField] = []) { self.id = id; self.subscribedFields = subscribedFields }; enum CodingKeys: String, CodingKey { case id; case subscribedFields = "subscribed_fields" } }
public struct WebhookSubscriptionMutationResult: Codable, Equatable, Sendable { public var success: Bool; public init(success: Bool) { self.success = success } }

public struct InstagramWebhookSignatureVerifier: Sendable {
  public var maximumBodyBytes: Int
  public init(maximumBodyBytes: Int = 1_048_576) { self.maximumBodyBytes = maximumBodyBytes }
  public func verify(body: Data, signatureHeader: String?, appSecret: String) throws {
    guard body.count <= maximumBodyBytes else { throw InstagramGatewayError.configurationInvalid("Webhook payload exceeds maximum size") }
    guard let signatureHeader, signatureHeader.hasPrefix("sha256=") else { throw InstagramGatewayError.authenticationRequired("Missing or malformed webhook signature") }
    let hex = String(signatureHeader.dropFirst("sha256=".count))
    guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }), let actual = Data(hexString: hex) else { throw InstagramGatewayError.authenticationRequired("Missing or malformed webhook signature") }
    let expected = Data(HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(appSecret.utf8))))
    guard fixedWorkEqual(expected, actual) else { throw InstagramGatewayError.authenticationRequired("Webhook signature mismatch") }
  }
}

public struct InstagramWebhookDecoder: Sendable {
  public var verifier: InstagramWebhookSignatureVerifier
  public init(verifier: InstagramWebhookSignatureVerifier = InstagramWebhookSignatureVerifier()) { self.verifier = verifier }
  public func verifyAndDecode(body: Data, signatureHeader: String?, appSecret: String) throws -> InstagramWebhookPayload {
    try verifier.verify(body: body, signatureHeader: signatureHeader, appSecret: appSecret)
    do { return try JSONDecoder().decode(InstagramWebhookPayload.self, from: body) }
    catch { throw InstagramGatewayError.decodingFailed("Webhook payload could not be decoded") }
  }
}

public struct InstagramWebhookChallengeValidator: Sendable {
  public init() {}
  public func challenge(mode: String?, verifyToken: String?, expectedVerifyToken: String, challenge: String?) throws -> String {
    guard mode == "subscribe", let verifyToken, let challenge, fixedWorkEqual(Data(verifyToken.utf8), Data(expectedVerifyToken.utf8)) else { throw InstagramGatewayError.authenticationRequired("Webhook challenge verification failed") }
    return challenge
  }
}

public struct InstagramWebhookSubscriptionService: Sendable {
  public var client: InstagramGatewayClient
  public var loginType: InstagramLoginType
  public init(client: InstagramGatewayClient, loginType: InstagramLoginType) { self.client = client; self.loginType = loginType }
  private func validate(_ accountId: String) throws { try requireProviderIdentifier(accountId, name: "account id"); guard loginType == .instagram else { throw InstagramGatewayError.unsupportedOperation("Webhook subscriptions require Instagram Login") } }
  public func list(accountId: String) async throws -> Page<WebhookSubscription> { try validate(accountId); return try await client.request(HTTPRequest(method: .get, path: "\(accountId)/subscribed_apps"), as: Page<WebhookSubscription>.self) }
  public func subscribe(accountId: String, fields: [InstagramWebhookField]) async throws -> WebhookSubscriptionMutationResult { try validate(accountId); guard !fields.isEmpty, !fields.contains(where: { if case .unknown = $0 { return true }; return false }) else { throw InstagramGatewayError.configurationInvalid("Webhook fields must be known and non-empty") }; let raw = try fields.map { field -> String in let d = try JSONEncoder().encode(field); return String(data: d, encoding: .utf8)!.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }.sorted().joined(separator: ","); return try await client.request(HTTPRequest(method: .post, path: "\(accountId)/subscribed_apps", query: [("subscribed_fields", raw)]), as: WebhookSubscriptionMutationResult.self) }
  public func delete(accountId: String) async throws -> WebhookSubscriptionMutationResult { try validate(accountId); return try await client.request(HTTPRequest(method: .delete, path: "\(accountId)/subscribed_apps"), as: WebhookSubscriptionMutationResult.self) }
}

private func fixedWorkEqual(_ left: Data, _ right: Data) -> Bool {
  guard left.count == right.count else { return false }
  var difference: UInt8 = 0
  for index in left.indices { difference |= left[index] ^ right[index] }
  return difference == 0
}

private extension Data {
  init?(hexString: String) {
    var bytes: [UInt8] = []
    var index = hexString.startIndex
    while index < hexString.endIndex {
      let next = hexString.index(index, offsetBy: 2)
      guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
      bytes.append(byte); index = next
    }
    self.init(bytes)
  }
}

public struct InstagramGatewayClient: Sendable {
  public var transport: any HTTPTransport
  public var token: String
  public var redactor: SecretRedactor
  public var decoder: JSONDecoder

  public init(transport: any HTTPTransport, token: String, redactor: SecretRedactor = SecretRedactor()) {
    self.transport = transport
    self.token = token
    self.redactor = redactor.including(secrets: [token])
    self.decoder = JSONDecoder()
  }

  public func request<T: Decodable & Sendable>(_ request: HTTPRequest, as type: T.Type) async throws -> T {
    var request = request
    if request.headers["Authorization"] == nil { request.headers["Authorization"] = "Bearer \(token)" }
    let response: HTTPResponse
    do {
      response = try await transport.send(request)
    } catch {
      throw InstagramGatewayError.transportFailed(redactor.redacting(error.localizedDescription))
    }
    guard (200..<300).contains(response.statusCode) else {
      let metaDetail = (try? decoder.decode(MetaAPIErrorPayload.self, from: response.body).error).map { detail in
        MetaAPIErrorDetail(
          message: redactor.redacting(detail.message),
          type: detail.type,
          code: detail.code,
          errorSubcode: detail.errorSubcode,
          fbtraceId: detail.fbtraceId
        )
      }
      let ruploadDetail = (try? decoder.decode(RuploadErrorPayload.self, from: response.body).debugInfo).map { info in
        MetaAPIErrorDetail(message: redactor.redacting(info.message ?? "Resumable upload failed"), type: "rupload", code: info.code)
      }
      let detail = metaDetail ?? ruploadDetail
      throw mapProviderError(status: response.statusCode, detail: detail)
    }
    do {
      return try decoder.decode(T.self, from: response.body)
    } catch {
      throw InstagramGatewayError.decodingFailed(redactor.redacting(error.localizedDescription))
    }
  }

  private func mapProviderError(status: Int, detail: MetaAPIErrorDetail?) -> InstagramGatewayError {
    if status == 401 { return .authenticationRequired(detail?.message ?? "Authentication required") }
    if status == 403 { return .permissionDenied(detail?.message ?? "Permission denied") }
    if status == 404 { return .notFound(detail?.message ?? "Not found") }
    if status == 429 { return .rateLimited(detail?.message ?? "Rate limited") }
    if status >= 500 { return .providerUnavailable(detail?.message ?? "Provider unavailable") }
    return .providerRejected(status: status, detail)
  }
}

public struct InstagramReaderService: Sendable {
  public var client: InstagramGatewayClient
  public var messagingAuthorization: InstagramMessagingAuthorization?

  public init(client: InstagramGatewayClient, messagingAuthorization: InstagramMessagingAuthorization? = nil) {
    self.client = client
    self.messagingAuthorization = messagingAuthorization
  }

  public func facebookPages(limit: Int? = nil, after: String? = nil) async throws -> Page<FacebookPage> {
    try await client.request(HTTPRequest(method: .get, path: "me/accounts", query: listQuery(fields: "id,name,instagram_business_account", limit: limit, after: after)), as: Page<FacebookPage>.self)
  }

  public func account(id: String) async throws -> BusinessProfile {
    try await client.request(HTTPRequest(method: .get, path: id, query: [("fields", "id,username,name,biography,website,followers_count,media_count")]), as: BusinessProfile.self)
  }

  public func businessDiscovery(accountId: String, username: String) async throws -> BusinessProfile {
    let fields = "business_discovery.username(\(username)){id,username,name,biography,website,followers_count,media_count}"
    let response = try await client.request(HTTPRequest(method: .get, path: accountId, query: [("fields", fields)]), as: BusinessDiscoveryResponse.self)
    return response.businessDiscovery
  }

  public func media(accountId: String, limit: Int? = nil, after: String? = nil) async throws -> Page<InstagramMedia> {
    try await client.request(HTTPRequest(method: .get, path: "\(accountId)/media", query: listQuery(fields: "id,caption,media_type,media_product_type,media_url,permalink,timestamp,username", limit: limit, after: after)), as: Page<InstagramMedia>.self)
  }

  public func media(id: String) async throws -> InstagramMedia {
    try await client.request(HTTPRequest(method: .get, path: id, query: [("fields", "id,caption,media_type,media_product_type,media_url,permalink,timestamp,username")]), as: InstagramMedia.self)
  }

  public func stories(accountId: String, limit: Int? = nil, after: String? = nil) async throws -> Page<InstagramMedia> {
    try await client.request(HTTPRequest(method: .get, path: "\(accountId)/stories", query: listQuery(fields: "id,caption,media_type,media_product_type,media_url,permalink,timestamp,username", limit: limit, after: after)), as: Page<InstagramMedia>.self)
  }

  public func liveMedia(accountId: String, limit: Int? = nil, after: String? = nil) async throws -> Page<InstagramMedia> {
    try await client.request(HTTPRequest(method: .get, path: "\(accountId)/live_media", query: listQuery(fields: "id,caption,media_type,media_product_type,media_url,permalink,timestamp,username", limit: limit, after: after)), as: Page<InstagramMedia>.self)
  }

  public func taggedMedia(accountId: String, limit: Int? = nil, after: String? = nil) async throws -> Page<InstagramMedia> {
    try await client.request(HTTPRequest(method: .get, path: "\(accountId)/tags", query: listQuery(fields: "id,caption,media_type,media_product_type,media_url,permalink,timestamp,username", limit: limit, after: after)), as: Page<InstagramMedia>.self)
  }

  public func comments(mediaId: String, limit: Int? = nil, after: String? = nil) async throws -> Page<InstagramComment> {
    try await client.request(HTTPRequest(method: .get, path: "\(mediaId)/comments", query: listQuery(fields: "id,text,username,timestamp,hidden", limit: limit, after: after)), as: Page<InstagramComment>.self)
  }

  public func insights(nodeId: String, metrics: String, period: String? = nil) async throws -> InsightsResponse {
    var query = [("metric", metrics)]
    if let period { query.append(("period", period)) }
    return try await client.request(HTTPRequest(method: .get, path: "\(nodeId)/insights", query: query), as: InsightsResponse.self)
  }

  public func contentPublishingLimit(accountId: String) async throws -> ContentPublishingLimit {
    try await client.request(
      HTTPRequest(method: .get, path: "\(accountId)/content_publishing_limit", query: [("fields", "config,quota_usage")]),
      as: ContentPublishingLimit.self
    )
  }

  public func searchHashtags(accountId: String, query: String) async throws -> Page<InstagramHashtag> {
    try requireProviderIdentifier(accountId, name: "account id")
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, !normalized.contains("#") else { throw InstagramGatewayError.configurationInvalid("Hashtag query must be non-empty without '#'") }
    return try await client.request(HTTPRequest(method: .get, path: "ig_hashtag_search", query: [("user_id", accountId), ("q", normalized)]), as: Page<InstagramHashtag>.self)
  }

  public func topHashtagMedia(hashtagId: String, accountId: String, limit: Int? = nil, after: String? = nil) async throws -> Page<InstagramHashtagMedia> {
    try await hashtagRequest(hashtagId: hashtagId, accountId: accountId, edge: "top_media", limit: limit, after: after)
  }

  public func recentHashtagMedia(hashtagId: String, accountId: String, limit: Int? = nil, after: String? = nil) async throws -> Page<InstagramHashtagMedia> {
    try await hashtagRequest(hashtagId: hashtagId, accountId: accountId, edge: "recent_media", limit: limit, after: after)
  }

  public func recentlySearchedHashtags(accountId: String, limit: Int? = nil, after: String? = nil) async throws -> Page<InstagramHashtag> {
    try requireProviderIdentifier(accountId, name: "account id")
    return try await client.request(HTTPRequest(method: .get, path: "\(accountId)/recently_searched_hashtags", query: listQuery(fields: "id,name", limit: try checkedLimit(limit), after: try checkedCursor(after))), as: Page<InstagramHashtag>.self)
  }

  public func oEmbed(_ input: InstagramOEmbedRequest) async throws -> InstagramOEmbed {
    guard let url = URL(string: input.url), url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil, let host = url.host, !host.isEmpty, !url.queryItemsContainSecret else {
      throw InstagramGatewayError.configurationInvalid("oEmbed URL must be a public HTTPS URL without credentials, fragments, or token query values")
    }
    if let width = input.maxWidth, !(320...658).contains(width) { throw InstagramGatewayError.configurationInvalid("oEmbed max width must be between 320 and 658") }
    var query = [("url", input.url)]
    if let width = input.maxWidth { query.append(("maxwidth", String(width))) }
    if let value = input.hideCaption { query.append(("hidecaption", value ? "true" : "false")) }
    if let value = input.omitScript { query.append(("omitscript", value ? "true" : "false")) }
    return try await client.request(HTTPRequest(method: .get, path: "instagram_oembed", query: query), as: InstagramOEmbed.self)
  }

  public func mentionedMedia(accountId: String) async throws -> MentionedMediaResponse {
    try requireProviderIdentifier(accountId, name: "account id")
    return try await client.request(HTTPRequest(method: .get, path: accountId, query: [("fields", "mentioned_media{id,caption,media_type,media_url,permalink}")]), as: MentionedMediaResponse.self)
  }

  public func mentionedMedia(_ lookup: MentionedMediaLookup) async throws -> MentionedMediaResponse {
    try requireProviderIdentifier(lookup.accountId, name: "account id"); try requireProviderIdentifier(lookup.mediaId, name: "media id")
    try requireUnique(lookup.fields.map(\.rawValue), name: "Mentioned media fields")
    try requireUnique(lookup.commentFields.map(\.rawValue), name: "Mentioned comment fields")
    guard !lookup.fields.isEmpty else { throw InstagramGatewayError.configurationInvalid("At least one mentioned media field is required") }
    var mediaFields = lookup.fields.map(\.rawValue).sorted().joined(separator: ",")
    if lookup.commentsLimit != nil || lookup.commentsAfter != nil {
      let limit = try checkedLimit(lookup.commentsLimit) ?? 25
      let after = try checkedCursor(lookup.commentsAfter)
      mediaFields += ",comments.limit(\(limit))"
      if let after { mediaFields += ".after(\(after))" }
      let commentFields = lookup.commentFields.map { $0 == .media ? "media{id,media_type,media_url,permalink}" : $0.rawValue }.sorted().joined(separator: ",")
      mediaFields += "{\(commentFields)}"
    }
    let fields = "mentioned_media.media_id(\(lookup.mediaId)){\(mediaFields)}"
    return try await client.request(HTTPRequest(method: .get, path: lookup.accountId, query: [("fields", fields)]), as: MentionedMediaResponse.self)
  }

  public func mentionedComment(accountId: String) async throws -> MentionedCommentResponse {
    try requireProviderIdentifier(accountId, name: "account id")
    return try await client.request(HTTPRequest(method: .get, path: accountId, query: [("fields", "mentioned_comment{id,text,username}")]), as: MentionedCommentResponse.self)
  }

  public func mentionedComment(_ lookup: MentionedCommentLookup) async throws -> MentionedCommentResponse {
    try requireProviderIdentifier(lookup.accountId, name: "account id"); try requireProviderIdentifier(lookup.commentId, name: "comment id")
    try requireUnique(lookup.fields.map(\.rawValue), name: "Mentioned comment fields")
    guard !lookup.fields.isEmpty else { throw InstagramGatewayError.configurationInvalid("At least one mentioned comment field is required") }
    let fields = lookup.fields.map { $0 == .media ? "media{id,media_type,media_url,permalink}" : $0.rawValue }.sorted().joined(separator: ",")
    return try await client.request(HTTPRequest(method: .get, path: lookup.accountId, query: [("fields", "mentioned_comment.comment_id(\(lookup.commentId)){\(fields)}")]), as: MentionedCommentResponse.self)
  }

  public func shoppingEligibility(accountId: String) async throws -> ShoppingEligibility {
    try requireProviderIdentifier(accountId, name: "account id")
    return try await client.request(HTTPRequest(method: .get, path: "\(accountId)/shopping_eligibility", query: [("fields", "eligible,reason")]), as: ShoppingEligibility.self)
  }
  public func availableCatalogs(accountId: String, limit: Int? = nil, after: String? = nil) async throws -> Page<ShoppingCatalog> {
    try requireProviderIdentifier(accountId, name: "account id")
    return try await client.request(HTTPRequest(method: .get, path: "\(accountId)/available_catalogs", query: listQuery(fields: "id,name", limit: try checkedLimit(limit), after: try checkedCursor(after))), as: Page<ShoppingCatalog>.self)
  }
  public func searchCatalogProducts(accountId: String, catalogId: String, query: String? = nil, limit: Int? = nil, after: String? = nil) async throws -> Page<ShoppingProduct> {
    try requireProviderIdentifier(accountId, name: "account id"); try requireProviderIdentifier(catalogId, name: "catalog id")
    var values = listQuery(fields: "id,name,review_status,variants{id,name}", limit: try checkedLimit(limit), after: try checkedCursor(after)); values.append(("user_id", accountId)); if let query, !query.isEmpty { values.append(("q", query)) }
    return try await client.request(HTTPRequest(method: .get, path: "\(catalogId)/products", query: values), as: Page<ShoppingProduct>.self)
  }
  public func productTags(mediaId: String, limit: Int? = nil, after: String? = nil) async throws -> Page<PublishedProductTag> {
    try requireProviderIdentifier(mediaId, name: "media id")
    return try await client.request(HTTPRequest(method: .get, path: "\(mediaId)/product_tags", query: listQuery(fields: "product_id,x,y", limit: try checkedLimit(limit), after: try checkedCursor(after))), as: Page<PublishedProductTag>.self)
  }
  public func productAppealStatus(accountId: String, productId: String) async throws -> ProductAppealStatus {
    try requireProviderIdentifier(accountId, name: "account id"); try requireProviderIdentifier(productId, name: "product id")
    return try await client.request(HTTPRequest(method: .get, path: "\(accountId)/product_appeal", query: [("product_id", productId)]), as: ProductAppealStatus.self)
  }
  public func mediaChildren(mediaId: String, limit: Int? = nil, after: String? = nil) async throws -> Page<InstagramMedia> {
    try requireProviderIdentifier(mediaId, name: "media id")
    return try await client.request(HTTPRequest(method: .get, path: "\(mediaId)/children", query: listQuery(fields: "id,media_type,media_url,permalink", limit: try checkedLimit(limit), after: try checkedCursor(after))), as: Page<InstagramMedia>.self)
  }
  public func conversations(actorId: String, instagramScopedUserId: String? = nil, limit: Int? = nil, after: String? = nil) async throws -> Page<InstagramConversation> {
    let authorization = try requireMessagingAuthorization(.read)
    try requireProviderIdentifier(actorId, name: "messaging actor id")
    var query = listQuery(fields: "id,updated_time,participants{id,username}", limit: try checkedLimit(limit), after: try checkedCursor(after))
    if case .facebook = authorization.loginType { query.append(("platform", "instagram")) }
    if let instagramScopedUserId { try requireProviderIdentifier(instagramScopedUserId, name: "Instagram-scoped user id"); query.append(("user_id", instagramScopedUserId)) }
    return try await client.request(HTTPRequest(method: .get, path: "\(actorId)/conversations", query: query), as: Page<InstagramConversation>.self)
  }
  public func conversations(_ input: ListInstagramConversationsInput) async throws -> Page<InstagramConversation> { try await conversations(actorId: input.accountId, instagramScopedUserId: input.instagramScopedUserId, limit: input.limit, after: input.after) }
  public func conversationMessages(conversationId: String, limit: Int? = nil, after: String? = nil) async throws -> Page<InstagramMessage> {
    _ = try requireMessagingAuthorization(.read)
    try requireProviderIdentifier(conversationId, name: "conversation id")
    var field = "messages"
    if let limit = try checkedLimit(limit) { field += ".limit(\(limit))" }
    if let after = try checkedCursor(after) { field += ".after(\(after))" }
    field += "{id,created_time,is_unsupported,from{id,username},to{id,username},message,attachments{type,url}}"
    return try await client.request(HTTPRequest(method: .get, path: conversationId, query: [("fields", field)]), as: InstagramConversationMessagesEnvelope.self).messages
  }
  public func conversationMessages(_ input: ListInstagramMessagesInput) async throws -> Page<InstagramMessage> { try await conversationMessages(conversationId: input.conversationId, limit: input.limit, after: input.after) }
  public func message(id: String) async throws -> InstagramMessage { _ = try requireMessagingAuthorization(.read); try requireProviderIdentifier(id, name: "message id"); return try await client.request(HTTPRequest(method: .get, path: id, query: [("fields", "id,created_time,is_unsupported,from{id,username},to{id,username},message,attachments{type,url}")]), as: InstagramMessage.self) }
  public func message(_ input: GetInstagramMessageInput) async throws -> InstagramMessage { try await message(id: input.messageId) }
  public func messagingUserProfile(instagramScopedUserId: String) async throws -> InstagramMessagingUserProfile {
    _ = try requireMessagingAuthorization(.read)
    try requireProviderIdentifier(instagramScopedUserId, name: "Instagram-scoped user id")
    return try await client.request(HTTPRequest(method: .get, path: instagramScopedUserId, query: [("fields", "id,name,username,profile_pic,follower_count,is_verified_user,is_user_follow_business,is_business_follow_user")]), as: InstagramMessagingUserProfile.self)
  }
  public func messagingUserProfile(_ input: GetInstagramMessagingProfileInput) async throws -> InstagramMessagingUserProfile { try await messagingUserProfile(instagramScopedUserId: input.instagramScopedUserId) }
  public func messagingProfile(actorId: String) async throws -> InstagramMessagingProfile {
    _ = try requireMessagingAuthorization(.read)
    try requireProviderIdentifier(actorId, name: "messaging actor id")
    return try await client.request(HTTPRequest(method: .get, path: "\(actorId)/messenger_profile", query: [("fields", "ice_breakers,persistent_menu")]), as: InstagramMessagingProfile.self)
  }
  public func iceBreakers(accountId: String) async throws -> [InstagramIceBreaker] {
    _ = try requireMessagingAuthorization(.read); try requireProviderIdentifier(accountId, name: "messaging actor id")
    return try await client.request(HTTPRequest(method: .get, path: "\(accountId)/messenger_profile", query: [("fields", "ice_breakers")]), as: InstagramMessagingProfile.self).iceBreakers ?? []
  }
  public func persistentMenu(accountId: String) async throws -> [InstagramPersistentMenuItem] {
    _ = try requireMessagingAuthorization(.read); try requireProviderIdentifier(accountId, name: "messaging actor id")
    return try await client.request(HTTPRequest(method: .get, path: "\(accountId)/messenger_profile", query: [("fields", "persistent_menu")]), as: InstagramMessagingProfile.self).persistentMenu ?? []
  }

  private func requireMessagingAuthorization(_ operation: InstagramMessagingOperation) throws -> InstagramMessagingAuthorization {
    guard let messagingAuthorization else { throw InstagramGatewayError.permissionDenied("Messaging authorization context is required") }
    try messagingAuthorization.validate(operation)
    return messagingAuthorization
  }

  private func hashtagRequest(hashtagId: String, accountId: String, edge: String, limit: Int?, after: String?) async throws -> Page<InstagramHashtagMedia> {
    try requireProviderIdentifier(hashtagId, name: "hashtag id")
    try requireProviderIdentifier(accountId, name: "account id")
    var query = listQuery(fields: "id,caption,media_type,media_product_type,media_url,permalink,timestamp,children{id,media_type,media_url}", limit: try checkedLimit(limit), after: try checkedCursor(after))
    query.append(("user_id", accountId))
    return try await client.request(HTTPRequest(method: .get, path: "\(hashtagId)/\(edge)", query: query), as: Page<InstagramHashtagMedia>.self)
  }

  private func listQuery(fields: String, limit: Int?, after: String?) -> [(String, String)] {
    var query = [("fields", fields)]
    if let limit { query.append(("limit", String(limit))) }
    if let after { query.append(("after", after)) }
    return query
  }
}

public enum InstagramMessagingOperation: String, Codable, Equatable, Sendable {
  case read
  case send
  case privateReply = "private_reply"
  case react
  case senderAction = "sender_action"
  case uploadAttachment = "upload_attachment"
  case profile
}

/// Credential-derived messaging authorization supplied by applications that
/// manage credentials. Keeping it separate preserves the existing raw-token
/// SDK initializer while ensuring configured callers preflight at the service
/// boundary before a transport request is created.
public struct InstagramMessagingAuthorization: Equatable, Sendable {
  public var loginType: InstagramLoginType
  public var scopes: Set<String>
  public var features: Set<String>

  public init(loginType: InstagramLoginType, scopes: [String], features: [String] = []) {
    self.loginType = loginType
    self.scopes = Set(scopes)
    self.features = Set(features)
  }

  public init(profile: CredentialProfile) {
    self.init(loginType: profile.loginType, scopes: profile.scopes, features: profile.features)
  }

  public func validate(_ operation: InstagramMessagingOperation, humanAgent: Bool = false) throws {
    let requiredScopes: Set<String>
    switch loginType {
    case .instagram:
      requiredScopes = [
        "instagram_business_basic",
        operation == .privateReply ? "instagram_business_manage_comments" : "instagram_business_manage_messages"
      ]
    case .facebook:
      requiredScopes = operation == .privateReply
        ? ["instagram_basic", "instagram_manage_comments", "pages_read_engagement"]
        : ["instagram_basic", "instagram_manage_messages", "pages_manage_metadata"]
    case .unknown:
      throw InstagramGatewayError.configurationInvalid("Unsupported Instagram login type")
    }
    guard requiredScopes.isSubset(of: scopes) else {
      throw InstagramGatewayError.permissionDenied("Messaging operation is missing declared scopes: \(requiredScopes.subtracting(scopes).sorted().joined(separator: ", "))")
    }
    if humanAgent, !features.contains("human_agent") {
      throw InstagramGatewayError.permissionDenied("Human Agent messaging requires the human_agent feature")
    }
  }
}

public struct InstagramWriterService: Sendable {
  public var client: InstagramGatewayClient
  public var messagingAuthorization: InstagramMessagingAuthorization?

  public init(client: InstagramGatewayClient, messagingAuthorization: InstagramMessagingAuthorization? = nil) {
    self.client = client
    self.messagingAuthorization = messagingAuthorization
  }

  private func requireMessagingAuthorization(_ operation: InstagramMessagingOperation, humanAgent: Bool = false) throws -> InstagramMessagingAuthorization {
    guard let messagingAuthorization else {
      throw InstagramGatewayError.permissionDenied("Messaging authorization context is required")
    }
    try messagingAuthorization.validate(operation, humanAgent: humanAgent)
    return messagingAuthorization
  }

  public func createMediaContainer(_ input: CreateMediaContainerInput) async throws -> MediaContainer {
    guard !input.accountId.isEmpty else {
      throw InstagramGatewayError.configurationInvalid("Missing required account id")
    }
    var query: [(String, String)] = []
    switch input.mediaType {
    case .image:
      query.append(("image_url", try input.imageURL.required("image URL")))
    case .video:
      query.append(("video_url", try input.videoURL.required("video URL")))
      query.append(("media_type", "REELS"))
    case .storyImage:
      query.append(("image_url", try input.imageURL.required("image URL")))
      query.append(("media_type", "STORIES"))
    case .storyVideo:
      query.append(("video_url", try input.videoURL.required("video URL")))
      query.append(("media_type", "STORIES"))
    case .carouselImage:
      query.append(("image_url", try input.imageURL.required("image URL")))
      query.append(("is_carousel_item", "true"))
    case .carouselVideo:
      query.append(("video_url", try input.videoURL.required("video URL")))
      query.append(("media_type", "VIDEO"))
      query.append(("is_carousel_item", "true"))
    case .carousel:
      guard !input.children.isEmpty else {
        throw InstagramGatewayError.configurationInvalid("Missing required carousel children")
      }
      query.append(("media_type", "CAROUSEL"))
      query.append(("children", input.children.joined(separator: ",")))
    }
    if let caption = input.caption { query.append(("caption", caption)) }
    if !input.productTags.isEmpty {
      guard input.providerFields["product_tags"] == nil else { throw InstagramGatewayError.configurationInvalid("providerFields must not set product_tags") }
      try validateProductTags(input.productTags, mediaType: input.mediaType)
      query.append(("product_tags", try encodedJSON(input.productTags)))
    }
    try appendPublishingOptions(input.publishingOptions, to: &query)
    for (key, value) in input.providerFields.sorted(by: { $0.key < $1.key }) {
      query.append((key, value))
    }
    return try await client.request(HTTPRequest(method: .post, path: "\(input.accountId)/media", query: query), as: MediaContainer.self)
  }

  public func createMediaContainer(accountId: String, imageURL: String, caption: String?) async throws -> MediaContainer {
    try await createMediaContainer(CreateMediaContainerInput(accountId: accountId, imageURL: imageURL, caption: caption))
  }

  public func containerStatus(containerId: String) async throws -> MediaContainerStatus {
    try await client.request(HTTPRequest(method: .get, path: containerId, query: [("fields", "id,status_code,status,video_status")]), as: MediaContainerStatus.self)
  }

  public func publish(_ input: PublishMediaContainerInput) async throws -> PublishedMedia {
    try await client.request(HTTPRequest(method: .post, path: "\(input.accountId)/media_publish", query: [("creation_id", input.containerId)]), as: PublishedMedia.self)
  }

  public func publish(accountId: String, containerId: String) async throws -> PublishedMedia {
    try await publish(PublishMediaContainerInput(accountId: accountId, containerId: containerId))
  }

  public func reply(_ input: ReplyToCommentInput) async throws -> CommentReply {
    guard !input.accountId.isEmpty else {
      throw InstagramGatewayError.configurationInvalid("Missing required account id")
    }
    return try await client.request(HTTPRequest(method: .post, path: "\(input.commentId)/replies", query: [("message", input.message)]), as: CommentReply.self)
  }

  public func reply(accountId: String, commentId: String, message: String) async throws -> CommentReply {
    try await reply(ReplyToCommentInput(accountId: accountId, commentId: commentId, message: message))
  }

  public func moderate(_ input: ModerateCommentInput) async throws -> ModerationResult {
    guard !input.accountId.isEmpty else {
      throw InstagramGatewayError.configurationInvalid("Missing required account id")
    }
    switch input.action {
    case .hide:
      return try await client.request(HTTPRequest(method: .post, path: input.commentId, query: [("hide", "true")]), as: ModerationResult.self)
    case .unhide:
      return try await client.request(HTTPRequest(method: .post, path: input.commentId, query: [("hide", "false")]), as: ModerationResult.self)
    case .delete:
      return try await client.request(HTTPRequest(method: .delete, path: input.commentId), as: ModerationResult.self)
    }
  }

  public func moderate(accountId: String, commentId: String, action: ModerationAction) async throws -> ModerationResult {
    try await moderate(ModerateCommentInput(accountId: accountId, commentId: commentId, action: action))
  }

  public func setCommentsEnabled(mediaId: String, enabled: Bool) async throws -> ModerationResult {
    try await client.request(
      HTTPRequest(method: .post, path: mediaId, query: [("comments", enabled ? "true" : "false")]),
      as: ModerationResult.self
    )
  }

  public func addOrUpdateProductTags(_ input: UpdateProductTagsInput) async throws -> ShoppingMutationResult {
    try requireProviderIdentifier(input.accountId, name: "account id"); try requireProviderIdentifier(input.mediaId, name: "media id")
    try validateProductTags(input.tags, mediaType: .image)
    return try await client.request(HTTPRequest(method: .post, path: "\(input.mediaId)/product_tags", query: [("updated_tags", try encodedJSON(input.tags))]), as: ShoppingMutationResult.self)
  }
  public func submitProductAppeal(_ input: SubmitProductAppealInput) async throws -> ShoppingMutationResult {
    try requireProviderIdentifier(input.accountId, name: "account id"); try requireProviderIdentifier(input.productId, name: "product id")
    guard !input.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InstagramGatewayError.configurationInvalid("Appeal reason must not be empty") }
    return try await client.request(HTTPRequest(method: .post, path: "\(input.accountId)/product_appeal", query: [("product_id", input.productId), ("appeal_reason", input.reason)]), as: ShoppingMutationResult.self)
  }
  public func createResumableVideoContainer(_ input: CreateResumableVideoContainerInput) async throws -> MediaContainer {
    try requireProviderIdentifier(input.accountId, name: "account id")
    var query = [("media_type", "REELS"), ("upload_type", "resumable")]
    try appendPublishingOptions(input.options, to: &query)
    return try await client.request(HTTPRequest(method: .post, path: "\(input.accountId)/media", query: query), as: MediaContainer.self)
  }
  public func uploadResumableVideo(_ input: UploadResumableVideoInput) async throws -> ResumableVideoUploadResult {
    guard let url = URL(string: input.uploadURI), url.scheme == "https", url.host == "rupload.facebook.com", url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.hasPrefix("/ig-api-upload/") else { throw InstagramGatewayError.configurationInvalid("Invalid resumable upload URI") }
    guard input.offset >= 0, FileManager.default.fileExists(atPath: input.filePath) else { throw InstagramGatewayError.configurationInvalid("Upload file or offset is invalid") }
    let attributes = try FileManager.default.attributesOfItem(atPath: input.filePath)
    guard let size = (attributes[.size] as? NSNumber)?.int64Value, input.offset <= size else { throw InstagramGatewayError.configurationInvalid("Upload offset exceeds file size") }
    return try await client.request(HTTPRequest(method: .post, path: input.uploadURI, headers: ["Authorization": "OAuth \(client.token)", "Content-Type": "application/octet-stream", "offset": String(input.offset), "file_size": String(size)], fileBody: HTTPFileBody(filePath: input.filePath, offset: input.offset)), as: ResumableVideoUploadResult.self)
  }

  public func sendMessage(actorId: String, input: SendInstagramMessageInput, loginType: InstagramLoginType? = nil) async throws -> InstagramSendReceipt {
    let authorization = try requireMessagingAuthorization(.send, humanAgent: input.humanAgent)
    if let loginType, loginType != authorization.loginType {
      throw InstagramGatewayError.configurationInvalid("Messaging login type must match the authorization context")
    }
    try requireProviderIdentifier(actorId, name: "messaging actor id"); try requireProviderIdentifier(input.recipientId, name: "recipient id")
    let payload: [String: JSONValue]
    switch input.content {
    case .text(let text): guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InstagramGatewayError.configurationInvalid("Message text must not be empty") }; payload = ["recipient": .object(["id": .string(input.recipientId)]), "message": .object(["text": .string(text)])]
    case .imageURL(let url), .audioURL(let url), .videoURL(let url): guard let absolute = URL(string: url), absolute.scheme == "https" else { throw InstagramGatewayError.configurationInvalid("Media URL must be HTTPS") }; let kind: String = { switch input.content { case .imageURL: return "image"; case .audioURL: return "audio"; default: return "video" } }(); payload = ["recipient": .object(["id": .string(input.recipientId)]), "message": .object(["attachment": .object(["type": .string(kind), "payload": .object(["url": .string(url)])])])]
    case .uploadedImage(let attachmentId):
      try requireProviderIdentifier(attachmentId, name: "attachment id")
      payload = ["recipient": .object(["id": .string(input.recipientId)]), "message": .object(["attachment": .object(["type": .string("image"), "payload": .object(["attachment_id": .string(attachmentId)])])])]
    case .publishedPost(let mediaId):
      guard authorization.features.contains("owned_messaging_media_fixture") else { throw InstagramGatewayError.permissionDenied("Published-post messaging requires an owned_messaging_media_fixture credential feature") }
      try requireProviderIdentifier(mediaId, name: "owned media id")
      payload = ["recipient": .object(["id": .string(input.recipientId)]), "message": .object(["attachment": .object(["type": .string("MEDIA_SHARE"), "payload": .object(["id": .string(mediaId)])])])]
    case .heartSticker:
      payload = ["recipient": .object(["id": .string(input.recipientId)]), "message": .object(["attachment": .object(["type": .string("template"), "payload": .object(["template_type": .string("heart")])])])]
    case .quickReplies(let text, let replies):
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...13).contains(replies.count), replies.allSatisfy(validateQuickReply) else { throw InstagramGatewayError.configurationInvalid("Quick replies require text and 1...13 valid reply values") }
      payload = ["recipient": .object(["id": .string(input.recipientId)]), "message": .object(["text": .string(text), "quick_replies": .array(replies.map(quickReplyJSON))])]
    case .template(let template):
      let templatePayload: JSONValue
      switch template {
      case .generic(let elements):
        guard !elements.isEmpty, elements.allSatisfy({ validateTemplateElement($0) }) else { throw InstagramGatewayError.configurationInvalid("Generic template requires valid elements") }
        templatePayload = .object(["template_type": .string("generic"), "elements": .array(elements.map(templateElementJSON))])
      case .button(let text, let buttons):
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...3).contains(buttons.count), buttons.allSatisfy(validateTemplateButton) else { throw InstagramGatewayError.configurationInvalid("Button template requires text and 1...3 valid buttons") }
        templatePayload = .object(["template_type": .string("button"), "text": .string(text), "buttons": .array(buttons.map(templateButtonJSON))])
      }
      payload = ["recipient": .object(["id": .string(input.recipientId)]), "message": .object(["attachment": .object(["type": .string("template"), "payload": templatePayload])])]
    }
    var body = payload
    if case .facebook = authorization.loginType { body["messaging_type"] = .string("RESPONSE") }
    if input.humanAgent { guard case .text = input.content else { throw InstagramGatewayError.configurationInvalid("Human Agent is text-only") }; body["tag"] = .string("HUMAN_AGENT") }
    return try await client.request(HTTPRequest(method: .post, path: "\(actorId)/messages", headers: ["Content-Type": "application/json"], body: try JSONEncoder().encode(body)), as: InstagramSendReceipt.self)
  }
  public func privateReply(_ input: PrivateReplyInput) async throws -> InstagramSendReceipt {
    _ = try requireMessagingAuthorization(.privateReply)
    try requireProviderIdentifier(input.accountId, name: "account id"); try requireProviderIdentifier(input.commentId, name: "comment id"); guard !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InstagramGatewayError.configurationInvalid("Private reply text must not be empty") }
    let body: [String: JSONValue] = ["recipient": .object(["comment_id": .string(input.commentId)]), "message": .object(["text": .string(input.text)])]
    return try await client.request(HTTPRequest(method: .post, path: "\(input.accountId)/messages", headers: ["Content-Type": "application/json"], body: try JSONEncoder().encode(body)), as: InstagramSendReceipt.self)
  }
  public func sendPrivateReply(_ input: SendInstagramPrivateReplyInput) async throws -> InstagramSendReceipt { try await privateReply(input) }

  public func react(actorId: String, input: SendReactionInput) async throws -> InstagramSendReceipt {
    _ = try requireMessagingAuthorization(.react)
    try requireProviderIdentifier(actorId, name: "messaging actor id"); try requireProviderIdentifier(input.recipientId, name: "recipient id"); try requireProviderIdentifier(input.messageId, name: "message id")
    let body: [String: JSONValue] = [
      "recipient": .object(["id": .string(input.recipientId)]),
      "sender_action": .string(input.action.rawValue),
      "message_reaction": .object(["message_id": .string(input.messageId), "reaction": .string(input.reaction.rawValue)])
    ]
    return try await client.request(HTTPRequest(method: .post, path: "\(actorId)/messages", headers: ["Content-Type": "application/json"], body: try JSONEncoder().encode(body)), as: InstagramSendReceipt.self)
  }
  public func reactToMessage(_ input: ReactToInstagramMessageInput) async throws -> InstagramSendReceipt {
    try await react(actorId: input.accountId, input: SendReactionInput(recipientId: input.recipientId, messageId: input.messageId, action: input.action, reaction: input.reaction))
  }

  public func senderAction(actorId: String, input: SendSenderActionInput) async throws -> InstagramSendReceipt {
    _ = try requireMessagingAuthorization(.senderAction)
    try requireProviderIdentifier(actorId, name: "messaging actor id"); try requireProviderIdentifier(input.recipientId, name: "recipient id")
    let body: [String: JSONValue] = ["recipient": .object(["id": .string(input.recipientId)]), "sender_action": .string(input.action.rawValue)]
    return try await client.request(HTTPRequest(method: .post, path: "\(actorId)/messages", headers: ["Content-Type": "application/json"], body: try JSONEncoder().encode(body)), as: InstagramSendReceipt.self)
  }
  public func performSenderAction(_ input: PerformInstagramSenderActionInput) async throws -> InstagramSendReceipt { try await senderAction(actorId: input.accountId, input: SendSenderActionInput(recipientId: input.recipientId, action: input.action)) }

  public func uploadImageAttachment(actorId: String, input: UploadMessageAttachmentInput) async throws -> InstagramAttachmentReceipt {
    _ = try requireMessagingAuthorization(.uploadAttachment)
    try requireProviderIdentifier(actorId, name: "messaging actor id"); try requireProviderIdentifier(input.recipientId, name: "recipient id")
    guard let url = URL(string: input.imageURL), url.scheme == "https", url.user == nil, url.password == nil else { throw InstagramGatewayError.configurationInvalid("Attachment URL must be public HTTPS") }
    let body: [String: JSONValue] = [
      "recipient": .object(["id": .string(input.recipientId)]),
      "message": .object(["attachment": .object(["type": .string("image"), "payload": .object(["url": .string(input.imageURL), "is_reusable": .bool(input.reusable)])])])
    ]
    return try await client.request(HTTPRequest(method: .post, path: "\(actorId)/message_attachments", headers: ["Content-Type": "application/json"], body: try JSONEncoder().encode(body)), as: InstagramAttachmentReceipt.self)
  }
  public func uploadMessageAttachment(_ input: UploadInstagramMessageAttachmentInput) async throws -> InstagramAttachmentReceipt { try await uploadImageAttachment(actorId: input.accountId, input: UploadMessageAttachmentInput(recipientId: input.recipientId, imageURL: input.imageURL, reusable: input.reusable)) }

  public func setIceBreakers(actorId: String, iceBreakers: [InstagramIceBreaker]) async throws -> InstagramMutationResult {
    _ = try requireMessagingAuthorization(.profile)
    try requireProviderIdentifier(actorId, name: "messaging actor id")
    guard (1...4).contains(iceBreakers.count), iceBreakers.allSatisfy({ !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.payload.isEmpty }) else { throw InstagramGatewayError.configurationInvalid("Ice breakers require 1...4 non-empty question/payload values") }
    return try await messagingProfileMutation(actorId: actorId, body: ["ice_breakers": .array(iceBreakers.map { .object(["question": .string($0.question), "payload": .string($0.payload)]) })])
  }
  public func setIceBreakers(_ input: SetInstagramIceBreakersInput) async throws -> InstagramMutationResult { try await setIceBreakers(actorId: input.accountId, iceBreakers: input.iceBreakers) }
  public func deleteIceBreakers(actorId: String) async throws -> InstagramMutationResult {
    _ = try requireMessagingAuthorization(.profile)
    try requireProviderIdentifier(actorId, name: "messaging actor id")
    return try await messagingProfileMutation(actorId: actorId, body: ["ice_breakers": .array([])])
  }
  public func setPersistentMenu(actorId: String, items: [InstagramPersistentMenuItem]) async throws -> InstagramMutationResult {
    _ = try requireMessagingAuthorization(.profile)
    try requireProviderIdentifier(actorId, name: "messaging actor id")
    guard !items.isEmpty, items.count <= 3, items.allSatisfy({ validateTemplateButton(InstagramTemplateButton(type: $0.type, title: $0.title, payload: $0.payload, url: $0.url)) }) else { throw InstagramGatewayError.configurationInvalid("Persistent menu requires 1...3 valid items") }
    return try await messagingProfileMutation(actorId: actorId, body: ["persistent_menu": .array(items.map { templateButtonJSON(InstagramTemplateButton(type: $0.type, title: $0.title, payload: $0.payload, url: $0.url)) })])
  }
  public func setPersistentMenu(_ input: SetInstagramPersistentMenuInput) async throws -> InstagramMutationResult { try await setPersistentMenu(actorId: input.accountId, items: input.items) }
  public func deletePersistentMenu(actorId: String) async throws -> InstagramMutationResult {
    _ = try requireMessagingAuthorization(.profile)
    try requireProviderIdentifier(actorId, name: "messaging actor id")
    return try await messagingProfileMutation(actorId: actorId, body: ["persistent_menu": .array([])])
  }
  private func messagingProfileMutation(actorId: String, body: [String: JSONValue]) async throws -> InstagramMutationResult {
    try await client.request(HTTPRequest(method: .post, path: "\(actorId)/messenger_profile", headers: ["Content-Type": "application/json"], body: try JSONEncoder().encode(body)), as: InstagramMutationResult.self)
  }

  public func replyToMention(_ input: ReplyToMentionInput) async throws -> CommentReply {
    try requireProviderIdentifier(input.accountId, name: "account id")
    guard !input.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InstagramGatewayError.configurationInvalid("Mention reply message must not be empty") }
    var query = [("message", input.message)]
    switch input.target {
    case .caption(let mediaId): try requireProviderIdentifier(mediaId, name: "media id"); query.append(("media_id", mediaId))
    case .comment(let mediaId, let commentId): try requireProviderIdentifier(mediaId, name: "media id"); try requireProviderIdentifier(commentId, name: "comment id"); query.append(("media_id", mediaId)); query.append(("comment_id", commentId))
    }
    var safeClient = client
    safeClient.redactor = client.redactor.including(secrets: [input.message])
    return try await safeClient.request(HTTPRequest(method: .post, path: "\(input.accountId)/mentions", query: query), as: CommentReply.self)
  }
}

private func requireProviderIdentifier(_ value: String, name: String) throws {
  guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw InstagramGatewayError.configurationInvalid("Invalid \(name)") }
}

private struct AnyCodingKey: CodingKey, Hashable {
  var stringValue: String
  var intValue: Int?
  init(_ stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
  init?(stringValue: String) { self.init(stringValue) }
  init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

private func decodeLosslessID<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) throws -> String {
  if let value = try? container.decode(String.self, forKey: key), !value.isEmpty { return value }
  if let value = try? container.decode(Int64.self, forKey: key) { return String(value) }
  throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Expected a string or integer provider ID")
}

private func decodeOptionalFlexibleInt<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) throws -> Int? {
  guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
  if let value = try? container.decode(Int.self, forKey: key) { return value }
  if let value = try? container.decode(String.self, forKey: key), let integer = Int(value) { return integer }
  throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Expected integer or decimal string")
}

private func requireUnique(_ values: [String], name: String) throws {
  guard Set(values).count == values.count else { throw InstagramGatewayError.configurationInvalid("\(name) must not contain duplicates") }
}

private func encodedJSON<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  guard let text = String(data: try encoder.encode(value), encoding: .utf8) else { throw InstagramGatewayError.configurationInvalid("Unable to encode JSON") }
  return text
}

private func validateProductTags(_ tags: [ProductTagInput], mediaType: PublishingMediaType) throws {
  guard !tags.isEmpty, tags.count <= 5 else { throw InstagramGatewayError.configurationInvalid("Product tags require 1...5 entries") }
  guard ![.storyImage, .storyVideo].contains(mediaType) else { throw InstagramGatewayError.configurationInvalid("Product tags are unsupported for Stories") }
  var ids = Set<String>()
  for tag in tags {
    guard !tag.productId.isEmpty, ids.insert(tag.productId).inserted else { throw InstagramGatewayError.configurationInvalid("Product tag IDs must be non-empty and unique") }
    if tag.x != nil || tag.y != nil {
      guard let x = tag.x, let y = tag.y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { throw InstagramGatewayError.configurationInvalid("Product tag coordinates must be paired finite values from 0 to 1") }
    }
  }
}

private func validateTemplateButton(_ button: InstagramTemplateButton) -> Bool {
  guard !button.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, button.title.count <= 20 else { return false }
  switch button.type {
  case .postback: return !(button.payload ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && button.url == nil
  case .webURL:
    guard button.payload == nil, let url = button.url, let value = URL(string: url) else { return false }
    return value.scheme == "https" && value.user == nil && value.password == nil
  }
}

private func validateTemplateElement(_ element: InstagramGenericTemplateElement) -> Bool {
  guard !element.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, element.buttons.count <= 3, element.buttons.allSatisfy(validateTemplateButton) else { return false }
  guard let imageURL = element.imageURL else { return true }
  guard let value = URL(string: imageURL) else { return false }
  return value.scheme == "https" && value.user == nil && value.password == nil
}

private func templateButtonJSON(_ button: InstagramTemplateButton) -> JSONValue {
  var value: [String: JSONValue] = ["type": .string(button.type.rawValue), "title": .string(button.title)]
  if let payload = button.payload { value["payload"] = .string(payload) }
  if let url = button.url { value["url"] = .string(url) }
  return .object(value)
}

private func templateElementJSON(_ element: InstagramGenericTemplateElement) -> JSONValue {
  var value: [String: JSONValue] = ["title": .string(element.title)]
  if let subtitle = element.subtitle { value["subtitle"] = .string(subtitle) }
  if let imageURL = element.imageURL { value["image_url"] = .string(imageURL) }
  if !element.buttons.isEmpty { value["buttons"] = .array(element.buttons.map(templateButtonJSON)) }
  return .object(value)
}

private func validateQuickReply(_ reply: InstagramQuickReply) -> Bool {
  switch reply.contentType {
  case .text:
    return !(reply.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (reply.title?.count ?? 0) <= 20 && !(reply.payload ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  case .userPhoneNumber, .userEmail:
    return reply.title == nil && reply.payload == nil
  }
}

private func quickReplyJSON(_ reply: InstagramQuickReply) -> JSONValue {
  var value: [String: JSONValue] = ["content_type": .string(reply.contentType.rawValue)]
  if let title = reply.title { value["title"] = .string(title) }
  if let payload = reply.payload { value["payload"] = .string(payload) }
  return .object(value)
}

private func appendPublishingOptions(_ options: InstagramPublishingOptions, to query: inout [(String, String)]) throws {
  var names = Set<String>()
  for tag in options.userTags { guard !tag.username.isEmpty, names.insert(tag.username).inserted else { throw InstagramGatewayError.configurationInvalid("User tags must be unique and non-empty") }; if let p = tag.position, !p.x.isFinite || !p.y.isFinite || !(0...1).contains(p.x) || !(0...1).contains(p.y) { throw InstagramGatewayError.configurationInvalid("User tag position must be finite and within 0...1") } }
  if !options.userTags.isEmpty { query.append(("user_tags", try encodedJSON(options.userTags))) }
  let collaborators = Array(Set(options.collaborators)).sorted(); if collaborators.count != options.collaborators.count || collaborators.contains(where: { $0.isEmpty }) { throw InstagramGatewayError.configurationInvalid("Collaborators must be unique and non-empty") }; if !collaborators.isEmpty { query.append(("collaborators", collaborators.joined(separator: ","))) }
  if let locationId = options.locationId { try requireProviderIdentifier(locationId, name: "location id"); query.append(("location_id", locationId)) }
  if let altText = options.altText { guard !altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InstagramGatewayError.configurationInvalid("Alt text must not be empty") }; query.append(("alt_text", altText)) }
  if let cover = options.cover { if cover.url != nil && cover.thumbnailOffsetMilliseconds != nil { throw InstagramGatewayError.configurationInvalid("Cover URL and thumbnail offset are mutually exclusive") }; if let url = cover.url { guard let value = URL(string: url), value.scheme == "https" else { throw InstagramGatewayError.configurationInvalid("Cover URL must be HTTPS") }; query.append(("cover_url", url)) }; if let offset = cover.thumbnailOffsetMilliseconds { guard offset >= 0 else { throw InstagramGatewayError.configurationInvalid("Thumbnail offset must be non-negative") }; query.append(("thumb_offset", String(offset))) } }
}

private func checkedLimit(_ value: Int?) throws -> Int? {
  guard let value else { return nil }
  guard value > 0 else { throw InstagramGatewayError.configurationInvalid("Limit must be a positive integer") }
  return value
}

private func checkedCursor(_ value: String?) throws -> String? {
  guard let value else { return nil }
  guard value.range(of: "^[A-Za-z0-9_=-]+$", options: .regularExpression) != nil else { throw InstagramGatewayError.configurationInvalid("Invalid cursor") }
  return value
}

private extension URL {
  var queryItemsContainSecret: Bool {
    URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.contains { ["access_token", "client_secret", "appsecret_proof"].contains($0.name.lowercased()) } ?? false
  }
}

private extension Optional where Wrapped == String {
  func required(_ name: String) throws -> String {
    guard let self, !self.isEmpty else {
      throw InstagramGatewayError.configurationInvalid("Missing required \(name)")
    }
    return self
  }
}
