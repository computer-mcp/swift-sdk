import Foundation
import Testing

@testable import MCP

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

private struct ErrorCase: Sendable {
    let raw: String
    let id: Value
    let code: Int
}

private let errorCases: [ErrorCase] = [
    .init(
        raw: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"x","arguments":{},"_meta":{"sequence":9223372036854775808}}}"#,
        id: .int(2), code: -32602),
    .init(
        raw: #"{"jsonrpc":"2.0","id":"arguments","method":"tools/call","params":{"name":"x","arguments":{"n":-9223372036854775809}}}"#,
        id: .string("arguments"), code: -32602),
    .init(
        raw: #"{"jsonrpc":"2.0","id":"typed","method":"tools/call","params":{"name":17}}"#,
        id: .string("typed"), code: -32602),
    .init(
        raw: #"{"jsonrpc":"2.0","id":9223372036854775807,"method":"tools/call","params":{"name":"x","_meta":{"n":9223372036854775808}}}"#,
        id: .int(Int.max), code: -32602),
    .init(raw: #"{"jsonrpc":"2.0","id":2,"method":"ping""#, id: .null, code: -32700),
    .init(raw: #"{"jsonrpc":"2.0","id":"invalid","method":17}"#, id: .string("invalid"), code: -32600),
    .init(raw: #"{"jsonrpc":"1.0","id":7,"method":"ping"}"#, id: .int(7), code: -32600),
    .init(raw: #"{"jsonrpc":"2.0","id":9223372036854775808,"method":"ping"}"#, id: .null, code: -32600),
    .init(raw: #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, id: .null, code: -32600),
    .init(raw: #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#, id: .null, code: -32600),
    .init(raw: #"{"jsonrpc":"2.0","id":{},"method":"ping"}"#, id: .null, code: -32600),
    .init(raw: #"{"other":9223372036854775808}"#, id: .null, code: -32600),
    .init(raw: "17", id: .null, code: -32600),
    .init(raw: "[]", id: .null, code: -32600),
]

private let invalidNotification =
    #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{"_meta":{"sequence":9223372036854775808}}}"#

private let mixedBatch = """
    [{"jsonrpc":"2.0","id":"good","method":"ping"},
     {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"x","arguments":{"n":9223372036854775808}}},
     17,
     \(invalidNotification)]
    """.replacingOccurrences(of: "\n", with: "")

private struct WireResponse: Decodable {
    struct Error: Decodable {
        let code: Int
    }
    let jsonrpc: String
    // Required so a missing ID cannot pass as a null ID.
    let id: Value
    let error: Error?
    let result: Value?
}

@Suite("Request error correlation", .timeLimit(.minutes(1)))
struct RequestErrorCorrelationTests {
    @Test("Stdio errors preserve the wire ID and error code", arguments: errorCases)
    fileprivate func stdioError(_ test: ErrorCase) async throws {
        let frames = try await stdioExchange(test.raw, responseCount: 1)
        let response = try JSONDecoder().decode(WireResponse.self, from: #require(frames.first))
        #expect(response.jsonrpc == "2.0")
        #expect(response.id == test.id)
        #expect(response.error?.code == test.code)
        #expect(response.result == nil)
    }

    @Test("Stdio drops an unsupported notification")
    func stdioNotification() async throws {
        let frames = try await stdioExchange(invalidNotification, responseCount: 0)
        #expect(frames.isEmpty)
    }

    @Test("Stdio batches preserve good elements and correlate each error")
    func stdioBatch() async throws {
        let frames = try await stdioExchange(mixedBatch, responseCount: 1)
        try checkMixedBatch(#require(frames.first))
    }

    @Test("Stdio batches containing only notifications have no response")
    func stdioNotificationBatch() async throws {
        let frames = try await stdioExchange("[\(invalidNotification)]", responseCount: 0)
        #expect(frames.isEmpty)
    }

    @Test("HTTP errors complete the carrying POST or request stream", arguments: errorCases)
    fileprivate func httpError(_ test: ErrorCase) async throws {
        try await withHTTPServer { transport, headers in
            let response = await transport.handleRequest(HTTPRequest(
                method: "POST", headers: headers, body: Data(test.raw.utf8)))
            let messages = try await completedHTTPMessages(response)
            #expect(messages.count == 1)
            let wire = try JSONDecoder().decode(WireResponse.self, from: #require(messages.first))
            #expect(wire.jsonrpc == "2.0")
            #expect(wire.id == test.id)
            #expect(wire.error?.code == test.code)
            #expect(wire.result == nil)
            if test.id != .null {
                let id = try JSONDecoder().decode(ID.self, from: JSONEncoder().encode(test.id))
                #expect(await transport.httpRequestContext(for: id) == nil)
            }
        }
    }

    @Test("HTTP mixed batches complete one stream with only the responses due")
    func httpBatch() async throws {
        try await withHTTPServer { transport, headers in
            let response = await transport.handleRequest(HTTPRequest(
                method: "POST", headers: headers, body: Data(mixedBatch.utf8)))
            let messages = try await completedHTTPMessages(response)
            #expect(messages.count == 1)
            try checkMixedBatch(#require(messages.first))
            #expect(await transport.httpRequestContext(for: .string("good")) == nil)
            #expect(await transport.httpRequestContext(for: .number(2)) == nil)
        }
    }

    @Test("HTTP null-id batch errors answer their own POST")
    func httpNullBatch() async throws {
        try await withHTTPServer { transport, headers in
            let response = await transport.handleRequest(HTTPRequest(
                method: "POST", headers: headers,
                body: Data("[17,\(invalidNotification),{\"id\":null}]".utf8)))
            let messages = try await completedHTTPMessages(response)
            let errors = try JSONDecoder().decode([WireResponse].self, from: #require(messages.first))
            #expect(errors.count == 2)
            #expect(errors.allSatisfy { $0.id == .null && $0.error?.code == -32600 })
        }
    }

    @Test("HTTP unsupported notifications are accepted without a response body")
    func httpNotification() async throws {
        try await withHTTPServer { transport, headers in
            for raw in [invalidNotification, "[\(invalidNotification)]"] {
                let response = await transport.handleRequest(HTTPRequest(
                    method: "POST", headers: headers, body: Data(raw.utf8)))
                #expect(response.statusCode == 202)
                #expect(response.bodyData == nil)
            }
        }
    }

    @Test("Concurrent HTTP batch and single replies reach their own streams")
    func httpConcurrentBatches() async throws {
        try await withHTTPServer { transport, headers in
            let first = await transport.handleRequest(HTTPRequest(
                method: "POST", headers: headers, body: Data(mixedBatch.utf8)))
            let second = await transport.handleRequest(HTTPRequest(
                method: "POST", headers: headers,
                body: Data(#"[{"jsonrpc":"2.0","id":"second","method":"ping"},false]"#.utf8)))
            let single = await transport.handleRequest(HTTPRequest(
                method: "POST", headers: headers, body: Data(errorCases[1].raw.utf8)))
            let secondMessages = try await completedHTTPMessages(second)
            let secondReplies = try JSONDecoder().decode(
                [WireResponse].self, from: #require(secondMessages.first))
            try #require(secondReplies.count == 2)
            #expect(secondReplies[0].id == .string("second"))
            #expect(secondReplies[0].error == nil)
            #expect(secondReplies[1].id == .null)
            #expect(secondReplies[1].error?.code == -32600)
            let singleMessages = try await completedHTTPMessages(single)
            let singleReply = try JSONDecoder().decode(
                WireResponse.self, from: #require(singleMessages.first))
            #expect(singleReply.id == .string("arguments"))
            #expect(singleReply.error?.code == -32602)
            let firstMessages = try await completedHTTPMessages(first)
            try checkMixedBatch(#require(firstMessages.first))
        }
    }

    @Test("HTTP null-id errors do not consume an in-flight request stream")
    func httpConcurrentPosts() async throws {
        try await withHTTPServer { transport, headers in
            let correlated = await transport.handleRequest(HTTPRequest(
                method: "POST", headers: headers, body: Data(errorCases[0].raw.utf8)))
            let uncorrelated = await transport.handleRequest(HTTPRequest(
                method: "POST", headers: headers, body: Data("not JSON".utf8)))
            let nullMessages = try await completedHTTPMessages(uncorrelated)
            let nullError = try JSONDecoder().decode(WireResponse.self, from: #require(nullMessages.first))
            #expect(nullError.id == .null)
            #expect(nullError.error?.code == -32700)
            let correlatedMessages = try await completedHTTPMessages(correlated)
            let error = try JSONDecoder().decode(WireResponse.self, from: #require(correlatedMessages.first))
            #expect(error.id == .int(2))
            #expect(error.error?.code == -32602)
        }
    }
}

private func checkMixedBatch(_ data: Data) throws {
    let responses = try JSONDecoder().decode([WireResponse].self, from: data)
    try #require(responses.count == 3)
    #expect(responses[0].id == .string("good"))
    #expect(responses[0].result == .object([:]))
    #expect(responses[0].error == nil)
    #expect(responses[1].id == .int(2))
    #expect(responses[1].error?.code == -32602)
    #expect(responses[2].id == .null)
    #expect(responses[2].error?.code == -32600)
}

private func withinDeadline<T: Sendable>(
    _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw MCPError.internalError("Response did not complete")
        }
        defer { group.cancelAll() }
        return try await #require(group.next())
    }
}

private func makeServer() async -> Server {
    let server = Server(name: "correlation-test", version: "1")
    await server.withMethodHandler(CallTool.self) { _ in
        .init(content: [.text(text: "ok", annotations: nil, _meta: nil)])
    }
    return server
}

private func stdioExchange(_ raw: String, responseCount: Int) async throws -> [Data] {
    let (input, writer) = try FileDescriptor.pipe()
    let (reader, output) = try FileDescriptor.pipe()
    defer {
        for descriptor in [input, writer, reader, output] { try? descriptor.close() }
    }
    let serverTransport = StdioTransport(input: input, output: output)
    let client = StdioTransport(input: reader, output: writer)
    let server = await makeServer()
    do {
        try await server.start(transport: serverTransport)
        try await client.connect()
        try await client.send(Data(raw.utf8))
        // The server processes invalid notifications before this request. Its
        // reply establishes progress without a timed "no response" assertion.
        try await client.send(Data(#"{"jsonrpc":"2.0","id":"barrier","method":"ping"}"#.utf8))
        let frames = try await withinDeadline {
            var frames: [Data] = []
            for try await frame in await client.receive() {
                frames.append(frame)
                if frames.count == responseCount + 1 { break }
            }
            return frames
        }
        await server.stop()
        await client.disconnect()
        let replies = frames.filter { frame in
            (try? JSONDecoder().decode(WireResponse.self, from: frame).id) != .string("barrier")
        }
        #expect(frames.count == responseCount + 1)
        #expect(replies.count == responseCount)
        return replies
    } catch {
        await server.stop()
        await client.disconnect()
        throw error
    }
}

private func withHTTPServer(
    _ operation: (StatefulHTTPServerTransport, [String: String]) async throws -> Void
) async throws {
    let transport = StatefulHTTPServerTransport()
    let server = await makeServer()
    var headers = [
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": "2025-11-25",
    ]
    do {
        try await server.start(transport: transport)
        let initialize = await transport.handleRequest(HTTPRequest(
            method: "POST", headers: headers,
            body: Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#.utf8)))
        let messages = try await completedHTTPMessages(initialize)
        let initialized = try JSONDecoder().decode(WireResponse.self, from: #require(messages.first))
        #expect(initialized.id == .int(0))
        #expect(initialized.error == nil)
        let sessionID = try #require(initialize.headers[HTTPHeaderName.sessionID])
        headers[HTTPHeaderName.sessionID] = sessionID
        try await operation(transport, headers)
        await server.stop()
    } catch {
        await server.stop()
        throw error
    }
}

private func completedHTTPMessages(_ response: HTTPResponse) async throws -> [Data] {
    if case .stream(let stream, _) = response {
        return try await withinDeadline {
            var messages: [Data] = []
            for try await chunk in stream {
                for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if !payload.isEmpty { messages.append(Data(payload.utf8)) }
                }
            }
            return messages
        }
    }
    return response.bodyData.map { [$0] } ?? []
}
