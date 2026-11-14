import CryptoKit
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

@Test func hashtagAndMentionRequestsAreTypedAndValidated() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"data":[{"id":"tag","name":"swift"}]}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"mentioned_media":{"id":"m","media_type":"IMAGE"}}"#.utf8))
  ])
  let reader = InstagramReaderService(client: InstagramGatewayClient(transport: transport, token: "token"))
  #expect(try await reader.searchHashtags(accountId: "123", query: "swift").data.first?.name == "swift")
  #expect(try await reader.mentionedMedia(accountId: "123").mentionedMedia?.mediaType == .image)
  let requests = await transport.requests
  #expect(requests[0].path == "ig_hashtag_search")
  #expect(requests[1].query.first?.1 == "mentioned_media{id,caption,media_type,media_url,permalink}")
}

@Test func oEmbedRejectsTokenURLsBeforeNetwork() async throws {
  let transport = RecordingHTTPTransport()
  let reader = InstagramReaderService(client: InstagramGatewayClient(transport: transport, token: "token"))
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await reader.oEmbed(InstagramOEmbedRequest(url: "https://instagram.com/p/x?access_token=secret"))
  }
  #expect(await transport.requests.isEmpty)
}

@Test func webhookSignatureIsVerifiedBeforeDecoding() throws {
  let secret = "app-secret"
  let body = Data(#"{"object":"instagram","entry":[]}"#.utf8)
  let digest = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8))).map { String(format: "%02x", $0) }.joined()
  let decoder = InstagramWebhookDecoder()
  #expect(try decoder.verifyAndDecode(body: body, signatureHeader: "sha256=\(digest)", appSecret: secret).object == "instagram")
  #expect(throws: InstagramGatewayError.self) { _ = try decoder.verifyAndDecode(body: body, signatureHeader: "sha256=" + String(repeating: "0", count: 64), appSecret: secret) }
}

@Test func loginHostAndSubscriptionPreflightAreTyped() async throws {
  #expect(try URLSessionHTTPTransport.baseURL(loginType: .instagram).host == "graph.instagram.com")
  #expect(try URLSessionHTTPTransport.baseURL(loginType: .facebook).host == "graph.facebook.com")
  #expect(throws: InstagramGatewayError.self) { _ = try URLSessionHTTPTransport.baseURL(loginType: .unknown("other")) }
  let transport = RecordingHTTPTransport()
  let service = InstagramWebhookSubscriptionService(client: InstagramGatewayClient(transport: transport, token: "token"), loginType: .facebook)
  await #expect(throws: InstagramGatewayError.self) { _ = try await service.list(accountId: "1") }
  #expect(await transport.requests.isEmpty)
}

@Test func shoppingAndMessagingBuildTypedRequests() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"data":[{"id":123,"name":"Catalog"}]}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"recipient_id":"r","message_id":"m"}"#.utf8))
  ])
  let client = InstagramGatewayClient(transport: transport, token: "token")
  let reader = InstagramReaderService(client: client)
  #expect(try await reader.availableCatalogs(accountId: "1").data.first?.id == "123")
  let writer = InstagramWriterService(client: client, messagingAuthorization: messagingAuthorization())
  let receipt = try await writer.sendMessage(actorId: "2", input: SendInstagramMessageInput(recipientId: "3", content: .text("hello")))
  #expect(receipt.messageId == "m")
  let requests = await transport.requests
  #expect(requests[0].path == "1/available_catalogs")
  #expect(requests[1].headers["Content-Type"] == "application/json")
  #expect(String(data: requests[1].body ?? Data(), encoding: .utf8)?.contains("hello") == true)
}

