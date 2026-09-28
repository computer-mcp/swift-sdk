#if os(Windows)
  import Foundation
  import Testing
  import Logging
  import WinSDK
  import ucrt
  @preconcurrency import SystemPackage
  import MCP

  @Suite("Windows stdio native pipes", .serialized, .timeLimit(.minutes(1)))
  struct WindowsStdioTransportTests {
    @Test("Standard MCP initialize, tool call and exact integer round trip")
    func standardMCP() async throws {
      let request = try NativePipe()
      let response = try NativePipe()
      let serverTransport = StdioTransport(
        input: request.reader.descriptor, output: response.writer.descriptor)
      let clientTransport = StdioTransport(
        input: response.reader.descriptor, output: request.writer.descriptor)
      let server = Server(name: "native-pipe", version: "1", capabilities: .init(tools: .init()))
      await server.withMethodHandler(CallTool.self) { request in
        CallTool.Result(
          content: [],
          structuredContent: Value.object(["echo": request.arguments?["value"] ?? .null]))
      }
      let client = Client(name: "native-consumer", version: "1")
      do {
        try await server.start(transport: serverTransport)
        let initialized = try await client.connect(transport: clientTransport)
        #expect(initialized.serverInfo.name == "native-pipe")
        let request: RequestContext<CallTool.Result> = try await client.callTool(
          name: "echo", arguments: ["value": .int(Int.max)])
        let result = try await request.value
        #expect(result.structuredContent?.objectValue?["echo"] == .int(Int.max))
      } catch {
        await client.disconnect()
        await server.stop()
        await clientTransport.disconnect()
        await serverTransport.disconnect()
        throw error
      }
      await client.disconnect()
      await server.stop()
      await clientTransport.disconnect()
      await serverTransport.disconnect()
    }

    @Test("Split UTF8 frames preserve bytes and clean EOF retires the connection")
    func framingAndEOF() async throws {
      let input = try NativePipe()
      let output = try NativePipe()
      let transport = StdioTransport(
        input: input.reader.descriptor, output: output.writer.descriptor)
      try await transport.connect()
      let message = Data("{\"value\":\"汉字\"}".utf8)
      try input.writer.write(Data(message.prefix(12)))
      try input.writer.write(Data(message.dropFirst(12)) + Data("\n\n".utf8))
      input.writer.close()
      var iterator = await transport.receive().makeAsyncIterator()
      #expect(try await iterator.next() == message)
      #expect(try await iterator.next() == nil)
      await transport.disconnect()
      await #expect(throws: (any Error).self) { try await transport.connect() }
    }

    @Test("Invalid UTF8, truncated EOF and oversized frames terminate input", arguments: [0, 1, 2])
    func invalidInput(_ mode: Int) async throws {
      let input = try NativePipe()
      let output = try NativePipe()
      let transport = StdioTransport(
        input: input.reader.descriptor, output: output.writer.descriptor,
        maximumMessageBytes: 32, maximumQueuedBytes: 64)
      try await transport.connect()
      let bytes =
        mode == 0
        ? Data([0xFF, 0x0A])
        : mode == 1 ? Data("{\"unfinished\":".utf8) : Data(repeating: 0x61, count: 33)
      try input.writer.write(bytes)
      input.writer.close()
      var iterator = await transport.receive().makeAsyncIterator()
      await #expect(throws: (any Error).self) { _ = try await iterator.next() }
      await transport.disconnect()
    }

    @Test(
      "Incoming count and aggregate byte bounds terminate a slow consumer",
      arguments: [false, true])
    func inputCapacity(_ byBytes: Bool) async throws {
      let input = try NativePipe()
      let output = try NativePipe()
      let transport = StdioTransport(
        input: input.reader.descriptor, output: output.writer.descriptor,
        maximumMessageBytes: 16, maximumQueuedMessages: byBytes ? 32 : 1,
        maximumQueuedBytes: 16)
      try await transport.connect()
      let frame = byBytes ? "1234567890\n" : "x\n"
      try input.writer.write(Data((frame + frame + frame).utf8))
      input.writer.close()
      output.writer.close()
      try await eventually { try output.reader.peerClosed() }
      var iterator = await transport.receive().makeAsyncIterator()
      var failed = false
      do { while try await iterator.next() != nil {} } catch { failed = true }
      #expect(failed)
      await transport.disconnect()
    }

    @Test("Disconnect joins blocked reads and preserves borrowed descriptors")
    func readShutdown() async throws {
      let input = try NativePipe()
      let output = try NativePipe()
      let transport = StdioTransport(
        input: input.reader.descriptor, output: output.writer.descriptor)
      try await transport.connect()
      async let first: Void = transport.disconnect()
      async let second: Void = transport.disconnect()
      _ = await (first, second)
      try input.writer.write(Data("still-owned".utf8))
      #expect(try input.reader.readAvailable() == Data("still-owned".utf8))
      try output.writer.write(Data("still-owned".utf8))
      #expect(try output.reader.readAvailable() == Data("still-owned".utf8))
    }

    @Test("Cancellation and deadlines join a blocked write", arguments: [false, true])
    func writeShutdown(_ timeout: Bool) async throws {
      let input = try NativePipe()
      let output = try NativePipe()
      let transport = StdioTransport(
        input: input.reader.descriptor, output: output.writer.descriptor,
        writeTimeout: timeout ? .milliseconds(150) : .seconds(30))
      try await transport.connect()
      let sending = Task { try await transport.send(Data(repeating: 0x61, count: 1_048_576)) }
      try await eventually { try output.reader.available() > 0 }
      if !timeout { sending.cancel() }
      await #expect(throws: (any Error).self) { try await sending.value }
      await transport.disconnect()
      // A transport-owned duplicate cannot keep the peer alive after native shutdown.
      output.writer.close()
      while (try? output.reader.available()) ?? 0 > 0 { _ = try output.reader.readAvailable() }
      var available: DWORD = 0
      let succeeded = PeekNamedPipe(output.reader.handle, nil, 0, nil, &available, nil)
      let code = GetLastError()
      #expect(!succeeded)
      #expect(code == DWORD(ERROR_BROKEN_PIPE))
    }

    @Test("Cancelling a queued write interrupts its blocked predecessor")
    func queuedCancellation() async throws {
      let input = try NativePipe()
      let output = try NativePipe()
      let observations = AdmissionObservations()
      let logger = Logger(
        label: "native-queue-test",
        factory: { _ in
          AdmissionLogHandler(observations: observations)
        })
      let transport = StdioTransport(
        input: input.reader.descriptor, output: output.writer.descriptor, logger: logger)
      try await transport.connect()
      let first = Task { try await transport.send(Data(repeating: 0x61, count: 1_048_576)) }
      try await eventually { try output.reader.available() > 0 }
      let second = Task { try await transport.send(Data("second".utf8)) }
      try await eventually { observations.count == 2 }
      second.cancel()
      await #expect(throws: (any Error).self) { try await second.value }
      await #expect(throws: (any Error).self) { try await first.value }
      await transport.disconnect()
    }

    @Test("Outgoing count and byte limits retire blocked writers", arguments: [false, true])
    func outputCapacity(_ byBytes: Bool) async throws {
      let input = try NativePipe()
      let output = try NativePipe()
      let transport = StdioTransport(
        input: input.reader.descriptor, output: output.writer.descriptor,
        maximumMessageBytes: 1_048_576, maximumQueuedMessages: byBytes ? 32 : 1,
        maximumQueuedBytes: byBytes ? 1_048_576 : 2_097_152)
      try await transport.connect()
      let first = Task { try await transport.send(Data(repeating: 0x61, count: 1_048_576)) }
      try await eventually { try output.reader.available() > 0 }
      await #expect(throws: (any Error).self) { try await transport.send(Data("next".utf8)) }
      await #expect(throws: (any Error).self) { try await first.value }
      await transport.disconnect()
    }

    @Test("Cancelling the receive iterator closes native I/O and duplicate handles")
    func cancelledReceiver() async throws {
      let input = try NativePipe()
      let output = try NativePipe()
      let transport = StdioTransport(
        input: input.reader.descriptor, output: output.writer.descriptor)
      try await transport.connect()
      output.writer.close()
      let receiving = Task {
        var iterator = await transport.receive().makeAsyncIterator()
        return try await iterator.next()
      }
      receiving.cancel()
      await #expect(throws: (any Error).self) { _ = try await receiving.value }
      try await eventually { try output.reader.peerClosed() }
      await transport.disconnect()
    }

    @Test("Invalid descriptors and invalid bounds fail without terminating the process")
    func invalidAdmission() async throws {
      let invalid = StdioTransport(input: FileDescriptor(rawValue: Int32.max))
      await #expect(throws: (any Error).self) { try await invalid.connect() }
      let bounds = StdioTransport(maximumMessageBytes: -1)
      await #expect(throws: (any Error).self) { try await bounds.connect() }
      await invalid.disconnect()
      await bounds.disconnect()
    }

    private func eventually(_ predicate: () throws -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(3)
      while try !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      try #require(try predicate())
    }
  }

  private struct NativePipe {
    let reader: NativeDescriptor
    let writer: NativeDescriptor

    init() throws {
      var read: HANDLE?
      var write: HANDLE?
      try #require(CreatePipe(&read, &write, nil, 4_096))
      let input = try #require(read)
      let output = try #require(write)
      do { reader = try NativeDescriptor(input, flags: _O_RDONLY | _O_BINARY) } catch {
        CloseHandle(output)
        throw error
      }
      writer = try NativeDescriptor(output, flags: _O_WRONLY | _O_BINARY)
    }
  }

  private final class NativeDescriptor: @unchecked Sendable {
    let descriptor: FileDescriptor
    let handle: HANDLE
    private let lock = NSLock()
    private var closed = false

    init(_ handle: HANDLE, flags: Int32) throws {
      let descriptor = _open_osfhandle(Int(bitPattern: handle), flags)
      guard descriptor >= 0 else {
        CloseHandle(handle)
        throw CocoaError(.fileReadUnknown)
      }
      self.descriptor = FileDescriptor(rawValue: descriptor)
      self.handle = handle
    }

    deinit { close() }

    func close() {
      lock.withLock {
        guard !closed else { return }
        closed = true
        _ = _close(descriptor.rawValue)
      }
    }

    func write(_ data: Data) throws {
      var count: DWORD = 0
      try #require(
        data.withUnsafeBytes {
          WriteFile(handle, $0.baseAddress, DWORD($0.count), &count, nil)
        })
      try #require(count == data.count)
    }

    func available() throws -> Int {
      var count: DWORD = 0
      guard PeekNamedPipe(handle, nil, 0, nil, &count, nil) else {
        throw NSError(domain: "NSWin32ErrorDomain", code: Int(GetLastError()))
      }
      return Int(count)
    }

    func peerClosed() throws -> Bool {
      var count: DWORD = 0
      if PeekNamedPipe(handle, nil, 0, nil, &count, nil) { return false }
      let code = GetLastError()
      if code == DWORD(ERROR_BROKEN_PIPE) { return true }
      throw NSError(domain: "NSWin32ErrorDomain", code: Int(code))
    }

    func readAvailable() throws -> Data {
      let available = try available()
      if available == 0 { return Data() }
      var bytes = [UInt8](repeating: 0, count: available)
      var count: DWORD = 0
      try #require(ReadFile(handle, &bytes, DWORD(bytes.count), &count, nil))
      return Data(bytes.prefix(Int(count)))
    }
  }
  private final class AdmissionObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var admitted = 0
    var count: Int { lock.withLock { admitted } }
    func record() { lock.withLock { admitted += 1 } }
  }

  private struct AdmissionLogHandler: LogHandler {
    let observations: AdmissionObservations
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
      get { metadata[key] }
      set { metadata[key] = newValue }
    }
    func log(
      level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
      source: String, file: String, function: String, line: UInt
    ) {
      if message.description == "Message queued" { observations.record() }
    }
  }
#endif
