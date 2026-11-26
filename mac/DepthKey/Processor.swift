import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

/// Composites every camera frame on the camera queue, with the latest depth from the model, which
/// runs on its own queue. In sync mode each frame waits for its own depth instead: no lag between
/// video and mask, but the video runs at the model's speed.
final class Processor {
    var onStats: ((_ fps: Double, _ modelMs: Double) -> Void)?
    var onAutoCutoff: ((_ cutoff: Double, _ face: Bool) -> Void)?
    var onVirtualCamera: ((_ connected: Bool, _ size: CMVideoDimensions) -> Void)?

    private let lock = NSLock()
    private var _params = Params()
    private var _model: DepthModel?
    private var _resetPending = false
    private var _autoPending = false
    private var _depth: DepthMap?
    private var _modelBusy = false
    private var _modelTime = 0.0
    private var _modelRuns = 0

    // Camera queue only.
    private let queue: DispatchQueue
    private let preview: PreviewSink
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let virtualCamera = OBSVirtualCamera()
    private var pool: CVPixelBufferPool?
    private var poolSize = CMVideoDimensions(width: 0, height: 0)
    private var frames = 0
    private var lastReport = CACurrentMediaTime()

    // Model queue only.
    private let modelQueue = DispatchQueue(label: "depthkey.model", qos: .userInteractive)
    private let modelContext = CIContext(options: [.cacheIntermediates: false])
    private var modelFrames = 0
    private var lastFollow = 0.0

    init(queue: DispatchQueue, preview: PreviewSink) {
        self.queue = queue
        self.preview = preview
    }

    var params: Params {
        get { lock.withLock { _params } }
        set { lock.withLock { _params = newValue } }
    }

    func setModel(_ model: DepthModel?, autoCutoff: Bool) {
        lock.withLock {
            _model = model
            _resetPending = true
            _autoPending = autoCutoff
        }
    }

    /// Forget earlier frames, e.g. after switching cameras.
    func resetModel(autoCutoff: Bool) {
        lock.withLock {
            _resetPending = true
            _autoPending = _autoPending || autoCutoff
        }
    }

    func requestAutoCutoff() {
        lock.withLock { _autoPending = true }
    }

    /// Connects to the OBS Virtual Camera if it isn't yet, and reports the state.
    func checkVirtualCamera() {
        queue.async { [self] in
            virtualCamera.connect()
            onVirtualCamera?(virtualCamera.isConnected, virtualCamera.dimensions)
        }
    }

    func stop() {
        queue.sync { virtualCamera.disconnect() }
    }

    func process(_ pixelBuffer: CVPixelBuffer) {
        // The models take 16:9 frames: use the centered 16:9 part of the camera image.
        let W = CVPixelBufferGetWidth(pixelBuffer), H = CVPixelBufferGetHeight(pixelBuffer)
        var w = min(W, H * 16 / 9), h = min(H, W * 9 / 16)
        w -= w % 2
        h -= h % 2
        let x0 = (W - w) / 2, y0 = (H - h) / 2
        let frame = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: CGRect(x: x0, y: y0, width: w, height: h))
            .transformed(by: CGAffineTransform(translationX: CGFloat(-x0), y: CGFloat(-y0)))

        let p = params
        if p.mode != .off {
            if p.sync {
                modelQueue.sync { runModel(frame) }
            } else {
                let start = lock.withLock { () -> Bool in
                    if _modelBusy || _model == nil { return false }
                    _modelBusy = true
                    return true
                }
                if start {
                    modelQueue.async { [self] in
                        runModel(frame)
                        lock.withLock { _modelBusy = false }
                    }
                }
            }
        }

        var (depth, params) = lock.withLock { (_depth, _params) }  // cut-off may have just been measured
        if params.mode == .video {
            params.image = params.video?.currentFrame()
        }
        let size = virtualCamera.isConnected ? virtualCamera.dimensions : CMVideoDimensions(width: 1920, height: 1080)
        guard let output = makeBuffer(size) else { return }
        let image = Compositor.compose(frame: frame, depth: depth, params: params,
                                       size: CGSize(width: Int(size.width), height: Int(size.height)))
        context.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: Int(size.width), height: Int(size.height)),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        virtualCamera.send(output)
        preview.show(output)

        frames += 1
        let now = CACurrentMediaTime()
        if now - lastReport >= 1 {
            let (time, runs) = lock.withLock { () -> (Double, Int) in
                defer { _modelTime = 0; _modelRuns = 0 }
                return (_modelTime, _modelRuns)
            }
            onStats?(Double(frames) / (now - lastReport), runs > 0 ? 1000 * time / Double(runs) : 0)
            frames = 0
            lastReport = now
        }
    }

    /// Model queue: depth for `frame`, and the auto cut-off when asked for or following.
    private func runModel(_ frame: CIImage) {
        let (model, reset, auto, follow) = lock.withLock { () -> (DepthModel?, Bool, Bool, Bool) in
            defer { _resetPending = false }
            return (_model, _resetPending, _autoPending, _params.follow)
        }
        guard let model else { return }
        if reset {
            model.reset()
            modelFrames = 0
            lock.withLock { _depth = nil }
        }

        let t = CACurrentMediaTime()
        guard let depth = try? model.depth(frame, context: modelContext) else { return }
        let elapsed = CACurrentMediaTime() - t
        modelFrames += 1

        var measured: (cutoff: Double, face: Bool)?
        let now = CACurrentMediaTime()
        if modelFrames >= 4, auto || (follow && now - lastFollow >= 0.5) {  // let the first frames settle
            lastFollow = now
            measured = AutoCutoff.measure(depth, frame: frame)
        }

        var report: Double?
        lock.withLock {
            _depth = depth
            _modelTime += elapsed
            _modelRuns += 1
            if let measured {
                // A requested measurement jumps; following eases in and ignores jitter.
                let current = _params.cutoff
                let next = auto ? measured.cutoff : current + 0.3 * (measured.cutoff - current)
                _autoPending = false
                if auto || abs(next - current) >= 0.02 {
                    _params.cutoff = next
                    report = next
                }
            }
        }
        if let report, let measured { onAutoCutoff?(report, measured.face) }
    }

    private func makeBuffer(_ size: CMVideoDimensions) -> CVPixelBuffer? {
        if pool == nil || size.width != poolSize.width || size.height != poolSize.height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: Int(size.width),
                kCVPixelBufferHeightKey: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                    attributes as CFDictionary, &pool)
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
