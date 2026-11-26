@preconcurrency import AVFoundation
import CoreImage
import Foundation
import QuartzCore

/// The background video: a file, a direct or HLS link (played by AVFoundation), a video page such
/// as YouTube or Vimeo (downloaded once with yt-dlp, then played from the cache), or a live stream
/// such as rtsp:// (decoded by ffmpeg). Loops without sound.
/// `load`, `play` and `pause` from the main thread; `currentFrame()` from any thread.
final class VideoBackground: @unchecked Sendable {
    /// Status for the UI: nil when playing normally, and whether it is an error.
    var onStatus: ((_ text: String?, _ isError: Bool) -> Void)?

    private(set) var source = ""
    private let player = AVPlayer()
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ])
    private let lock = NSLock()
    private var last: CIImage?
    private var orientation = CGImagePropertyOrientation.up
    private var endObserver: NSObjectProtocol?
    private var wantsPlaying = false
    private var download: Process?
    private var live: LiveStream?
    private var generation = 0  // ignores late results of a source that was replaced

    init() {
        player.isMuted = true                // the virtual camera carries no sound
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    func load(_ source: String) {
        guard source != self.source else { return }
        self.source = source
        generation += 1
        stopAll()
        status(nil)
        guard !source.isEmpty else { return }

        if FileManager.default.fileExists(atPath: (source as NSString).expandingTildeInPath) {
            play(url: URL(fileURLWithPath: (source as NSString).expandingTildeInPath))
            return
        }
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else {
            return status("File not found.", error: true)
        }
        switch scheme {
        case "http", "https":
            let direct = ["mp4", "mov", "m4v", "m3u8"].contains(url.pathExtension.lowercased())
            if direct || Tools.find("yt-dlp") == nil {
                play(url: url)
            } else {
                fetch(url)
            }
        case "rtsp", "rtsps", "rtmp", "rtmps", "srt", "udp", "rtp", "tcp":
            startLive(url)
        case "file":
            play(url: url)
        default:
            status("Unsupported link: \(scheme)://", error: true)
        }
    }

    func play() {
        wantsPlaying = true
        if player.currentItem != nil, player.timeControlStatus != .playing { player.play() }
        live?.start()
    }

    func pause() {
        wantsPlaying = false
        player.pause()
        live?.stop()  // no point decoding a stream nobody sees
    }

    /// The frame for now, or the previous one if no new frame is due.
    func currentFrame() -> CIImage? {
        if let live { return live.latest }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lock.withLock {
                let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
                last = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            }
        }
        return lock.withLock { last }
    }

    // MARK: AVFoundation (files, direct links, HLS)

    private func play(url: URL) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.add(output)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [player] _ in
            player.seek(to: .zero)  // loop
        }
        let generation = self.generation
        Task { @MainActor [weak self] in
            // Phone videos are stored sideways with a rotation to apply.
            do {
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw NSError(domain: "DepthKey", code: 3, userInfo: [NSLocalizedDescriptionKey: "No video in it."])
                }
                let t = try await track.load(.preferredTransform)
                let o: CGImagePropertyOrientation =
                    t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 ? .right :
                    t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 ? .left :
                    t.a == -1 && t.d == -1 ? .down : .up
                self?.lock.withLock { self?.orientation = o }
            } catch {
                guard let self, self.generation == generation else { return }
                self.status("Cannot play it: \(error.localizedDescription)", error: true)
            }
        }
        if wantsPlaying { player.play() }
    }

    // MARK: yt-dlp (YouTube, Vimeo and other video pages)

    private static var cacheDirectory: URL {
        ModelStore.directory.deletingLastPathComponent().appendingPathComponent("Videos", isDirectory: true)
    }

    /// Downloads the page's video (H.264 up to 1080p, no sound) once, then plays the file.
    private func fetch(_ url: URL) {
        let cache = UserDefaults.standard.dictionary(forKey: "videoCache") as? [String: String] ?? [:]
        if let path = cache[url.absoluteString], FileManager.default.fileExists(atPath: path) {
            return play(url: URL(fileURLWithPath: path))
        }
        guard let ytdlp = Tools.find("yt-dlp") else {
            return status("Links to video pages need yt-dlp: brew install yt-dlp", error: true)
        }
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = ytdlp
        process.arguments = [
            "--no-playlist", "--newline", "--progress", "--no-warnings",
            // H.264 in MP4 decodes in hardware on every Mac; VP9 and AV1 often don't play.
            "-f", "bv*[ext=mp4][vcodec^=avc1][height<=1080]/b[ext=mp4][height<=1080]/bv*[ext=mp4]/b",
            "-o", Self.cacheDirectory.appendingPathComponent("%(id)s.%(ext)s").path,
            "--print", "after_move:filepath",
            url.absoluteString,
        ]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Tools.searchPath  // yt-dlp may call ffmpeg
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let generation = self.generation
        var path: String?
        var lastError = ""
        weak let owner = self
        let lines = { (handle: FileHandle) in
            handle.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(whereSeparator: \.isNewline).map(String.init) {
                    if line.hasPrefix("/") { path = line }
                    else if line.contains("ERROR") { lastError = line.replacingOccurrences(of: "ERROR: ", with: "") }
                    else if let r = line.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression), line.contains("[download]") {
                        let percent = String(line[r])
                        DispatchQueue.main.async {
                            guard owner?.generation == generation else { return }
                            owner?.status("Downloading the video… \(percent)")
                        }
                    }
                }
            }
        }
        lines(out.fileHandleForReading)
        lines(err.fileHandleForReading)
        process.terminationHandler = { [weak self] p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.download = nil
                if p.terminationStatus == 0, let path, FileManager.default.fileExists(atPath: path) {
                    var cache = UserDefaults.standard.dictionary(forKey: "videoCache") as? [String: String] ?? [:]
                    cache[url.absoluteString] = path
                    UserDefaults.standard.set(cache, forKey: "videoCache")
                    self.status(nil)
                    self.play(url: URL(fileURLWithPath: path))
                } else if p.terminationReason == .exit {
                    self.status(lastError.isEmpty ? "Cannot download this video." : lastError, error: true)
                }
            }
        }
        status("Getting the video…")
        do {
            try process.run()
            download = process
        } catch {
            status("Cannot run yt-dlp: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: ffmpeg (live streams)

    private func startLive(_ url: URL) {
        guard let ffmpeg = Tools.find("ffmpeg") else {
            return status("Live streams need ffmpeg: brew install ffmpeg", error: true)
        }
        let generation = self.generation
        let stream = LiveStream(ffmpeg: ffmpeg, url: url) { [weak self] text, isError in
            DispatchQueue.main.async {
                guard self?.generation == generation else { return }
                self?.status(text, error: isError)
            }
        }
        live = stream
        if wantsPlaying { stream.start() }
    }

    // MARK: -

    private func stopAll() {
        player.pause()
        player.currentItem?.remove(output)
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        download?.terminate()
        download = nil
        live?.stop()
        live = nil
        lock.withLock {
            last = nil
            orientation = .up
        }
    }

    private func status(_ text: String?, error: Bool = false) {
        onStatus?(text, error)
    }
}

/// Command-line tools from Homebrew. Apps opened from Finder don't get the shell's PATH.
enum Tools {
    static let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    static var searchPath: String { (directories + [ProcessInfo.processInfo.environment["PATH"] ?? ""]).joined(separator: ":") }

    static func find(_ name: String) -> URL? {
        directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Decodes a live stream with ffmpeg into raw BGRA frames on a pipe, and reconnects when it drops.
final class LiveStream: @unchecked Sendable {
    static let width = 1280, height = 720

    private let ffmpeg: URL
    private let url: URL
    private let onStatus: (String?, Bool) -> Void
    private let lock = NSLock()
    private var process: Process?
    private var running = false
    private var _latest: CIImage?

    init(ffmpeg: URL, url: URL, onStatus: @escaping (String?, Bool) -> Void) {
        self.ffmpeg = ffmpeg
        self.url = url
        self.onStatus = onStatus
    }

    var latest: CIImage? { lock.withLock { _latest } }

    func start() {
        let start = lock.withLock { () -> Bool in
            if running { return false }
            running = true
            return true
        }
        if start { launch() }
    }

    func stop() {
        let p = lock.withLock { () -> Process? in
            running = false
            defer { process = nil }
            return process
        }
        p?.terminate()
    }

    private func launch() {
        let w = Self.width, h = Self.height
        let process = Process()
        process.executableURL = ffmpeg
        var args = ["-nostdin", "-loglevel", "error"]
        if url.scheme?.lowercased().hasPrefix("rtsp") == true { args += ["-rtsp_transport", "tcp"] }
        args += ["-i", url.absoluteString, "-an",
                 "-vf", "scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h)",
                 "-pix_fmt", "bgra", "-f", "rawvideo", "-"]
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .split(whereSeparator: \.isNewline).last.map(String.init)
            let again = self.lock.withLock { self.running }
            guard again else { return }
            self.onStatus("Stream ended\(message.map { ": \($0)" } ?? ""). Reconnecting…", true)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.lock.withLock({ self.running }) else { return }
                self.launch()
            }
        }
        onStatus("Connecting to the stream…", false)
        do {
            try process.run()
        } catch {
            onStatus("Cannot run ffmpeg: \(error.localizedDescription)", true)
            return
        }
        lock.withLock { self.process = process }

        let reader = out.fileHandleForReading  // held by the thread: freeing it would close the pipe
        Thread.detachNewThread { [weak self] in
            let fd = reader.fileDescriptor
            let size = w * h * 4
            var frame = [UInt8](repeating: 0, count: size)
            var first = true
            while true {
                var filled = 0
                while filled < size {
                    let n = frame.withUnsafeMutableBytes { read(fd, $0.baseAddress! + filled, size - filled) }
                    if n <= 0 { return }  // ffmpeg exited; terminationHandler reconnects
                    filled += n
                }
                guard let self else { return }
                let image = CIImage(bitmapData: Data(frame), bytesPerRow: w * 4,
                                    size: CGSize(width: w, height: h), format: .BGRA8,
                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                self.lock.withLock { self._latest = image }
                if first {
                    first = false
                    self.onStatus(nil, false)
                }
            }
        }
    }
}
