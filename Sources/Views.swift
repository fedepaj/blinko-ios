import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: SessionModel
    var body: some View {
        TabView {
            LiveView().tabItem { Label("Live", systemImage: "camera.viewfinder") }
            ConsoleView().tabItem { Label("Console", systemImage: "list.bullet.rectangle") }
            LabView().tabItem { Label("Lab", systemImage: "waveform.path.ecg") }
            SettingsView().tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .onAppear { model.start() }
    }
}

// MARK: - Live

struct LiveView: View {
    @EnvironmentObject var model: SessionModel
    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                CameraPreview(session: model.controller.session, tracks: model.tracks, lastTexts: model.lastTextPerSource)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack {
                    statsBar
                    Spacer()
                    if !model.isStill {
                        Label("Hold still", systemImage: "hand.raised.fill")
                            .padding(8).background(.red.opacity(0.8)).clipShape(Capsule()).padding(.bottom, 8)
                    }
                    if let e = model.error { Text(e).foregroundStyle(.red).padding(8).background(.black.opacity(0.7)) }
                }
            }
            ProfileChart(profile: model.profile, marks: model.marks)
                .frame(height: 110)
                .background(Color.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(alignment: .top, spacing: 6) {
                Text(model.progressLabel.isEmpty ? "slots" : model.progressLabel).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                SlotBar(progress: model.slotProgress)
            }
            if model.settings.recordingEnabled {
                HStack {
                    Button(action: { model.startRecording(seconds: 2) }) {
                        Label(model.isRecording ? "REC" : "Record 2 s", systemImage: "record.circle")
                            .foregroundStyle(model.isRecording ? .white : .red)
                    }
                    .buttonStyle(.bordered).disabled(model.isRecording)
                    TextField("note (board, motion…)", text: $model.recordingNote).textFieldStyle(.roundedBorder).font(.footnote)
                }
            }
            if !model.lastRecording.isEmpty { Text(model.lastRecording).font(.caption).foregroundStyle(.secondary) }
            lastMessage
        }
        .padding(8)
        .background(Color.black)
    }

    private var statsBar: some View {
        HStack(spacing: 10) {
            stat("fps", String(format: "%.0f", model.stats.fps))
            stat("pkt/s", String(format: "%.1f", model.stats.packetsPerSec))
            stat("rows/chip", model.stats.rowsPerChip > 0 ? String(format: "%.1f", model.stats.rowsPerChip) : "-")
            stat("contrast", String(format: "%.0f", model.stats.contrast))
            stat("mode", model.stats.modeName)
            stat("peak", "\(model.stats.peak)")
            stat("pilots", "\(model.stats.pilots)")
            stat("msgs", "\(model.stats.totalMessages)")
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(6).background(.black.opacity(0.6)).clipShape(Capsule()).padding(.top, 8)
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(spacing: 0) { Text(v).bold(); Text(k).foregroundStyle(.secondary).font(.system(size: 9)) }
    }

    private var lastMessage: some View {
        Group {
            if let m = model.messages.first {
                HStack { Text(m.levelName).bold().foregroundStyle(m.color); Text(m.text).lineLimit(2) }
                    .font(.system(.footnote, design: .monospaced))
            } else {
                Text(model.stats.lastPacketAge < 3 ? "Receiving packets…" : "Point the camera at the LED, 1–3 cm away")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

struct SlotBar: View {
    let progress: [Float]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<8, id: \.self) { i in
                VStack(spacing: 2) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.gray.opacity(0.3))
                            Rectangle().fill(i == 7 ? .red : (i == 6 ? .cyan : .green))
                                .frame(width: g.size.width * CGFloat(i < progress.count ? progress[i] : 0))
                        }
                    }.frame(height: 6)
                    Text(i == 7 ? "F" : (i == 6 ? "S" : "\(i)")).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ProfileChart: View {
    let profile: [Float]
    let marks: [PacketMark]
    var body: some View {
        Canvas { ctx, size in
            for m in marks {
                let r = CGRect(x: CGFloat(m.start) * size.width, y: 0, width: CGFloat(m.end - m.start) * size.width, height: size.height)
                let col: Color = m.slot == 7 ? .red : (m.channel == 1 ? .green : (m.channel == 2 ? .blue : .orange))
                ctx.fill(Path(r), with: .color(col.opacity(0.3)))
            }
            guard profile.count > 1 else { return }
            var path = Path()
            for (i, v) in profile.enumerated() {
                let x = CGFloat(i) / CGFloat(profile.count - 1) * size.width
                let y = size.height - CGFloat(v) / 255 * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(.yellow), lineWidth: 1)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var tracks: [TrackInfo] = []
    var lastTexts: [Int: String] = [:]

    /// Preview with per-source markers: a ring at each tracked light, its id and last message.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var markerLayers: [CALayer] = []
        static let palette: [UIColor] = [.systemOrange, .systemGreen, .systemCyan, .systemPink]

        func setMarkers(_ tracks: [TrackInfo], texts: [Int: String]) {
            markerLayers.forEach { $0.removeFromSuperlayer() }; markerLayers.removeAll()
            // lights of one board (same group) are joined by a line to their leader
            for t in tracks where t.group != t.id {
                guard let leader = tracks.first(where: { $0.id == t.group }) else { continue }
                let a = previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: CGFloat(t.x), y: CGFloat(t.y)))
                let b = previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: CGFloat(leader.x), y: CGFloat(leader.y)))
                let line = CAShapeLayer(); let path = UIBezierPath(); path.move(to: a); path.addLine(to: b)
                line.path = path.cgPath; line.strokeColor = Self.palette[(t.group - 1) % Self.palette.count].cgColor
                line.lineWidth = 2; line.lineDashPattern = [6, 4]; line.fillColor = nil
                layer.addSublayer(line); markerLayers.append(line)
            }
            for t in tracks {
                // track position is in the native (sensor) buffer; the preview layer knows the rotation
                let p = previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: CGFloat(t.x), y: CGFloat(t.y)))
                let edge = previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: CGFloat(t.x + t.radius), y: CGFloat(t.y)))
                let r = max(12, abs(edge.x - p.x))
                let color = Self.palette[(t.group - 1) % Self.palette.count]
                let ring = CAShapeLayer()
                ring.path = UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).cgPath
                ring.strokeColor = color.cgColor; ring.fillColor = UIColor.clear.cgColor; ring.lineWidth = 2
                let label = CATextLayer()
                label.string = "#\(t.group)" + (t.group != t.id ? "·\(t.id)" : "") + " \(t.modeName) \(t.packets)p" + (texts[t.group].map { "\n" + $0 } ?? "")
                label.fontSize = 11; label.foregroundColor = color.cgColor; label.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
                label.contentsScale = UIScreen.main.scale; label.alignmentMode = .left; label.isWrapped = true
                label.frame = CGRect(x: p.x - r, y: p.y + r + 2, width: max(2 * r, 150), height: 44)
                layer.addSublayer(ring); layer.addSublayer(label)
                markerLayers.append(ring); markerLayers.append(label)
            }
        }
    }
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) { uiView.setMarkers(tracks, texts: lastTexts) }
}

