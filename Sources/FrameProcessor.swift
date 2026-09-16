import CoreVideo

enum ScanAxis: String, CaseIterable, Identifiable {
    case rows = "Rows", columns = "Columns"
    var id: String { rawValue }
}

/// BGRA frame -> R, G, B profiles along the scan axis (shared C implementation, rs_frame.c).
final class FrameProcessor {
    struct Result { var count = 0; var roi = (0, 0); var crossLength = 0; var width = 0; var height = 0; var peak = 0; var satFrac: Float = 0 }
    private(set) var r = [Float](repeating: 0, count: 4096)
    private(set) var g = [Float](repeating: 0, count: 4096)
    private(set) var b = [Float](repeating: 0, count: 4096)

    func profiles(from pb: CVPixelBuffer, axis: ScanAxis) -> Result {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return Result() }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        var info = rs_frame_info_t()
        let px = base.assumingMemoryBound(to: UInt8.self)
        r.withUnsafeMutableBufferPointer { rp in g.withUnsafeMutableBufferPointer { gp in b.withUnsafeMutableBufferPointer { bp in
            rs_frame_profile_rgb(px, Int32(w), Int32(h), Int32(bpr), 4, 2, 1, 0, axis == .rows ? 0 : 1,
                                 rp.baseAddress, gp.baseAddress, bp.baseAddress, &info)
        } } }
        var res = Result(); res.width = w; res.height = h
        res.count = Int(info.count); res.roi = (Int(info.roi_start), Int(info.roi_end)); res.peak = Int(info.peak); res.satFrac = info.sat_frac
        res.crossLength = axis == .rows ? w : h
        return res
    }
}
