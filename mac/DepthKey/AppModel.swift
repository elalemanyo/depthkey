import AppKit
@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ServiceManagement

/// Connects the settings, the camera, the model and the processor, and holds the status the UI shows.
@MainActor
final class AppModel: ObservableObject {
    let settings = Settings()
    let preview = PreviewSink()

    @Published var cameras: [AVCaptureDevice] = []
    @Published var cameraError: String?
    @Published var modelStatus = "Starting…"
    @Published var modelProgress: Double?
    @Published var modelReady = false
    let stats = Stats()
    let video = VideoBackground()
    @Published var videoStatus: String?
    @Published var videoStatusIsError = false
    @Published var virtualCameraConnected = false
    @Published var virtualCameraSize = ""
    @Published var effectsWarning: String?
    @Published var measuredFrom: String?
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginNote: String?

    private let camera = Camera()
    private let processor: Processor
    private var cameraAuthorized = false
    private var activeCameraID: String?
    private var loadedModelKey: String?
    private var loadTask: Task<Void, Never>?
    private var image: (path: String, image: CIImage?)?
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var testFeed: DispatchSourceTimer?

    init() {
        processor = Processor(queue: camera.queue, preview: preview)
        processor.onStats = { [weak self] fps, ms in
            Task { @MainActor in
                self?.stats.fps = fps
                self?.stats.modelMs = ms
            }
        }
        processor.onAutoCutoff = { [weak self] cutoff, face in
            Task { @MainActor in
                guard let self else { return }
                self.settings.cutoff = (cutoff * 100).rounded() / 100
                let source = face ? "Measured behind your face" : "No face found: measured the middle"
                if self.measuredFrom != source { self.measuredFrom = source }
            }
        }
        processor.onVirtualCamera = { [weak self] connected, size in
            Task { @MainActor in
                guard let self else { return }
                let text = "\(size.width) × \(size.height)"
                if self.virtualCameraConnected != connected { self.virtualCameraConnected = connected }
                if self.virtualCameraSize != text { self.virtualCameraSize = text }
            }
        }
        camera.onFrame = { [processor] buffer in processor.process(buffer) }
        settings.onChange = { [weak self] in self?.apply() }
        video.onStatus = { [weak self] text, isError in
            Task { @MainActor in
                self?.videoStatus = text
                self?.videoStatusIsError = isError
            }
        }
    }