// MARK: - Console

struct ConsoleView: View {
    @EnvironmentObject var model: SessionModel
    @State private var confirmClear = false
    var body: some View {
        NavigationStack {
            List {
                if let f = model.faultMessage {
                    Section("Fault") {
                        HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red); Text(f.text).font(.system(.body, design: .monospaced)) }
                    }
                }
                Section("Messages (\(model.filteredMessages.count))") {
                    ForEach(model.filteredMessages) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(m.levelName).font(.caption.bold()).foregroundStyle(m.color)
                                if m.source > 0 { Text("src #\(m.source)" + (model.boardIds[m.source].map { " \($0)" } ?? "")).font(.caption2.bold()).foregroundStyle(CameraPreviewColors.color(m.source)) }
                                if m.replay { Text("replay").font(.caption2).foregroundStyle(.purple) }
                                Text("slot \(m.slot)").font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(m.date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(m.text).font(.system(.body, design: .monospaced))
                        }
                    }
                    .onDelete { idx in model.deleteMessages(at: idx) }
                }
            }
            .navigationTitle(model.sourceFilter == 0 ? "Blinko Console" : "Source #\(model.sourceFilter)")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .confirmationDialog("Delete all \(model.messages.count) messages?", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("Delete all", role: .destructive) { model.clearMessages() }
                        }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        // source picker as a menu: scales to many boards (id, board id, message count, last seen)
                        Menu {
                            Picker("Source", selection: $model.sourceFilter) {
                                Label("All sources", systemImage: "circle.grid.2x2").tag(0)
                                ForEach(model.sourcesSeen, id: \.id) { s in
                                    Label("#\(s.id)" + (s.board.map { " · board \($0)" } ?? "") + "  (\(model.messages.filter { $0.source == s.id }.count))", systemImage: "lightbulb").tag(s.id)
                                }
                            }
                        } label: {
                            Label(model.sourceFilter == 0 ? "All" : "#\(model.sourceFilter)" + (model.boardIds[model.sourceFilter].map { " \($0)" } ?? ""), systemImage: "line.3.horizontal.decrease.circle")
                        }
                        ShareLink(item: model.exportText) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
    }
}

