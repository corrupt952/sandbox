import Foundation

/// Returns the index just past the first "\r\n\r\n" (end of HTTP headers), or nil.
func indexPastHeaderTerminator(_ b: [UInt8]) -> Int? {
  guard b.count >= 4 else { return nil }
  var i = 0
  while i <= b.count - 4 {
    if b[i] == 13, b[i + 1] == 10, b[i + 2] == 13, b[i + 3] == 10 { return i + 4 }
    i += 1
  }
  return nil
}

/// Parses Content-Length from a raw header block (case-insensitive). 0 if absent.
///
/// Note: split on the "\r\n" *string*, not on `"\r"`/`"\n"` characters — Swift
/// treats a CRLF as a single extended grapheme cluster, so a Character-level
/// `split(whereSeparator:)` never matches it and would return the whole header
/// as one line.
func parseContentLength(_ header: String) -> Int {
  for line in header.components(separatedBy: "\r\n") {
    if line.lowercased().hasPrefix("content-length:") {
      let value = line.drop(while: { $0 != ":" }).dropFirst()
      return Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
    }
  }
  return 0
}

/// The request line (first line) of a raw request, e.g. "GET / HTTP/1.1".
func requestFirstLine(_ b: [UInt8]) -> String {
  var line = [UInt8]()
  for byte in b {
    if byte == 13 || byte == 10 { break }
    line.append(byte)
  }
  return String(decoding: line, as: UTF8.self)
}

/// The request path (second token of the request line), e.g. "/events".
func requestPath(_ raw: String) -> String {
  let parts = raw.split(separator: " ")
  return parts.count >= 2 ? String(parts[1]) : "/"
}

/// Builds an HTTP/1.1 response that echoes `echo` as text/plain and closes.
func makeEchoResponse(echo: [UInt8]) -> [UInt8] {
  let head =
    "HTTP/1.1 200 OK\r\n"
    + "Content-Type: text/plain; charset=utf-8\r\n"
    + "Content-Length: \(echo.count)\r\n"
    + "Connection: close\r\n\r\n"
  var out = Array(head.utf8)
  out.append(contentsOf: echo)
  return out
}
