import AVFoundation
import Combine
import SwiftUI

struct LogMessage: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let slot: Int
    let level: Int
    let text: String
    var source: Int = 0          // multi-source track id, 0 = single receiver
    static let levelNames = ["DEBUG", "INFO", "WARN", "ERROR", "FATAL", "STATUS", "FAULT", "?"]
    var levelName: String { Self.levelNames[min(level, 7)] }
    var color: Color {
        switch level { case 0: return .gray; case 1: return .green; case 2: return .yellow; case 3: return .orange
                       case 4, 6: return .red; case 5: return .cyan; default: return .white }
    }
}

struct CaptureSettings: Equatable {
    var camera: CameraKind = .wide
    var fps: Double = 120
    var exposure: Double = 0        // 0 = shortest
    var iso: Double = 0.1
    var lensPosition: Float = 1.0   // 1 = far focus -> near LED is defocused
    var zoom: Double = 1
    var axis: ScanAxis = .rows
    var minContrast: Float = 6
    var strobeHz: Double = 2000
    var dumpFrames = false
    var multiSource = true        /* segment the frame and decode every light separately */
}

@MainActor
final class SessionModel: ObservableObject {
    @Published var messages: [LogMessage] = []
    @Published var profile: [Float] = []
    @Published var marks: [PacketMark] = []
    @Published var stats = DecodeStats()
    @Published var slotProgress: [Float] = Array(repeating: 0, count: 8)
    @Published var isStill = true
    @Published var motionLevel = 0.0
    @Published var camera = CameraInfo()
    @Published var lab: LabResult?
    @Published var tracks: [TrackInfo] = []
    @Published var labMode = false { didSet { pipeline.labMode = labMode } }
    @Published var error: String?
    @Published var isRecording = false
    @Published var lastRecording = ""
    @Published var recordingNote = ""
    @Published var settings = CaptureSettings() { didSet { applySettings(old: oldValue) } }

    let controller = CameraController()
    let pipeline = Pipeline()
    let motion = MotionMonitor()
    private var started = false
    private let haptic = UINotificationFeedbackGenerator()
    private var refreshTimer: Timer?

    var faultMessage: LogMessage? { messages.first { $0.level == 6 || $0.level == 4 } }
    var lastTextPerSource: [Int: String] {
        var d: [Int: String] = [:]
        for m in messages where m.source > 0 && d[m.source] == nil { d[m.source] = m.text }
        return d
    }

