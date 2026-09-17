import AVFoundation
import Combine
import SwiftUI

struct LogMessage: Identifiable, Hashable, Codable {
    var id = UUID()
    let date: Date
    let slot: Int
    let level: Int
    let text: String
    var source: Int = 0          // multi-source track id, 0 = single receiver
    var replay: Bool = false     // decoded from a recording (Lab), not live
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
    var remoteEnabled = true      /* TCP remote session server (Settings > Debug) */
    var recordingEnabled = false  /* Record button in the live view (Settings > Debug); remote record always works */
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
    @Published var boardIds: [Int: String] = [:]      // source (group id) -> "id=xxxx" announced by the board
    @Published var sourceFilter = 0                    // console: 0 = every source
    @Published var replayProgress = ""
    @Published var replayRunning = false
    let replayEngine = ReplayEngine()
    private var historyDirty = false
    private static let historyURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("history.json")
    private static let historyMax = 2000
    @Published var labMode = false { didSet { pipeline.labMode = labMode } }
    @Published var error: String?
    @Published var isRecording = false
    @Published var lastRecording = ""
    @Published var recordingNote = ""
    @Published var settings = CaptureSettings() { didSet { applySettings(old: oldValue) } }
    @Published var remoteClients = 0
    @Published var remoteAddress = ""
    let remote = RemoteServer()
    private var remoteStatsTimer: Timer?
    private var pendingRecordReply: (reply: ([String: Any], Data?) -> Void, send: Bool, keep: Bool)?

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
        for (src, id) in boardIds { d[src] = "board " + id + (d[src].map { "\n" + $0 } ?? "") }
        return d
    }

    func start() {
        guard !started else { return }
        started = true
        loadHistory()
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
                Diag.log("[blinko] message src \(source) slot \(slot) level \(level): \(text)")
                let m = LogMessage(date: Date(), slot: slot, level: level, text: text, source: source)
                self.messages.insert(m, at: 0)
                if self.messages.count > Self.historyMax { self.messages.removeLast() }
                self.historyDirty = true
                if source > 0, let r = text.range(of: "id=") {
                    let hex = text[r.upperBound...].prefix(4)
                    if hex.count == 4, hex.allSatisfy({ $0.isHexDigit }) { self.boardIds[source] = String(hex) }
                }
                if self.remoteClients > 0 {
                    self.remote.broadcast(["type": "message", "t": m.date.timeIntervalSince1970, "slot": slot, "level": level,
                                           "level_name": m.levelName, "text": text, "source": source])
                }
                self.haptic.notificationOccurred(level >= 4 && level != 5 ? .error : .success)
            }
        }
        pipeline.recorder.latestMotion = { [weak self] in (self?.motion.gyro ?? [0, 0, 0], self?.motion.accel ?? [0, 0, 0]) }
        pipeline.onRecordingFinished = { [weak self] summary in
            Task { @MainActor in
                guard let self = self else { return }
                self.isRecording = false; self.lastRecording = summary; Diag.log("[blinko] recording done: \(summary)")
                self.finishRemoteRecording()
            }
        }
        pipeline.onLab = { [weak self] r in
            Diag.log(String(format: "[blinko] lab axis=%@ period=%.2f strength=%.2f other=%.2f rowTime=%.2fus readout=%.2fms n=%d", r.axis.rawValue, r.periodRows, r.strength, r.otherStrength, r.rowTimeUs, r.readoutMs, r.count))
            Task { @MainActor in self?.lab = r }
        }
        controller.frameHandler = { [weak self] pb, t in self?.pipeline.process(pb, time: t) }
        motion.onUpdate = { [weak self] still, level in
            Task { @MainActor in self?.isStill = still; self?.motionLevel = level }
        }
        motion.start()
        if settings.remoteEnabled { startRemote() }
        AVCaptureDevice.requestAccess(for: .video) { ok in
            Task { @MainActor in
                if ok { self.configureCamera() } else { self.error = "Camera access denied. Enable it in Settings." }
            }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.historyDirty { self.historyDirty = false; self.saveHistory() }
                let e = self.controller.currentExposure()
                self.camera.exposureUs = e.us; self.camera.iso = e.iso; self.camera.lensPosition = e.lens
                let st = self.stats
                let tr = self.tracks.map { "#\($0.id)(\(Int($0.x * 100)),\(Int($0.y * 100)) \($0.modeName) \($0.packets)p)" }.joined(separator: " ")
                Diag.log(String(format: "[blinko] stats fps=%.0f pkt/s=%.1f rpc=%.1f contrast=%.0f syncs=%d crcfail=%d pkts=%d msgs=%d roi=%d-%d/%d n=%d exp=%.1fus iso=%.0f mode=%@ pilots=%d cond=%.2f peak=%d sat=%.3f tracks=%@",
                             st.fps, st.packetsPerSec, st.rowsPerChip, st.contrast, st.syncs, st.crcFail, st.totalPackets, st.totalMessages,
                             st.roi.0, st.roi.1, st.crossLength, st.profileLength, e.us, e.iso, st.modeName, st.pilots, st.calCond, st.peak, st.satFrac, tr))
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
                    Diag.log(String(format: "[blinko] camera %@ %dx%d @%.0f fps minExp=%.1fus maxExp=%.0fus iso %.0f-%.0f lens=%d zoom=%.1f rates=%@",
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
        if s.remoteEnabled != old.remoteEnabled { s.remoteEnabled ? startRemote() : stopRemote() }
        if s.camera != old.camera || s.fps != old.fps { configureCamera(); return }
        if s.exposure != old.exposure || s.iso != old.iso { controller.applyExposure(fraction: s.exposure, isoFraction: s.iso) }
        if s.lensPosition != old.lensPosition { controller.applyLens(position: s.lensPosition) }
        if s.zoom != old.zoom { controller.applyZoom(CGFloat(s.zoom)) }
    }

    func clearMessages() { messages.removeAll(); boardIds.removeAll(); pipeline.reset(); saveHistory() }

    // MARK: - history (Documents/history.json, last 2000 messages, survives relaunches)

    private func loadHistory() {
        guard let d = try? Data(contentsOf: Self.historyURL), let list = try? JSONDecoder().decode([LogMessage].self, from: d) else { return }
        messages = list
    }
    private func saveHistory() {
        let list = Array(messages.prefix(Self.historyMax))
        DispatchQueue.global(qos: .utility).async {
            if let d = try? JSONEncoder().encode(list) { try? d.write(to: Self.historyURL, options: .atomic) }
        }
    }

    /// Sources seen in the console (group ids), with their board id when announced.
    var sourcesSeen: [(id: Int, board: String?)] {
        var ids = Set<Int>()
        for m in messages where m.source > 0 { ids.insert(m.source) }
        return ids.sorted().map { ($0, boardIds[$0]) }
    }
    var filteredMessages: [LogMessage] { sourceFilter == 0 ? messages : messages.filter { $0.source == sourceFilter } }
    func deleteMessages(at offsets: IndexSet) {
        let shown = filteredMessages
        let ids = Set(offsets.map { shown[$0].id })
        messages.removeAll { ids.contains($0.id) }
        saveHistory()
    }

    // MARK: - replay of a recording (Lab)

    func replay(_ url: URL) {
        guard !replayRunning else { return }
        replayRunning = true; replayProgress = "replaying \(url.lastPathComponent)…"
        replayEngine.run(url, onMessage: { [weak self] slot, level, text, source in
            Task { @MainActor in
                guard let self = self else { return }
                self.messages.insert(LogMessage(date: Date(), slot: slot, level: level, text: text, source: source, replay: true), at: 0)
                if self.remoteClients > 0 {
                    self.remote.broadcast(["type": "message", "t": Date().timeIntervalSince1970, "slot": slot, "level": level,
                                           "level_name": LogMessage.levelNames[min(level, 7)], "text": text, "source": source, "replay": true])
                }
            }
        }, onProgress: { [weak self] done, total in
            Task { @MainActor in self?.replayProgress = "frame \(done)/\(total)" }
        }, onDone: { [weak self] r in
            Task { @MainActor in
                guard let self = self else { return }
                self.replayRunning = false
                self.replayProgress = r.map { String(format: "%@: %d frames, %d packets, %d messages, %d tracks in %.1f s", url.lastPathComponent, $0.frames, $0.packets, $0.messages, $0.tracks, $0.seconds) } ?? "replay failed"
                Diag.log("[replay] " + self.replayProgress)
                self.remote.broadcast(["type": "replay", "state": "done", "summary": self.replayProgress])
            }
        })
    }

    // MARK: - remote session (RemoteServer.swift; client: ios/tools/rslive.py)

    func startRemote() {
        remote.onCommand = { [weak self] cmd, reply in Task { @MainActor in self?.handleRemote(cmd, reply) } }
        remote.onClientsChanged = { [weak self] n in Task { @MainActor in self?.remoteClients = n } }
        remote.start()
        remoteAddress = "\(RemoteServer.localIPv4() ?? "no Wi-Fi"):\(RemoteServer.port)"
        remoteStatsTimer?.invalidate()
        remoteStatsTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.remoteClients > 0 else { return }
                self.remote.broadcast(self.statsDict())
            }
        }
        Diag.log("[remote] server on \(remoteAddress)")
    }

    func stopRemote() {
        remoteStatsTimer?.invalidate(); remoteStatsTimer = nil
        remote.stop(); remoteClients = 0
    }

    private func statsDict() -> [String: Any] {
        let st = stats, e = camera
        let tr: [[String: Any]] = tracks.map { ["id": $0.id, "group": $0.group, "board": boardIds[$0.group] ?? "", "x": $0.x, "y": $0.y, "radius": $0.radius, "mode": $0.modeName,
                                                 "packets": $0.packets, "messages": $0.messages, "pilots": $0.pilots] }
        return ["type": "stats", "t": Date().timeIntervalSince1970, "fps": st.fps, "pkt_per_s": st.packetsPerSec,
                "rows_per_chip": st.rowsPerChip, "contrast": st.contrast, "syncs": st.syncs, "crc_fail": st.crcFail,
                "packets": st.totalPackets, "messages": st.totalMessages, "roi": [st.roi.0, st.roi.1], "mode": st.modeName,
                "pilots": st.pilots, "cond": st.calCond, "peak": st.peak, "sat": st.satFrac, "last_packet_age": st.lastPacketAge,
                "exposure_us": e.exposureUs, "iso": e.iso, "cam_fps": e.fps, "width": e.width, "height": e.height,
                "still": isStill, "motion": motionLevel, "recording": isRecording, "tracks": tr,
                "thermal": ["nominal", "fair", "serious", "critical"][min(ProcessInfo.processInfo.thermalState.rawValue, 3)]]
    }

    private func settingsDict() -> [String: Any] {
        let s = settings
        return ["camera": s.camera.rawValue, "fps": s.fps, "exposure": s.exposure, "iso": s.iso, "lensPosition": s.lensPosition,
                "zoom": s.zoom, "axis": s.axis.rawValue, "minContrast": s.minContrast, "multiSource": s.multiSource,
                "remoteEnabled": s.remoteEnabled, "camera_name": camera.name, "frame_rates": camera.frameRates,
                "min_exposure_us": camera.minExposureUs, "iso_range": [camera.minISO, camera.maxISO], "max_zoom": camera.maxZoom]
    }

    private func handleRemote(_ cmd: [String: Any], _ reply: @escaping ([String: Any], Data?) -> Void) {
        let name = cmd["cmd"] as? String ?? ""
        switch name {
        case "get":
            reply(["type": "settings", "settings": settingsDict()], nil)
        case "stats":
            reply(statsDict(), nil)
        case "messages":
            let list: [[String: Any]] = messages.reversed().map { ["t": $0.date.timeIntervalSince1970, "slot": $0.slot, "level": $0.level,
                                                                     "level_name": $0.levelName, "text": $0.text, "source": $0.source] }
            reply(["type": "messages", "messages": list], nil)
        case "reset":
            clearMessages(); reply(["type": "ok", "cmd": name], nil)
        case "files":
            let dir = Recorder.directory
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            let list: [[String: Any]] = names.map { n in
                let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path)[.size] as? Int) ?? 0
                return ["name": n, "size": size]
            }
            reply(["type": "files", "files": list], nil)
        case "delete":
            let names = (cmd["names"] as? [String]) ?? [(cmd["name"] as? String) ?? ""]
            var removed = 0
            for n in names where !n.isEmpty && !n.contains("/") {
                if (try? FileManager.default.removeItem(at: Recorder.directory.appendingPathComponent(n))) != nil { removed += 1 }
            }
            reply(["type": "ok", "cmd": name, "removed": removed], nil)
        case "set":
            guard let key = cmd["key"] as? String else { reply(["type": "error", "msg": "set needs key/value"], nil); return }
            let v = cmd["value"]
            let d = (v as? Double) ?? (v as? NSNumber)?.doubleValue ?? Double((v as? String) ?? "") ?? 0
            let b = (v as? Bool) ?? (d != 0)
            switch key {
            case "fps": settings.fps = d
            case "exposure": settings.exposure = d
            case "iso": settings.iso = d
            case "lensPosition": settings.lensPosition = Float(d)
            case "zoom": settings.zoom = d
            case "minContrast": settings.minContrast = Float(d)
            case "multiSource": settings.multiSource = b
            case "axis": if let a = ScanAxis(rawValue: (v as? String ?? "").capitalized) { settings.axis = a }
            case "camera": if let c = CameraKind(rawValue: (v as? String ?? "").capitalized) { settings.camera = c }
            case "note": recordingNote = v as? String ?? ""
            default: reply(["type": "error", "msg": "unknown key \(key)"], nil); return
            }
            reply(["type": "settings", "settings": settingsDict()], nil)
        case "replay":
            let name = cmd["name"] as? String ?? ""
            let url = Recorder.directory.appendingPathComponent(name)
            guard !name.isEmpty, !name.contains("/"), FileManager.default.fileExists(atPath: url.path) else { reply(["type": "error", "msg": "no such recording"], nil); return }
            replay(url); reply(["type": "replay", "state": "started", "name": name], nil)
        case "frame":
            let step = max(1, cmd["step"] as? Int ?? 2)
            pipeline.frameRequest = { pb, t in
                guard let f = Pipeline.subsampled(pb, step: step) else { reply(["type": "error", "msg": "no frame"], nil); return }
                reply(["type": "frame", "w": f.w, "h": f.h, "step": step, "format": "BGRA", "t": t], f.data)
            }
        case "record":
            guard !isRecording else { reply(["type": "error", "msg": "already recording"], nil); return }
            let seconds = cmd["seconds"] as? Double ?? 2
            recordingNote = cmd["note"] as? String ?? recordingNote
            pendingRecordReply = (reply, cmd["send"] as? Bool ?? true, cmd["keep"] as? Bool ?? true)
            startRecording(seconds: seconds)
            reply(["type": "recording", "state": "started", "seconds": seconds, "note": recordingNote], nil)
        default:
            reply(["type": "error", "msg": "unknown cmd \(name)"], nil)
        }
    }

    private func finishRemoteRecording() {
        guard let p = pendingRecordReply else { return }
        pendingRecordReply = nil
        guard let url = pipeline.recorder.url else { p.reply(["type": "error", "msg": "no recording file"], nil); return }
        let summary = lastRecording
        p.reply(["type": "recording", "state": "done", "file": url.lastPathComponent, "summary": summary], nil)
        guard p.send else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? Data(contentsOf: url) else { p.reply(["type": "error", "msg": "cannot read recording"], nil); return }
            p.reply(["type": "file", "name": url.lastPathComponent, "size": data.count], data)
            if !p.keep { try? FileManager.default.removeItem(at: url) }
        }
    }

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
