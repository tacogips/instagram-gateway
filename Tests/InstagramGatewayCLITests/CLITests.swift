import CryptoKit
import Foundation
import Testing
@testable import InstagramGatewayCore
@testable import InstagramGatewayCLI

@Test func readerHelpExposesReadCommandsOnly() async throws {
  let result = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--help"])
  #expect(result.status == 0)
  #expect(result.text.contains("accounts pages"))
  #expect(!result.text.contains("create-container"))
  #expect(result.text.contains("hashtags search"))
  #expect(result.text.contains("oembed get"))
}

@Test func readerOEmbedUsesReaderCredential() async throws {
  let transport = RecordingHTTPTransport(responses: [HTTPResponse(statusCode: 200, body: Data(#"{"version":"1.0","type":"rich","html":"<blockquote>"}"#.utf8))])
  let runtime = InstagramGatewayCLI.Runtime(loader: fixtureLoader(), resolver: SecretResolver(environment: { _ in nil }, kinko: { reference in reference == "oembed-token" ? "oembed-token" : "reader-token" }), transport: { _ in transport })
  let result = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "oembed", "get", "--url", "https://www.instagram.com/p/example/"], runtime: runtime)
  #expect(result.text.contains(#""type":"rich""#))
  #expect(await transport.requests.first?.path == "instagram_oembed")
  #expect(await transport.requests.first?.headers["Authorization"] == "Bearer oembed-token")
}

@Test func writerMutationsFailBeforeCredentialResolutionWithoutYes() async {
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["messaging", "send", "--text", "nope"])
  }
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["media", "upload-resumable"])
  }
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["subscriptions", "delete", "--account", "1"])
  }
}

@Test func writerTemplateAndShoppingPreflightRejectBeforeTransport() async throws {
  let input = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("instagram-gateway-template-\(UUID().uuidString)")
  try Data(#"{"text":"Choose","buttons":[{"type":"postback","title":"Help","payload":"help"}]}"#.utf8).write(to: input)
  defer { try? FileManager.default.removeItem(at: input) }
  let transport = RecordingHTTPTransport()
  let runtime = InstagramGatewayCLI.Runtime(loader: fixtureLoader(defaultCredential: "writer"), resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "writer-token" }), transport: { _ in transport })
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "send", "--yes", "--recipient-id", "2", "--template-input", input.path, "--template-kind", "button"], runtime: runtime)
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "shopping", "update-product-tags", "--yes", "--account", "other", "--media-id", "2", "--product-tags-json", input.path], runtime: runtime)
  }
  let requests = await transport.requests
  #expect(requests.count == 1)
  #expect(String(data: requests[0].body ?? Data(), encoding: .utf8)?.contains(#""template_type":"button""#) == true)
}

@Test func shoppingMutationsRequireOwnedFixtureBeforeTransport() async throws {
  let transport = RecordingHTTPTransport()
  let runtime = InstagramGatewayCLI.Runtime(
    loader: fixtureLoader(defaultCredential: "writer", ownedCommerceFixture: false),
    resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "writer-token" }),
    transport: { _ in transport }
  )
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "shopping", "appeal", "--yes", "--account", "ig"], runtime: runtime)
  }
  #expect(await transport.requests.isEmpty)
}

@Test func taggedContainerRequiresOwnedFixtureBeforeTransport() async throws {
  let transport = RecordingHTTPTransport()
  let runtime = InstagramGatewayCLI.Runtime(
    loader: fixtureLoader(defaultCredential: "writer", ownedCommerceFixture: false),
    resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "writer-token" }),
    transport: { _ in transport }
  )
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "media", "create-container", "--account", "ig", "--image-url", "https://example.test/image.jpg", "--product-tags-json", #"[{"product_id":"3","x":0.5,"y":0.5}]"#, "--yes"], runtime: runtime)
  }
  #expect(await transport.requests.isEmpty)
}

