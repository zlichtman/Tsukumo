#if os(macOS)
import Foundation

// The Muse link's protobuf messages, written by hand so TsukumoKit keeps no dependencies.
// Ported from Meta's Muse Gadget SDK (Apache-2.0), `linux/src/musegadget/noise/_proto.py` and
// `noise/envelope.py`: the same field numbers, wire types, defaults that are left out, and checks.
// Provenance: TsukumoKit/MUSE-NOTICE.md.

public struct MuseProtoError: Error, Equatable, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

enum MuseProto {
    static let wireVarint = 0, wireFixed64 = 1, wireDelimited = 2, wireFixed32 = 5
    static let maxFieldNumber = (1 << 29) - 1

    static func validField(_ number: Int) -> Bool {
        number != 0 && number <= maxFieldNumber && !(19000...19999).contains(number)
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value, out: [UInt8] = []
        while true {
            let byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { out.append(byte | 0x80) } else { out.append(byte); return out }
        }
    }
    static func key(_ field: Int, _ wire: Int) -> [UInt8] { varint(UInt64((field << 3) | wire)) }
    static func varintField(_ field: Int, _ value: UInt64) -> [UInt8] { key(field, wireVarint) + varint(value) }
    /// int64 and int32 go as their two's-complement uint64, as protobuf writes negative numbers.
    static func int64Field(_ field: Int, _ value: Int64) -> [UInt8] { varintField(field, UInt64(bitPattern: value)) }
    static func int32Field(_ field: Int, _ value: Int32) -> [UInt8] { varintField(field, UInt64(bitPattern: Int64(value))) }
    static func boolField(_ field: Int, _ value: Bool) -> [UInt8] { varintField(field, value ? 1 : 0) }
    static func bytesField(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        key(field, wireDelimited) + varint(UInt64(payload.count)) + payload
    }
    static func stringField(_ field: Int, _ value: String) -> [UInt8] { bytesField(field, Array(value.utf8)) }

    /// Reads protobuf fields one by one.
    struct Reader {
        let data: [UInt8]
        var offset = 0
        init(_ data: [UInt8]) { self.data = data }
        var atEnd: Bool { offset >= data.count }

        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0, shift: UInt64 = 0
            for index in 0..<10 {
                guard offset < data.count else { throw MuseProtoError("truncated varint") }
                let byte = data[offset]
                offset += 1
                if index == 9 && (byte & 0xFE) != 0 { throw MuseProtoError("malformed varint") }
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            throw MuseProtoError("malformed varint")
        }
        mutating func key() throws -> (field: Int, wire: Int) {
            let key = try varint()
            let field = Int(key >> 3), wire = Int(key & 0x07)
            guard MuseProto.validField(field) else { throw MuseProtoError("invalid field number") }
            guard [MuseProto.wireVarint, MuseProto.wireFixed64, MuseProto.wireDelimited, MuseProto.wireFixed32].contains(wire) else {
                throw MuseProtoError("invalid wire type")
            }
            return (field, wire)
        }
        mutating func delimited() throws -> [UInt8] {
            let length = try varint()
            guard length <= UInt64(data.count - offset) else { throw MuseProtoError("truncated delimited field") }
            let end = offset + Int(length)
            defer { offset = end }
            return Array(data[offset..<end])
        }
        mutating func string() throws -> String {
            guard let text = String(bytes: try delimited(), encoding: .utf8) else { throw MuseProtoError("invalid utf-8 string") }
            return text
        }
        mutating func skip(_ wire: Int) throws {
            switch wire {
            case MuseProto.wireVarint: _ = try varint()
            case MuseProto.wireFixed64: try advance(8)
            case MuseProto.wireDelimited: _ = try delimited()
            case MuseProto.wireFixed32: try advance(4)
            default: throw MuseProtoError("invalid wire type")
            }
        }
        private mutating func advance(_ count: Int) throws {
            guard offset + count <= data.count else { throw MuseProtoError("truncated fixed field") }
            offset += count
        }
        /// A field of the expected wire type, or an error naming it.
        mutating func expect(_ wire: Int, _ actual: Int, _ name: String) throws {
            guard wire == actual else { throw MuseProtoError("\(name) wrong wire type") }
        }
    }

