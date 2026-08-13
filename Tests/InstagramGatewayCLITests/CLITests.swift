import Foundation
import Testing
@testable import InstagramGatewayCore
@testable import InstagramGatewayCLI

@Test func readerHelpExposesReadCommandsOnly() async throws {
  let result = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--help"])
  #expect(result.status == 0)
  #expect(result.text.contains("accounts pages"))
  #expect(!result.text.contains("create-container"))
}

@Test func writerRequiresYesForStateChanges() async {
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["media", "publish"])
  }
}

@Test func writerCreateContainerRequiresYes() async {
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["media", "create-container"])
  }
}

@Test func readerRejectsWriterCommands() async {
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["media", "publish"])
  }
}

@Test func versionProducesJSONEnvelope() async throws {
  let result = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["version"])
  #expect(result.text.contains(#""ok":true"#))
  #expect(result.text.contains(#""version":"0.1.0"#))
}

@Test func readerMediaListExecutesServiceRequest() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"data":[{"id":"m1","media_type":"IMAGE"}],"paging":{"cursors":{"after":"next"},"next":"https://graph.facebook.com/v23.0/ig/media?access_token=reader-token&client_secret=app-secret"}}"#.utf8))
  ])
  let runtime = InstagramGatewayCLI.Runtime(
    loader: fixtureLoader(),
    resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "reader-token" }),
    transport: { _ in transport }
  )
  let result = try await InstagramGatewayCLI.handle(
    binary: .reader,
    arguments: ["--config", "fixture.toml", "media", "list", "--account-id", "ig", "--limit", "5"],
    runtime: runtime
  )
  let requests = await transport.requests
  #expect(result.status == 0)
  #expect(result.text.contains(#""id":"m1""#))
  #expect(!result.text.contains("reader-token"))
  #expect(!result.text.contains("app-secret"))
  #expect(result.text.contains("<redacted>"))
  #expect(requests.first?.path == "ig/media")
  #expect(requests.first?.headers["Authorization"] == "Bearer reader-token")
}

@Test func readerBusinessDiscoveryExecutesServiceRequest() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"business_discovery":{"id":"biz","username":"target","followers_count":42,"media_count":7}}"#.utf8))
  ])
  let runtime = InstagramGatewayCLI.Runtime(
    loader: fixtureLoader(),
    resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "reader-token" }),
    transport: { _ in transport }
  )
  let result = try await InstagramGatewayCLI.handle(
    binary: .reader,
    arguments: ["--config", "fixture.toml", "accounts", "business-discovery", "--username", "target"],
    runtime: runtime
  )
  let requests = await transport.requests
  #expect(result.status == 0)
  #expect(result.text.contains(#""username":"target""#))
  #expect(result.text.contains(#""followers_count":42"#))
  #expect(requests.first?.path == "ig")
  #expect(requests.first?.query.contains(where: { $0.0 == "fields" && $0.1.contains("business_discovery.username(target)") }) == true)
  #expect(requests.first?.headers["Authorization"] == "Bearer reader-token")
}

@Test func writerHideExecutesServiceRequestWithConfirmation() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"success":true}"#.utf8))
  ])
  let runtime = InstagramGatewayCLI.Runtime(
    loader: fixtureLoader(defaultCredential: "writer"),
    resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "writer-token" }),
    transport: { _ in transport }
  )
  let result = try await InstagramGatewayCLI.handle(
    binary: .writer,
    arguments: ["--config", "fixture.toml", "comments", "hide", "--account", "ig", "--comment-id", "c1", "--yes"],
    runtime: runtime
  )
  let requests = await transport.requests
  #expect(result.status == 0)
  #expect(result.text.contains(#""success":true"#))
  #expect(requests.first?.path == "c1")
  #expect(requests.first?.query.contains(where: { $0.0 == "hide" && $0.1 == "true" }) == true)
}

