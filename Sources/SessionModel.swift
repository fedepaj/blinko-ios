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
    var levelName: String { Self.levelNames[max(0, min(level, 7))] }
    var color: Color {
        switch level { case 0: return .gray; case 1: return .green; case 2: return .yellow; case 3: return .orange
                       case 4, 6: return .red; case 5: return .cyan; default: return .white }
    }
}

extension LogMessage {
    /// Missing keys take their defaults. The synthesized decoder requires every key, so a
    /// history.json written before a field was added failed to decode as a whole and was then
    /// overwritten by the next save: a new field has to be given a default here.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date(timeIntervalSinceReferenceDate: 0)
        slot = try c.decodeIfPresent(Int.self, forKey: .slot) ?? 0
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? 7
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        source = try c.decodeIfPresent(Int.self, forKey: .source) ?? 0
        replay = try c.decodeIfPresent(Bool.self, forKey: .replay) ?? false
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
    var remoteEnabled = true      /* TCP remote session server (Settings > Debug), for clients on this device (USB forward) */
    var remoteLAN = false         /* ...and for clients on the network: the server has no authentication */
    var recordingEnabled = false  /* Record button in the live view (Settings > Debug); remote record always works */

    /// The defaults, with the two remote switches as the user left them (UserDefaults): what the
    /// server is exposed to must not fall back to a default at every launch.
    static func stored() -> CaptureSettings {
        var s = CaptureSettings(); let d = UserDefaults.standard
        if let v = d.object(forKey: remoteEnabledKey) as? Bool { s.remoteEnabled = v }
        if let v = d.object(forKey: remoteLANKey) as? Bool { s.remoteLAN = v }
        return s
    }
    static let remoteEnabledKey = "remoteEnabled", remoteLANKey = "remoteLAN"
}

@MainActor
final class SessionModel: ObservableObject {
    @Published var messages: [LogMessage] = []
    @Published var profile: [Float] = []
    @Published var marks: [PacketMark] = []
    @Published var stats = DecodeStats()
    @Published var isStill = true
    @Published var motionLevel = 0.0
    @Published var camera = CameraInfo()
    @Published var lab: LabResult?
    @Published var tracks: [TrackInfo] = []
    @Published var boardIds: [Int: String] = [:]      // source (group id) -> "id=xxxx" announced by the board
    @Published var sourceFilter = 0   // console: 0 = every source
    @Published var replayProgress = ""
    @Published var replayRunning = false
    let replayEngine = ReplayEngine()
    private var historyDirty = false
    private static let historyURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("history.json")
    private static let historyMax = 2000
    @Published var labMode = false { didSet { let on = labMode; onCamera { $0.labMode = on } } }
    @Published var error: String?
    @Published var isRecording = false
    @Published var lastRecording = ""
    @Published var recordingNote = ""
    @Published var settings = CaptureSettings.stored() { didSet { applySettings(old: oldValue) } }
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
    /// Sensor row time (µs) the receivers and the replay use: the Lab calibration's last good
    /// measurement, kept in UserDefaults so it does not have to be redone after every launch.
    private var rowTimeUs = Pipeline.defaultRowUs
    private static let rowTimeKey = "rowTimeUs"

    /// The pipeline's state belongs to the camera queue (see Pipeline): every change made from
    /// here goes through this, so it lands between two frames and never inside one.
    private func onCamera(_ change: @escaping (Pipeline) -> Void) {
        controller.queue.async { [pipeline] in change(pipeline) }
    }

