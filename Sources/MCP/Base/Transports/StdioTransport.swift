import Logging

import struct Foundation.Data
import struct Foundation.UUID

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

// Import for specific low-level operations not yet in Swift System
#if canImport(Darwin)
    import Darwin.POSIX
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    /// An implementation of the MCP stdio transport protocol.
    ///
    /// This transport implements the [stdio transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#stdio)
    /// specification from the Model Context Protocol.
    ///
    /// The stdio transport works by:
    /// - Reading JSON-RPC messages from standard input
    /// - Writing JSON-RPC messages to standard output
    /// - Using newline characters as message delimiters
    /// - Supporting non-blocking I/O operations
    ///
    /// This transport is the recommended option for most MCP applications due to its
    /// simplicity and broad platform support.
    ///
    /// - Important: This transport is available on Apple platforms and Linux distributions with glibc
    ///   (Ubuntu, Debian, Fedora, CentOS, RHEL).
    ///
    /// ## Example Usage
    ///
    /// ```swift
    /// import MCP
    ///
    /// // Initialize the client
    /// let client = Client(name: "MyApp", version: "1.0.0")
    ///
    /// // Create a transport and connect
    /// let transport = StdioTransport()
    /// try await client.connect(transport: transport)
    /// ```
    public actor StdioTransport: Transport {
        private let input: FileDescriptor
        private let output: FileDescriptor
        /// Logger instance for transport-related events
        public nonisolated let logger: Logger

        private var isConnected = false
        private var writeGeneration = UUID()
        private var sendTail: (id: UUID, task: Task<Void, Swift.Error>)?
        private let messageStream: AsyncThrowingStream<Data, Swift.Error>
        private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

        /// Creates a new stdio transport with the specified file descriptors
        ///
        /// - Parameters:
        ///   - input: File descriptor for reading (defaults to standard input)
        ///   - output: File descriptor for writing (defaults to standard output)
        ///   - logger: Optional logger instance for transport events
        public init(
            input: FileDescriptor = FileDescriptor.standardInput,
            output: FileDescriptor = FileDescriptor.standardOutput,
            logger: Logger? = nil
        ) {
            self.input = input
            self.output = output
            self.logger =
                logger
                ?? Logger(
                    label: "mcp.transport.stdio",
                    factory: { _ in SwiftLogNoOpLogHandler() })

            // Create message stream
            var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
            self.messageStream = AsyncThrowingStream { continuation = $0 }
            self.messageContinuation = continuation
        }

        /// Establishes connection with the transport
        ///
        /// This method configures the file descriptors for non-blocking I/O
        /// and starts the background message reading loop.
        ///
        /// - Throws: Error if the file descriptors cannot be configured
        public func connect() async throws {
            guard !isConnected else { return }

            // Set non-blocking mode
            try setNonBlocking(fileDescriptor: input)
            try setNonBlocking(fileDescriptor: output)

            writeGeneration = UUID()
            isConnected = true
            logger.debug("Transport connected successfully")

            // Start reading loop in background
            Task {
                await readLoop()
            }
        }

        /// Configures a file descriptor for non-blocking I/O
        ///
        /// - Parameter fileDescriptor: The file descriptor to configure
        /// - Throws: Error if the operation fails
        private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
            #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
                // Get current flags
                let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
                guard flags >= 0 else {
                    throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                }

                // Set non-blocking flag
                let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
                guard result >= 0 else {
                    throw MCPError.transportError(Errno(rawValue: CInt(errno)))
                }
            #else
                // For platforms where non-blocking operations aren't supported
                throw MCPError.internalError(
                    "Setting non-blocking mode not supported on this platform")
            #endif
        }

        /// Continuous loop that reads and processes incoming messages
        ///
        /// This method runs in the background while the transport is connected,
        /// parsing complete messages delimited by newlines and yielding them
        /// to the message stream.
        private func readLoop() async {
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            var pendingData = Data()

            while isConnected && !Task.isCancelled {
                do {
                    let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                        try input.read(into: UnsafeMutableRawBufferPointer(pointer))
                    }

                    if bytesRead == 0 {
                        logger.notice("EOF received")
                        break
                    }

                    pendingData.append(Data(buffer[..<bytesRead]))

                    // Process complete messages
                    while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                        let messageData = pendingData[..<newlineIndex]
                        pendingData = pendingData[(newlineIndex + 1)...]

                        if !messageData.isEmpty {
                            logger.trace(
                                "Message received", metadata: ["size": "\(messageData.count)"])
                            messageContinuation.yield(Data(messageData))
                        }
                    }
                } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                } catch {
                    if !Task.isCancelled {
                        logger.error("Read error occurred", metadata: ["error": "\(error)"])
                    }
                    break
                }
            }

            messageContinuation.finish()
        }

        /// Disconnects from the transport
        ///
        /// This stops the message reading loop and releases associated resources.
        public func disconnect() async {
            isConnected = false
            writeGeneration = UUID()
            messageContinuation.finish()
            // Pending frames observe retirement before writing; join the accepted tail.
            let pending = sendTail
            _ = await pending?.task.result
            logger.debug("Transport disconnected")
        }

        /// Sends a message over the transport.
        ///
        /// This method supports sending both individual JSON-RPC messages and JSON-RPC batches.
        /// Batches should be encoded as a JSON array containing multiple request/notification objects
        /// according to the JSON-RPC 2.0 specification.
        ///
        /// - Parameter message: The message data to send (without a trailing newline)
        /// - Throws: Error if the message cannot be sent
        public func send(_ message: Data) async throws {
            try Task.checkCancellation()
            guard isConnected else {
                throw MCPError.transportError(Errno(rawValue: ENOTCONN))
            }
            let generation = writeGeneration
            let predecessor = sendTail?.task
            let id = UUID()
            // Nonblocking writes suspend on backpressure. Keep complete frames ordered
            // across those suspension points, including the newline delimiter.
            let task = Task {
                _ = await predecessor?.result
                try Task.checkCancellation()
                try await writeFrame(message, generation: generation)
            }
            sendTail = (id, task)
            defer { if sendTail?.id == id { sendTail = nil } }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }

        private func writeFrame(_ message: Data, generation: UUID) async throws {
            var frame = message
            frame.append(UInt8(ascii: "\n"))
            var offset = 0
            do {
                while offset < frame.count {
                    try Task.checkCancellation()
                    guard isConnected, writeGeneration == generation else {
                        throw MCPError.transportError(Errno(rawValue: ENOTCONN))
                    }
                    do {
                        let written = try frame.withUnsafeBytes { buffer in
                            try output.write(UnsafeRawBufferPointer(rebasing: buffer[offset...]))
                        }
                        guard written > 0 else { throw Errno(rawValue: EIO) }
                        offset += written
                    } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            } catch {
                // A partial frame cannot be followed by another message. Cancellation
                // before writing any bytes leaves the connection reusable.
                if writeGeneration == generation,
                    offset > 0 || !(error is CancellationError)
                {
                    isConnected = false
                    writeGeneration = UUID()
                    messageContinuation.finish(throwing: error)
                }
                if error is CancellationError { throw error }
                throw MCPError.transportError(error)
            }
        }

        /// Receives messages from the transport.
        ///
        /// Messages may be individual JSON-RPC requests, notifications, responses,
        /// or batches containing multiple requests/notifications encoded as JSON arrays.
        /// Each message is guaranteed to be a complete JSON object or array.
        ///
        /// - Returns: An AsyncThrowingStream of Data objects representing JSON-RPC messages
        public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
            return messageStream
        }
    }
#endif