@Test func writerReplyExecutesServiceRequestWithAccountAndConfirmation() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"id":"reply"}"#.utf8))
  ])
  let runtime = InstagramGatewayCLI.Runtime(
    loader: fixtureLoader(defaultCredential: "writer"),
    resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "writer-token" }),
    transport: { _ in transport }
  )
  let result = try await InstagramGatewayCLI.handle(
    binary: .writer,
    arguments: ["--config", "fixture.toml", "comments", "reply", "--account", "ig", "--comment-id", "c1", "--message", "hello", "--yes"],
    runtime: runtime
  )
  let requests = await transport.requests
  #expect(result.status == 0)
  #expect(result.text.contains(#""id":"reply""#))
  #expect(requests.first?.method == .post)
  #expect(requests.first?.path == "c1/replies")
  #expect(requests.first?.query.contains(where: { $0.0 == "message" && $0.1 == "hello" }) == true)
}

@Test func writerCommentCommandsRequireAccount() async {
  let runtime = InstagramGatewayCLI.Runtime(
    loader: fixtureLoader(defaultCredential: "writer"),
    resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "writer-token" }),
    transport: { _ in RecordingHTTPTransport() }
  )
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await InstagramGatewayCLI.handle(
      binary: .writer,
      arguments: ["--config", "fixture.toml", "comments", "reply", "--comment-id", "c1", "--message", "hello", "--yes"],
      runtime: runtime
    )
  }
}

@Test func writerCreateContainerExecutesServiceRequestWithConfirmation() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"id":"container"}"#.utf8))
  ])
  let runtime = InstagramGatewayCLI.Runtime(
    loader: fixtureLoader(defaultCredential: "writer"),
    resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "writer-token" }),
    transport: { _ in transport }
  )
  let result = try await InstagramGatewayCLI.handle(
    binary: .writer,
    arguments: ["--config", "fixture.toml", "media", "create-container", "--account", "ig", "--image-url", "https://example.test/image.jpg", "--caption", "caption", "--yes"],
    runtime: runtime
  )
  let requests = await transport.requests
  #expect(result.status == 0)
  #expect(result.text.contains(#""id":"container""#))
  #expect(requests.first?.method == .post)
  #expect(requests.first?.path == "ig/media")
  #expect(requests.first?.query.contains(where: { $0.0 == "image_url" && $0.1 == "https://example.test/image.jpg" }) == true)
  #expect(requests.first?.query.contains(where: { $0.0 == "caption" && $0.1 == "caption" }) == true)
}

@Test func writerCreatesReelFromCLIOptions() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"id":"reel-container"}"#.utf8))
  ])
  let runtime = InstagramGatewayCLI.Runtime(
    loader: fixtureLoader(defaultCredential: "writer"),
    resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "writer-token" }),
    transport: { _ in transport }
  )
  _ = try await InstagramGatewayCLI.handle(
    binary: .writer,
    arguments: ["--config", "fixture.toml", "media", "create-container", "--account", "ig", "--type", "reel", "--video-url", "https://example.test/reel.mp4", "--share-to-feed", "--yes"],
    runtime: runtime
  )
  let request = await transport.requests.first
  #expect(request?.query.contains(where: { $0.0 == "media_type" && $0.1 == "REELS" }) == true)
  #expect(request?.query.contains(where: { $0.0 == "share_to_feed" && $0.1 == "true" }) == true)
}

@Test func configParserRejectsUnknownKeys() throws {
  #expect(throws: InstagramGatewayError.self) {
    _ = try ConfigLoader().parseTOML("""
    default_credential = "reader"
    unexpected = "value"
    """)
  }
}

private func fixtureLoader(defaultCredential: String = "reader") -> ConfigLoader {
  ConfigLoader(fileReader: { _ in
    """
    default_credential = "\(defaultCredential)"

    [[credentials]]
    id = "reader"
    provider = "meta-instagram"
    access_mode = "read"
    access_token_ref = "kinko:reader-token"
    instagram_user_id = "ig"
    page_id = "page"
    scopes = ["instagram_basic"]

    [[credentials]]
    id = "writer"
    provider = "meta-instagram"
    access_mode = "write"
    access_token_ref = "kinko:writer-token"
    instagram_user_id = "ig"
    page_id = "page"
    scopes = ["instagram_content_publish", "instagram_manage_comments"]
    """
  })
}