    func start() {
        guard !started else { return }
        started = true
        pipeline.onSnapshot = { [weak self] s in
            Task { @MainActor in
                guard let self = self else { return }
                self.profile = s.profile; self.marks = s.marks; self.stats = s.stats; self.tracks = s.tracks
                if !s.slotProgress.isEmpty { self.slotProgress = s.slotProgress }
            }
        }
        pipeline.onMessage = { [weak self] slot, level, text, source in
            Task { @MainActor in
                guard let self = self else { return }
                Diag.log("[rslog] message src \(source) slot \(slot) level \(level): \(text)")
                self.messages.insert(LogMessage(date: Date(), slot: slot, level: level, text: text, source: source), at: 0)
                if self.messages.count > 500 { self.messages.removeLast() }
                self.haptic.notificationOccurred(level >= 4 && level != 5 ? .error : .success)
            }
        }
        pipeline.recorder.latestMotion = { [weak self] in (self?.motion.gyro ?? [0, 0, 0], self?.motion.accel ?? [0, 0, 0]) }
        pipeline.onRecordingFinished = { [weak self] summary in
            Task { @MainActor in self?.isRecording = false; self?.lastRecording = summary; Diag.log("[rslog] recording done: \(summary)") }
        }
        pipeline.onLab = { [weak self] r in
            Diag.log(String(format: "[rslog] lab axis=%@ period=%.2f strength=%.2f other=%.2f rowTime=%.2fus readout=%.2fms n=%d", r.axis.rawValue, r.periodRows, r.strength, r.otherStrength, r.rowTimeUs, r.readoutMs, r.count))
            Task { @MainActor in self?.lab = r }
        }
        controller.frameHandler = { [weak self] pb, t in self?.pipeline.process(pb, time: t) }
        motion.onUpdate = { [weak self] still, level in
            Task { @MainActor in self?.isStill = still; self?.motionLevel = level }
        }
        motion.start()
        AVCaptureDevice.requestAccess(for: .video) { ok in
            Task { @MainActor in
                if ok { self.configureCamera() } else { self.error = "Camera access denied. Enable it in Settings." }
            }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let e = self.controller.currentExposure()
                self.camera.exposureUs = e.us; self.camera.iso = e.iso; self.camera.lensPosition = e.lens
                let st = self.stats
                let tr = self.tracks.map { "#\($0.id)(\(Int($0.x * 100)),\(Int($0.y * 100)) \($0.rgb ? "rgb" : "luma") \($0.packets)p)" }.joined(separator: " ")
                Diag.log(String(format: "[rslog] stats fps=%.0f pkt/s=%.1f rpc=%.1f contrast=%.0f syncs=%d crcfail=%d pkts=%d msgs=%d roi=%d-%d/%d n=%d exp=%.1fus iso=%.0f mode=%@ pilots=%d cond=%.2f peak=%d sat=%.3f tracks=%@",
                             st.fps, st.packetsPerSec, st.rowsPerChip, st.contrast, st.syncs, st.crcFail, st.totalPackets, st.totalMessages,
                             st.roi.0, st.roi.1, st.crossLength, st.profileLength, e.us, e.iso, st.rgbMode ? "rgb" : "luma", st.pilots, st.calCond, st.peak, st.satFrac, tr))
            }
        }
    }

    func configureCamera() {
        let s = settings
        controller.configure(kind: s.camera, fps: s.fps) { result in
            Task { @MainActor in
                switch result {
                case .success(let info):
                    self.camera = info
                    self.error = nil
                    Diag.log(String(format: "[rslog] camera %@ %dx%d @%.0f fps minExp=%.1fus maxExp=%.0fus iso %.0f-%.0f lens=%d zoom=%.1f rates=%@",
                                 info.name, info.width, info.height, info.fps, info.minExposureUs, info.maxExposureUs, info.minISO, info.maxISO,
                                 info.lensSupported ? 1 : 0, Double(info.maxZoom), info.frameRates.description))
                    self.controller.applyExposure(fraction: s.exposure, isoFraction: s.iso)
                    self.controller.applyLens(position: s.lensPosition)
                    self.controller.applyZoom(CGFloat(s.zoom))
                case .failure(let e): self.error = e.localizedDescription
                }
            }
        }
    }

    private func applySettings(old: CaptureSettings) {
        let s = settings
        pipeline.axis = s.axis
        pipeline.minContrast = s.minContrast
        pipeline.strobeHz = s.strobeHz
        pipeline.dumpFrames = s.dumpFrames
        pipeline.multiSource = s.multiSource
        if s.camera != old.camera || s.fps != old.fps { configureCamera(); return }
        if s.exposure != old.exposure || s.iso != old.iso { controller.applyExposure(fraction: s.exposure, isoFraction: s.iso) }
        if s.lensPosition != old.lensPosition { controller.applyLens(position: s.lensPosition) }
        if s.zoom != old.zoom { controller.applyZoom(CGFloat(s.zoom)) }
    }

    func clearMessages() { messages.removeAll(); pipeline.reset() }

    func startRecording(seconds: Double) {
        guard !isRecording else { return }
        let c = camera, s = settings
        let header = Recorder.Header(width: c.width / 2, height: c.height, columnStep: 2, pixelFormat: "BGRA",
                                     fps: c.fps, exposureUs: c.exposureUs, iso: c.iso, lensPosition: c.lensPosition,
                                     camera: c.name, device: UIDevice.current.model, axis: s.axis.rawValue,
                                     startedAt: ISO8601DateFormatter().string(from: Date()), note: recordingNote)
        controller.queue.async { [pipeline] in
            _ = pipeline.recorder.start(seconds: seconds, header: header)
        }
        isRecording = true
        lastRecording = "recording…"
    }

    var exportText: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return messages.reversed().map { "\(f.string(from: $0.date)) [\($0.levelName)] src\($0.source) slot\($0.slot) \($0.text)" }.joined(separator: "\n")
    }
}