@Test func productTagsAndMentionCursorFailBeforeSend() async throws {
  let transport = RecordingHTTPTransport()
  let client = InstagramGatewayClient(transport: transport, token: "token")
  let writer = InstagramWriterService(client: client)
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await writer.createMediaContainer(CreateMediaContainerInput(accountId: "1", imageURL: "https://example.test/a.jpg", productTags: [ProductTagInput(productId: "x", x: 2, y: 0)]))
  }
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await writer.addOrUpdateProductTags(UpdateProductTagsInput(accountId: "1", mediaId: "2", tags: []))
  }
  let reader = InstagramReaderService(client: client)
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await reader.mentionedMedia(MentionedMediaLookup(accountId: "1", mediaId: "2", commentsAfter: "bad cursor"))
  }
  #expect(await transport.requests.isEmpty)
}

@Test func resumableURIAndStatusAreValidated() async throws {
  let status = try JSONDecoder().decode(MediaContainerStatus.self, from: Data(#"{"id":"c","video_status":{"uploading_phase":{"bytes_transferred":99}}}"#.utf8))
  #expect(status.videoStatus?.uploadingPhase?.bytesTransferred == 99)
  let transport = RecordingHTTPTransport()
  let writer = InstagramWriterService(client: InstagramGatewayClient(transport: transport, token: "token"))
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await writer.uploadResumableVideo(UploadResumableVideoInput(uploadURI: "https://evil.test/ig-api-upload/x", filePath: "/missing", offset: 0))
  }
  #expect(await transport.requests.isEmpty)
}

@Test func resumableUploadStreamsAFileSliceWithoutBuffering() async throws {
  let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("instagram-gateway-upload-(UUID().uuidString)")
  try Data(repeating: 7, count: 64).write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  let transport = RecordingHTTPTransport(responses: [HTTPResponse(statusCode: 200, body: Data(#"{"success":true}"#.utf8))])
  let writer = InstagramWriterService(client: InstagramGatewayClient(transport: transport, token: "token"))
  _ = try await writer.uploadResumableVideo(UploadResumableVideoInput(uploadURI: "https://rupload.facebook.com/ig-api-upload/v1", filePath: file.path, offset: 16))
  let request = await transport.requests.first
  #expect(request?.body == nil)
  #expect(request?.fileBody == HTTPFileBody(filePath: file.path, offset: 16))
  #expect(request?.headers["Authorization"] == "OAuth token")
}

private actor StreamedRequestProbe {
  private var bytes: [UInt8] = []
  private var redirectWasCancelled = false
  private var forwardedAuthorization: String?

  func execute(_ request: URLRequest, redirectDelegate: RedirectBlockingDelegate) throws -> (Data, HTTPURLResponse) {
    guard let stream = request.httpBodyStream else { throw InstagramGatewayError.configurationInvalid("Missing streamed body") }
    stream.open(); defer { stream.close() }
    var buffer = [UInt8](repeating: 0, count: 64)
    let count = stream.read(&buffer, maxLength: buffer.count)
    guard count >= 0 else { throw InstagramGatewayError.transportFailed("Stream read failed") }
    bytes = Array(buffer.prefix(count))
    var redirected = URLRequest(url: URL(string: "https://untrusted.example/upload")!)
    redirected.setValue(request.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: request.url!)
    let redirectResponse = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
    var followup: URLRequest?
    redirectDelegate.urlSession(session, task: task, willPerformHTTPRedirection: redirectResponse, newRequest: redirected) { followup = $0 }
    session.invalidateAndCancel()
    redirectWasCancelled = followup == nil
    forwardedAuthorization = followup?.value(forHTTPHeaderField: "Authorization")
    return (Data(#"{"success":true}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }

  func result() -> ([UInt8], Bool, String?) { (bytes, redirectWasCancelled, forwardedAuthorization) }
}

@Test func streamedRequestExecutionEnforcesOffsetAndRedirectCredentialSafety() async throws {
  let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("instagram-gateway-stream-\(UUID().uuidString)")
  try Data((0..<12).map(UInt8.init)).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
  let probe = StreamedRequestProbe()
  let transport = URLSessionHTTPTransport(baseURL: URL(string: "https://rupload.facebook.com")!, sessionExecutor: { request, redirectDelegate in
    try await probe.execute(request, redirectDelegate: redirectDelegate)
  })
  let response = try await transport.send(HTTPRequest(method: .post, path: "ig-api-upload/v1", headers: ["Authorization": "OAuth token"], fileBody: HTTPFileBody(filePath: file.path, offset: 5)))
  let (bytes, redirectWasCancelled, forwardedAuthorization) = await probe.result()
  #expect(response.statusCode == 200)
  #expect(bytes == Array(5..<12))
  #expect(redirectWasCancelled)
  #expect(forwardedAuthorization == nil)
}


@Test func webhookMessagingPayloadPreservesTypedFamilies() throws {
  let body = Data(#"{"object":"instagram","entry":[{"id":"1","time":2,"messaging":[{"sender":{"id":"3"},"recipient":{"id":"4"},"timestamp":5,"message":{"mid":"m","text":"hello"},"reaction":{"mid":"m","action":"react","reaction":"love"},"postback":{"title":"Go","payload":"p"}}],"standby":[{"sender":{"id":"3"},"message_edit":{"mid":"m"}}]}]}"#.utf8)
  let payload = try JSONDecoder().decode(InstagramWebhookPayload.self, from: body)
  #expect(payload.entries.first?.messaging.first?.message?.text == "hello")
  #expect(payload.entries.first?.messaging.first?.reaction?.reaction == "love")
  #expect(payload.entries.first?.standby.first?.messageEdit != nil)
}

@Test func messagingMutationDTOsUseTypedJSONBodies() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"reaction"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"action"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"attachment_id":"attachment"}"#.utf8))
  ])
  let writer = InstagramWriterService(client: InstagramGatewayClient(transport: transport, token: "token"), messagingAuthorization: messagingAuthorization())
  _ = try await writer.react(actorId: "1", input: SendReactionInput(recipientId: "2", messageId: "3", reaction: .love))
  _ = try await writer.senderAction(actorId: "1", input: SendSenderActionInput(recipientId: "2", action: .typingOn))
  #expect(try await writer.uploadImageAttachment(actorId: "1", input: UploadMessageAttachmentInput(recipientId: "2", imageURL: "https://example.test/a.jpg")).attachmentId == "attachment")
  let requests = await transport.requests
  #expect(String(data: requests[0].body ?? Data(), encoding: .utf8)?.contains(#""reaction":"love""#) == true)
  #expect(String(data: requests[1].body ?? Data(), encoding: .utf8)?.contains(#""sender_action":"typing_on""#) == true)
  #expect(requests[2].path == "1/message_attachments")
}

@Test func mentionFieldsRejectDuplicatesAndDecodeFlexibleCounts() async throws {
  let transport = RecordingHTTPTransport()
  let reader = InstagramReaderService(client: InstagramGatewayClient(transport: transport, token: "token"))
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await reader.mentionedMedia(MentionedMediaLookup(accountId: "1", mediaId: "2", fields: [.id, .id]))
  }
  let comment = try JSONDecoder().decode(MentionedComment.self, from: Data(#"{"id":"2","like_count":"7","timestamp":"now"}"#.utf8))
  #expect(comment.likeCount == 7)
  #expect(comment.timestamp == "now")
  #expect(await transport.requests.isEmpty)
}

@Test func messagingProfileMutationsValidateAndUseJSONBodies() async throws {
  let transport = RecordingHTTPTransport(responses: [HTTPResponse(statusCode: 200, body: Data(#"{"success":true}"#.utf8))])
  let writer = InstagramWriterService(client: InstagramGatewayClient(transport: transport, token: "token"), messagingAuthorization: messagingAuthorization())
  _ = try await writer.setIceBreakers(actorId: "1", iceBreakers: [InstagramIceBreaker(question: "Help", payload: "help")])
  let request = await transport.requests.first
  #expect(request?.path == "1/messenger_profile")
  #expect(String(data: request?.body ?? Data(), encoding: .utf8)?.contains(#""ice_breakers""#) == true)
}

@Test func messagingTemplatesAreTypedAndValidatedBeforeTransport() async throws {
  let transport = RecordingHTTPTransport(responses: [HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"template"}"#.utf8))])
  let writer = InstagramWriterService(client: InstagramGatewayClient(transport: transport, token: "token"), messagingAuthorization: messagingAuthorization())
  let button = InstagramTemplateButton(type: .postback, title: "Help", payload: "help")
  _ = try await writer.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .template(.generic([InstagramGenericTemplateElement(title: "Welcome", buttons: [button])]))) )
  let body = String(data: await transport.requests.first?.body ?? Data(), encoding: .utf8) ?? ""
  #expect(body.contains(#""template_type":"generic""#))
  #expect(body.contains(#""payload":"help""#))
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await writer.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .template(.button(text: "x", buttons: []))))
  }
  #expect(await transport.requests.count == 1)
}

@Test func messagingSDKAuthorizationFailsBeforeTransport() async throws {
  let transport = RecordingHTTPTransport()
  let authorization = InstagramMessagingAuthorization(loginType: .facebook, scopes: ["instagram_basic", "instagram_manage_messages"])
  let writer = InstagramWriterService(client: InstagramGatewayClient(transport: transport, token: "token"), messagingAuthorization: authorization)
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await writer.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .text("hello")))
  }
  #expect(await transport.requests.isEmpty)
}

@Test func messagingSDKRequiresAuthorizationAndRejectsUnknownLoginBeforeTransport() async throws {
  let transport = RecordingHTTPTransport()
  let client = InstagramGatewayClient(transport: transport, token: "token")
  let missingAuthorization = InstagramWriterService(client: client)
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await missingAuthorization.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .text("hello")))
  }
  let unknownLogin = InstagramWriterService(client: client, messagingAuthorization: InstagramMessagingAuthorization(loginType: .unknown("future"), scopes: ["instagram_basic", "instagram_manage_messages", "pages_manage_metadata"]))
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await unknownLogin.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .text("hello")))
  }
  #expect(await transport.requests.isEmpty)
}

