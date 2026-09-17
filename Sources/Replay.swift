import Compression
import Foundation

/// Replays a .rsrec recording (Recorder.swift format) through its own multi-source receiver,
/// the same C code the live pipeline uses, so a recording can be studied inside the app
/// (Lab tab). Runs on a background queue; messages are reported with their source track.
final class ReplayEngine {
    struct Result { var frames = 0; var packets = 0; var messages = 0; var seconds = 0.0; var tracks = 0 }
    private let queue = DispatchQueue(label: "blinko.replay", qos: .userInitiated)
    private var cancelled = false

    static func recordings() -> [URL] {
        let d = Recorder.directory
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasSuffix(".rsrec") }.sorted()
        return names.map { d.appendingPathComponent($0) }
    }

    func cancel() { cancelled = true }

    /// onMessage(slot, level, text, source); onProgress(frames done, frames total); onDone(result)
    func run(_ url: URL, onMessage: @escaping (Int, Int, String, Int) -> Void,
             onProgress: @escaping (Int, Int) -> Void, onDone: @escaping (Result?) -> Void) {
        cancelled = false
        queue.async {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { onDone(nil); return }
            var r = Result()
            let t0 = CFAbsoluteTimeGetCurrent()
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard raw.count > 12, let base = raw.baseAddress else { return }
                let p = base.assumingMemoryBound(to: UInt8.self)
                guard String(bytes: UnsafeBufferPointer(start: p, count: 8), encoding: .utf8) == "RSREC001" else { return }
                let hlen = Int(Self.u32(p + 8))
                guard let header = try? JSONSerialization.jsonObject(with: Data(bytes: p + 12, count: hlen)) as? [String: Any],
                      let w = header["width"] as? Int, let h = header["height"] as? Int else { return }
                // count frames first for the progress bar
                var off = 12 + hlen, total = 0
                while off + 45 <= raw.count {
                    let comp = Int(Self.u32(p + off + 40)); off += 45 + comp; total += 1
                }
                let multi = UnsafeMutableRawPointer.allocate(byteCount: rs_multi_sizeof(), alignment: 16)
                defer { multi.deallocate() }
                let mp = multi.assumingMemoryBound(to: rs_multi_t.self)
                rs_multi_init(mp)
                let rawSize = w * h * 4
                var frame = [UInt8](repeating: 0, count: rawSize)
                off = 12 + hlen
                var k = 0
                while off + 45 <= raw.count && !self.cancelled {
                    let ts = Self.f64(p + off + 4)                       /* FRME(4) ts(8) gyro(12) accel(12) raw(4) comp(4) codec(1) */
                    let rsz = Int(Self.u32(p + off + 36)), comp = Int(Self.u32(p + off + 40)), codec = p[off + 44]
                    let payload = p + off + 45
                    off += 45 + comp
                    guard rsz == rawSize, off <= raw.count else { break }
                    var ok = true
                    if codec == 0 {
                        frame.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: payload, count: rawSize) }
                    } else {
                        let n = frame.withUnsafeMutableBufferPointer { dst in
                            compression_decode_buffer(dst.baseAddress!, rawSize, payload, comp, nil, COMPRESSION_LZ4)
                        }
                        ok = n == rawSize
                    }
                    if ok {
                        let n = frame.withUnsafeBufferPointer { fp in
                            rs_multi_process(mp, fp.baseAddress!, Int32(w), Int32(h), Int32(w * 4), 4, 2, 1, 0, Float(ts))
                        }
                        r.packets += Int(n)
                        var msg = rs_message_t(); var tid: Int32 = 0
                        while rs_multi_pop_message(mp, &msg, &tid) != 0 {
                            r.messages += 1
                            let text = withUnsafePointer(to: &msg.text) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
                            onMessage(Int(msg.id), Int(msg.level), text, Int(tid))
                        }
                    }
                    k += 1; r.frames = k
                    if k % 10 == 0 { onProgress(k, total) }
                }
                r.tracks = Int(rs_multi_track_count(mp))
            }
            r.seconds = CFAbsoluteTimeGetCurrent() - t0
            onDone(r)
        }
    }

    private static func u32(_ p: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
    }
    private static func f64(_ p: UnsafePointer<UInt8>) -> Double {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(p[i]) << (8 * UInt64(i)) }
        return Double(bitPattern: v)
    }
}
