import CoreImage
import Foundation

enum BackgroundMode: String, CaseIterable, Identifiable {
    case blur, color, image, depth, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .blur: "Blur"
        case .color: "Color"
        case .image: "Image"
        case .depth: "Depth"
        case .off: "Off"
        }
    }
}

/// Model input size: larger is sharper at the edges and slower. One function per size in the package.
enum ModelSize: String, CaseIterable, Identifiable {
    case w640 = "640x360", w854 = "854x480", w896 = "896x512", w1138 = "1138x640", w1280 = "1280x720"
    var id: String { rawValue }
    var width: Int { Int(rawValue.split(separator: "x")[0])! }
    var height: Int { Int(rawValue.split(separator: "x")[1])! }
    var label: String { rawValue.replacingOccurrences(of: "x", with: " × ") }
}

enum ModelVariant: String, CaseIterable, Identifiable {
    case small = "depthpro2-s", base = "depthpro2-b"
    var id: String { rawValue }
    var label: String { self == .small ? "Small" : "Base" }
    var package: String { "\(rawValue)_w4.mlpackage" }
}

/// What the processing thread needs from the settings, copied as one value.
struct Params {
    var mode: BackgroundMode = .blur
    var cutoff: Double = 1.5          // meters
    var softness: Double = 0.12       // meters
    var blur: Double = 24             // Gaussian sigma in pixels at 1280 px width
    var color: (r: Double, g: Double, b: Double) = (0, 0.69, 0.25)
    var image: CIImage? = nil         // background picture, any size
    var sync = false                  // wait for each frame's depth instead of using the latest
    var follow = false                // keep measuring the cut-off from your face
}

/// User settings, saved in UserDefaults as they change.
@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard
    var onChange: (() -> Void)?

    @Published var cameraID: String { didSet { save(cameraID, "cameraID") } }
    @Published var mode: BackgroundMode { didSet { save(mode.rawValue, "mode") } }
    @Published var cutoff: Double { didSet { save(cutoff, "cutoff") } }
    @Published var softness: Double { didSet { save(softness, "softness") } }
    @Published var blur: Double { didSet { save(blur, "blur") } }
    @Published var colorHex: String { didSet { save(colorHex, "colorHex") } }
    @Published var imagePath: String { didSet { save(imagePath, "imagePath") } }
    @Published var modelSize: ModelSize { didSet { save(modelSize.rawValue, "modelSize") } }
    @Published var variant: ModelVariant { didSet { save(variant.rawValue, "variant") } }
    @Published var autoCutoffOnStart: Bool { didSet { save(autoCutoffOnStart, "autoCutoffOnStart") } }
    @Published var followFace: Bool { didSet { save(followFace, "followFace") } }
    @Published var syncMask: Bool { didSet { save(syncMask, "syncMask") } }
    @Published var mirrorPreview: Bool { didSet { save(mirrorPreview, "mirrorPreview") } }

    init() {
        let d = UserDefaults.standard
        cameraID = d.string(forKey: "cameraID") ?? ""
        mode = BackgroundMode(rawValue: d.string(forKey: "mode") ?? "") ?? .blur
        cutoff = d.object(forKey: "cutoff") as? Double ?? 1.5
        softness = d.object(forKey: "softness") as? Double ?? 0.12
        blur = d.object(forKey: "blur") as? Double ?? 24
        colorHex = d.string(forKey: "colorHex") ?? "00b140"
        imagePath = d.string(forKey: "imagePath") ?? ""
        modelSize = ModelSize(rawValue: d.string(forKey: "modelSize") ?? "") ?? .w640
        variant = ModelVariant(rawValue: d.string(forKey: "variant") ?? "") ?? .small
        autoCutoffOnStart = d.object(forKey: "autoCutoffOnStart") as? Bool ?? true
        followFace = d.object(forKey: "followFace") as? Bool ?? false
        syncMask = d.object(forKey: "syncMask") as? Bool ?? false
        mirrorPreview = d.object(forKey: "mirrorPreview") as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }

    var rgb: (r: Double, g: Double, b: Double) {
        let v = UInt32(colorHex, radix: 16) ?? 0x00b140
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }

    func setColor(r: Double, g: Double, b: Double) {
        func c(_ x: Double) -> Int { max(0, min(255, Int((x * 255).rounded()))) }
        colorHex = String(format: "%02x%02x%02x", c(r), c(g), c(b))
    }
}
