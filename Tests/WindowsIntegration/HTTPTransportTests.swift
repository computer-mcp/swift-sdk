import Foundation
import MCP
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Native MCP HTTP transport", .serialized, .timeLimit(.minutes(1)))
struct HTTPTransportTests {
  private struct Response: Decodable {
    let body: String
    let headers: [String: String]
  }

  @Test("Native HTTP preserves UTF-8 bodies, protocol headers and acquired session identity")
  func sessionRoundTrip() async throws {
    let transport = try makeTransport(path: "echo")
    try await transport.connect()
    do {
      await transport.updateNegotiatedProtocolVersion("2025-11-25")
      var iterator = await transport.receive().makeAsyncIterator()
      let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"text":"汉字 🐈"}}"#
      try await transport.send(Data(body.utf8))
      let firstData = try #require(await iterator.next())
      let first = try JSONDecoder().decode(Response.self, from: firstData)
      #expect(first.body == body)
      #expect(first.headers["content-type"] == "application/json")
      #expect(first.headers["accept"] == "application/json, text/event-stream")
      #expect(first.headers["mcp-protocol-version"] == "2025-11-25")
      #expect(first.headers["mcp-session-id"] == nil)
      #expect(await transport.sessionID == "native-session")
      try await transport.send(Data(body.utf8))
      let secondData = try #require(await iterator.next())
      let second = try JSONDecoder().decode(Response.self, from: secondData)
      #expect(second.headers["mcp-session-id"] == "native-session")
      await transport.disconnect()
      #expect(try await iterator.next() == nil)
      await #expect(throws: MCPError.self) { try await transport.send(Data(body.utf8)) }
    } catch {
      await transport.disconnect()
      throw error
    }
  }

  @Test(
    "Native HTTP errors propagate without accepting a message",
    arguments: [400, 401, 403, 404, 500])
  func httpErrors(status: Int) async throws {
    let transport = try makeTransport(path: "status/\(status)")
    try await transport.connect()
    await #expect(throws: MCPError.self) {
      try await transport.send(Data(#"{"jsonrpc":"2.0","method":"ping","id":2}"#.utf8))
    }
    await transport.disconnect()
    var iterator = await transport.receive().makeAsyncIterator()
    #expect(try await iterator.next() == nil)
  }

  @Test("An expired native HTTP session is cleared before the error returns")
  func expiredSession() async throws {
    let transport = try makeTransport(path: "expire")
    try await transport.connect()
    do {
      let body = Data(#"{"jsonrpc":"2.0","method":"ping","id":3}"#.utf8)
      try await transport.send(body)
      #expect(await transport.sessionID == "native-session")
      await #expect(throws: MCPError.internalError("Session expired")) {
        try await transport.send(body)
      }
      #expect(await transport.sessionID == nil)
      await transport.disconnect()
    } catch {
      await transport.disconnect()
      throw error
    }
  }

  private func makeTransport(path: String) throws -> HTTPClientTransport {
    let endpoint = try #require(ProcessInfo.processInfo.environment["MCP_HTTP_FIXTURE_ENDPOINT"])
    let base = try #require(URL(string: endpoint))
    #expect(base.host == "127.0.0.1")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    return HTTPClientTransport(
      endpoint: base.appendingPathComponent(path), configuration: configuration, streaming: false)
  }
}