@Test func messagingCLIPermissionMatrixRejectsBeforeTransport() async throws {
  let transport = RecordingHTTPTransport()
  let runtime = InstagramGatewayCLI.Runtime(
    loader: fixtureLoader(
      defaultCredential: "writer",
      writerScopes: #"["instagram_basic", "instagram_manage_messages"]"#
    ),
    resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "writer-token" }),
    transport: { _ in transport }
  )
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "send", "--yes", "--recipient-id", "2", "--text", "hello"], runtime: runtime)
  }
  #expect(await transport.requests.isEmpty)
}

@Test func messagingReaderPermissionMatrixRejectsBothLoginModesBeforeTransport() async throws {
  let facebookTransport = RecordingHTTPTransport()
  let facebookRuntime = InstagramGatewayCLI.Runtime(
    loader: fixtureLoader(readerScopes: #"["instagram_basic", "instagram_manage_messages"]"#),
    resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "reader-token" }),
    transport: { _ in facebookTransport }
  )
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "messaging", "conversations"], runtime: facebookRuntime)
  }
  #expect(await facebookTransport.requests.isEmpty)

  let instagramTransport = RecordingHTTPTransport()
  let instagramRuntime = InstagramGatewayCLI.Runtime(
    loader: fixtureLoader(readerScopes: #"["instagram_business_basic"]"#, loginMode: "instagram"),
    resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "reader-token" }),
    transport: { _ in instagramTransport }
  )
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "messaging", "user-profile", "get", "--instagram-scoped-user-id", "2"], runtime: instagramRuntime)
  }
  #expect(await instagramTransport.requests.isEmpty)
}

@Test func messagingReaderAndVariantCLILeavesUseTypedRequests() async throws {
  let quickReplies = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("instagram-gateway-quick-replies-\(UUID().uuidString).json")
  try Data(#"[{"content_type":"text","title":"One","payload":"one"}]"#.utf8).write(to: quickReplies)
  defer { try? FileManager.default.removeItem(at: quickReplies) }
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"data":[]}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"id":"2","username":"person"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"m1"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"m2"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"m3"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"m4"}"#.utf8))
  ])
  let readerRuntime = InstagramGatewayCLI.Runtime(loader: fixtureLoader(), resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "reader-token" }), transport: { _ in transport })
  _ = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "messaging", "conversation", "find", "--instagram-scoped-user-id", "2"], runtime: readerRuntime)
  _ = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "messaging", "user-profile", "get", "--instagram-scoped-user-id", "2"], runtime: readerRuntime)
  let writerRuntime = InstagramGatewayCLI.Runtime(loader: fixtureLoader(defaultCredential: "writer"), resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "writer-token" }), transport: { _ in transport })
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "send", "attachment", "--yes", "--recipient-id", "2", "--attachment-id", "3"], runtime: writerRuntime)
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "send", "published-post", "--yes", "--recipient-id", "2", "--owned-media-id", "4"], runtime: writerRuntime)
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "send", "sticker", "--yes", "--recipient-id", "2"], runtime: writerRuntime)
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "send", "quick-replies", "--yes", "--recipient-id", "2", "--text", "Choose", "--input", quickReplies.path], runtime: writerRuntime)
  let requests = await transport.requests
  #expect(requests[0].query.contains(where: { $0.0 == "user_id" && $0.1 == "2" }))
  #expect(requests[1].path == "2")
  #expect(String(data: requests[2].body ?? Data(), encoding: .utf8)?.contains("attachment_id") == true)
  #expect(String(data: requests[3].body ?? Data(), encoding: .utf8)?.contains("MEDIA_SHARE") == true)
  #expect(String(data: requests[4].body ?? Data(), encoding: .utf8)?.contains("heart") == true)
  #expect(String(data: requests[5].body ?? Data(), encoding: .utf8)?.contains("quick_replies") == true)
}