    func start() {
        // Keep processing at full speed when the window is hidden: calls use the virtual camera.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Processing the camera for the virtual camera")
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCameras() }
            })
        }
        refreshCameras()
        apply()
        // `open DepthKey.app --args -DepthKeyTestImage photo.jpg` shows a still image instead of the
        // camera (for screenshots and testing). Settings can be overridden the same way: `-mode depth`.
        if let path = UserDefaults.standard.string(forKey: "DepthKeyTestImage"), startTestImage(path) {
            // no camera
        } else {
            requestCameraAccess()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func stop() {
        camera.stop()
        processor.stop()
    }

    func autoCutoff() {
        processor.requestAutoCutoff()
    }

    /// Moves the cut-off by hand, which stops following the face.
    func nudgeCutoff(by delta: Double) {
        settings.followFace = false
        settings.cutoff = min(4, max(0.3, ((settings.cutoff + delta) * 100).rounded() / 100))
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginNote = error.localizedDescription
        }
        let status = SMAppService.mainApp.status
        openAtLogin = status == .enabled
        if status == .requiresApproval {
            loginNote = "Allow DepthKey in System Settings › General › Login Items."
        } else if loginNote != nil, status == .enabled || !on {
            loginNote = nil
        }
    }

    /// Copies a picture into Application Support, so the background survives the original moving.
    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dir = ModelStore.directory.deletingLastPathComponent()
        let target = dir.appendingPathComponent("background.\(url.pathExtension.lowercased())")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix("background.") {
                try? FileManager.default.removeItem(at: old)
            }
            try FileManager.default.copyItem(at: url, to: target)
            image = nil
            settings.imagePath = target.path
            settings.mode = .image
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Plays the file where it is: videos are often large, so it isn't copied.
    func chooseBackgroundVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.videoPath = url.path
        settings.mode = .video
    }

    func openCameraPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    // MARK: -

    /// Feeds `path` to the processor 30 times a second, like a camera that never moves.
    private func startTestImage(_ path: String) -> Bool {
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true])
        else { return false }
        let s = min(1, 1920 / image.extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let w = Int(scaled.extent.width) & ~1, h = Int(scaled.extent.height) & ~1
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let buffer else { return false }
        CIContext().render(scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY)),
                           to: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let processor = self.processor
        processor.resetModel(autoCutoff: settings.autoCutoffOnStart)
        let timer = DispatchSource.makeTimerSource(queue: camera.queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30)
        timer.setEventHandler { processor.process(buffer) }
        timer.resume()
        testFeed = timer
        return true
    }

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAuthorized = true
            apply()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    self.cameraAuthorized = granted
                    if granted { self.apply() } else { self.cameraError = "DepthKey has no camera access." }
                }
            }
        default:
            cameraError = "DepthKey has no camera access."
        }
    }

    private func refreshCameras() {
        cameras = Camera.available()
        if !cameras.contains(where: { $0.uniqueID == settings.cameraID }) {
            activeCameraID = nil  // the selected camera went away (or none yet): pick another
        }
        apply()
    }

    /// Pushes the settings to the camera, the model and the processor.
    private func apply() {
        let s = settings
        preview.mirrored = s.mirrorPreview

        if cameraAuthorized {
            let device = cameras.first { $0.uniqueID == s.cameraID } ?? cameras.first
            if let device, device.uniqueID != s.cameraID {
                s.cameraID = device.uniqueID  // calls apply() again
                return
            }
            if let device, device.uniqueID != activeCameraID {
                switchCamera(to: device)
            } else if device == nil {
                cameraError = "No camera found."
            }
        }

        let key = "\(s.variant.rawValue)@\(s.modelSize.rawValue)"
        if key != loadedModelKey {
            loadModel(s.variant, s.modelSize, key: key)
        }

        var p = Params()
        p.mode = s.mode
        p.cutoff = s.cutoff
        p.softness = s.softness
        p.blur = s.blur
        p.color = s.rgb
        p.image = backgroundImage(s.imagePath)
        p.sync = s.syncMask
        video.load(s.videoPath)
        if s.mode == .video { video.play() } else { video.pause() }
        p.video = video
        p.follow = s.followFace
        processor.params = p
    }

    private func switchCamera(to device: AVCaptureDevice) {
        activeCameraID = device.uniqueID
        cameraError = nil
        let camera = self.camera
        let auto = settings.autoCutoffOnStart
        processor.resetModel(autoCutoff: auto)
        camera.queue.async {
            do {
                try camera.use(device)
            } catch {
                Task { @MainActor in self.cameraError = error.localizedDescription }
            }
        }
    }

    private func loadModel(_ variant: ModelVariant, _ size: ModelSize, key: String) {
        loadTask?.cancel()
        loadedModelKey = key
        modelReady = false
        let auto = settings.autoCutoffOnStart
        loadTask = Task {
            do {
                let urls = try await ModelStore.prepare(variant) { status, progress in
                    Task { @MainActor in
                        self.modelStatus = status
                        self.modelProgress = progress
                    }
                }
                modelStatus = "Loading \(variant.rawValue) at \(size.label)…"
                modelProgress = nil
                let model = try await Task.detached(priority: .userInitiated) {
                    try DepthModel(depthURL: urls.depth, fovURL: urls.fov, size: size)
                }.value
                guard !Task.isCancelled else { return }
                processor.setModel(model, autoCutoff: auto)
                modelStatus = "\(variant.rawValue) · \(size.label)"
                modelReady = true
            } catch {
                guard !Task.isCancelled else { return }
                modelStatus = "Model failed: \(error.localizedDescription)"
                modelProgress = nil
                loadedModelKey = nil
            }
        }
    }

    private func backgroundImage(_ path: String) -> CIImage? {
        guard !path.isEmpty else { return nil }
        if let image, image.path == path { return image.image }
        let loaded = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true])
        image = (path, loaded)
        return loaded
    }

    private func tick() {
        processor.checkVirtualCamera()
        guard let device = camera.device else {
            if effectsWarning != nil { effectsWarning = nil }
            return
        }
        var effects: [String] = []
        if device.isPortraitEffectActive { effects.append("Portrait") }
        if device.isStudioLightActive { effects.append("Studio Light") }
        if device.isBackgroundReplacementActive { effects.append("Background") }
        let warning = effects.isEmpty ? nil
            : "macOS \(effects.joined(separator: ", ")) effect is on for DepthKey. Turn it off in Control Center › Video Effects."
        if warning != effectsWarning { effectsWarning = warning }
    }
}

/// Speed figures, apart from AppModel so their updates every second don't redraw the settings.
@MainActor
final class Stats: ObservableObject {
    @Published var fps = 0.0
    @Published var modelMs = 0.0
}