    private func setRowTime(_ us: Double) {
        guard us != rowTimeUs else { return }
        rowTimeUs = us
        UserDefaults.standard.set(us, forKey: Self.rowTimeKey)
        onCamera { $0.rowUs = us }
    }

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
        let storedRow = UserDefaults.standard.double(forKey: Self.rowTimeKey)
        if storedRow > 2 && storedRow < 30 { rowTimeUs = storedRow; onCamera { $0.rowUs = storedRow } }
        pipeline.onSnapshot = { [weak self] s in
            Task { @MainActor in
                guard let self = self else { return }
                self.profile = s.profile; self.marks = s.marks; self.stats = s.stats; self.tracks = s.tracks
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
        pipeline.onRecordingFinished = { [weak self] summary, failure in
            Task { @MainActor in
                guard let self = self else { return }
                self.isRecording = false; self.lastRecording = summary; Diag.log("[blinko] recording done: \(summary)")
                self.finishRemoteRecording(failure: failure)
            }
        }
        pipeline.onLab = { [weak self] r in
            Diag.log(String(format: "[blinko] lab axis=%@ period=%.2f strength=%.2f other=%.2f rowTime=%.2fus readout=%.2fms n=%d", r.axis.rawValue, r.periodRows, r.strength, r.otherStrength, r.rowTimeUs, r.readoutMs, r.count))
            Task { @MainActor in self?.lab = r; if r.rowTimeUs > 2 && r.rowTimeUs < 30 && r.strength > 0.3 { self?.setRowTime(r.rowTimeUs) } }
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
                self.onCamera { $0.exposureUs = e.us }
                let st = self.stats
                let tr = self.tracks.map { "#\($0.id)(\(Int($0.x * 100)),\(Int($0.y * 100)) \($0.modeName) \($0.packets)p)" }.joined(separator: " ")
                Diag.log(String(format: "[blinko] stats fps=%.0f pkt/s=%.1f rpc=%.1f contrast=%.0f syncs=%d crcfail=%d pkts=%d msgs=%d roi=%d-%d/%d n=%d exp=%.1fus iso=%.0f mode=%@ pilots=%d cond=%.2f peak=%d sat=%.3f tracks=%@",
                             st.fps, st.packetsPerSec, st.rowsPerChip, st.contrast, st.syncs, st.crcFail, st.totalPackets, st.totalMessages,
                             st.roi.0, st.roi.1, st.crossLength, st.profileLength, e.us, e.iso, st.modeName, st.pilots, st.calCond, st.peak, st.satFrac, tr))
            }
        }
    }

