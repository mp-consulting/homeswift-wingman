import Foundation

/// One bounded HTTP/1 request per connection; no chunking or pipelining.
enum HTTPRequest {
    static let maximumHeaderBytes = 16_384
    static let maximumBytes = 65_536
    enum Result {
        case incomplete
        case complete(head: String, body: Data)
        case invalid(status: String)
    }

    static func parse(_ buffer: Data) -> Result {
        guard buffer.count <= maximumBytes else { return .invalid(status: "413 Content Too Large") }
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maximumHeaderBytes ? .invalid(status: "431 Request Header Fields Too Large") : .incomplete
        }
        guard end.upperBound <= maximumHeaderBytes else { return .invalid(status: "431 Request Header Fields Too Large") }
        guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return .invalid(status: "400 Bad Request") }
        let lines = head.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[1].hasPrefix("/"), ["HTTP/1.1", "HTTP/1.0"].contains(request[2]) else {
            return .invalid(status: "400 Bad Request")
        }
        var length: Int?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .invalid(status: "400 Bad Request") }
            let key = line[..<colon].lowercased()
            guard !key.contains(where: { $0.isWhitespace }) else { return .invalid(status: "400 Bad Request") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "transfer-encoding" { return .invalid(status: "400 Bad Request") }
            if key == "content-length" {
                guard length == nil, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(value) else {
                    return .invalid(status: "400 Bad Request")
                }
                length = count
            }
        }
        let count = length ?? 0
        guard count <= maximumBytes - end.upperBound else { return .invalid(status: "413 Content Too Large") }
        let body = buffer[end.upperBound...]
        guard body.count <= count else { return .invalid(status: "400 Bad Request") }
        guard body.count == count else { return .incomplete }
        return .complete(head: head, body: Data(body))
    }

    static func waitSeconds(_ text: String?) -> Double? {
        guard let text else { return 0 }
        guard let value = Double(text), value.isFinite else { return nil }
        return min(max(value, 0), 30)
    }
}
