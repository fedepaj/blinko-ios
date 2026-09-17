import Compression
import CoreVideo
import Foundation

/// Records raw camera frames to a compact container for offline replay through
/// the same C core (core/tools/replay.py).
///
/// File layout ("RSREC001"):
///   magic[8] | u32 headerLen | header JSON
///   then per frame: "FRME" | f64 timestamp | f32 gyro[3] | f32 accel[3] | u32 rawSize | u32 compSize | u8 codec | bytes
/// Frames are BGRA with every `columnStep`-th column kept (rows, the time axis, stay at full
/// resolution) and LZ4-compressed with Apple's Compression framework (codec 1).
final class Recorder {
    struct Header: Codable {
        var width: Int, height: Int, columnStep: Int, pixelFormat: String
        var fps: Double, exposureUs: Double, iso: Float, lensPosition: Float
        var camera: String, device: String, axis: String, startedAt: String, note: String
    }

    private(set) var isRecording = false
    private var handle: FileHandle?
    private(set) var url: URL?
    private var deadline: Double = 0
    private var frames = 0
    private var bytesWritten = 0
    private let columnStep = 2
    private var subsampled = [UInt8]()
    private var compressed = [UInt8]()
    var latestMotion: () -> (gyro: [Float], accel: [Float]) = { ([0, 0, 0], [0, 0, 0]) }

    static var directory: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func start(seconds: Double, header: Header) -> URL? {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let u = Self.directory.appendingPathComponent("rec-\(f.string(from: Date())).rsrec")
        FileManager.default.createFile(atPath: u.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: u), let json = try? JSONEncoder().encode(header) else { return nil }
        var data = Data("RSREC001".utf8)
        var len = UInt32(json.count).littleEndian
        data.append(Data(bytes: &len, count: 4)); data.append(json)
        h.write(data)
        handle = h; url = u; frames = 0; bytesWritten = data.count
        deadline = CFAbsoluteTimeGetCurrent() + seconds
        isRecording = true
        return u
    }

    /// Returns true while recording continues; false when the recording just finished.
    func append(_ pb: CVPixelBuffer, timestamp: Double) -> Bool {
        guard isRecording, let h = handle else { return false }
        if CFAbsoluteTimeGetCurrent() >= deadline { finish(); return false }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return true }
        let w = CVPixelBufferGetWidth(pb), hgt = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let ow = w / columnStep
        let raw = ow * hgt * 4
        if subsampled.count < raw { subsampled = [UInt8](repeating: 0, count: raw) }
        if compressed.count < raw + 65536 { compressed = [UInt8](repeating: 0, count: raw + 65536) }
        let src = base.assumingMemoryBound(to: UInt32.self)
        subsampled.withUnsafeMutableBytes { dstRaw in
            let dst = dstRaw.baseAddress!.assumingMemoryBound(to: UInt32.self)
            for r in 0..<hgt {
                let s = UnsafeRawPointer(src).advanced(by: r * bpr).assumingMemoryBound(to: UInt32.self)
                let d = dst.advanced(by: r * ow)
                var c = 0
                while c < ow { d[c] = s[c * 2]; c += 1 }
            }
        }
        let n = subsampled.withUnsafeBufferPointer { s in
            compressed.withUnsafeMutableBufferPointer { d in
                compression_encode_buffer(d.baseAddress!, d.count, s.baseAddress!, raw, nil, COMPRESSION_LZ4)
            }
        }
        let m = latestMotion()
        var rec = Data("FRME".utf8)
        var ts = timestamp; rec.append(Data(bytes: &ts, count: 8))
        for v in m.gyro + m.accel { var f = v; rec.append(Data(bytes: &f, count: 4)) }
        var rs = UInt32(raw).littleEndian; rec.append(Data(bytes: &rs, count: 4))
        if n > 0 {
            var cs = UInt32(n).littleEndian; rec.append(Data(bytes: &cs, count: 4)); rec.append(1)
            rec.append(compressed, count: n)
        } else {
            var cs = UInt32(raw).littleEndian; rec.append(Data(bytes: &cs, count: 4)); rec.append(0)
            rec.append(subsampled, count: raw)
        }
        h.write(rec)
        frames += 1; bytesWritten += rec.count
        return true
    }

    func finish() {
        guard isRecording else { return }
        isRecording = false
        try? handle?.close(); handle = nil
    }

    var summary: String {
        guard let u = url else { return "" }
        return "\(u.lastPathComponent): \(frames) frames, \(bytesWritten / 1_000_000) MB"
    }
}
