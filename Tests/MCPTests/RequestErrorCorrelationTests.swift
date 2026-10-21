import Foundation
import Testing

@testable import MCP

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

private struct ErrorCase: Sendable, CustomTestStringConvertible {
    let raw: String
    let id: Value
    let code: Int

    var testDescription: String { "\(raw.prefix(160)) (\(raw.utf8.count) bytes)" }
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
    .init(raw: #"{"jsonrpc":"2.0","id":2}"#, id: .int(2), code: -32600),
    .init(raw: #"{"jsonrpc":"1.0","id":7,"method":"ping"}"#, id: .int(7), code: -32600),
    .init(raw: #"{"jsonrpc":"2.0","id":9223372036854775808,"method":"ping"}"#, id: .null, code: -32600),
    .init(raw: #"{"jsonrpc":"2.0","id":-9223372036854775809,"method":"ping"}"#, id: .null, code: -32600),
    .init(raw: #"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#, id: .null, code: -32600),
    .init(raw: #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, id: .null, code: -32600),
    .init(raw: #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#, id: .null, code: -32600),
    .init(raw: #"{"jsonrpc":"2.0","id":{},"method":"ping"}"#, id: .null, code: -32600),
    .init(raw: #"{"other":9223372036854775808}"#, id: .null, code: -32600),
    .init(raw: "17", id: .null, code: -32600),
    .init(raw: "[]", id: .null, code: -32600),
    .init(
        raw: #"{"jsonrpc":"2.0","id":"deep","method":"tools/call","params":{"name":"x","arguments":{"n":\#(String(repeating: "[", count: 128))9223372036854775808\#(String(repeating: "]", count: 128))}}}"#,
        id: .string("deep"), code: -32602),
    .init(
        raw: #"{"jsonrpc":"2.0","id":"large","method":"tools/call","params":{"name":"x","arguments":{"padding":"\#(String(repeating: "x", count: 1_048_576))","n":9223372036854775808}}}"#,
        id: .string("large"), code: -32602),
]

private let invalidNotification =
    #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{"_meta":{"sequence":9223372036854775808}}}"#

private let mixedBatch = """
    [{"jsonrpc":"2.0","id":"good","method":"ping"},
     {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"x","arguments":{"n":9223372036854775808}}},
     17,
     \(invalidNotification)]
    """.replacingOccurrences(of: "\n", with: "")

private let httpHeaders = [
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
    "MCP-Protocol-Version": "2025-11-25",
]

private let initializeRequest =
    #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#

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

    @Test("Stateless HTTP errors complete the carrying POST", arguments: errorCases)
    fileprivate func statelessHTTPError(_ test: ErrorCase) async throws {
        try await withStatelessHTTPServer { transport in
            let response = try await withinDeadline(onTimeout: { await transport.disconnect() }) {
                await transport.handleRequest(HTTPRequest(
                    method: "POST", headers: httpHeaders, body: Data(test.raw.utf8)))
            }
            let wire = try JSONDecoder().decode(WireResponse.self, from: #require(response.bodyData))
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

    @Test("HTTP transports reject array POSTs without forwarding", arguments: [
        "[]", mixedBatch, "[\(invalidNotification)]", "[17, {\"id\":null}]",
    ])
    func httpArrayPost(_ raw: String) async throws {
        let stateful = StatefulHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: []))
        let stateless = StatelessHTTPServerTransport()
        try await stateful.connect()
        try await stateless.connect()
        let request = HTTPRequest(method: "POST", headers: httpHeaders, body: Data(raw.utf8))
        let responses = [await stateful.handleRequest(request), await stateless.handleRequest(request)]
        for transport in [stateful as any Transport, stateless as any Transport] {
            await transport.disconnect()
            var forwarded: [Data] = []
            for try await data in await transport.receive() { forwarded.append(data) }
            #expect(forwarded.isEmpty)
        }
        for response in responses {
            #expect(response.statusCode == 400)
            let wire = try JSONDecoder().decode(WireResponse.self, from: #require(response.bodyData))
            #expect(wire.id == .null)
            #expect(wire.error?.code == -32600)
        }
    }

    @Test("HTTP notifications are accepted without a response body", arguments: [
        invalidNotification, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
    ])
    func httpNotification(_ raw: String) async throws {
        try await withHTTPServer { transport, headers in
            let response = await transport.handleRequest(HTTPRequest(
                method: "POST", headers: headers, body: Data(raw.utf8)))
            #expect(response.statusCode == 202)
            #expect(response.bodyData == nil)
        }
        try await withStatelessHTTPServer { transport in
            let response = await transport.handleRequest(HTTPRequest(
                method: "POST", headers: httpHeaders, body: Data(raw.utf8)))
            #expect(response.statusCode == 202)
            #expect(response.bodyData == nil)
        }
    }

    @Test("Failed initialization leaves no session and permits retry", arguments: [
        #"{"jsonrpc":"2.0","id":"failed","method":"initialize","params":{"clientInfo":17}}"#,
        #"{"jsonrpc":"2.0","id":"failed","method":"initialize","params":{"_meta":{"n":9223372036854775808}}}"#,
    ])
    func httpInitializeRetry(_ raw: String) async throws {
        let transport = StatefulHTTPServerTransport()
        let server = await makeServer()
        do {
            try await server.start(transport: transport)
            let failed = await transport.handleRequest(HTTPRequest(
                method: "POST", headers: httpHeaders, body: Data(raw.utf8)))
            #expect(failed.headers[HTTPHeaderName.sessionID] == nil)
            let errors = try await completedHTTPMessages(failed)
            let error = try JSONDecoder().decode(WireResponse.self, from: #require(errors.first))
            #expect(error.id == .string("failed"))
            #expect(error.error?.code == -32602)
            #expect(await transport.httpRequestContext(for: .string("failed")) == nil)

            let retried = await transport.handleRequest(HTTPRequest(
                method: "POST", headers: httpHeaders, body: Data(initializeRequest.utf8)))
            #expect(retried.headers[HTTPHeaderName.sessionID] != nil)
            let messages = try await completedHTTPMessages(retried)
            let initialized = try JSONDecoder().decode(WireResponse.self, from: #require(messages.first))
            #expect(initialized.id == .int(0))
            #expect(initialized.result != nil)
            #expect(initialized.error == nil)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test("Stateful HTTP preserves ID types in active and resumed streams", arguments: [false, true])
    func statefulTypedIDRouting(replay: Bool) async throws {
        let transport = StatefulHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: []))
        try await transport.connect()
        let ids: [ID] = [.number(2), .string("2")]
        var responses: [HTTPResponse] = []
        for id in ids {
            responses.append(await transport.handleRequest(try routingRequest(id: id)))
        }
        #expect(await transport.httpRequestContext(for: .number(2))?.path == "/numeric")
        #expect(await transport.httpRequestContext(for: .string("2"))?.path == "/string")

        var eventIDs: [String] = []
        if replay {
            for (id, response) in zip(ids, responses) {
                guard case .stream(let stream, _) = response else {
                    Issue.record("Expected request SSE stream")
                    await transport.disconnect()
                    return
                }
                var iterator = stream.makeAsyncIterator()
                let chunk = try #require(try await iterator.next())
                let line = try #require(String(decoding: chunk, as: UTF8.self)
                    .split(separator: "\n").first { $0.hasPrefix("id:") })
                eventIDs.append(line.dropFirst(3).trimmingCharacters(in: .whitespaces))
                await transport.closeSSEStream(forRequestID: id)
            }
        }

        try await transport.send(JSONEncoder().encode(Ping.response(
            id: .string("2"), error: .invalidParams("string request"))))
        if !replay {
            #expect(await transport.httpRequestContext(for: .string("2")) == nil)
            #expect(await transport.httpRequestContext(for: .number(2))?.path == "/numeric")
        }
        try await transport.send(JSONEncoder().encode(Ping.response(id: .number(2))))

        if replay {
            responses = []
            for (id, eventID) in zip(ids, eventIDs) {
                var headers = httpHeaders
                headers[HTTPHeaderName.lastEventID] = eventID
                responses.append(await transport.handleRequest(HTTPRequest(method: "GET", headers: headers)))
                await transport.closeSSEStream(forRequestID: id)
            }
        }
        await transport.disconnect()
        for (id, response) in zip(ids, responses) {
            let messages = try await completedHTTPMessages(response)
            try #require(messages.count == 1)
            let wire = try JSONDecoder().decode(WireResponse.self, from: #require(messages.first))
            if id == .number(2) {
                #expect(wire.id == .int(2))
                #expect(wire.result == .object([:]))
                #expect(wire.error == nil)
            } else {
                #expect(wire.id == .string("2"))
                #expect(wire.error?.code == -32602)
                #expect(wire.result == nil)
            }
        }
    }

    @Test("Stateless HTTP preserves ID types in concurrent POSTs")
    func statelessTypedIDRouting() async throws {
        let transport = StatelessHTTPServerTransport()
        try await transport.connect()
        let ids: [ID] = [.number(2), .string("2")]
        let (replies, continuation) = AsyncStream<(ID, HTTPResponse)>.makeStream()
        let tasks = try ids.map { id in
            let request = try routingRequest(id: id)
            return Task {
                let response = await transport.handleRequest(request)
                continuation.yield((id, response))
            }
        }
        do {
            let received = try await withinDeadline {
                var ids: [ID] = []
                for try await data in await transport.receive() {
                    let envelope = try JSONDecoder().decode(JSONRPCEnvelope.self, from: data)
                    ids.append(try #require(envelope.id))
                    if ids.count == 2 { break }
                }
                return ids
            }
            #expect(Set(received) == Set(ids))
            #expect(await transport.httpRequestContext(for: .number(2))?.path == "/numeric")
            #expect(await transport.httpRequestContext(for: .string("2"))?.path == "/string")
            try await transport.send(JSONEncoder().encode(Ping.response(
                id: .string("2"), error: .invalidParams("string request"))))
            try await transport.send(JSONEncoder().encode(Ping.response(id: .number(2))))

            let responses = try await withinDeadline {
                var responses: [(ID, HTTPResponse)] = []
                for await reply in replies {
                    responses.append(reply)
                    if responses.count == 2 { break }
                }
                return responses
            }
            #expect(responses.count == 2)
            for (id, response) in responses {
                #expect(response.statusCode == 200)
                let wire = try JSONDecoder().decode(WireResponse.self, from: #require(response.bodyData))
                if id == .number(2) {
                    #expect(wire.id == .int(2))
                    #expect(wire.result == .object([:]))
                    #expect(wire.error == nil)
                } else {
                    #expect(wire.id == .string("2"))
                    #expect(wire.error?.code == -32602)
                    #expect(wire.result == nil)
                }
                #expect(await transport.httpRequestContext(for: id) == nil)
            }
            await transport.disconnect()
        } catch {
            await transport.disconnect()
            continuation.finish()
            for task in tasks { task.cancel() }
            throw error
        }
        continuation.finish()
        for task in tasks { await task.value }
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
    onTimeout: @Sendable @escaping () async -> Void = {},
    _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            await onTimeout()
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
    var headers = httpHeaders
    do {
        try await server.start(transport: transport)
        let initialize = await transport.handleRequest(HTTPRequest(
            method: "POST", headers: headers,
            body: Data(initializeRequest.utf8)))
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

private func withStatelessHTTPServer(
    _ operation: (StatelessHTTPServerTransport) async throws -> Void
) async throws {
    let transport = StatelessHTTPServerTransport()
    let server = await makeServer()
    do {
        try await server.start(transport: transport)
        try await operation(transport)
        await server.stop()
    } catch {
        await server.stop()
        throw error
    }
}

private func routingRequest(id: ID) throws -> HTTPRequest {
    HTTPRequest(
        method: "POST", headers: httpHeaders,
        body: try JSONEncoder().encode(Ping.request(id: id)),
        path: id == .number(2) ? "/numeric" : "/string")
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
