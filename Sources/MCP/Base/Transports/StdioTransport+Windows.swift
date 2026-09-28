#if os(Windows)
  import Foundation
  import Logging
  @preconcurrency import SystemPackage

  /// Newline-delimited MCP over Windows byte pipes.
  ///
  /// The transport duplicates the supplied CRT descriptors' native handles. The
  /// caller retains its descriptors and must not concurrently read or write them.
  /// Frames, queued message counts and queued payload bytes are independently
  /// bounded. A terminal connection cannot be reused. Disconnect waits for native
  /// I/O completion before releasing the owned duplicates; it never stops a peer.
  public actor StdioTransport: Transport {
    public nonisolated let logger: Logger
    private let inputDescriptor: Int32
    private let outputDescriptor: Int32
    private let maximumMessageBytes: Int
    private let maximumQueuedMessages: Int
    private let maximumQueuedBytes: Int
    private let writeTimeout: Duration
    private let mailbox: WindowsStdioMailbox
    private var pipes: (input: WindowsStdioPipe, output: WindowsStdioPipe)?
    private var reader: Task<Void, Never>?
    private var writers: [UUID: Task<Void, any Error>] = [:]
    private var writerTail: Task<Void, any Error>?
    private var queuedWriteBytes = 0
    private var pending = Data()
    private var connected = false
    private var closed = false
    private var cleanup: Task<Void, Never>?

    /// Creates a transport. Bounds are validated by `connect()` before native admission.
    /// Queue byte limits count payload bytes; each outbound frame adds one newline.
    public init(
      input: FileDescriptor = .standardInput,
      output: FileDescriptor = .standardOutput,
      logger: Logger? = nil,
      maximumMessageBytes: Int = 16_777_216,
      maximumQueuedMessages: Int = 32,
      maximumQueuedBytes: Int = 16_777_216,
      writeTimeout: Duration = .seconds(30)
    ) {
      inputDescriptor = input.rawValue
      outputDescriptor = output.rawValue
      self.logger =
        logger
        ?? Logger(
          label: "mcp.transport.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
      self.maximumMessageBytes = maximumMessageBytes
      self.maximumQueuedMessages = maximumQueuedMessages
      self.maximumQueuedBytes = maximumQueuedBytes
      self.writeTimeout = writeTimeout
      mailbox = WindowsStdioMailbox(
        maximumMessages: maximumQueuedMessages, maximumBytes: maximumQueuedBytes)
    }

    deinit {
      reader?.cancel()
      for writer in writers.values { writer.cancel() }
      mailbox.finish(throwing: MCPError.connectionClosed)
    }

    public func connect() async throws {
      try Task.checkCancellation()
      guard !closed else { throw MCPError.connectionClosed }
      guard !connected else { return }
      guard (1...16_777_216).contains(maximumMessageBytes),
        (1...256).contains(maximumQueuedMessages),
        (maximumMessageBytes...16_777_216).contains(maximumQueuedBytes),
        writeTimeout > .zero, writeTimeout <= .seconds(60)
      else { throw MCPError.invalidParams("Invalid Windows stdio bounds.") }
      let input = try WindowsStdioPipe(descriptor: inputDescriptor)
      let output = try WindowsStdioPipe(descriptor: outputDescriptor)
      pipes = (input, output)
      connected = true
      reader = Task { [weak self, input] in
        do {
          while !Task.isCancelled {
            guard let chunk = try await input.read() else {
              await self?.receivedEOF()
              return
            }
            guard try await self?.receiveChunk(chunk) == true else { return }
          }
        } catch { await self?.retire(throwing: error) }
      }
    }

    public func receive() -> AsyncThrowingStream<Data, any Error> {
      let mailbox = mailbox
      let lifetime = WindowsStdioReceiveLifetime { [weak self] in
        Task { [weak self] in await self?.disconnect() }
      }
      return AsyncThrowingStream(unfolding: { [weak self, lifetime] in
        defer { withExtendedLifetime(lifetime) {} }
        return try await withTaskCancellationHandler {
          try await mailbox.next()
        } onCancel: { [weak self] in
          Task { [weak self] in await self?.disconnect() }
        }
      })
    }

    public func send(_ message: Data) async throws {
      try Task.checkCancellation()
      guard connected, !closed, let output = pipes?.output else {
        throw MCPError.connectionClosed
      }
      guard !message.isEmpty, message.count <= maximumMessageBytes,
        !message.contains(0x0A), String(data: message, encoding: .utf8) != nil
      else { throw MCPError.invalidRequest("Invalid Windows stdio frame.") }
      guard writers.count < maximumQueuedMessages,
        message.count <= maximumQueuedBytes - queuedWriteBytes
      else {
        retire(throwing: WindowsStdioError.capacity)
        await cleanup?.value
        throw WindowsStdioError.capacity
      }
      let id = UUID()
      let predecessor = writerTail
      let deadline = ContinuousClock.now + writeTimeout
      var line = message
      line.append(0x0A)
      let payload = line
      let task = Task {
        _ = await predecessor?.result
        try Task.checkCancellation()
        try await output.write(payload, deadline: deadline)
      }
      writers[id] = task
      writerTail = task
      queuedWriteBytes += message.count
      logger.trace(
        "Message queued",
        metadata: [
          "queuedMessages": "\(writers.count)", "queuedPayloadBytes": "\(queuedWriteBytes)",
        ])
      defer {
        writers.removeValue(forKey: id)
        queuedWriteBytes -= message.count
        if writers.isEmpty { writerTail = nil }
      }
      do {
        try await withTaskCancellationHandler {
          try await task.value
          try Task.checkCancellation()
        } onCancel: { [weak self] in
          task.cancel()
          Task { [weak self] in await self?.retire(throwing: CancellationError()) }
        }
      } catch {
        retire(throwing: error)
        await cleanup?.value
        throw error
      }
    }

    public func disconnect() async {
      retire(throwing: MCPError.connectionClosed)
      await cleanup?.value
    }

    private func receiveChunk(_ chunk: Data) throws -> Bool {
      guard !closed else { return false }
      pending.append(chunk)
      while let newline = pending.firstIndex(of: 0x0A) {
        let size = pending.distance(from: pending.startIndex, to: newline)
        guard size <= maximumMessageBytes else {
          throw MCPError.parseError("Windows stdio frame exceeds its byte limit.")
        }
        let message = Data(pending[..<newline])
        pending.removeSubrange(...newline)
        if message.isEmpty { continue }
        guard String(data: message, encoding: .utf8) != nil else {
          throw MCPError.parseError("Windows stdio frame is not UTF-8.")
        }
        try mailbox.offer(message)
      }
      guard pending.count <= maximumMessageBytes else {
        throw MCPError.parseError("Windows stdio frame exceeds its byte limit.")
      }
      return true
    }

    private func receivedEOF() {
      if pending.isEmpty {
        retire()
      } else {
        retire(throwing: MCPError.parseError("Truncated Windows stdio frame at EOF."))
      }
    }

    private func retire(throwing error: (any Error)? = nil) {
      guard !closed else { return }
      connected = false
      closed = true
      pending.removeAll(keepingCapacity: false)
      mailbox.finish(throwing: error)
      let reading = reader
      let writing = Array(writers.values)
      let owned = pipes
      reader = nil
      pipes = nil
      reading?.cancel()
      for writer in writing { writer.cancel() }
      cleanup = Task {
        await reading?.value
        for writer in writing { _ = await writer.result }
        withExtendedLifetime(owned) {}
      }
    }
  }

  /// A pre-cancelled unfolding stream discards its producer without invoking it.
  /// Producer release must retire native I/O even when its cancellation handler never ran.
  private final class WindowsStdioReceiveLifetime: Sendable {
    private let finish: @Sendable () -> Void

    init(_ finish: @escaping @Sendable () -> Void) { self.finish = finish }

    deinit { finish() }
  }
#endif
