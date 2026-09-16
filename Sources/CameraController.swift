import AVFoundation
import Foundation

enum CameraKind: String, CaseIterable, Identifiable {
    case wide = "Wide", ultraWide = "Ultra", front = "Front"
    var id: String { rawValue }
    var deviceType: AVCaptureDevice.DeviceType {
        switch self { case .wide: return .builtInWideAngleCamera; case .ultraWide: return .builtInUltraWideCamera; case .front: return .builtInWideAngleCamera }
    }
    var position: AVCaptureDevice.Position { self == .front ? .front : .back }
}

struct CameraInfo {
    var name = "-"
    var width = 0, height = 0
    var fps: Double = 0
    var frameRates: [Double] = []
    var minExposureUs: Double = 0, maxExposureUs: Double = 0, exposureUs: Double = 0
    var minISO: Float = 0, maxISO: Float = 0, iso: Float = 0
    var lensPosition: Float = 1
    var lensSupported = false
    var maxZoom: CGFloat = 1
}

enum CameraError: LocalizedError {
    case noDevice, cannotAddInput, cannotAddOutput
    var errorDescription: String? {
        switch self { case .noDevice: return "Camera not available"; case .cannotAddInput: return "Cannot use camera input"; case .cannotAddOutput: return "Cannot add video output" }
    }
}

/// Owns the AVCaptureSession. All configuration happens on `queue`.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "rslog.camera", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private(set) var device: AVCaptureDevice?
    var frameHandler: ((CVPixelBuffer, Double) -> Void)?

    static let preferredRates: [Double] = [30, 60, 120, 240]

    func configure(kind: CameraKind, fps: Double, completion: @escaping (Result<CameraInfo, Error>) -> Void) {
        queue.async {
            do { completion(.success(try self.configureSync(kind: kind, fps: fps))) }
            catch { completion(.failure(error)) }
        }
    }

    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

    private func maxRate(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }

    private func candidateFormats(_ dev: AVCaptureDevice) -> [AVCaptureDevice.Format] {
        dev.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            return (sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) && d.width == 1920 && d.height == 1080
        }
    }

    private func configureSync(kind: CameraKind, fps: Double) throws -> CameraInfo {
        session.beginConfiguration()
        defer { session.commitConfiguration(); if !session.isRunning { session.startRunning() } }
        session.sessionPreset = .inputPriority
        session.inputs.forEach { session.removeInput($0) }

        guard let dev = AVCaptureDevice.default(kind.deviceType, for: .video, position: kind.position)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: kind.position) else { throw CameraError.noDevice }
        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)
        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]   // full-res colour for RGB channels
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
            session.addOutput(output)
        }

        var formats = candidateFormats(dev)
        if formats.isEmpty { formats = dev.formats }
        // closest mode whose max rate covers the requested fps, else the fastest
        let fitting = formats.filter { maxRate($0) >= fps }.sorted { maxRate($0) < maxRate($1) }
        let fmt = fitting.first ?? formats.max { maxRate($0) < maxRate($1) }!
        let actualFps = min(fps, maxRate(fmt))

        try dev.lockForConfiguration()
        dev.activeFormat = fmt
        dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(actualFps.rounded()))
        dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(actualFps.rounded()))
        if dev.isExposureModeSupported(.custom) {
            dev.setExposureModeCustom(duration: fmt.minExposureDuration, iso: fmt.minISO, completionHandler: nil)
        }
        if dev.isLockingFocusWithCustomLensPositionSupported {
            dev.setFocusModeLocked(lensPosition: 1.0, completionHandler: nil)
        } else if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
        if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
        dev.videoZoomFactor = 1
        dev.unlockForConfiguration()

        if let c = output.connection(with: .video) {
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
            if c.isVideoRotationAngleSupported(0) { c.videoRotationAngle = 0 }   // keep sensor-native rows
        }
        device = dev
        return info(dev, fps: actualFps, allFormats: formats)
    }

    private func info(_ dev: AVCaptureDevice, fps: Double, allFormats: [AVCaptureDevice.Format]) -> CameraInfo {
        let f = dev.activeFormat
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let top = allFormats.map(maxRate).max() ?? 30
        var i = CameraInfo()
        i.name = dev.localizedName
        i.width = Int(d.width); i.height = Int(d.height)
        i.fps = fps
        i.frameRates = Self.preferredRates.filter { $0 <= top + 0.5 }
        i.minExposureUs = f.minExposureDuration.seconds * 1e6
        i.maxExposureUs = min(f.maxExposureDuration.seconds, 1.0 / 250.0) * 1e6
        i.exposureUs = dev.exposureDuration.seconds * 1e6
        i.minISO = f.minISO; i.maxISO = f.maxISO; i.iso = dev.iso
        i.lensPosition = dev.lensPosition
        i.lensSupported = dev.isLockingFocusWithCustomLensPositionSupported
        i.maxZoom = min(f.videoMaxZoomFactor, 4)
        return i
    }

    /// exposureFraction 0 = shortest, 1 = 1/250 s (log scale); isoFraction 0..1 of the ISO range.
    func applyExposure(fraction: Double, isoFraction: Double) {
        queue.async {
            guard let dev = self.device else { return }
            let f = dev.activeFormat
            let minE = f.minExposureDuration.seconds
            let maxE = min(f.maxExposureDuration.seconds, 1.0 / 250.0)
            let e = minE * pow(maxE / minE, max(0, min(1, fraction)))
            let iso = f.minISO + Float(max(0, min(1, isoFraction))) * (f.maxISO - f.minISO)
            do {
                try dev.lockForConfiguration()
                if dev.isExposureModeSupported(.custom) {
                    dev.setExposureModeCustom(duration: CMTime(seconds: e, preferredTimescale: 1_000_000), iso: iso, completionHandler: nil)
                }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    func applyLens(position: Float) {
        queue.async {
            guard let dev = self.device, dev.isLockingFocusWithCustomLensPositionSupported else { return }
            do { try dev.lockForConfiguration(); dev.setFocusModeLocked(lensPosition: max(0, min(1, position)), completionHandler: nil); dev.unlockForConfiguration() } catch {}
        }
    }

    func applyZoom(_ z: CGFloat) {
        queue.async {
            guard let dev = self.device else { return }
            do { try dev.lockForConfiguration(); dev.videoZoomFactor = max(1, min(z, dev.activeFormat.videoMaxZoomFactor)); dev.unlockForConfiguration() } catch {}
        }
    }

    func currentExposure() -> (us: Double, iso: Float, lens: Float) {
        guard let dev = device else { return (0, 0, 0) }
        return (dev.exposureDuration.seconds * 1e6, dev.iso, dev.lensPosition)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameHandler?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }
}