@Test func messagingNestedCLILeavesRouteToTypedSDKOperations() async throws {
  let iceBreakers = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("instagram-gateway-ice-breakers-\(UUID().uuidString).json")
  try Data(#"[{"question":"Help","payload":"help"}]"#.utf8).write(to: iceBreakers)
  defer { try? FileManager.default.removeItem(at: iceBreakers) }
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"data":[]}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"messages":{"data":[]}}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"ice_breakers":[]}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"persistent_menu":[]}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"r"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"u"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"a"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"attachment_id":"x"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"success":true}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"success":true}"#.utf8))
  ])
  let reader = InstagramGatewayCLI.Runtime(loader: fixtureLoader(), resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "reader-token" }), transport: { _ in transport })
  _ = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "messaging", "conversations", "list"], runtime: reader)
  _ = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "messaging", "messages", "list", "--conversation-id", "2"], runtime: reader)
  _ = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "messaging", "ice-breakers", "get"], runtime: reader)
  _ = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "messaging", "persistent-menu", "get"], runtime: reader)
  let writer = InstagramGatewayCLI.Runtime(loader: fixtureLoader(defaultCredential: "writer", instagramUserID: "11"), resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "writer-token" }), transport: { _ in transport })
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "react", "--yes", "--recipient-igsid", "2", "--message-id", "3", "--reaction", "love"], runtime: writer)
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "unreact", "--yes", "--recipient-igsid", "2", "--message-id", "3", "--reaction", "love"], runtime: writer)
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "action", "mark-seen", "--yes", "--recipient-igsid", "2"], runtime: writer)
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "attachments", "upload", "--yes", "--recipient-igsid", "2", "--image-url", "https://example.test/a.jpg"], runtime: writer)
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "ice-breakers", "set", "--yes", "--input", iceBreakers.path], runtime: writer)
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "persistent-menu", "delete", "--yes"], runtime: writer)
  let requests = await transport.requests
  #expect(requests[0].query.contains(where: { $0.0 == "platform" && $0.1 == "instagram" }))
  #expect(requests[1].path == "2")
  #expect(String(data: requests[4].body ?? Data(), encoding: .utf8)?.contains("react") == true)
  #expect(String(data: requests[5].body ?? Data(), encoding: .utf8)?.contains("unreact") == true)
  #expect(requests[7].path == "10/message_attachments")
}

@Test func messagingCLICompletesDetailProfileAndActionLeaves() async throws {
  let persistentMenu = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("instagram-gateway-persistent-menu-\(UUID().uuidString).json")
  try Data(#"[{"title":"Help","type":"postback","payload":"help"}]"#.utf8).write(to: persistentMenu)
  defer { try? FileManager.default.removeItem(at: persistentMenu) }
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"id":"3"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"ice_breakers":[],"persistent_menu":[]}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"p"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"s"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"t"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"o"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"success":true}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"success":true}"#.utf8))
  ])
  let reader = InstagramGatewayCLI.Runtime(loader: fixtureLoader(), resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "reader-token" }), transport: { _ in transport })
  _ = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "messaging", "messages", "get", "--message-id", "3"], runtime: reader)
  _ = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "messaging", "profile", "get"], runtime: reader)
  let writer = InstagramGatewayCLI.Runtime(loader: fixtureLoader(defaultCredential: "writer", instagramUserID: "11"), resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "writer-token" }), transport: { _ in transport })
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "private-reply", "--yes", "--comment-id", "3", "--text", "private"], runtime: writer)
  for action in ["mark-seen", "typing-on", "typing-off"] {
    _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "action", action, "--yes", "--recipient-igsid", "2"], runtime: writer)
  }
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "ice-breakers", "delete", "--yes"], runtime: writer)
  _ = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--config", "fixture.toml", "messaging", "persistent-menu", "set", "--yes", "--input", persistentMenu.path], runtime: writer)
  let requests = await transport.requests
  #expect(requests[0].path == "3")
  #expect(requests[1].path == "10/messenger_profile")
  #expect(requests[2].path == "11/messages")
  #expect(String(data: requests[3].body ?? Data(), encoding: .utf8)?.contains("mark_seen") == true)
  #expect(String(data: requests[4].body ?? Data(), encoding: .utf8)?.contains("typing_on") == true)
  #expect(String(data: requests[5].body ?? Data(), encoding: .utf8)?.contains("typing_off") == true)
  #expect(requests[6].path == "10/messenger_profile")
  #expect(requests[7].path == "10/messenger_profile")
}

