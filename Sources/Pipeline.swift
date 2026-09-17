import CoreVideo
import Foundation

struct PacketMark: Identifiable {
    let id: Int
    let start: Float, end: Float   // normalized 0..1 along the scan axis
    let quality: Float
    let slot: Int, seed: Int
    let channel: Int               // 0 red/luma, 1 green, 2 blue
}

struct DecodeStats {
    var fps: Double = 0
    var packetsPerSec: Double = 0
    var rowsPerChip: Float = 0
    var contrast: Float = 0
    var syncs = 0, crcFail = 0
    var totalPackets = 0, totalMessages = 0
    var roi = (0, 0), crossLength = 1
    var profileLength = 0
    var lastPacketAge: Double = 999
    var rgbMode = false
    var modeName = "luma"      // luma | RGB (pilot-calibrated unmix) | direct (camera channels as streams)
    var pilots = 0
    var calCond: Float = 0
    var peak = 0
    var satFrac: Float = 0
}

struct TrackInfo: Identifiable {
    let id: Int
    let x: Float, y: Float, radius: Float   // normalized to the native buffer (0..1 of width / height)
    let rgb: Bool
    var direct: Bool = false
    var group: Int = 0            // logical source (smallest track id of the linked lights); == id when alone
    let packets: Int, messages: Int, pilots: Int
    var modeName: String { direct ? "direct" : (rgb ? "RGB" : "mono") }
}

struct Snapshot {
    var profile: [Float]
    var marks: [PacketMark]
    var stats: DecodeStats
    var slotProgress: [Float]
    var tracks: [TrackInfo] = []
    var progressLabel = ""      // source the slot bars refer to
}

struct LabResult {
    var axis: ScanAxis
    var periodRows: Float        // band period in scan units
    var strength: Float          // normalized autocorrelation peak 0..1
    var otherStrength: Float
    var rowTimeUs: Double        // derived with the strobe frequency
    var readoutMs: Double
    var count: Int
}

/// Frame -> profile -> packets -> messages. Runs on the camera queue.
final class Pipeline {
    var axis: ScanAxis = .rows
    var labMode = false
    var strobeHz: Double = 2000
    var minContrast: Float = 6

    let recorder = Recorder()
    var onRecordingFinished: ((String) -> Void)?
    var onSnapshot: ((Snapshot) -> Void)?
    var onMessage: ((Int, Int, String, Int) -> Void)?   // slot, level, text, source track (0 = single)
    var multiSource = true
    /// Which logical source the slot bars follow in multi-source mode (0 = the busiest light).
    var progressSource = 0
    var onLab: ((LabResult) -> Void)?

    private let processor = FrameProcessor()
    private let rx: UnsafeMutableRawPointer = {
        let p = UnsafeMutableRawPointer.allocate(byteCount: rs_rx_sizeof(), alignment: 16)
        rs_rx_init(p.assumingMemoryBound(to: rs_rx_t.self))
        return p
    }()
    private var rxp: UnsafeMutablePointer<rs_rx_t> { rx.assumingMemoryBound(to: rs_rx_t.self) }
    private let multi: UnsafeMutableRawPointer = {
        let p = UnsafeMutableRawPointer.allocate(byteCount: rs_multi_sizeof(), alignment: 16)
        rs_multi_init(p.assumingMemoryBound(to: rs_multi_t.self))
        return p
    }()
    private var mp: UnsafeMutablePointer<rs_multi_t> { multi.assumingMemoryBound(to: rs_multi_t.self) }
    private var lastTracks: [TrackInfo] = []
    private var progressLabel = ""
    private var lastProgress = [Float](repeating: 0, count: 8)
    private var profile = [Float](repeating: 0, count: 4096)   /* luma, for display and lab */
    private var profileB = [Float](repeating: 0, count: 4096)
    private var frameTimes: [Double] = []
    private var packetTimes: [Double] = []
    private var lastUI: Double = 0
    private var multiFrame = 0
    private var lastRes = FrameProcessor.Result()
    private var lastPacket: Double = -1e9
    private var totalPackets = 0, totalMessages = 0
    private var rpcEMA: Float = 0
    private var markSeq = 0
    private var lastDump: Double = 0
    var dumpFrames = false
    /// One-shot: the next frame is handed to this closure (remote "frame" command), then cleared.
    var frameRequest: ((CVPixelBuffer, Double) -> Void)?

