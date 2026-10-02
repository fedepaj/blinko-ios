import Compression
import Foundation

/// Replays a .rsrec recording (Recorder.swift format) through its own multi-source receiver,
/// the same C code the live pipeline uses, so a recording can be studied inside the app
/// (Lab tab). Messages are reported with their source track.
///
/// It runs on the queue it is given, which is the camera queue: the C core decodes one frame
/// at a time per process (its scratch buffers are static), and a replay on a queue of its own
/// ran into the live decode next to it. Live frames wait behind the replay and are dropped.
final class ReplayEngine {
    struct Result { var frames = 0; var packets = 0; var messages = 0; var seconds = 0.0; var tracks = 0; var truncated = false }
    private var cancelled = false

    static func recordings() -> [URL] {
        let d = Recorder.directory
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasSuffix(".rsrec") }.sorted()
        return names.map { d.appendingPathComponent($0) }
    }

    func cancel() { cancelled = true }

    /// `rowUs` is the sensor row time the live pipeline uses; the exposure comes from the recording.
    /// onMessage(slot, level, text, source); onProgress(frames done, frames total);
    /// onDone(result, nil), or onDone(nil, reason) for a file that is not a readable recording.
    func run(_ url: URL, on queue: DispatchQueue, rowUs: Double, onMessage: @escaping (Int, Int, String, Int) -> Void,
             onProgress: @escaping (Int, Int) -> Void, onDone: @escaping (Result?, String?) -> Void) {
        cancelled = false
        queue.async {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { onDone(nil, "cannot read the file"); return }
            var r = Result()
            let t0 = CFAbsoluteTimeGetCurrent()
            let failure: String? = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
                guard raw.count >= 12, let base = raw.baseAddress else { return "not a recording" }
                let p = base.assumingMemoryBound(to: UInt8.self)
                guard String(bytes: UnsafeBufferPointer(start: p, count: 8), encoding: .utf8) == "RSREC001" else { return "not a recording" }
                let hlen = Int(Self.u32(p + 8))
                guard hlen <= raw.count - 12 else { return "truncated header" }
                guard let header = try? JSONSerialization.jsonObject(with: Data(bytes: p + 12, count: hlen)) as? [String: Any],
                      let w = header["width"] as? Int, let h = header["height"] as? Int,
                      w > 0, h > 0, w <= 4096, h <= Int(RS_DEC_MAX_ROWS) else { return "unreadable header" }
                let rawSize = w * h * 4
                // Count the whole frames first, for the progress bar and so that the decode loop below only
                // walks records known to lie inside the file. A record that is cut short, lacks the FRME
                // tag or disagrees with the header ends the list: a file without a single good frame is a
                // failure (it used to be reported as a replay of 0 frames), a cut tail is noted.
                var off = 12 + hlen, total = 0
                while raw.count - off >= 45 {
                    let rsz = Int(Self.u32(p + off + 36)), comp = Int(Self.u32(p + off + 40)), codec = p[off + 44]
                    guard p[off] == 0x46, p[off + 1] == 0x52, p[off + 2] == 0x4d, p[off + 3] == 0x45,   /* "FRME" */
                          rsz == rawSize, codec == 0 ? comp == rawSize : (codec == 1 && comp > 0), comp <= raw.count - off - 45 else { break }
                    off += 45 + comp; total += 1
                }
                guard total > 0 else { return "no frames (truncated or not this format)" }
                r.truncated = off != raw.count
                let multi = UnsafeMutableRawPointer.allocate(byteCount: rs_multi_sizeof(), alignment: 16)
                defer { multi.deallocate() }
                let mp = multi.assumingMemoryBound(to: rs_multi_t.self)
                rs_multi_init(mp)
                // the same hook and camera description the live tracks get (Pipeline.swift)
                rs_multi_set_parallel(mp, Pipeline.parallelHook, nil)
                rs_multi_set_camera(mp, Pipeline.cameraDescription(exposureUs: (header["exposureUs"] as? Double) ?? 0, rowUs: rowUs))
                var frame = [UInt8](repeating: 0, count: rawSize)
                off = 12 + hlen
                // Frame times are seconds since boot; the receiver takes a Float, which is too coarse for
                // them after hours of uptime (see Pipeline.timeBase): count from the first frame.
                let ts0 = Self.f64(p + off + 4)
                var k = 0
                while k < total && !self.cancelled {
                    let ts = Self.f64(p + off + 4)                       /* FRME(4) ts(8) gyro(12) accel(12) raw(4) comp(4) codec(1) */
                    let comp = Int(Self.u32(p + off + 40)), codec = p[off + 44]
                    let payload = p + off + 45
                    off += 45 + comp
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
                            rs_multi_process(mp, fp.baseAddress!, Int32(w), Int32(h), Int32(w * 4), 4, 2, 1, 0, Float(ts - ts0))
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
                return nil
            }
            r.seconds = CFAbsoluteTimeGetCurrent() - t0
            if let f = failure { onDone(nil, f) } else { onDone(r, nil) }
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
