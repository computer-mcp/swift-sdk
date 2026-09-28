#if os(Windows)
  import Foundation
  import WinSDK
  import ucrt

  enum WindowsStdioError: Error, LocalizedError, Sendable {
    case native(String, UInt32)
    case unsupportedPipe
    case capacity
    case timeout

    var errorDescription: String? {
      switch self {
      case .native(let operation, let code):
        return "\(operation) failed (Windows error \(code))."
      case .unsupportedPipe: return "Windows stdio requires native byte pipes."
      case .capacity: return "Windows stdio exceeded its queued message or byte capacity."
      case .timeout: return "Windows stdio write exceeded its deadline."
      }
    }
  }

  /// Owns one non-inheritable duplicate; the caller keeps its CRT descriptor.
  final class WindowsStdioPipe: @unchecked Sendable {
    private let handle: HANDLE

    init(descriptor: Int32) throws {
      // Invalid CRT descriptors are recoverable input errors. This synchronous scope
      // restores the calling thread's handler before any suspension or native I/O.
      let previous = _set_thread_local_invalid_parameter_handler { _, _, _, _, _ in }
      let value = _get_osfhandle(descriptor)
      _ = _set_thread_local_invalid_parameter_handler(previous)
      guard value != -1, value != -2, let original = HANDLE(bitPattern: value) else {
        throw WindowsStdioError.native("Resolve stdio descriptor", UInt32(ERROR_INVALID_HANDLE))
      }
      var duplicate: HANDLE?
      guard
        DuplicateHandle(
          GetCurrentProcess(), original, GetCurrentProcess(), &duplicate, 0, false,
          DWORD(DUPLICATE_SAME_ACCESS)), let duplicate
      else { throw WindowsStdioError.native("Duplicate stdio pipe", GetLastError()) }
      var flags: DWORD = 0
      guard GetFileType(duplicate) == DWORD(FILE_TYPE_PIPE),
        GetNamedPipeInfo(duplicate, &flags, nil, nil, nil),
        flags & DWORD(PIPE_TYPE_MESSAGE) == 0
      else {
        CloseHandle(duplicate)
        throw WindowsStdioError.unsupportedPipe
      }
      handle = duplicate
    }

    deinit { CloseHandle(handle) }

    func read() async throws -> Data? {
      try await WindowsStdioOperation<Data?>().perform {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var count: DWORD = 0
        let success = bytes.withUnsafeMutableBytes {
          ReadFile(self.handle, $0.baseAddress, DWORD($0.count), &count, nil)
        }
        if !success {
          let code = GetLastError()
          if code == DWORD(ERROR_BROKEN_PIPE) { return nil }
          throw WindowsStdioError.native("Read stdio pipe", code)
        }
        return count == 0 ? nil : Data(bytes.prefix(Int(count)))
      }
    }

    func write(_ data: Data, deadline: ContinuousClock.Instant) async throws {
      try await WindowsStdioOperation<Void>().perform(deadline: deadline) { operation in
        var offset = 0
        while offset < data.count {
          try operation.checkCancellation()
          guard ContinuousClock.now < deadline else { throw WindowsStdioError.timeout }
          var count: DWORD = 0
          let success = data.withUnsafeBytes {
            WriteFile(
              self.handle, $0.baseAddress!.advanced(by: offset),
              DWORD(min(data.count - offset, 16_384)), &count, nil)
          }
          guard success else {
            throw WindowsStdioError.native("Write stdio pipe", GetLastError())
          }
          guard count > 0 else {
            throw WindowsStdioError.native("Write stdio pipe", UInt32(ERROR_BROKEN_PIPE))
          }
          offset += Int(count)
        }
      }
    }
  }

  /// A worker publishes and clears its exact thread handle under the cancellation lock.
  /// No later job on the dispatch pool can inherit this operation's cancellation authority.
  private final class WindowsStdioOperation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var thread: HANDLE?
    private var finished = false
    private var cancellation: (any Error)?
    private var cancellationTask: Task<Void, Never>?

    func perform(
      _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
      try await perform { _ in try work() }
    }

    func perform(
      deadline: ContinuousClock.Instant? = nil,
      _ work: @escaping @Sendable (WindowsStdioOperation<Value>) throws -> Value
    ) async throws -> Value {
      try Task.checkCancellation()
      let timer = deadline.map { deadline in
        Task {
          do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
          self.cancel(WindowsStdioError.timeout)
        }
      }
      let result: Result<Value, any Error> = await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            let result = Result { () throws -> Value in
              try self.begin()
              return try work(self)
            }
            continuation.resume(returning: self.finish(result))
          }
        }
      } onCancel: {
        self.cancel(CancellationError())
      }
      timer?.cancel()
      await timer?.value
      let cancellationTask = lock.withLock { self.cancellationTask }
      await cancellationTask?.value
      lock.withLock { self.cancellationTask = nil }
      return try result.get()
    }

    func checkCancellation() throws {
      if let error = lock.withLock({ cancellation }) { throw error }
    }

    private func begin() throws {
      try lock.withLock {
        if let cancellation { throw cancellation }
        var retained: HANDLE?
        guard
          DuplicateHandle(
            GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &retained,
            DWORD(THREAD_TERMINATE), false, 0), let retained
        else { throw WindowsStdioError.native("Retain I/O worker", GetLastError()) }
        thread = retained
      }
    }

    private func finish(_ result: Result<Value, any Error>) -> Result<Value, any Error> {
      lock.withLock {
        finished = true
        if let thread { CloseHandle(thread) }
        thread = nil
        return cancellation.map(Result.failure) ?? result
      }
    }

    private func cancel(_ error: any Error) {
      lock.withLock {
        guard !finished, cancellation == nil else { return }
        cancellation = error
        // Cancellation can race the interval immediately before ReadFile/WriteFile.
        // Reissue only while this exact operation retains its worker authority.
        cancellationTask = Task.detached {
          while self.requestCancellation() {
            try? await Task.sleep(for: .milliseconds(5))
          }
        }
      }
    }

    private func requestCancellation() -> Bool {
      lock.withLock {
        guard !finished else { return false }
        if let thread { _ = CancelSynchronousIo(thread) }
        return true
      }
    }
  }
#endif