@Test func messagingAuthorizationUsesAcceptedLoginSpecificScopeMatrix() throws {
  try InstagramMessagingAuthorization(
    loginType: .instagram,
    scopes: ["instagram_business_basic", "instagram_business_manage_messages"]
  ).validate(.send)
  try InstagramMessagingAuthorization(
    loginType: .instagram,
    scopes: ["instagram_business_basic", "instagram_business_manage_comments"]
  ).validate(.privateReply)
  try InstagramMessagingAuthorization(
    loginType: .facebook,
    scopes: ["instagram_basic", "instagram_manage_messages", "pages_manage_metadata"]
  ).validate(.send)
  try InstagramMessagingAuthorization(
    loginType: .facebook,
    scopes: ["instagram_basic", "instagram_manage_comments", "pages_read_engagement"]
  ).validate(.privateReply)
  #expect(throws: InstagramGatewayError.self) {
    try InstagramMessagingAuthorization(loginType: .instagram, scopes: ["instagram_manage_messages"]).validate(.send)
  }
  #expect(throws: InstagramGatewayError.self) {
    try InstagramMessagingAuthorization(loginType: .facebook, scopes: ["instagram_basic", "instagram_manage_messages"]).validate(.send)
  }
  #expect(throws: InstagramGatewayError.self) {
    try InstagramMessagingAuthorization(loginType: .facebook, scopes: ["instagram_basic", "instagram_manage_comments"]).validate(.privateReply)
  }
}

