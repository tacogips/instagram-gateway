import Foundation
import Testing
@testable import InstagramGatewayCore

@Test func mediaTypePreservesUnknownValues() throws {
  let data = Data(#"{"id":"1","media_type":"THREADS_POST","media_product_type":"FEED"}"#.utf8)
  let media = try JSONDecoder().decode(InstagramMedia.self, from: data)
  #expect(media.mediaType == .unknown("THREADS_POST"))
  #expect(media.mediaProductType == .feed)
}

@Test func paginationPreservesCursors() throws {
  let data = Data(#"{"data":[{"id":"1"}],"paging":{"cursors":{"before":"b","after":"a"},"next":"https://example.test?access_token=secret"}}"#.utf8)
  let page = try JSONDecoder().decode(Page<InstagramAccount>.self, from: data)
  #expect(page.data.first?.id == "1")
  #expect(page.paging?.before == "b")
  #expect(page.paging?.after == "a")
}

@Test func redactorRemovesTokenBearingValues() {
  let redactor = SecretRedactor(secrets: ["super-secret-token"])
  let text = #"Authorization: Bearer super-secret-token https://graph.facebook.com/me?access_token=abc&client_secret=def"#
  let redacted = redactor.redacting(text)
  #expect(!redacted.contains("super-secret-token"))
  #expect(!redacted.contains("abc"))
  #expect(!redacted.contains("def"))
  #expect(redacted.contains("<redacted>"))
}

@Test func configLoadsCredentialProfilesAndModes() throws {
  let toml = """
  default_credential = "reader"

  [[credentials]]
  id = "reader"
  provider = "meta-instagram"
  access_mode = "read"
  access_token_ref = "env:READER_TOKEN"
  instagram_user_id = "ig"
  page_id = "page"
  scopes = ["instagram_basic"]
  """
  let config = try ConfigLoader().parseTOML(toml)
  #expect(config.defaultProfileId == "reader")
  #expect(try config.profile(requiredMode: .read).accessMode == .read)
  #expect(throws: InstagramGatewayError.self) {
    _ = try config.profile(requiredMode: .write)
  }
}

@Test func requestBuilderEncodesURLAndAuthorization() async throws {
  let transport = RecordingHTTPTransport(responses: [HTTPResponse(statusCode: 200, body: Data(#"{"data":[]}"#.utf8))])
  let client = InstagramGatewayClient(transport: transport, token: "token")
  let reader = InstagramReaderService(client: client)
  _ = try await reader.media(accountId: "1784", limit: 5, after: "cursor")
  let requests = await transport.requests
  #expect(requests.first?.path == "1784/media")
  #expect(requests.first?.headers["Authorization"] == "Bearer token")
  #expect(requests.first?.query.contains(where: { $0.0 == "limit" && $0.1 == "5" }) == true)
}

@Test func readerBuildsStoriesAndTaggedMediaRequests() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"data":[]}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"data":[]}"#.utf8))
  ])
  let reader = InstagramReaderService(client: InstagramGatewayClient(transport: transport, token: "token"))
  _ = try await reader.stories(accountId: "ig")
  _ = try await reader.taggedMedia(accountId: "ig")
  let requests = await transport.requests
  #expect(requests[0].path == "ig/stories")
  #expect(requests[1].path == "ig/tags")
}

@Test func providerErrorsMapToTypedError() async throws {
  let body = Data(#"{"error":{"message":"bad token","type":"OAuthException","code":190,"fbtrace_id":"trace"}}"#.utf8)
  let transport = RecordingHTTPTransport(responses: [HTTPResponse(statusCode: 401, body: body)])
  let client = InstagramGatewayClient(transport: transport, token: "token")
  await #expect(throws: InstagramGatewayError.self) {
    let _: InstagramAccount = try await client.request(HTTPRequest(method: .get, path: "me"), as: InstagramAccount.self)
  }
}

