import Foundation

public let instagramGatewayVersion = "0.1.0"
public let metaGraphAPIVersion = "v26.0"

public enum AccessMode: String, Codable, Equatable, Sendable {
  case read
  case write
}

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

  public init(
    id: String,
    provider: String = "meta-instagram",
    accessMode: AccessMode,
    appId: SecretReference? = nil,
    appSecret: SecretReference? = nil,
    accessToken: SecretReference,
    instagramUserId: String? = nil,
    pageId: String? = nil,
    scopes: [String] = []
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
      "access_token_ref", "instagram_user_id", "page_id", "scopes"
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
        scopes: Self.array(values["scopes"])
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

  public init(
    accountId: String,
    mediaType: PublishingMediaType = .image,
    imageURL: String? = nil,
    videoURL: String? = nil,
    caption: String? = nil,
    children: [String] = [],
    providerFields: [String: String] = [:]
  ) {
    self.accountId = accountId
    self.mediaType = mediaType
    self.imageURL = imageURL
    self.videoURL = videoURL
    self.caption = caption
    self.children = children
    self.providerFields = providerFields
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

  public init(id: String? = nil, statusCode: ContainerStatusCode? = nil, status: String? = nil) {
    self.id = id
    self.statusCode = statusCode
    self.status = status
  }

  enum CodingKeys: String, CodingKey {
    case id, status
    case statusCode = "status_code"
  }
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

public struct HTTPRequest: Sendable {
  public var method: HTTPMethod
  public var path: String
  public var query: [(String, String)]
  public var headers: [String: String]
  public var body: Data?

  public init(method: HTTPMethod, path: String, query: [(String, String)] = [], headers: [String: String] = [:], body: Data? = nil) {
    self.method = method
    self.path = path
    self.query = query
    self.headers = headers
    self.body = body
  }

  public func url(baseURL: URL) throws -> URL {
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

public struct URLSessionHTTPTransport: HTTPTransport {
  public var baseURL: URL

  public init(baseURL: URL = URL(string: "https://graph.facebook.com/\(metaGraphAPIVersion)")!) {
    self.baseURL = baseURL
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    let url = try request.url(baseURL: baseURL)
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method.rawValue
    for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
    urlRequest.httpBody = request.body
    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse else {
      throw InstagramGatewayError.transportFailed("Response was not HTTP")
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
    request.headers["Authorization"] = "Bearer \(token)"
    let response: HTTPResponse
    do {
      response = try await transport.send(request)
    } catch {
      throw InstagramGatewayError.transportFailed(redactor.redacting(error.localizedDescription))
    }
    guard (200..<300).contains(response.statusCode) else {
      let detail = (try? decoder.decode(MetaAPIErrorPayload.self, from: response.body).error).map { detail in
        MetaAPIErrorDetail(
          message: redactor.redacting(detail.message),
          type: detail.type,
          code: detail.code,
          errorSubcode: detail.errorSubcode,
          fbtraceId: detail.fbtraceId
        )
      }
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

  public init(client: InstagramGatewayClient) {
    self.client = client
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

  private func listQuery(fields: String, limit: Int?, after: String?) -> [(String, String)] {
    var query = [("fields", fields)]
    if let limit { query.append(("limit", String(limit))) }
    if let after { query.append(("after", after)) }
    return query
  }
}

public struct InstagramWriterService: Sendable {
  public var client: InstagramGatewayClient

  public init(client: InstagramGatewayClient) {
    self.client = client
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
    for (key, value) in input.providerFields.sorted(by: { $0.key < $1.key }) {
      query.append((key, value))
    }
    return try await client.request(HTTPRequest(method: .post, path: "\(input.accountId)/media", query: query), as: MediaContainer.self)
  }

  public func createMediaContainer(accountId: String, imageURL: String, caption: String?) async throws -> MediaContainer {
    try await createMediaContainer(CreateMediaContainerInput(accountId: accountId, imageURL: imageURL, caption: caption))
  }

  public func containerStatus(containerId: String) async throws -> MediaContainerStatus {
    try await client.request(HTTPRequest(method: .get, path: containerId, query: [("fields", "id,status_code,status")]), as: MediaContainerStatus.self)
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
}

private extension Optional where Wrapped == String {
  func required(_ name: String) throws -> String {
    guard let self, !self.isEmpty else {
      throw InstagramGatewayError.configurationInvalid("Missing required \(name)")
    }
    return self
  }
}