    func configureCamera() {
        controller.configure(kind: settings.camera, fps: settings.fps) { result in
            Task { @MainActor in
                switch result {
                case .success(let info):
                    // the settings as they are now: the ones captured before the (asynchronous) configuration
                    // put the exposure, lens and zoom back to what they were when it was requested
                    let s = self.settings
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
        onCamera { p in
            p.axis = s.axis; p.minContrast = s.minContrast; p.strobeHz = s.strobeHz
            p.dumpFrames = s.dumpFrames; p.multiSource = s.multiSource
        }
        if s.remoteEnabled != old.remoteEnabled || s.remoteLAN != old.remoteLAN {
            UserDefaults.standard.set(s.remoteEnabled, forKey: CaptureSettings.remoteEnabledKey)
            UserDefaults.standard.set(s.remoteLAN, forKey: CaptureSettings.remoteLANKey)
            stopRemote()                      // the interface is chosen when the listener is made
            if s.remoteEnabled { startRemote() }
        }
        if s.camera != old.camera || s.fps != old.fps { configureCamera(); return }
        if s.exposure != old.exposure || s.iso != old.iso { controller.applyExposure(fraction: s.exposure, isoFraction: s.iso) }
        if s.lensPosition != old.lensPosition { controller.applyLens(position: s.lensPosition) }
        if s.zoom != old.zoom { controller.applyZoom(CGFloat(s.zoom)) }
    }

    func clearMessages() { messages.removeAll(); boardIds.removeAll(); onCamera { $0.reset() }; saveHistory() }

    // MARK: - history (Documents/history.json, last 2000 messages, survives relaunches)

    private func loadHistory() {
        guard let d = try? Data(contentsOf: Self.historyURL) else { return }
        guard let list = try? JSONDecoder().decode([LogMessage].self, from: d) else { Diag.log("[blinko] history.json is unreadable, ignored"); return }
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

    /// The replay takes the camera queue for as long as it runs (see ReplayEngine): no live
    /// decoding meanwhile, and no recording, which lives on the frames of that queue.
    func replay(_ url: URL) {
        guard !replayRunning, !isRecording else { return }
        replayRunning = true; replayProgress = "replaying \(url.lastPathComponent)…"
        replayEngine.run(url, on: controller.queue, rowUs: rowTimeUs, onMessage: { [weak self] slot, level, text, source in
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
        }, onDone: { [weak self] r, failure in
            Task { @MainActor in
                guard let self = self else { return }
                self.replayRunning = false
                self.replayProgress = r.map { String(format: "%@: %d frames, %d packets, %d messages, %d tracks in %.1f s%@", url.lastPathComponent, $0.frames, $0.packets, $0.messages, $0.tracks, $0.seconds, $0.truncated ? " (file cut short)" : "") }
                    ?? "\(url.lastPathComponent): replay failed, \(failure ?? "unknown reason")"
                Diag.log("[replay] " + self.replayProgress)
                self.remote.broadcast(["type": "replay", "state": r != nil ? "done" : "failed", "summary": self.replayProgress])
            }
        })
    }

    // MARK: - remote session (RemoteServer.swift; client: ios/tools/rslive.py)

    func startRemote() {
        remote.onCommand = { [weak self] cmd, reply in Task { @MainActor in self?.handleRemote(cmd, reply) } }
        remote.onClientsChanged = { [weak self] n in Task { @MainActor in self?.remoteClients = n } }
        remote.start(lan: settings.remoteLAN)
        remoteAddress = settings.remoteLAN ? "\(RemoteServer.localIPv4() ?? "no Wi-Fi"):\(RemoteServer.port)" : "localhost:\(RemoteServer.port)"
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
                "remoteEnabled": s.remoteEnabled, "remoteLAN": s.remoteLAN, "camera_name": camera.name, "frame_rates": camera.frameRates,
                "min_exposure_us": camera.minExposureUs, "iso_range": [camera.minISO, camera.maxISO], "max_zoom": camera.maxZoom]
    }

    /// The recording a remote client names: a plain file name of a regular file directly inside
    /// the recordings directory, nil for anything else. Names are joined to that directory, and
    /// only "/" was refused: ".." made `delete` remove the whole Documents directory, "." the recordings.
    private func recording(named name: String) -> URL? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        let dir = Recorder.directory.standardizedFileURL
        let url = dir.appendingPathComponent(name).standardizedFileURL
        guard url.deletingLastPathComponent().path == dir.path,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return url
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
            for n in names {
                if let url = recording(named: n), (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
            }
            reply(["type": "ok", "cmd": name, "removed": removed], nil)
        case "set":
            guard let key = cmd["key"] as? String else { reply(["type": "error", "msg": "set needs key/value"], nil); return }
            let v = cmd["value"]
            let d = (v as? Double) ?? (v as? NSNumber)?.doubleValue ?? Double((v as? String) ?? "") ?? 0
            let b = (v as? Bool) ?? (d != 0)
            // "nan" and "inf" parse as Doubles: keep them out of the numeric settings
            guard d.isFinite || ["axis", "camera", "note"].contains(key) else { reply(["type": "error", "msg": "\(key) needs a finite number"], nil); return }
            switch key {
            case "fps":
                // only the rates the camera lists (frame_rates in `get`): anything else used to reach AVFoundation as it came
                guard camera.frameRates.contains(d) else { reply(["type": "error", "msg": "fps must be one of \(camera.frameRates.map { Int($0) })"], nil); return }
                settings.fps = d
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
            guard let url = recording(named: name) else { reply(["type": "error", "msg": "no such recording"], nil); return }
            guard !replayRunning, !isRecording else { reply(["type": "error", "msg": replayRunning ? "a replay is already running" : "a recording is running"], nil); return }
            replay(url); reply(["type": "replay", "state": "started", "name": name], nil)
        case "frame":
            let step = max(1, cmd["step"] as? Int ?? 2)
            onCamera { p in
                p.frameRequest = { pb, t in
                    guard let f = Pipeline.subsampled(pb, step: step) else { reply(["type": "error", "msg": "no frame"], nil); return }
                    reply(["type": "frame", "w": f.w, "h": f.h, "step": step, "format": "BGRA", "t": t], f.data)
                }
            }
        case "record":
            guard !isRecording else { reply(["type": "error", "msg": "already recording"], nil); return }
            guard !replayRunning else { reply(["type": "error", "msg": "a replay is running"], nil); return }
            let seconds = cmd["seconds"] as? Double ?? 2
            // bounded: the client chose the duration freely, and a recording is about 250 MB per second at 120 fps
            guard seconds >= 0.1, seconds <= 10 else { reply(["type": "error", "msg": "seconds must be between 0.1 and 10"], nil); return }
            recordingNote = cmd["note"] as? String ?? recordingNote
            pendingRecordReply = (reply, cmd["send"] as? Bool ?? true, cmd["keep"] as? Bool ?? true)
            startRecording(seconds: seconds)
            reply(["type": "recording", "state": "started", "seconds": seconds, "note": recordingNote], nil)
        default:
            reply(["type": "error", "msg": "unknown cmd \(name)"], nil)
        }
    }

    /// Answers the remote client that asked for the recording, if one did. `failure`: why the
    /// recording did not run to its end (it could not be started, or a write failed).
    private func finishRemoteRecording(failure: String? = nil) {
        guard let p = pendingRecordReply else { return }
        pendingRecordReply = nil
        if let f = failure { p.reply(["type": "error", "msg": "recording failed: \(f)"], nil); return }
        guard let url = pipeline.recorder.url else { p.reply(["type": "error", "msg": "no recording file"], nil); return }
        let summary = lastRecording
        p.reply(["type": "recording", "state": "done", "file": url.lastPathComponent, "summary": summary], nil)
        guard p.send else { return }
        DispatchQueue.global(qos: .utility).async {
            // mapped, not read into memory: the file is hundreds of MB (it stays mapped after the delete below, until it is sent)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { p.reply(["type": "error", "msg": "cannot read recording"], nil); return }
            guard data.count <= Int(UInt32.max) else { p.reply(["type": "error", "msg": "recording too large to send, kept on the phone as \(url.lastPathComponent)"], nil); return }
            p.reply(["type": "file", "name": url.lastPathComponent, "size": data.count], data)
            if !p.keep { try? FileManager.default.removeItem(at: url) }
        }
    }

    func startRecording(seconds: Double) {
        guard !isRecording, !replayRunning else { return }
        let c = camera, s = settings
        // width and columnStep as the recorder stores the frames (it keeps every Recorder.columnStep-th column)
        let header = Recorder.Header(width: c.width / Recorder.columnStep, height: c.height, columnStep: Recorder.columnStep, pixelFormat: "BGRA",
                                     fps: c.fps, exposureUs: c.exposureUs, iso: c.iso, lensPosition: c.lensPosition,
                                     camera: c.name, device: UIDevice.current.model, axis: s.axis.rawValue,
                                     startedAt: ISO8601DateFormatter().string(from: Date()), note: recordingNote)
        controller.queue.async { [weak self, pipeline] in
            // The file is opened here, on the camera queue, and that can fail (disk full): without this
            // the model stayed in "recording" for good, since only a running recorder ends a recording.
            if pipeline.recorder.start(seconds: seconds, header: header) == nil {
                Task { @MainActor in self?.recordingFailed("cannot create the recording file") }
            }
        }
        isRecording = true
        lastRecording = "recording…"
    }

    private func recordingFailed(_ why: String) {
        isRecording = false; lastRecording = "recording failed: \(why)"; Diag.log("[blinko] " + lastRecording)
        finishRemoteRecording(failure: why)
    }

    var exportText: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return messages.reversed().map { "\(f.string(from: $0.date)) [\($0.levelName)] src\($0.source) slot\($0.slot) \($0.text)" }.joined(separator: "\n")
    }
}