@Test func messagingSendDerivesLoginFromAuthorizationAndRejectsMismatchesBeforeTransport() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"instagram"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"facebook"}"#.utf8))
  ])
  let instagram = InstagramWriterService(
    client: InstagramGatewayClient(transport: transport, token: "token"),
    messagingAuthorization: InstagramMessagingAuthorization(loginType: .instagram, scopes: ["instagram_business_basic", "instagram_business_manage_messages"])
  )
  _ = try await instagram.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .text("hello")))
  let facebook = InstagramWriterService(
    client: InstagramGatewayClient(transport: transport, token: "token"),
    messagingAuthorization: messagingAuthorization()
  )
  _ = try await facebook.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .text("hello")))
  let requests = await transport.requests
  #expect(String(data: requests[0].body ?? Data(), encoding: .utf8)?.contains("messaging_type") == false)
  #expect(String(data: requests[1].body ?? Data(), encoding: .utf8)?.contains(#""messaging_type":"RESPONSE""#) == true)

  let rejectedTransport = RecordingHTTPTransport()
  let rejected = InstagramWriterService(
    client: InstagramGatewayClient(transport: rejectedTransport, token: "token"),
    messagingAuthorization: messagingAuthorization()
  )
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await rejected.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .text("hello")), loginType: .instagram)
  }
  await #expect(throws: InstagramGatewayError.self) {
    _ = try await rejected.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .text("hello")), loginType: .unknown("future"))
  }
  #expect(await rejectedTransport.requests.isEmpty)
}

