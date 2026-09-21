import Foundation
import CryptoKit
import CoreImage

/// v0.18 codec family (G1): pure-Swift encodings, hashes, UUIDs, JSON, QR.
/// QR renders to /tmp PNG via CoreImage — no network, no sound, no writes
/// outside /tmp.
public enum Codec {
    static func b64encode(_ text: String) -> String {
        guard !text.isEmpty else { return "missing text." }
        guard text.utf8.count <= 100_000 else { return "100KB cap." }
        return Data(text.utf8).base64EncodedString()
    }

    static func b64decode(_ b64: String) -> String {
        let t = b64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "missing base64." }
        guard let d = Data(base64Encoded: t, options: .ignoreUnknownCharacters) else {
            return "invalid base64."
        }
        guard d.count <= 1_000_000 else { return "1MB cap." }
        return String(data: d, encoding: .utf8) ?? "(decoded \(d.count) non-UTF8 bytes)"
    }

    static func sha256(_ text: String) -> String {
        guard !text.isEmpty else { return "missing text." }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func uuid() -> String { UUID().uuidString.lowercased() }

    static func jsonPretty(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let d = t.data(using: .utf8) else { return "missing json." }
        guard let obj = try? JSONSerialization.jsonObject(with: d),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: out, encoding: .utf8)
        else { return "invalid json." }
        return String(s.prefix(100_000))
    }

    static func qr(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.utf8.count <= 2000 else { return "need 1-2000 chars of text." }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return "qr unavailable." }
        filter.setValue(Data(t.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return "qr render failed." }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return "qr render failed." }
        let path = "/tmp/macrix_qr_\(Int(Date().timeIntervalSince1970)).png"
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
            "public.png" as CFString, 1, nil) else { return "qr save failed." }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return "qr save failed." }
        return "qr: \(path)"
    }
}