// MARK: - Lab (rolling shutter calibration)

struct LabView: View {
    @EnvironmentObject var model: SessionModel
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Strobe calibration mode", isOn: $model.labMode)
                    HStack {
                        Text("Strobe frequency (Hz)")
                        Spacer()
                        TextField("Hz", value: $model.settings.strobeHz, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                    }
                    Text("Flash the strobe_calib sketch (or send `strobe 2000` to the demo), enable this mode and point the camera at the LED.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Replay a recording") {
                    let recs = ReplayEngine.recordings()
                    if recs.isEmpty {
                        Text("No recordings on this phone. Enable Recording mode in Settings › Debug, or keep one with the remote session.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(recs, id: \.self) { u in
                        HStack {
                            Text(u.lastPathComponent).font(.system(.footnote, design: .monospaced))
                            Spacer()
                            Button(model.replayRunning ? "…" : "Run") { model.replay(u) }.disabled(model.replayRunning)
                        }
                    }
                    if !model.replayProgress.isEmpty { Text(model.replayProgress).font(.footnote).foregroundStyle(.secondary) }
                    if model.replayRunning { Button("Cancel") { model.replayEngine.cancel() } }
                    Text("Runs the recording through the multi-source receiver; messages appear in the console tagged 'replay'.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Live profile") {
                    ProfileChart(profile: model.profile, marks: []).frame(height: 90)
                }
                if let r = model.lab {
                    Section("Measurement (\(r.axis.rawValue) axis, \(r.count) samples)") {
                        row("Band period", r.periodRows > 0 ? String(format: "%.2f rows", r.periodRows) : "no bands found")
                        row("Peak strength", String(format: "%.2f (other axis %.2f)", r.strength, r.otherStrength))
                        row("Row time", r.rowTimeUs > 0 ? String(format: "%.2f µs", r.rowTimeUs) : "-")
                        row("Frame readout", r.readoutMs > 0 ? String(format: "%.2f ms", r.readoutMs) : "-")
                        if r.rowTimeUs > 0 {
                            row("Min chip (4 rows)", String(format: "%.0f µs", 4 * r.rowTimeUs))
                            row("Packet height @100µs", String(format: "%.0f rows", 59 * 100 / r.rowTimeUs))
                        }
                        if r.otherStrength > r.strength * 1.5 && r.otherStrength > 0.2 {
                            Button("Bands are on the other axis → switch") {
                                model.settings.axis = r.axis == .rows ? .columns : .rows
                            }
                        }
                    }
                }
                Section("Camera") {
                    row("Device", model.camera.name)
                    row("Format", "\(model.camera.width)×\(model.camera.height) @ \(Int(model.camera.fps))")
                    row("Exposure", String(format: "%.1f µs (min %.1f)", model.camera.exposureUs, model.camera.minExposureUs))
                    row("ISO", String(format: "%.0f (%.0f–%.0f)", model.camera.iso, model.camera.minISO, model.camera.maxISO))
                    row("Lens", String(format: "%.2f", model.camera.lensPosition))
                    row("ROI", "\(model.stats.roi.0)–\(model.stats.roi.1) / \(model.stats.crossLength)")
                }
            }
            .navigationTitle("Lab")
        }
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: SessionModel
    var body: some View {
        NavigationStack {
            Form {
                Section("Camera") {
                    Picker("Camera", selection: $model.settings.camera) { ForEach(CameraKind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    Picker("Frame rate", selection: $model.settings.fps) {
                        ForEach(model.camera.frameRates.isEmpty ? [30, 60] : model.camera.frameRates, id: \.self) { Text("\(Int($0)) fps").tag($0) }
                    }.pickerStyle(.segmented)
                    VStack(alignment: .leading) {
                        Text(String(format: "Exposure: %.0f µs (shortest %.0f µs)", model.camera.exposureUs, model.camera.minExposureUs))
                        Slider(value: $model.settings.exposure, in: 0...1)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "ISO: %.0f", model.camera.iso))
                        Slider(value: $model.settings.iso, in: 0...1)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Lens position: %.2f (1 = far focus, LED blurred)", model.settings.lensPosition))
                        Slider(value: $model.settings.lensPosition, in: 0...1)
                    }.disabled(!model.camera.lensSupported)
                    VStack(alignment: .leading) {
                        Text(String(format: "Zoom: %.1fx", model.settings.zoom))
                        Slider(value: $model.settings.zoom, in: 1...Double(max(1, model.camera.maxZoom)))
                    }
                }
                Section("Decoder") {
                    Picker("Scan axis", selection: $model.settings.axis) { ForEach(ScanAxis.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    VStack(alignment: .leading) {
                        Text(String(format: "Min contrast: %.0f", model.settings.minContrast))
                        Slider(value: $model.settings.minContrast, in: 2...40, step: 1)
                    }
                    Toggle("Multi-source (track every light separately)", isOn: $model.settings.multiSource)
                    Text("Stats: \(model.stats.totalPackets) packets, \(model.stats.totalMessages) messages, syncs/frame \(model.stats.syncs), crc fail \(model.stats.crcFail)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Debug") {
                    Toggle("Remote session (TCP port \(RemoteServer.port))", isOn: $model.settings.remoteEnabled)
                    if model.settings.remoteEnabled {
                        Text("Wi-Fi: \(model.remoteAddress)  ·  USB: pymobiledevice3 usbmux forward 7777 7777  ·  clients: \(model.remoteClients)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Recording mode (Record button, .rsrec to Documents)", isOn: $model.settings.recordingEnabled)
                    NavigationLink("Recordings on this phone") { RecordingsView() }
                    Toggle("Dump frames to Documents", isOn: $model.settings.dumpFrames)
                }
                Section("Tips") {
                    Text("Hold the phone 1–3 cm from the board so the defocused LED fills the frame. Keep exposure at the shortest setting and lens position at 1.0. Use 60 fps or higher.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
        }
    }
}


enum CameraPreviewColors {
    static func color(_ id: Int) -> Color {
        [Color.orange, .green, .cyan, .pink][(max(id, 1) - 1) % 4]
    }
}


// MARK: - Recordings (share / delete)

struct RecordingsView: View {
    @State private var files: [URL] = ReplayEngine.recordings()
    var body: some View {
        List {
            if files.isEmpty { Text("No recordings.").foregroundStyle(.secondary) }
            ForEach(files, id: \.self) { u in
                let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
                HStack {
                    VStack(alignment: .leading) {
                        Text(u.lastPathComponent).font(.system(.footnote, design: .monospaced))
                        Text(String(format: "%.0f MB", Double(size) / 1e6)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: u) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .onDelete { idx in
                for i in idx { try? FileManager.default.removeItem(at: files[i]) }
                files = ReplayEngine.recordings()
            }
        }
        .navigationTitle("Recordings")
        .toolbar { EditButton() }
    }
}