@Test func messagingReaderAuthorizationAppliesToBothLoginModesBeforeTransport() async throws {
  let transport = RecordingHTTPTransport(responses: [HTTPResponse(statusCode: 200, body: Data(#"{"data":[]}"#.utf8)), HTTPResponse(statusCode: 200, body: Data(#"{"id":"3","username":"person"}"#.utf8))])
  let instagram = InstagramReaderService(client: InstagramGatewayClient(transport: transport, token: "token"), messagingAuthorization: InstagramMessagingAuthorization(loginType: .instagram, scopes: ["instagram_business_basic", "instagram_business_manage_messages"]))
  _ = try await instagram.conversations(actorId: "1", instagramScopedUserId: "2")
  let facebook = InstagramReaderService(client: InstagramGatewayClient(transport: transport, token: "token"), messagingAuthorization: InstagramMessagingAuthorization(loginType: .facebook, scopes: ["instagram_basic", "instagram_manage_messages", "pages_manage_metadata"]))
  #expect(try await facebook.messagingUserProfile(instagramScopedUserId: "3").username == "person")
  let requests = await transport.requests
  #expect(requests[0].query.contains(where: { $0.0 == "user_id" && $0.1 == "2" }))
  #expect(requests[1].path == "3")

  let rejectedTransport = RecordingHTTPTransport()
  let rejected = InstagramReaderService(client: InstagramGatewayClient(transport: rejectedTransport, token: "token"), messagingAuthorization: InstagramMessagingAuthorization(loginType: .facebook, scopes: ["instagram_basic"]))
  await #expect(throws: InstagramGatewayError.self) { _ = try await rejected.conversationMessages(conversationId: "1") }
  let unknown = InstagramReaderService(client: InstagramGatewayClient(transport: rejectedTransport, token: "token"), messagingAuthorization: InstagramMessagingAuthorization(loginType: .unknown("future"), scopes: []))
  await #expect(throws: InstagramGatewayError.self) { _ = try await unknown.messagingProfile(actorId: "1") }
  #expect(await rejectedTransport.requests.isEmpty)
}

@Test func messagingTypedSendVariantsEncodeNestedBodies() async throws {
  let transport = RecordingHTTPTransport(responses: Array(repeating: HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"m"}"#.utf8)), count: 4))
  let writer = InstagramWriterService(client: InstagramGatewayClient(transport: transport, token: "token"), messagingAuthorization: InstagramMessagingAuthorization(loginType: .facebook, scopes: ["instagram_basic", "instagram_manage_messages", "pages_manage_metadata"], features: ["owned_messaging_media_fixture"]))
  _ = try await writer.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .uploadedImage(attachmentId: "3")))
  _ = try await writer.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .publishedPost(mediaId: "4")))
  _ = try await writer.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .heartSticker))
  _ = try await writer.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .quickReplies(text: "Choose", replies: [InstagramQuickReply(title: "One", payload: "one")])))
  let bodies = await transport.requests.map { String(data: $0.body ?? Data(), encoding: .utf8) ?? "" }
  #expect(bodies[0].contains(#""attachment_id":"3""#))
  #expect(bodies[1].contains("MEDIA_SHARE"))
  #expect(bodies[2].contains(#""template_type":"heart""#))
  #expect(bodies[3].contains(#""quick_replies""#))

  let rejectedTransport = RecordingHTTPTransport()
  let noFixture = InstagramWriterService(client: InstagramGatewayClient(transport: rejectedTransport, token: "token"), messagingAuthorization: messagingAuthorization())
  await #expect(throws: InstagramGatewayError.self) { _ = try await noFixture.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .publishedPost(mediaId: "3"))) }
  await #expect(throws: InstagramGatewayError.self) { _ = try await noFixture.sendMessage(actorId: "1", input: SendInstagramMessageInput(recipientId: "2", content: .quickReplies(text: "", replies: []))) }
  #expect(await rejectedTransport.requests.isEmpty)
}

