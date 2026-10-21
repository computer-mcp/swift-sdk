/// The fields needed to recover correlation independently of parameter values.
struct JSONRPCEnvelope: Decodable {
    let jsonrpc: String?
    let id: ID?
    let method: String?
    let hasID: Bool
    let hasResultOrError: Bool

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, result, error
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try? container?.decode(String.self, forKey: .jsonrpc)
        method = try? container?.decode(String.self, forKey: .method)
        hasID = container?.contains(.id) ?? false
        hasResultOrError = container?.contains(.result) == true || container?.contains(.error) == true
        // ID's public decoder maps null to an empty string. An error envelope
        // instead treats null and unsupported IDs as undeterminable.
        if (try? container?.decodeNil(forKey: .id)) == false {
            id = try? container?.decode(ID.self, forKey: .id)
        } else {
            id = nil
        }
    }

    var isNotification: Bool { !hasID && method != nil }

    var isInitializeRequest: Bool {
        jsonrpc == "2.0" && id != nil && method == Initialize.name
    }

    var decodingError: JSONRPCErrorResponse {
        let error: MCPError =
            jsonrpc == "2.0" && id != nil && method != nil
            ? .invalidParams("Invalid params field")
            : .invalidRequest("Invalid message format")
        return JSONRPCErrorResponse(id: id, error: error)
    }
}

/// Decodes one message, including a malformed element of a JSON-RPC batch.
enum IncomingMessage: Decodable, Sendable {
    case request(AnyRequest)
    case response(AnyResponse)
    case notification(AnyMessage)
    case error(JSONRPCErrorResponse)
    case invalidNotification

    init(from decoder: Decoder) throws {
        let envelope = try JSONRPCEnvelope(from: decoder)
        if envelope.isNotification {
            if let notification = try? AnyMessage(from: decoder) {
                self = .notification(notification)
            } else {
                self = .invalidNotification
            }
        } else if envelope.id != nil, let response = try? AnyResponse(from: decoder) {
            self = .response(response)
        } else if envelope.id != nil, let request = try? AnyRequest(from: decoder) {
            self = .request(request)
        } else {
            self = .error(envelope.decodingError)
        }
    }
}

/// Error-only wire encoding; an undeterminable request ID is explicitly null.
struct JSONRPCErrorResponse: Encodable, Sendable {
    let id: ID?
    let error: MCPError

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(error, forKey: .error)
    }
}
