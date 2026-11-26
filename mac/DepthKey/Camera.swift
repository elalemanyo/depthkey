@preconcurrency import AVFoundation
import Foundation

/// The physical camera, delivering BGRA frames on `queue`.
/// Unchecked Sendable: the session is only reconfigured on `queue`.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "depthkey.camera", qos: .userInteractive)
    var onFrame: ((CVPixelBuffer) -> Void)?
    private(set) var device: AVCaptureDevice?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()

    /// Cameras to pick from, built-in first. Leaves out the OBS Virtual Camera: reading our own
    /// output back would loop.
    static func available() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified
        ).devices
            .filter { $0.uniqueID != OBSVirtualCamera.deviceUID && !$0.modelID.contains("OBS") }
            .sorted { rank($0) < rank($1) }
    }

    private static func rank(_ d: AVCaptureDevice) -> Int {
        switch d.deviceType {
        case .builtInWideAngleCamera: 0
        case .external: 1
        case .continuityCamera: 2
        default: 3
        }
    }

    override init() {
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Switches to `device` (blocking while the session restarts).
    func use(_ device: AVCaptureDevice) throws {
        session.stopRunning()
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            session.startRunning()
        }
        session.inputs.forEach { session.removeInput($0) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "DepthKey", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot use \(device.localizedName)"])
        }
        session.addInput(input)
        if session.outputs.isEmpty, session.canAddOutput(output) {
            session.addOutput(output)
        }
        for preset in [AVCaptureSession.Preset.hd1920x1080, .hd1280x720, .high] where session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
            break
        }
        self.device = device
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
