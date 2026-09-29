import Foundation
import MCP
import Testing

@Suite("Exact JSON integers")
struct ValueIntegerTests {
    @Test(arguments: [
        Int.min, -9_007_199_254_740_993, 9_007_199_254_740_991,
        9_007_199_254_740_992, 9_007_199_254_740_993, Int.max,
    ])
    func integerIdentitySurvivesRequestsAndResponses(_ integer: Int) throws {
        let request = Data(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"value\":\(integer)}}}"
                .utf8)
        let decoded = try JSONDecoder().decode(Request<CallTool>.self, from: request)
        #expect(decoded.params.arguments?["value"] == .int(integer))
        let value = try JSONDecoder().decode(Value.self, from: Data("{\"value\":\(integer)}".utf8))
        let encoded = try JSONEncoder().encode(value)
        #expect(String(decoding: encoded, as: UTF8.self).contains(String(integer)))
        #expect(try JSONDecoder().decode(Value.self, from: encoded) == value)
    }

    @Test(arguments: [
        "9223372036854775808", "-9223372036854775809",
        "18446744073709551615", "1e100", "-1e100",
    ])
    func unsupportedIntegerCannotEnterThroughDoubleFallback(_ literal: String) throws {
        let request = Data(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"value\":\(literal)}}}"
                .utf8)
        let response = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":\(literal)}}".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Request<CallTool>.self, from: request)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Response<IntegerEcho>.self, from: response)
        }
    }

    @Test(arguments: [1.25, -0.5, 1e-100])
    func fractionsRetainFloatingPointRepresentation(_ number: Double) throws {
        let encoded = try JSONEncoder().encode(Value.double(number))
        #expect(try JSONDecoder().decode(Value.self, from: encoded) == .double(number))
    }

    @Test
    func encodingCannotEmitAnUnsupportedIntegralDouble() throws {
        let minimum = try JSONEncoder().encode(Value.double(Double(Int.min)))
        #expect(try JSONDecoder().decode(Value.self, from: minimum) == .int(Int.min))
        for number in [Double(Int.max), 1e100, -1e100, .infinity, .nan] {
            #expect(throws: EncodingError.self) {
                try JSONEncoder().encode(Value.double(number))
            }
        }
    }
}

private enum IntegerEcho: MCP.Method {
    static let name = "integer/echo"
    typealias Parameters = Value
    typealias Result = Value
}