@Test func providerErrorMessagesAreRedactedBeforeThrowing() async throws {
  let body = Data(#"{"error":{"message":"bad https://graph.facebook.com/me?access_token=secret-token&client_secret=app-secret","type":"OAuthException","code":190}}"#.utf8)
  let transport = RecordingHTTPTransport(responses: [HTTPResponse(statusCode: 400, body: body)])
  let client = InstagramGatewayClient(transport: transport, token: "secret-token")
  do {
    let _: InstagramAccount = try await client.request(HTTPRequest(method: .get, path: "me"), as: InstagramAccount.self)
    Issue.record("Expected provider rejection")
  } catch let error as InstagramGatewayError {
    #expect(!error.message.contains("secret-token"))
    #expect(!error.message.contains("app-secret"))
    #expect(error.message.contains("<redacted>"))
  }
}

@Test func clientPreservesCallerSuppliedRedactorSecrets() async throws {
  let body = Data(#"{"error":{"message":"bad caller-secret and bearer-token","type":"OAuthException","code":190}}"#.utf8)
  let transport = RecordingHTTPTransport(responses: [HTTPResponse(statusCode: 400, body: body)])
  let client = InstagramGatewayClient(
    transport: transport,
    token: "bearer-token",
    redactor: SecretRedactor(secrets: ["caller-secret"])
  )
  do {
    let _: InstagramAccount = try await client.request(HTTPRequest(method: .get, path: "me"), as: InstagramAccount.self)
    Issue.record("Expected provider rejection")
  } catch let error as InstagramGatewayError {
    #expect(!error.message.contains("caller-secret"))
    #expect(!error.message.contains("bearer-token"))
    #expect(error.message.contains("<redacted>"))
  }
}

@Test func publicDTOInitializersConstructSDKValues() {
  let account = InstagramAccount(id: "ig", username: "user", name: "Name")
  let page = FacebookPage(id: "page", name: "Page", instagramBusinessAccount: account)
  let profile = BusinessProfile(id: "ig", username: "user", followersCount: 10, mediaCount: 2)
  let media = InstagramMedia(id: "m", caption: "caption", mediaType: .image, mediaProductType: .feed)
  let comment = InstagramComment(id: "c", text: "hello", username: "user", hidden: false)
  let metric = InsightMetric(name: "reach", period: "day", values: [InsightValue(value: .number(1), endTime: "now")])
  #expect(page.instagramBusinessAccount == account)
  #expect(profile.followersCount == 10)
  #expect(media.mediaType == .image)
  #expect(comment.hidden == false)
  #expect(InsightsResponse(data: [metric]).data.first?.name == "reach")
  #expect(MediaContainer(id: "container").id == "container")
  #expect(MediaContainerStatus(id: "container", statusCode: .finished, status: "Finished").statusCode == .finished)
  #expect(PublishedMedia(id: "published").id == "published")
  #expect(CommentReply(id: "reply").id == "reply")
  #expect(ModerationResult(success: true).success)
  #expect(CreateMediaContainerInput(accountId: "ig", mediaType: .video, videoURL: "https://example.test/video.mp4").mediaType == .video)
  #expect(PublishMediaContainerInput(accountId: "ig", containerId: "container").containerId == "container")
  #expect(ReplyToCommentInput(accountId: "ig", commentId: "comment", message: "hello").message == "hello")
  #expect(ModerateCommentInput(accountId: "ig", commentId: "comment", action: .hide).action == .hide)
}

@Test func writerBuildsModerationRequest() async throws {
  let transport = RecordingHTTPTransport(responses: [HTTPResponse(statusCode: 200, body: Data(#"{"success":true}"#.utf8))])
  let writer = InstagramWriterService(client: InstagramGatewayClient(transport: transport, token: "token"))
  let result = try await writer.moderate(accountId: "ig", commentId: "comment", action: .hide)
  #expect(result.success)
  let requests = await transport.requests
  #expect(requests.first?.method == .post)
  #expect(requests.first?.path == "comment")
  #expect(requests.first?.query.contains(where: { $0.0 == "hide" && $0.1 == "true" }) == true)
}

@Test func writerInputDTOBuildsVideoContainerRequest() async throws {
  let transport = RecordingHTTPTransport(responses: [HTTPResponse(statusCode: 200, body: Data(#"{"id":"container"}"#.utf8))])
  let writer = InstagramWriterService(client: InstagramGatewayClient(transport: transport, token: "token"))
  let input = CreateMediaContainerInput(
    accountId: "ig",
    mediaType: .video,
    videoURL: "https://example.test/video.mp4",
    caption: "caption",
    providerFields: ["share_to_feed": "true"]
  )
  let container = try await writer.createMediaContainer(input)
  let requests = await transport.requests
  #expect(container.id == "container")
  #expect(requests.first?.path == "ig/media")
  #expect(requests.first?.query.contains(where: { $0.0 == "video_url" && $0.1 == "https://example.test/video.mp4" }) == true)
  #expect(requests.first?.query.contains(where: { $0.0 == "media_type" && $0.1 == "REELS" }) == true)
  #expect(requests.first?.query.contains(where: { $0.0 == "share_to_feed" && $0.1 == "true" }) == true)
}

@Test func writerBuildsStoryAndCarouselItemContainers() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"id":"story"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"id":"child"}"#.utf8))
  ])
  let writer = InstagramWriterService(client: InstagramGatewayClient(transport: transport, token: "token"))
  _ = try await writer.createMediaContainer(CreateMediaContainerInput(
    accountId: "ig", mediaType: .storyVideo, videoURL: "https://example.test/story.mp4"
  ))
  _ = try await writer.createMediaContainer(CreateMediaContainerInput(
    accountId: "ig", mediaType: .carouselImage, imageURL: "https://example.test/child.jpg"
  ))
  let requests = await transport.requests
  #expect(requests[0].query.contains(where: { $0.0 == "media_type" && $0.1 == "STORIES" }))
  #expect(requests[1].query.contains(where: { $0.0 == "is_carousel_item" && $0.1 == "true" }))
}

@Test func writerCanDisableMediaComments() async throws {
  let transport = RecordingHTTPTransport(responses: [HTTPResponse(statusCode: 200, body: Data(#"{"success":true}"#.utf8))])
  let writer = InstagramWriterService(client: InstagramGatewayClient(transport: transport, token: "token"))
  let result = try await writer.setCommentsEnabled(mediaId: "media", enabled: false)
  let requests = await transport.requests
  #expect(result.success)
  #expect(requests.first?.query.contains(where: { $0.0 == "comments" && $0.1 == "false" }) == true)
}

@Test func transportErrorsAreRedactedBeforeThrowing() async throws {
  let transport = ThrowingHTTPTransport(message: "Authorization: Bearer bearer-token caller-secret access_token=bearer-token&client_secret=caller-secret")
  let client = InstagramGatewayClient(
    transport: transport,
    token: "bearer-token",
    redactor: SecretRedactor(secrets: ["caller-secret"])
  )
  do {
    let _: InstagramAccount = try await client.request(HTTPRequest(method: .get, path: "me"), as: InstagramAccount.self)
    Issue.record("Expected transport failure")
  } catch let error as InstagramGatewayError {
    #expect(error.code == "TRANSPORT_FAILED")
    #expect(!error.message.contains("bearer-token"))
    #expect(!error.message.contains("caller-secret"))
    #expect(error.message.contains("<redacted>"))
  }
}

private struct ThrowingHTTPTransport: HTTPTransport {
  var message: String

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    throw TransportFixtureError(message: message)
  }
}

private struct TransportFixtureError: LocalizedError {
  var message: String

  var errorDescription: String? {
    message
  }
}
