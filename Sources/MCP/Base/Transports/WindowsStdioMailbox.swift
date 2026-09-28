#if os(Windows)
  import Foundation

  /// An unfolding stream consumes this queue directly, preserving a real aggregate byte bound.
  final class WindowsStdioMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumMessages: Int
    private let maximumBytes: Int
    private var messages: [Data?] = []
    private var head = 0
    private var bytes = 0
    private var waiter: CheckedContinuation<Data?, any Error>?
    private var terminal: Result<Void, any Error>?

    init(maximumMessages: Int, maximumBytes: Int) {
      self.maximumMessages = maximumMessages
      self.maximumBytes = maximumBytes
    }

    func offer(_ message: Data) throws {
      let waiting = try lock.withLock { () throws -> CheckedContinuation<Data?, any Error>? in
        guard terminal == nil else { throw MCPError.connectionClosed }
        if let waiting = waiter {
          waiter = nil
          return waiting
        }
        guard messages.count - head < maximumMessages,
          message.count <= maximumBytes - bytes
        else { throw WindowsStdioError.capacity }
        messages.append(message)
        bytes += message.count
        return nil
      }
      waiting?.resume(returning: message)
    }

    func next() async throws -> Data? {
      try Task.checkCancellation()
      return try await withTaskCancellationHandler {
        let value = try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Data?, any Error>) in
          let result: Result<Data?, any Error>? = lock.withLock {
            if head < messages.count {
              let message = messages[head]!
              messages[head] = nil
              head += 1
              bytes -= message.count
              if head >= 64 && head * 2 >= messages.count {
                messages.removeFirst(head)
                head = 0
              }
              return .success(message)
            }
            if let terminal { return terminal.map { nil } }
            guard waiter == nil else {
              return .failure(
                MCPError.invalidRequest("Concurrent stdio receivers are unsupported."))
            }
            waiter = continuation
            return nil
          }
          if let result { continuation.resume(with: result) }
        }
        try Task.checkCancellation()
        return value
      } onCancel: {
        self.finish(throwing: CancellationError())
      }
    }

    func finish(throwing error: (any Error)? = nil) {
      let waiting = lock.withLock { () -> CheckedContinuation<Data?, any Error>? in
        guard terminal == nil else { return nil }
        terminal = error.map(Result.failure) ?? .success(())
        if error != nil {
          messages.removeAll(keepingCapacity: false)
          head = 0
          bytes = 0
        }
        let waiting = waiter
        waiter = nil
        return waiting
      }
      if let error { waiting?.resume(throwing: error) } else { waiting?.resume(returning: nil) }
    }
  }
#endif
