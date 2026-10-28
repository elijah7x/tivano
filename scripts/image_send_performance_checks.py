#!/usr/bin/env python3
"""Measure production image encoding versus the pre-audit raw-image send path.

Synthetic PNGs only; no provider, app or stored user data. A main-actor probe
measures scheduling delay, not frame rate. Timings are machine/workload specific.
"""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from local_control_domain_checks import declaration

ROOT = Path(__file__).resolve().parents[1]
swift = 'import Foundation\nimport CoreGraphics\nimport ImageIO\n'
swift += declaration('Tivano/Core/Models/Timeline.swift', 'struct Attachment:')
swift += '\n' + (ROOT / 'Tivano/Core/Support/JSONValue.swift').read_text()
swift += '\nenum ImageWire {\n' + declaration('Tivano/Services/Providers/PiSession.swift', '    @concurrent\n    private static func encodePrompt(').replace('private ', '') + '\n}\n'
swift += r'''
@main struct Benchmark {
    static func fixture(_ url: URL) throws {
        let width = 3000, height = 2400
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { bytes in
            let p = bytes.bindMemory(to: UInt8.self)
            var state: UInt32 = 19
            for i in stride(from: 0, to: p.count, by: 4) {
                for c in 0..<3 {
                    state = state &* 1664525 &+ 1013904223
                    p[i+c] = UInt8(truncatingIfNeeded: state >> 24)
                }
                p[i+3] = 255
            }
        }
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                            bitsPerPixel: 32, bytesPerRow: width*4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
    }
    @MainActor static func measure(_ images: [Attachment], raw: Bool) async throws -> [String: Double] {
        let start = Date.now
        let probe = Task { @MainActor in Date.now.timeIntervalSince(start) * 1000 }
        let payload: Data
        if raw {
            // Baseline: Pi/OMP read/base64/serialized originals synchronously before this audit.
            let encoded: [JSONValue] = try images.map {
                ["type": "image", "data": .string(try Data(contentsOf: $0.url).base64EncodedString()), "mimeType": .string($0.mimeType)]
            }
            let prompt: JSONValue = ["type": "prompt", "message": "fixture", "images": .array(encoded)]
            payload = prompt.data() + Data([10])
        } else {
            let encoded: [JSONValue] = await Attachment.base64Images(images).map { image, base64 in
                ["type": "image", "data": .string(base64), "mimeType": .string(image.mimeType)]
            }
            payload = await ImageWire.encodePrompt(["type": "prompt", "message": "fixture", "images": .array(encoded)])
        }
        let total = Date.now.timeIntervalSince(start) * 1000
        let delay = await probe.value
        let decoded = JSONValue.parse(payload)!["images"]!.array!
        for image in decoded {
            let data = Data(base64Encoded: image["data"]!.string!)!
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
            precondition((properties[kCGImagePropertyPixelWidth] as! Int) == (raw ? 3000 : 2000))
            precondition(image["mimeType"]!.string == (raw ? "image/png" : "image/jpeg"))
        }
        return ["wire_bytes": Double(payload.count), "main_actor_probe_ms": delay, "total_ms": total]
    }
    @MainActor static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("synthetic.png")
        try fixture(url)
        let images = (0..<2).map { _ in Attachment(name: "fixture.png", path: url.path, mimeType: "image/png") }
        var old: [[String: Double]] = [], current: [[String: Double]] = []
        for _ in 0..<3 {
            old.append(try await measure(images, raw: true))
            current.append(try await measure(images, raw: false))
        }
        let result: [String: Any] = ["workload": "Two 3000x2400 deterministic noise PNG attachments; three warm-cache runs",
                                    "baseline": old, "current": current,
                                    "source_image_bytes": try Data(contentsOf: url).count]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tivano-image-perf-') as folder:
    work = Path(folder)
    source = work / 'ImagePerf.swift'; source.write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '6', '-parse-as-library', str(source), '-o', str(work/'run')], check=True, timeout=180)
    subprocess.run([str(work/'run'), str(work)], check=True, timeout=120)
