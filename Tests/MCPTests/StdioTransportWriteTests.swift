import Foundation
import Testing

@testable import MCP

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    @Suite("Stdio Frame Write Tests", .timeLimit(.minutes(1)))
    struct StdioTransportWriteTests {
        @Test("Concurrent frames remain complete under pipe backpressure", .timeLimit(.minutes(1)))
        func concurrentFrames() async throws {
            let pipes = try BackpressuredPipes()
            defer { pipes.close() }
            let transport = StdioTransport(input: pipes.input, output: pipes.output)
            try await transport.connect()
            let large = try JSONEncoder().encode([
                "catalog": String(repeating: "x", count: 2_097_152)
            ])
            let small = try (0..<16).map { try JSONEncoder().encode(["status": $0]) }
            let first = Task { try await transport.send(large) }
            do {
                // Observed pipe bytes establish that the first frame owns a partial write.
                var received = try await pipes.readSome()
                let others = small.map { message in Task { try await transport.send(message) } }
                let expectedBytes = large.count + 1 + small.reduce(0) { $0 + $1.count + 1 }
                while received.count < expectedBytes {
                    received.append(try await pipes.readSome())
                    await Task.yield()
                }
                try await first.value
                for task in others { try await task.value }
                let lines: [Data] = received.split(separator: UInt8(ascii: "\n"))
                #expect(lines.count == small.count + 1)
                #expect(lines.first == large)
                #expect(Set(lines.dropFirst()) == Set(small))
                await transport.disconnect()
            } catch {
                await transport.disconnect()
                _ = await first.result
                throw error
            }
        }

        @Test("Retiring a partial frame fails every queued send", arguments: [true, false])
        func retirePartialFrame(cancel: Bool) async throws {
            let pipes = try BackpressuredPipes()
            defer { pipes.close() }
            let transport = StdioTransport(input: pipes.input, output: pipes.output)
            try await transport.connect()
            let first = Task { try await transport.send(Data(repeating: 0x61, count: 2_097_152)) }
            _ = try await pipes.readSome()
            let queued = Task { try await transport.send(Data("queued".utf8)) }
            if cancel { first.cancel() } else { await transport.disconnect() }
            await #expect(throws: (any Error).self) { try await first.value }
            await #expect(throws: (any Error).self) { try await queued.value }
            await #expect(throws: (any Error).self) { try await transport.send(Data("later".utf8)) }
            await transport.disconnect()
        }

        @Test("Cancelling a queued frame preserves the active writer")
        func cancelQueuedFrame() async throws {
            let pipes = try BackpressuredPipes()
            defer { pipes.close() }
            let transport = StdioTransport(input: pipes.input, output: pipes.output)
            try await transport.connect()
            let large = Data(repeating: 0x61, count: 2_097_152)
            let first = Task { try await transport.send(large) }
            var received = try await pipes.readSome()
            let queued = Task { try await transport.send(Data("cancelled".utf8)) }
            queued.cancel()
            let final = Data("final".utf8)
            let last = Task { try await transport.send(final) }
            do {
                let expected = large + Data([10]) + final + Data([10])
                while received.count < expected.count {
                    received.append(try await pipes.readSome())
                }
                try await first.value
                await #expect(throws: CancellationError.self) { try await queued.value }
                try await last.value
                #expect(received == expected)
                await transport.disconnect()
            } catch {
                await transport.disconnect()
                _ = await first.result
                _ = await queued.result
                _ = await last.result
                throw error
            }
        }

    }

    private struct BackpressuredPipes {
        let input: FileDescriptor
        let inputWriter: FileDescriptor
        let output: FileDescriptor
        let reader: FileDescriptor

        init() throws {
            (input, inputWriter) = try FileDescriptor.pipe()
            (reader, output) = try FileDescriptor.pipe()
            let flags = fcntl(reader.rawValue, F_GETFL)
            guard flags >= 0, fcntl(reader.rawValue, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw Errno(rawValue: errno)
            }
        }

        func readSome() async throws -> Data {
            let deadline = ContinuousClock.now + .seconds(10)
            var bytes = [UInt8](repeating: 0, count: 4096)
            while ContinuousClock.now < deadline {
                do {
                    let count = try bytes.withUnsafeMutableBytes { try reader.read(into: $0) }
                    guard count > 0 else { throw MCPError.connectionClosed }
                    return Data(bytes.prefix(count))
                } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            throw MCPError.internalError("Private output pipe did not make progress.")
        }

        func close() {
            for descriptor in [input, inputWriter, output, reader] { try? descriptor.close() }
        }
    }

#endif
