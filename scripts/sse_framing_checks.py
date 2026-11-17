#!/usr/bin/env python3
"""Compare chunked SSE framing with the former per-byte parsers and benchmark both."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
FRAMER = ROOT / 'Tivano/Core/Support/SSEByteFramer.swift'
PROVIDER = ROOT / 'Tivano/Services/Providers/OpenAICompatibleSession.swift'
WIRE = ROOT / 'Tivano/Services/MCP/MCPWire.swift'
PROXY = ROOT / 'Tivano/Services/MCP/MCPProxy.swift'


def declaration(text, marker, path):
    start = text.find(marker)
    if start < 0:
        raise RuntimeError(f'{path}: missing extraction marker {marker!r}')
    opening = text.find('{', start)
    if opening < 0:
        raise RuntimeError(f'{path}: no opening brace after {marker!r}')
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == '{':
            depth += 1
        elif text[index] == '}':
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise RuntimeError(f'{path}: unterminated declaration at {marker!r}')


def require(text, marker, path):
    if marker not in text:
        raise RuntimeError(f'{path}: required marker is missing: {marker!r}')


def main():
    for path in (FRAMER, PROVIDER, WIRE, PROXY):
        if not path.is_file():
            raise RuntimeError(f'missing required source file: {path}')
    provider = PROVIDER.read_text(encoding='utf-8')
    wire = WIRE.read_text(encoding='utf-8')
    proxy = PROXY.read_text(encoding='utf-8')
    framer = FRAMER.read_text(encoding='utf-8')

    require(framer, 'static func read(for request: URLRequest, session: URLSession = .shared)', FRAMER)
    require(framer, 'URLSessionDataDelegate', FRAMER)
    require(provider, 'drainSSE(chunks: AsyncThrowingStream<Data, Error>', PROVIDER)
    require(provider, 'SSEByteFramer(byteLimit: 16 * 1024 * 1024, newlineMode: .lf)', PROVIDER)
    require(wire, 'for text in try event.append(contentsOf: chunk)', WIRE)
    require(wire, 'guard chunk.count <= responseLimit - data.count', WIRE)
    require(proxy, 'SSEByteFramer(byteLimit: Int.max)', PROXY)
    require(proxy, 'guard chunk.count <= Self.responseLimit - payload.count', PROXY)
    for path, text in ((PROVIDER, provider), (WIRE, wire), (PROXY, proxy)):
        if 'for try await byte in' in text:
            raise RuntimeError(f'{path}: per-byte URLSession iteration remains')

    handle_line = declaration(provider, '        func handleLine(_ line: Data) async throws -> Bool', PROVIDER)
    for marker in ('if line.last == UInt8(ascii: "\\r")', 'let trimmed = String(decoding: line, as: UTF8.self).trimmed',
                   'if data == "[DONE]"', 'JSONValue.parse(data)', 'payload += "\\n"'):
        require(handle_line, marker, PROVIDER)

    event = declaration(wire, '    private struct SSEEvent {', WIRE)
    event = event.replace('private struct SSEEvent', 'struct SSEEvent', 1)
    require(event, 'mutating func append(contentsOf chunk: Data) throws -> [String]', WIRE)

    swift = r'''
import Foundation

enum MCPResponseError: Error {
    case eventTooLarge
}

enum MCPWire {
    static let responseLimit = 16 * 1024 * 1024
/* SSE_EVENT */
}

struct ReferenceEvent {
    var line = Data()
    var data = Data()
    var size = 0
    var afterCR = false
    var firstLine = true

    mutating func append(_ byte: UInt8) throws -> String? {
        if afterCR {
            afterCR = false
            if byte == 0x0A {
                if size > 0 {
                    guard size < MCPWire.responseLimit else { throw MCPResponseError.eventTooLarge }
                    size += 1
                }
                return nil
            }
        }
        guard size < MCPWire.responseLimit else { throw MCPResponseError.eventTooLarge }
        size += 1
        if byte != 0x0A && byte != 0x0D {
            line.append(byte)
            return nil
        }
        afterCR = byte == 0x0D
        if firstLine {
            firstLine = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            size = 0
            guard !data.isEmpty else { return nil }
            data.removeLast()
            let text = String(decoding: data, as: UTF8.self)
            data.removeAll(keepingCapacity: true)
            return text
        }
        let colon = line.firstIndex(of: 0x3A) ?? line.endIndex
        guard line[..<colon].elementsEqual("data".utf8) else { return nil }
        var value = colon == line.endIndex ? line.endIndex : line.index(after: colon)
        if value < line.endIndex, line[value] == 0x20 { value = line.index(after: value) }
        data.append(contentsOf: line[value...])
        data.append(0x0A)
        return nil
    }
}

enum EventOutcome: Equatable {
    case events([String])
    case failure(String)
}

enum LineOutcome: Equatable {
    case lines([Data])
    case failure(String)
}

func referenceEvents(_ input: Data) -> EventOutcome {
    var event = ReferenceEvent()
    var events: [String] = []
    do {
        for byte in input {
            if let text = try event.append(byte) { events.append(text) }
        }
        return .events(events)
    } catch {
        return .failure(String(describing: error))
    }
}

func framedEvents(_ chunks: [Data]) -> EventOutcome {
    var event = MCPWire.SSEEvent()
    var events: [String] = []
    do {
        for chunk in chunks {
            events.append(contentsOf: try event.append(contentsOf: chunk))
        }
        events.append(contentsOf: try event.finish())
        return .events(events)
    } catch {
        return .failure(String(describing: error))
    }
}

func referenceProviderLines(_ input: Data) -> LineOutcome {
    let limit = 16 * 1024 * 1024
    var line = Data()
    var lines: [Data] = []
    for byte in input {
        if byte == 0x0A {
            lines.append(line)
            line.removeAll(keepingCapacity: true)
        } else {
            guard line.count < limit else { return .failure("lineTooLarge") }
            line.append(byte)
        }
    }
    if !line.isEmpty { lines.append(line) }
    return .lines(lines)
}

func framedProviderLines(_ chunks: [Data]) -> LineOutcome {
    var framer = SSEByteFramer(byteLimit: 16 * 1024 * 1024, newlineMode: .lf)
    var lines: [Data] = []
    do {
        for chunk in chunks {
            for frame in try framer.append(chunk) {
                if case .line(let line) = frame { lines.append(line.content) }
            }
        }
        if let line = try framer.finish() { lines.append(line.content) }
        return .lines(lines)
    } catch {
        return .failure(String(describing: error))
    }
}

func fixedChunks(_ input: Data, size: Int) -> [Data] {
    precondition(size > 0)
    var chunks: [Data] = []
    var start = input.startIndex
    while start < input.endIndex {
        let end = min(start + size, input.endIndex)
        chunks.append(Data(input[start..<end]))
        start = end
    }
    return chunks
}

func randomChunks(_ input: Data, seed: UInt64) -> [Data] {
    var chunks: [Data] = []
    var state = seed
    var start = input.startIndex
    while start < input.endIndex {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let end = min(start + Int(state % 37) + 1, input.endIndex)
        chunks.append(Data(input[start..<end]))
        start = end
    }
    return chunks
}

func checkRawPreservation(_ input: Data, chunks: [Data]) throws {
    var framer = SSEByteFramer(byteLimit: Int.max)
    var raw = Data()
    for chunk in chunks {
        for frame in try framer.append(chunk) {
            switch frame {
            case .line(let line): raw.append(line.raw)
            case .pairedLineFeed(let bytes): raw.append(bytes)
            }
        }
    }
    if let line = try framer.finish() { raw.append(line.raw) }
    precondition(raw == input, "raw bytes changed under reframing")
}

func matrix() throws {
    let fixtures = [
        Data("data: {\"id\":1}\n\n".utf8),
        Data("\u{FEFF}data: first\r\nid: 7\r\ndata:second\r\n\r\n".utf8),
        Data("data: one\r\rdata: two\r\r".utf8),
        Data(": comment\n\nevent: message\ndata: ok\n\ndata: unfinished".utf8),
        Data("data:\n\ndata:  spaced  \n\n".utf8),
        Data("data: a\rdata: b\n\r\nretry: 100\n\n".utf8),
        Data("\u{FEFF}: bom comment\n: another comment\n\n".utf8),
        Data("event: ignored\r\nretry: 10\r\ndata: one\rdata: two\r\r".utf8),
    ]
    for (index, input) in fixtures.enumerated() {
        let plans = [
            [input], fixedChunks(input, size: 1), fixedChunks(input, size: 2),
            fixedChunks(input, size: 3), fixedChunks(input, size: 7),
            randomChunks(input, seed: 17), randomChunks(input, seed: 99),
        ]
        let expectedEvents = referenceEvents(input)
        let expectedLines = referenceProviderLines(input)
        for chunks in plans {
            precondition(framedEvents(chunks) == expectedEvents, "SSE event mismatch in fixture \(index)")
            precondition(framedProviderLines(chunks) == expectedLines, "provider line mismatch in fixture \(index)")
            try checkRawPreservation(input, chunks: chunks)
        }
    }

    let splitCRLF = Data("data: split\r\n\r\n".utf8)
    let splitPoint = splitCRLF.firstIndex(of: 0x0D)! + 1
    let splitChunks = [Data(splitCRLF[..<splitPoint]), Data(splitCRLF[splitPoint...])]
    precondition(framedEvents(splitChunks) == referenceEvents(splitCRLF), "explicit split-CRLF mismatch")
    try checkRawPreservation(splitCRLF, chunks: splitChunks)

    let overLimit = Data(repeating: 0x61, count: MCPWire.responseLimit + 1)
    precondition(referenceEvents(overLimit) == framedEvents([overLimit]), "event limit mismatch")
    precondition(referenceProviderLines(overLimit) == framedProviderLines([overLimit]), "provider limit mismatch")

    let prefix = Data("data: x\n".utf8)
    var acrossChunks = prefix
    acrossChunks.append(Data(repeating: 0x61, count: MCPWire.responseLimit))
    precondition(referenceEvents(acrossChunks) == framedEvents([prefix, Data(repeating: 0x61, count: MCPWire.responseLimit)]),
                 "accumulated event limit mismatch")

    var exact = SSEByteFramer(byteLimit: 4)
    _ = try exact.append(Data("1234".utf8))
    let exactLine = try exact.finish()
    precondition(exactLine?.content == Data("1234".utf8), "exact byte limit was rejected")
    var small = SSEByteFramer(byteLimit: 4)
    do {
        _ = try small.append(Data("12345".utf8))
        preconditionFailure("small explicit byte limit was not enforced")
    } catch is SSEByteFramer.Error {}
    print("PASS: chunk framing matches per-byte SSE events, provider lines, raw bytes and limits")
}

func bench() throws {
    let size = 20 * 1024 * 1024
    let event = Data("id: 42\r\nevent: message\r\ndata: {\"value\":\"abcdefghijklmnopqrstuvwxyz0123456789\"}\r\n\r\n".utf8)
    var input = Data()
    input.reserveCapacity(size)
    while input.count < size { input.append(event) }
    input = Data(input.prefix(size))
    let chunks = fixedChunks(input, size: 64 * 1024)

    let framedStart = Date()
    let framed = framedEvents(chunks)
    let framedMilliseconds = Date().timeIntervalSince(framedStart) * 1_000
    let referenceStart = Date()
    let reference = referenceEvents(input)
    let referenceMilliseconds = Date().timeIntervalSince(referenceStart) * 1_000
    precondition(framed == reference, "benchmark outputs differ")
    print(String(format: "BENCH framed_ms=%.3f reference_per_byte_ms=%.3f", framedMilliseconds, referenceMilliseconds))
}

@main
struct Checks {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty {
            try matrix()
        } else if arguments == ["--bench"] {
            try bench()
        } else {
            throw ValidationError.badArguments
        }
    }
}

enum ValidationError: Error {
    case badArguments
}
'''.replace('/* SSE_EVENT */', event)

    arguments = sys.argv[1:]
    if arguments not in ([], ['--bench']):
        raise RuntimeError('usage: sse_framing_checks.py [--bench]')
    with tempfile.TemporaryDirectory(prefix='tivano-sse-framing-') as folder:
        out = Path(folder)
        source = out / 'Checks.swift'
        source.write_text(swift, encoding='utf-8')
        binary = out / 'run'
        subprocess.run([
            'xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-O',
            str(FRAMER), str(source), '-o', str(binary),
        ], check=True, timeout=180)
        subprocess.run([str(binary), *arguments], check=True, timeout=240)
    return 0


if __name__ == '__main__':
    sys.exit(main())
