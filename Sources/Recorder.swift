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
///
/// The camera thread only copies the subsampled pixels into a pooled buffer (~1 ms); LZ4 and the
/// file write happen on a serial background queue so 120 fps is sustained. When the pool is
/// exhausted the frame is dropped and counted.
final class Recorder {
    struct Header: Codable {
        var width: Int, height: Int, columnStep: Int, pixelFormat: String
        var fps: Double, exposureUs: Double, iso: Float, lensPosition: Float
        var camera: String, device: String, axis: String, startedAt: String, note: String
    }

    static let columnStep = 4          // 1920 -> 480 columns: profiles are column averages, nothing is lost
    static let compress = false
    private static let poolSize = 24

    private(set) var isRecording = false
    private(set) var url: URL?
    private var handle: FileHandle?
    private var deadline: Double = 0
    private var frames = 0, dropped = 0
    private var bytesWritten = 0
    private var pool: [[UInt8]] = []
    private var free: [Int] = []
    private var compressed = [UInt8]()
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "rslog.recorder", qos: .userInitiated)
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
        var hdr = header; hdr.columnStep = Self.columnStep; hdr.width = header.width * header.columnStep / Self.columnStep
        guard let h = try? FileHandle(forWritingTo: u), let json = try? JSONEncoder().encode(hdr) else { return nil }
        var data = Data("RSREC001".utf8)
        var len = UInt32(json.count).littleEndian
        data.append(Data(bytes: &len, count: 4)); data.append(json)
        h.write(data)
        handle = h; url = u; frames = 0; dropped = 0; bytesWritten = data.count
        deadline = CFAbsoluteTimeGetCurrent() + seconds
        isRecording = true
        return u
    }

    /// Returns true while recording continues; false when the recording just finished.
    func append(_ pb: CVPixelBuffer, timestamp: Double) -> Bool {
        guard isRecording else { return false }
        if CFAbsoluteTimeGetCurrent() >= deadline { finish(); return false }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return true }
        let w = CVPixelBufferGetWidth(pb), hgt = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let st = Self.columnStep, ow = w / st
        let raw = ow * hgt * 4
        // a free pooled buffer, or drop the frame
        lock.lock()
        if pool.isEmpty || pool[0].count < raw {
            pool = (0..<Self.poolSize).map { _ in [UInt8](repeating: 0, count: raw) }
            free = Array(0..<Self.poolSize)
        }
        guard let slot = free.popLast() else { dropped += 1; lock.unlock(); return true }
        lock.unlock()
        let src = base.assumingMemoryBound(to: UInt32.self)
        pool[slot].withUnsafeMutableBytes { dstRaw in
            let dst = dstRaw.baseAddress!.assumingMemoryBound(to: UInt32.self)
            for r in 0..<hgt {
                let s = UnsafeRawPointer(src).advanced(by: r * bpr).assumingMemoryBound(to: UInt32.self)
                let d = dst.advanced(by: r * ow)
                var c = 0
                while c < ow { d[c] = s[c * st]; c += 1 }
            }
        }
        let m = latestMotion()
        worker.async { [self] in
            encodeAndWrite(slot: slot, raw: raw, timestamp: timestamp, gyro: m.gyro, accel: m.accel)
            lock.lock(); free.append(slot); lock.unlock()
        }
        return true
    }

    private func encodeAndWrite(slot: Int, raw: Int, timestamp: Double, gyro: [Float], accel: [Float]) {
        guard let h = handle else { return }
        // Camera noise makes LZ4 gain only ~1.4x at ~15 ms per frame, so frames are written raw
        // (codec 0, ~4 ms); set `compress` to trade CPU for size.
        var n = 0
        if Self.compress {
            if compressed.count < raw + 65536 { compressed = [UInt8](repeating: 0, count: raw + 65536) }
            n = pool[slot].withUnsafeBufferPointer { s in
                compressed.withUnsafeMutableBufferPointer { d in
                    compression_encode_buffer(d.baseAddress!, d.count, s.baseAddress!, raw, nil, COMPRESSION_LZ4)
                }
            }
        }
        var rec = Data("FRME".utf8)
        var ts = timestamp; rec.append(Data(bytes: &ts, count: 8))
        for v in gyro + accel { var f = v; rec.append(Data(bytes: &f, count: 4)) }
        var rs = UInt32(raw).littleEndian; rec.append(Data(bytes: &rs, count: 4))
        var cs = UInt32(n > 0 ? n : raw).littleEndian; rec.append(Data(bytes: &cs, count: 4)); rec.append(n > 0 ? 1 : 0)
        // POSIX writes straight from the buffers: no 2 MB Data copy per frame
        let fd = h.fileDescriptor
        rec.withUnsafeBytes { Self.writeAll(fd, $0.baseAddress!, $0.count) }
        if n > 0 { compressed.withUnsafeBytes { Self.writeAll(fd, $0.baseAddress!, n) } }
        else { pool[slot].withUnsafeBytes { Self.writeAll(fd, $0.baseAddress!, raw) } }
        frames += 1; bytesWritten += rec.count + (n > 0 ? n : raw)
    }

    private static func writeAll(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) {
        var off = 0
        while off < n {
            let k = write(fd, p.advanced(by: off), n - off)
            if k <= 0 { return }
            off += k
        }
    }

    func finish() {
        guard isRecording else { return }
        isRecording = false
        worker.async { [self] in try? handle?.close(); handle = nil }
    }

    /// Valid once the worker has drained (the finished callback is delivered through `worker`).
    var summary: String {
        guard let u = url else { return "" }
        return "\(u.lastPathComponent): \(frames) frames, \(bytesWritten / 1_000_000) MB" + (dropped > 0 ? ", \(dropped) dropped" : "")
    }

    /// Run `block` after every queued frame has been written.
    func whenDrained(_ block: @escaping () -> Void) { worker.async(execute: block) }
}
