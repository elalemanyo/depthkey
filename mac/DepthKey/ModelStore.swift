import CoreML
import Foundation

/// Downloads Apple's Depth Pro 2 Core ML packages from Hugging Face once, compiles them, and keeps
/// the compiled models in ~/Library/Application Support/DepthKey/Models.
enum ModelStore {
    static let repo = URL(string: "https://huggingface.co/apple/DepthPro2-coreml/resolve/main/")!
    static let fovPackage = "depthpro2-fov_512x896.mlpackage"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DepthKey/Models", isDirectory: true)
    }

    /// Compiled model URLs for the depth model and the field-of-view model, fetching them if needed.
    static func prepare(
        _ variant: ModelVariant, status: @escaping @Sendable (String, Double?) -> Void
    ) async throws -> (depth: URL, fov: URL) {
        let depth = try await compiled(variant.package, label: variant.rawValue, status: status)
        let fov = try await compiled(fovPackage, label: "field of view model", status: status)
        return (depth, fov)
    }

    private static func compiled(
        _ package: String, label: String, status: @escaping @Sendable (String, Double?) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        let name = (package as NSString).deletingPathExtension
        let target = directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: target.path) { return target }

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent("download-\(package)", isDirectory: true)
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }

        let files = [
            "Manifest.json",
            "Data/com.apple.CoreML/model.mlmodel",
            "Data/com.apple.CoreML/weights/weight.bin",
        ]
        for (i, file) in files.enumerated() {
            let destination = staging.appendingPathComponent(file)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = repo.appendingPathComponent("\(package)/\(file)")
            try await download(source, to: destination) { fraction in
                status("Downloading \(label) (\(i + 1)/\(files.count))…", fraction)
            }
        }

        status("Compiling \(label)…", nil)
        let compiledTemp = try await MLModel.compileModel(at: staging)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: compiledTemp, to: target)
        return target
    }

    private static func download(
        _ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
                observation?.invalidate()
                if let error { return continuation.resume(throwing: error) }
                guard let temp, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    return continuation.resume(throwing: URLError(
                        .badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) for \(url.lastPathComponent)"]))
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temp, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            task.resume()
        }
    }
}