@Test func messagingReaderUsesLoginSpecificPathsAndNestedMessageAdapter() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"data":[]}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"messages":{"data":[{"id":"3","to":[{"id":"4"}],"is_unsupported":false}]}}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"id":"5","to":[{"id":"6"}],"is_unsupported":true}"#.utf8))
  ])
  let reader = InstagramReaderService(client: InstagramGatewayClient(transport: transport, token: "token"), messagingAuthorization: InstagramMessagingAuthorization(loginType: .facebook, scopes: ["instagram_basic", "instagram_manage_messages", "pages_manage_metadata"]))
  _ = try await reader.conversations(actorId: "1", limit: 10)
  #expect(try await reader.conversationMessages(conversationId: "2").data.first?.isUnsupported == false)
  #expect(try await reader.message(id: "5").to?.first?.id == "6")
  let requests = await transport.requests
  #expect(requests[0].query.contains(where: { $0.0 == "platform" && $0.1 == "instagram" }))
  #expect(requests[1].path == "2")
  #expect(requests[1].query.first?.1.contains("messages{") == true)
  #expect(requests[2].query.first?.1.contains("is_unsupported") == true)
}

@Test func messagingPublicInputsAndReactionActionsUseTypedContracts() async throws {
  let transport = RecordingHTTPTransport(responses: [
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"r","flow_id":"f"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"u"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"a"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"attachment_id":"x"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"message_id":"p"}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"success":true}"#.utf8)),
    HTTPResponse(statusCode: 200, body: Data(#"{"success":true}"#.utf8))
  ])
  let writer = InstagramWriterService(client: InstagramGatewayClient(transport: transport, token: "token"), messagingAuthorization: messagingAuthorization())
  #expect(try await writer.reactToMessage(ReactToInstagramMessageInput(accountId: "1", recipientId: "2", messageId: "3")).flowId == "f")
  _ = try await writer.reactToMessage(ReactToInstagramMessageInput(accountId: "1", recipientId: "2", messageId: "3", action: .unreact))
  _ = try await writer.performSenderAction(PerformInstagramSenderActionInput(accountId: "1", recipientId: "2", action: .markSeen))
  _ = try await writer.uploadMessageAttachment(UploadInstagramMessageAttachmentInput(accountId: "1", recipientId: "2", imageURL: "https://example.test/a.jpg"))
  _ = try await writer.sendPrivateReply(SendInstagramPrivateReplyInput(accountId: "1", commentId: "2", text: "private"))
  _ = try await writer.setIceBreakers(SetInstagramIceBreakersInput(accountId: "1", iceBreakers: [InstagramIceBreaker(question: "Help", payload: "help")]))
  _ = try await writer.setPersistentMenu(SetInstagramPersistentMenuInput(accountId: "1", items: [InstagramPersistentMenuItem(title: "Help", payload: "help")]))
  let requests = await transport.requests
  #expect(String(data: requests[0].body ?? Data(), encoding: .utf8)?.contains(#""sender_action":"react""#) == true)
  #expect(String(data: requests[1].body ?? Data(), encoding: .utf8)?.contains(#""sender_action":"unreact""#) == true)
  #expect(String(data: requests[2].body ?? Data(), encoding: .utf8)?.contains("mark_seen") == true)
  #expect(requests[3].path == "1/message_attachments")
  #expect(requests[4].path == "1/messages")
  #expect(requests[5].path == "1/messenger_profile")
  #expect(requests[6].path == "1/messenger_profile")

  let rejected = RecordingHTTPTransport()
  let noAuthorization = InstagramWriterService(client: InstagramGatewayClient(transport: rejected, token: "token"))
  await #expect(throws: InstagramGatewayError.self) { _ = try await noAuthorization.reactToMessage(ReactToInstagramMessageInput(accountId: "1", recipientId: "2", messageId: "3", action: .unreact)) }
  #expect(await rejected.requests.isEmpty)
}