    static func int64(_ raw: UInt64) -> Int64 { Int64(bitPattern: raw) }
    static func int32(_ raw: UInt64) throws -> Int32 {
        let signed = Int64(bitPattern: raw)
        guard let value = Int32(exactly: signed) else { throw MuseProtoError("int32 value out of range") }
        return value
    }
    static func uint32(_ raw: UInt64) throws -> UInt32 {
        guard let value = UInt32(exactly: raw) else { throw MuseProtoError("uint32 value out of range") }
        return value
    }
}

// MARK: The service envelope

public enum MuseServiceType: Int, Sendable { case daemon = 0, sentinel = 1, vault = 2, authd = 3 }
public enum MuseResetCode: Int32, Sendable {
    case unspecified = 0, cancelled = 1, timeout = 2, protocolError = 3, refusedStream = 4, internalError = 5, serviceUnavailable = 6
}

public struct MuseHeader: Hashable, Sendable {
    public var key: String, value: String
    public init(_ key: String, _ value: String) { self.key = key; self.value = value }
}
public struct MuseApplicationRequest: Hashable, Sendable {
    public var verb = "", path = "", headers: [MuseHeader] = [], body: [UInt8] = [], endBody = false
    public init(verb: String = "", path: String = "", headers: [MuseHeader] = [], body: [UInt8] = [], endBody: Bool = false) {
        self.verb = verb; self.path = path; self.headers = headers; self.body = body; self.endBody = endBody
    }
}
public struct MuseApplicationResponse: Hashable, Sendable {
    public var status: Int32 = 0, headers: [MuseHeader] = [], body: [UInt8] = [], endBody = false
    public init(status: Int32 = 0, headers: [MuseHeader] = [], body: [UInt8] = [], endBody: Bool = false) {
        self.status = status; self.headers = headers; self.body = body; self.endBody = endBody
    }
}
public struct MuseBodyChunk: Hashable, Sendable {
    public var data: [UInt8] = [], endBody = false
    public init(data: [UInt8] = [], endBody: Bool = false) { self.data = data; self.endBody = endBody }
}
public struct MuseReset: Hashable, Sendable {
    public var code: MuseResetCode = .unspecified, reason = ""
    public init(code: MuseResetCode = .unspecified, reason: String = "") { self.code = code; self.reason = reason }
}

/// One frame on a stream: a request, a response, a piece of a body, or a reset.
public struct MuseServiceFrame: Hashable, Sendable {
    public enum Value: Hashable, Sendable {
        case request(MuseApplicationRequest), response(MuseApplicationResponse), bodyChunk(MuseBodyChunk), reset(MuseReset)
    }
    public var streamID: Int64
    public var value: Value?
    public init(streamID: Int64, value: Value?) { self.streamID = streamID; self.value = value }
}

