import CoreMotion
import Foundation

/// Reports whether the phone is being held still (decoding works best when it is).
final class MotionMonitor {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    var onUpdate: ((Bool, Double) -> Void)?
    private(set) var gyro: [Float] = [0, 0, 0]
    private(set) var accel: [Float] = [0, 0, 0]

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
            guard let m = m else { return }
            let r = m.rotationRate
            let a = m.userAcceleration
            let rot = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
            let acc = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            let level = rot / 0.35 + acc / 0.15
            self?.gyro = [Float(r.x), Float(r.y), Float(r.z)]
            self?.accel = [Float(a.x), Float(a.y), Float(a.z)]
            self?.onUpdate?(level < 1.0, level)
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}