@Test func webhookAndMentionNestedPayloadsRoundTrip() throws {
  let webhook = try JSONDecoder().decode(InstagramWebhookPayload.self, from: Data(#"{"object":"instagram","entry":[{"id":"1","media":[{"id":"m","media_type":"IMAGE"}],"comments":[{"id":"c","media_id":"m"}],"mentions":[{"media_id":"m","comment_id":"c"}],"story_insights":[{"name":"impressions","value":1}],"messaging":[{"referral":{"ref":"r"},"pass_thread_control":{"metadata":"x"},"message_edit":{"mid":"m","text":"new"}}]}]}"#.utf8))
  let entry = try #require(webhook.entries.first)
  #expect(entry.media.first?.mediaType == .image)
  #expect(entry.comments.first?.mediaId == "m")
  #expect(entry.messaging.first?.messageEdit?.text == "new")
  let encoded = try JSONEncoder().encode(webhook)
  #expect(try JSONDecoder().decode(InstagramWebhookPayload.self, from: encoded).entries.first?.mentions.first?.commentId == "c")
  let comment = try JSONDecoder().decode(MentionedComment.self, from: Data(#"{"id":"c","media":{"id":"m","media_type":"FUTURE","media_url":"https://example.test/m"}}"#.utf8))
  #expect(comment.media?.mediaType == .unknown("FUTURE"))
  let provider = try JSONDecoder().decode(InstagramWebhookPayload.self, from: Data(#"{"entry":[{"id":"1","provider_added":{"nested":true}}]}"#.utf8))
  let restored = try JSONDecoder().decode(InstagramWebhookPayload.self, from: JSONEncoder().encode(provider))
  #expect(restored.entries.first?.additionalFields["provider_added"] != nil)
}

@Test func ruploadDebugErrorsAreRedacted() async throws {
  let transport = RecordingHTTPTransport(responses: [HTTPResponse(statusCode: 400, body: Data(#"{"debug_info":{"message":"bad OAuth token","code":10}}"#.utf8))])
  let client = InstagramGatewayClient(transport: transport, token: "token")
  do {
    let _: ResumableVideoUploadResult = try await client.request(HTTPRequest(method: .post, path: "https://rupload.facebook.com/ig-api-upload/v1"), as: ResumableVideoUploadResult.self)
    Issue.record("Expected rupload failure")
  } catch let error as InstagramGatewayError {
    #expect(!error.message.contains("token"))
    #expect(error.message.contains("<redacted>"))
  }
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

private func messagingAuthorization() -> InstagramMessagingAuthorization {
  InstagramMessagingAuthorization(loginType: .facebook, scopes: ["instagram_basic", "instagram_manage_messages", "instagram_manage_comments", "pages_manage_metadata", "pages_read_engagement"], features: ["human_agent"])
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