enum MuseEnvelope {
    static func encode(_ header: MuseHeader) -> [UInt8] {
        var out: [UInt8] = []
        if !header.key.isEmpty { out += MuseProto.stringField(1, header.key) }
        if !header.value.isEmpty { out += MuseProto.stringField(2, header.value) }
        return out
    }
    static func decodeHeader(_ data: [UInt8]) throws -> MuseHeader {
        var reader = MuseProto.Reader(data), header = MuseHeader("", "")
        while !reader.atEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1: try reader.expect(MuseProto.wireDelimited, wire, "Header.key"); header.key = try reader.string()
            case 2: try reader.expect(MuseProto.wireDelimited, wire, "Header.value"); header.value = try reader.string()
            default: try reader.skip(wire)
            }
        }
        return header
    }

    static func encode(_ request: MuseApplicationRequest) -> [UInt8] {
        var out: [UInt8] = []
        if !request.verb.isEmpty { out += MuseProto.stringField(1, request.verb) }
        if !request.path.isEmpty { out += MuseProto.stringField(2, request.path) }
        for header in request.headers { out += MuseProto.bytesField(3, encode(header)) }
        if !request.body.isEmpty { out += MuseProto.bytesField(4, request.body) }
        if request.endBody { out += MuseProto.boolField(5, true) }
        return out
    }
    static func decodeRequest(_ data: [UInt8]) throws -> MuseApplicationRequest {
        var reader = MuseProto.Reader(data), request = MuseApplicationRequest()
        while !reader.atEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1: try reader.expect(MuseProto.wireDelimited, wire, "ApplicationRequest.verb"); request.verb = try reader.string()
            case 2: try reader.expect(MuseProto.wireDelimited, wire, "ApplicationRequest.path"); request.path = try reader.string()
            case 3: try reader.expect(MuseProto.wireDelimited, wire, "ApplicationRequest.headers"); request.headers.append(try decodeHeader(reader.delimited()))
            case 4: try reader.expect(MuseProto.wireDelimited, wire, "ApplicationRequest.body"); request.body = try reader.delimited()
            case 5: try reader.expect(MuseProto.wireVarint, wire, "ApplicationRequest.end_body"); request.endBody = try reader.varint() != 0
            default: try reader.skip(wire)
            }
        }
        return request
    }

    static func encode(_ response: MuseApplicationResponse) -> [UInt8] {
        var out: [UInt8] = []
        if response.status != 0 { out += MuseProto.int32Field(1, response.status) }
        for header in response.headers { out += MuseProto.bytesField(2, encode(header)) }
        if !response.body.isEmpty { out += MuseProto.bytesField(3, response.body) }
        if response.endBody { out += MuseProto.boolField(4, true) }
        return out
    }
    static func decodeResponse(_ data: [UInt8]) throws -> MuseApplicationResponse {
        var reader = MuseProto.Reader(data), response = MuseApplicationResponse()
        while !reader.atEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1: try reader.expect(MuseProto.wireVarint, wire, "ApplicationResponse.status"); response.status = try MuseProto.int32(reader.varint())
            case 2: try reader.expect(MuseProto.wireDelimited, wire, "ApplicationResponse.headers"); response.headers.append(try decodeHeader(reader.delimited()))
            case 3: try reader.expect(MuseProto.wireDelimited, wire, "ApplicationResponse.body"); response.body = try reader.delimited()
            case 4: try reader.expect(MuseProto.wireVarint, wire, "ApplicationResponse.end_body"); response.endBody = try reader.varint() != 0
            default: try reader.skip(wire)
            }
        }
        return response
    }

    static func encode(_ chunk: MuseBodyChunk) -> [UInt8] {
        var out: [UInt8] = []
        if !chunk.data.isEmpty { out += MuseProto.bytesField(1, chunk.data) }
        if chunk.endBody { out += MuseProto.boolField(2, true) }
        return out
    }
    static func decodeBodyChunk(_ data: [UInt8]) throws -> MuseBodyChunk {
        var reader = MuseProto.Reader(data), chunk = MuseBodyChunk()
        while !reader.atEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1: try reader.expect(MuseProto.wireDelimited, wire, "BodyChunk.data"); chunk.data = try reader.delimited()
            case 2: try reader.expect(MuseProto.wireVarint, wire, "BodyChunk.end_body"); chunk.endBody = try reader.varint() != 0
            default: try reader.skip(wire)
            }
        }
        return chunk
    }

    static func encode(_ reset: MuseReset) -> [UInt8] {
        var out: [UInt8] = []
        if reset.code != .unspecified { out += MuseProto.int32Field(1, reset.code.rawValue) }
        if !reset.reason.isEmpty { out += MuseProto.stringField(2, reset.reason) }
        return out
    }
    static func decodeReset(_ data: [UInt8]) throws -> MuseReset {
        var reader = MuseProto.Reader(data), reset = MuseReset()
        while !reader.atEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1:
                try reader.expect(MuseProto.wireVarint, wire, "Reset.code")
                guard let code = MuseResetCode(rawValue: try MuseProto.int32(reader.varint())) else { throw MuseProtoError("unknown reset code") }
                reset.code = code
            case 2: try reader.expect(MuseProto.wireDelimited, wire, "Reset.reason"); reset.reason = try reader.string()
            default: try reader.skip(wire)
            }
        }
        return reset
    }

    static func encode(_ frame: MuseServiceFrame) -> [UInt8] {
        var out: [UInt8] = []
        if frame.streamID != 0 { out += MuseProto.int64Field(1, frame.streamID) }
        switch frame.value {
        case nil: break
        case .request(let request)?: out += MuseProto.bytesField(2, encode(request))
        case .response(let response)?: out += MuseProto.bytesField(3, encode(response))
        case .bodyChunk(let chunk)?: out += MuseProto.bytesField(4, encode(chunk))
        case .reset(let reset)?: out += MuseProto.bytesField(5, encode(reset))
        }
        return out
    }
    static func decodeFrame(_ data: [UInt8]) throws -> MuseServiceFrame {
        var reader = MuseProto.Reader(data), frame = MuseServiceFrame(streamID: 0, value: nil)
        while !reader.atEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1: try reader.expect(MuseProto.wireVarint, wire, "ServiceFrame.stream_id"); frame.streamID = MuseProto.int64(try reader.varint())
            case 2: try reader.expect(MuseProto.wireDelimited, wire, "ServiceFrame.request"); frame.value = .request(try decodeRequest(reader.delimited()))
            case 3: try reader.expect(MuseProto.wireDelimited, wire, "ServiceFrame.response"); frame.value = .response(try decodeResponse(reader.delimited()))
            case 4: try reader.expect(MuseProto.wireDelimited, wire, "ServiceFrame.body_chunk"); frame.value = .bodyChunk(try decodeBodyChunk(reader.delimited()))
            case 5: try reader.expect(MuseProto.wireDelimited, wire, "ServiceFrame.reset"); frame.value = .reset(try decodeReset(reader.delimited()))
            default: try reader.skip(wire)
            }
        }
        return frame
    }

    /// `ServiceRequest`: the service (daemon, left out) and the frame's bytes.
    static func encodeRequestEnvelope(service: MuseServiceType = .daemon, frame: MuseServiceFrame) -> [UInt8] {
        var out: [UInt8] = []
        if service != .daemon { out += MuseProto.varintField(1, UInt64(service.rawValue)) }
        let payload = encode(frame)
        if !payload.isEmpty { out += MuseProto.bytesField(2, payload) }
        return out
    }
    static func decodeRequestEnvelope(_ data: [UInt8]) throws -> (service: MuseServiceType, frame: MuseServiceFrame) {
        var reader = MuseProto.Reader(data), service = MuseServiceType.daemon, payload: [UInt8] = []
        while !reader.atEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1:
                try reader.expect(MuseProto.wireVarint, wire, "ServiceRequest.service")
                guard let value = MuseServiceType(rawValue: Int(try reader.varint())) else { throw MuseProtoError("unknown service type") }
                service = value
            case 2: try reader.expect(MuseProto.wireDelimited, wire, "ServiceRequest.payload"); payload = try reader.delimited()
            default: try reader.skip(wire)
            }
        }
        return (service, try decodeFrame(payload))
    }

    /// `ServiceResponse`: the frame's bytes in field 1.
    static func encodeResponseEnvelope(_ frame: MuseServiceFrame) -> [UInt8] {
        let payload = encode(frame)
        return payload.isEmpty ? [] : MuseProto.bytesField(1, payload)
    }
    static func decodeResponsePayload(_ data: [UInt8]) throws -> [UInt8] {
        var reader = MuseProto.Reader(data), payload: [UInt8] = []
        while !reader.atEnd {
            let (field, wire) = try reader.key()
            if field == 1 { try reader.expect(MuseProto.wireDelimited, wire, "ServiceResponse.payload"); payload = try reader.delimited() }
            else { try reader.skip(wire) }
        }
        return payload
    }
}
#endif