    /// BGRA pixels with every `step`-th column kept (rows stay full), as the recorder stores them.
    static func subsampled(_ pb: CVPixelBuffer, step: Int) -> (data: Data, w: Int, h: Int)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let st = max(1, step), ow = w / st
        var out = Data(count: ow * h * 4)
        out.withUnsafeMutableBytes { dstRaw in
            let dst = dstRaw.baseAddress!.assumingMemoryBound(to: UInt32.self)
            for r in 0..<h {
                let s = UnsafeRawPointer(base).advanced(by: r * bpr).assumingMemoryBound(to: UInt32.self)
                let d = dst.advanced(by: r * ow)
                var c = 0
                while c < ow { d[c] = s[c * st]; c += 1 }
            }
        }
        return (out, ow, h)
    }

    /// Save the full luma plane as PGM (Documents/frame.pgm) for offline analysis.
    private func dumpFrame(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        var data = Data("P6\n\(w) \(h)\n255\n".utf8)
        let px = base.assumingMemoryBound(to: UInt8.self)
        var row = [UInt8](repeating: 0, count: w * 3)
        for r in 0..<h {
            let p = px + r * bpr
            for c in 0..<w { row[c * 3] = p[c * 4 + 2]; row[c * 3 + 1] = p[c * 4 + 1]; row[c * 3 + 2] = p[c * 4] }
            data.append(contentsOf: row)
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("frame.ppm")
        try? data.write(to: url)
    }

    init() { }

    func reset() { rs_rx_init(rxp); rs_multi_init(mp); totalPackets = 0; totalMessages = 0; packetTimes.removeAll(); rpcEMA = 0 }

    /// Multi-source path: segmentation + one receiver per light, straight on the BGRA buffer.
    /// Returns nil when no light is found (the caller falls back to the single-ROI path).
    private func processMulti(_ pb: CVPixelBuffer, t: Double, now: Double) -> Int32? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let n = rs_multi_process(mp, base.assumingMemoryBound(to: UInt8.self), Int32(w), Int32(h), Int32(bpr), 4, 2, 1, 0, Float(t))
        let count = Int(rs_multi_track_count(mp))
        if count == 0 { lastTracks = []; return nil }
        var tracks: [TrackInfo] = []
        for i in 0..<count {
            var id: Int32 = 0, mode: Int32 = 0, pilots: Int32 = 0; var cx: Float = 0, cy: Float = 0, rad: Float = 0
            var pk: UInt32 = 0, ms: UInt32 = 0
            if rs_multi_track_info(mp, Int32(i), &id, &cx, &cy, &rad, &mode, &pk, &ms, &pilots) != 0 {
                tracks.append(TrackInfo(id: Int(id), x: cx / Float(w), y: cy / Float(h), radius: rad / Float(w), rgb: mode != 0, direct: mode == 2,
                                        group: Int(rs_multi_track_group(mp, Int32(i))), packets: Int(pk), messages: Int(ms), pilots: Int(pilots)))
            }
        }
        lastTracks = tracks
        // slot bars: assembler fill of the followed source (its leader track), else the busiest track
        var best = -1
        for i in 0..<count {
            let t = tracks[i]
            if progressSource > 0 { if t.group == progressSource && (best < 0 || t.id == t.group) { best = i } }
            else if best < 0 || t.packets > tracks[best].packets { best = i }
        }
        if best >= 0, let rx = rs_multi_track_rx(mp, Int32(best)) {
            let asmPtr = (UnsafeRawPointer(rx) + MemoryLayout<rs_rx_t>.offset(of: \rs_rx_t.assembler)!).assumingMemoryBound(to: rs_asm_t.self)
            for s in 0..<8 { lastProgress[s] = rs_asm_progress(asmPtr, UInt8(s)) }
            progressLabel = "#\(tracks[best].group)"
        } else { for s in 0..<8 { lastProgress[s] = 0 }; progressLabel = "" }
        var msg = rs_message_t(); var tid: Int32 = 0
        while rs_multi_pop_message(mp, &msg, &tid) != 0 {
            totalMessages += 1
            let text = withUnsafePointer(to: &msg.text) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
            onMessage?(Int(msg.id), Int(msg.level), text, Int(tid))
        }
        for _ in 0..<Int(n) { packetTimes.append(now) }
        if n > 0 { lastPacket = now; totalPackets += Int(n) }
        return n
    }

    private func lumaProfile(_ res: FrameProcessor.Result) {
        let n = res.count
        for i in 0..<n { profile[i] = (processor.r[i] + processor.g[i] + processor.b[i]) / 3 }
    }

    func process(_ pb: CVPixelBuffer, time t: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        frameTimes.append(now); frameTimes.removeAll { now - $0 > 1 }
        if let req = frameRequest { frameRequest = nil; req(pb, t) }

        if recorder.isRecording {
            if !recorder.append(pb, timestamp: t) {
                recorder.whenDrained { [weak self] in guard let self = self else { return }; self.onRecordingFinished?(self.recorder.summary) }
            }
            return
        }
        if dumpFrames && now - lastDump > 2 { lastDump = now; dumpFrame(pb) }
        // The global profile costs a full-frame pass and, in multi-source mode, only feeds the
        // chart and the stats bar: compute it every 4th frame there, every frame otherwise.
        multiFrame &+= 1
        var resOpt: FrameProcessor.Result? = nil
        if !multiSource || labMode || multiFrame % 4 == 0 {
            let r0 = processor.profiles(from: pb, axis: axis)
            guard r0.count > 16 else { return }
            lumaProfile(r0); resOpt = r0; lastRes = r0
        }
        if labMode, let res = resOpt { analyzeLab(pb, res); return }

        if multiSource, let n = processMulti(pb, t: t, now: now) {
            let res = lastRes
            packetTimes.removeAll { now - $0 > 2 }
            if now - lastUI > 0.08 || n > 0 {
                lastUI = now
                var stats = DecodeStats()
                stats.fps = Double(frameTimes.count); stats.packetsPerSec = Double(packetTimes.count) / 2
                stats.totalPackets = totalPackets; stats.totalMessages = totalMessages
                stats.roi = res.roi; stats.crossLength = res.crossLength; stats.profileLength = res.count
                stats.lastPacketAge = now - lastPacket
                stats.peak = res.peak; stats.satFrac = res.satFrac
                stats.rgbMode = lastTracks.contains { $0.rgb }; stats.pilots = lastTracks.map(\.pilots).reduce(0, +)
                stats.modeName = lastTracks.map(\.modeName).joined(separator: "/")
                stats.rowsPerChip = rpcEMA
                onSnapshot?(Snapshot(profile: Self.downsample(profile, res.count, to: 320), marks: [], stats: stats,
                                     slotProgress: lastProgress, tracks: lastTracks, progressLabel: progressLabel))
            }
            return
        }
        let res: FrameProcessor.Result
        if let r0 = resOpt { res = r0 } else {
            let r0 = processor.profiles(from: pb, axis: axis)
            guard r0.count > 16 else { return }
            lumaProfile(r0); res = r0; lastRes = r0
        }

        rxp.pointee.cfg.min_contrast = minContrast
        let n = processor.r.withUnsafeBufferPointer { rp in processor.g.withUnsafeBufferPointer { gp in processor.b.withUnsafeBufferPointer { bp in
            rs_rx_process(rxp, rp.baseAddress, gp.baseAddress, bp.baseAddress, Int32(res.count), Float(t))
        } } }
        var marks: [PacketMark] = []
        var progress = [Float](repeating: 0, count: 8)
        for i in 0..<Int(n) {
            var pkt = rs_packet_t(); var ch: UInt8 = 0
            guard rs_rx_packet_at(rxp, Int32(i), &pkt, &ch) != 0 else { continue }
            totalPackets += 1
            packetTimes.append(now)
            lastPacket = now
            rpcEMA = rpcEMA == 0 ? pkt.rows_per_chip : 0.9 * rpcEMA + 0.1 * pkt.rows_per_chip
            markSeq += 1
            marks.append(PacketMark(id: markSeq, start: pkt.row_start / Float(res.count), end: pkt.row_end / Float(res.count),
                                    quality: pkt.quality, slot: Int(pkt.id), seed: Int(pkt.seed), channel: Int(ch)))
        }
        var msg = rs_message_t()
        while rs_rx_pop_message(rxp, &msg) != 0 {
            totalMessages += 1
            let text = withUnsafePointer(to: &msg.text) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
            onMessage?(Int(msg.id), Int(msg.level), text, 0)
        }
        packetTimes.removeAll { now - $0 > 2 }
        for s in 0..<8 { progress[s] = rs_asm_progress(&rxp.pointee.assembler, UInt8(s)) }
        let st = rs_rx_stats(rxp).pointee

        if now - lastUI > 0.08 || n > 0 {
            lastUI = now
            var stats = DecodeStats()
            stats.fps = Double(frameTimes.count)
            stats.packetsPerSec = Double(packetTimes.count) / 2
            stats.rowsPerChip = rpcEMA
            stats.contrast = st.contrast
            stats.syncs = Int(st.syncs); stats.crcFail = Int(st.crc_fail)
            stats.totalPackets = totalPackets; stats.totalMessages = totalMessages
            let m = rs_rx_mode(rxp)
            stats.rgbMode = m != 0; stats.modeName = m == 2 ? "direct" : (m == 1 ? "RGB" : "luma")
            stats.pilots = Int(rs_rx_pilots(rxp)); stats.calCond = rs_rx_cal_cond(rxp)
            stats.peak = res.peak; stats.satFrac = res.satFrac
            stats.roi = res.roi; stats.crossLength = res.crossLength
            stats.profileLength = res.count
            stats.lastPacketAge = now - lastPacket
            onSnapshot?(Snapshot(profile: Self.downsample(profile, res.count, to: 320), marks: marks, stats: stats, slotProgress: progress))
        }
    }

    // MARK: - Lab (strobe calibration)

    private func analyzeLab(_ pb: CVPixelBuffer, _ res: FrameProcessor.Result) {
        let other: ScanAxis = axis == .rows ? .columns : .rows
        let (pA, sA) = Self.period(profile, res.count)
        let resB = processor.profiles(from: pb, axis: other)
        for i in 0..<resB.count { profileB[i] = (processor.r[i] + processor.g[i] + processor.b[i]) / 3 }
        let (_, sB) = Self.period(profileB, resB.count)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastUI > 0.15 {
            lastUI = now
            var stats = DecodeStats()
            stats.fps = Double(frameTimes.count); stats.profileLength = res.count; stats.roi = res.roi; stats.crossLength = res.crossLength
            onSnapshot?(Snapshot(profile: Self.downsample(profile, res.count, to: 320), marks: [], stats: stats, slotProgress: []))
            let rowTime = pA > 0 ? 1.0 / (strobeHz * Double(pA)) : 0
            onLab?(LabResult(axis: axis, periodRows: pA, strength: sA, otherStrength: sB,
                             rowTimeUs: rowTime * 1e6, readoutMs: rowTime * Double(res.count) * 1e3, count: res.count))
        }
    }

    /// Dominant period (in samples) of a profile via normalized autocorrelation. Returns (period, peak strength).
    static func period(_ p: [Float], _ n: Int) -> (Float, Float) {
        guard n > 32 else { return (0, 0) }
        // remove slow envelope with a moving average of 1/8 of the length
        let w = max(8, n / 8)
        var x = [Float](repeating: 0, count: n)
        var acc: Float = 0
        for i in 0..<n {
            acc += p[i]; if i >= w { acc -= p[i - w] }
            let m = acc / Float(min(i + 1, w))
            x[i] = p[i] - m
        }
        var e: Float = 0; for i in 0..<n { e += x[i] * x[i] }
        guard e > 1e-3 else { return (0, 0) }
        let maxLag = n / 3
        var best: Float = 0, bestLag = 0
        var r = [Float](repeating: 0, count: maxLag + 1)
        for lag in 1...maxLag {
            var s: Float = 0
            for i in 0..<(n - lag) { s += x[i] * x[i + lag] }
            r[lag] = s / e
        }
        // first zero crossing, then first local maximum
        var lag = 1
        while lag < maxLag && r[lag] > 0 { lag += 1 }
        while lag < maxLag - 1 {
            if r[lag] > r[lag - 1] && r[lag] >= r[lag + 1] && r[lag] > 0.05 { best = r[lag]; bestLag = lag; break }
            lag += 1
        }
        guard bestLag > 1 else { return (0, 0) }
        // parabolic refinement
        let y0 = r[bestLag - 1], y1 = r[bestLag], y2 = r[bestLag + 1]
        let denom = y0 - 2 * y1 + y2
        let delta = denom != 0 ? 0.5 * (y0 - y2) / denom : 0
        return (Float(bestLag) + delta, best)
    }

    static func downsample(_ p: [Float], _ n: Int, to m: Int) -> [Float] {
        guard n > m else { return Array(p[0..<n]) }
        var o = [Float](repeating: 0, count: m)
        for i in 0..<m {
            let a = i * n / m, b = max(a + 1, (i + 1) * n / m)
            var mx: Float = -1
            for j in a..<b { mx = max(mx, p[j]) }
            o[i] = mx
        }
        return o
    }
}