@Test func messagingCLIUsesNestedFindAndConsentProfileLeaves() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"data":[]}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"id":"2","username":"self"}"#.utf8))
  ])
  let runtime = InstagramGatewayCLI.Runtime(loader: fixtureLoader(), resolver: SecretResolver(environment: { _ in nil }, kinko: { _ in "reader-token" }), transport: { _ in transport })
  _ = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "messaging", "conversations", "find", "--recipient-igsid", "2"], runtime: runtime)
  _ = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "messaging", "profile", "get", "--recipient-igsid", "2"], runtime: runtime)
  let requests = await transport.requests
  #expect(requests[0].query.contains(where: { $0.0 == "platform" && $0.1 == "instagram" }))
  #expect(requests[0].query.contains(where: { $0.0 == "user_id" && $0.1 == "2" }))
  #expect(requests[1].path == "2")
}

@Test func webhookReaderUsesExactBodyFileAndConfiguredAppSecret() async throws {
  let body = Data(#"{"object":"instagram","entry":[]}"#.utf8)
  let signature = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data("app-secret".utf8))).map { String(format: "%02x", $0) }.joined()
  let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("instagram-gateway-webhook-\(UUID().uuidString)")
  try body.write(to: path)
  defer { try? FileManager.default.removeItem(at: path) }
  let runtime = InstagramGatewayCLI.Runtime(
    loader: fixtureLoader(),
    resolver: SecretResolver(environment: { _ in nil }, kinko: { reference in reference == "app-secret" ? "app-secret" : "reader-token" }),
    transport: { _ in RecordingHTTPTransport() }
  )
  let result = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--config", "fixture.toml", "webhooks", "decode", "--body-file", path.path, "--signature", "sha256=\(signature)"], runtime: runtime)
  #expect(result.text.contains(#""object":"instagram""#))
}

@Test func writerHelpListsResumableCommandsReaderDoesNot() async throws {
  let writer = try await InstagramGatewayCLI.handle(binary: .writer, arguments: ["--help"])
  let reader = try await InstagramGatewayCLI.handle(binary: .reader, arguments: ["--help"])
  #expect(writer.text.contains("create-resumable-container"))
  #expect(writer.text.contains("upload-resumable"))
  #expect(!reader.text.contains("upload-resumable"))
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

private func fixtureLoader(defaultCredential: String = "reader", ownedCommerceFixture: Bool = true, writerScopes: String = #"["instagram_content_publish", "instagram_basic", "instagram_manage_comments", "instagram_manage_messages", "pages_manage_metadata", "pages_read_engagement"]"#, readerScopes: String = #"["instagram_basic", "instagram_manage_messages", "pages_manage_metadata"]"#, loginMode: String = "facebook", instagramUserID: String = "ig") -> ConfigLoader {
  ConfigLoader(fileReader: { _ in
    """
    default_credential = "\(defaultCredential)"

    [[credentials]]
    id = "reader"
    provider = "meta-instagram"
    login_type = "\(loginMode)"
    access_mode = "read"
    access_token_ref = "kinko:reader-token"
    app_secret_ref = "kinko:app-secret"
    oembed_access_token_ref = "kinko:oembed-token"
    instagram_user_id = "\(instagramUserID)"
    page_id = "10"
    scopes = \(readerScopes)
    features = ["oembed"]

    [[credentials]]
    id = "writer"
    provider = "meta-instagram"
    login_type = "\(loginMode)"
    access_mode = "write"
    access_token_ref = "kinko:writer-token"
    instagram_user_id = "\(instagramUserID)"
    page_id = "10"
    scopes = \(writerScopes)
    features = \(ownedCommerceFixture ? "[\"owned_commerce_fixture\", \"owned_messaging_media_fixture\"]" : "[]")
    """
  })
}
