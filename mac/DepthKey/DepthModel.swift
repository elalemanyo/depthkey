import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import CoreVideo
import Foundation

/// Metric depth for one model frame, row-major, top row first. `inf` where infinitely far.
struct DepthMap {
    let width: Int
    let height: Int
    var meters: [Float]
}

/// Depth Pro 2 (unbuffered, window 4) on the GPU, plus the field-of-view model for the focal length.
/// Not thread-safe: call `depth(_:)` from one queue.
final class DepthModel {
    static let fovSamples = 16

    let width: Int
    let height: Int
    private let model: MLModel
    private let fovModel: MLModel
    private var state: MLState
    private var verticalFOVs: [Float] = []

    private let input: MLMultiArray
    private let fovInput: MLMultiArray
    private let scaled: CVPixelBuffer
    private let fovScaled: CVPixelBuffer
    private static let toUnit: [Float16] = (0..<256).map { Float16(Float($0) / 255) }

    init(depthURL: URL, fovURL: URL, size: ModelSize) throws {
        width = size.width
        height = size.height
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        config.functionName = "res_\(size.rawValue)"
        model = try MLModel(contentsOf: depthURL, configuration: config)
        state = model.makeState()

        let fovConfig = MLModelConfiguration()
        fovConfig.computeUnits = .cpuAndGPU
        fovModel = try MLModel(contentsOf: fovURL, configuration: fovConfig)

        input = try MLMultiArray(shape: [1, 3, height, width].map { NSNumber(value: $0) }, dataType: .float16)
        fovInput = try MLMultiArray(shape: [1, 3, 512, 896], dataType: .float16)
        scaled = try Self.makeBuffer(width, height)
        fovScaled = try Self.makeBuffer(896, 512)
    }

    /// Forget earlier frames (after a camera switch) and measure the field of view again.
    func reset() {
        state = model.makeState()
        verticalFOVs = []
    }

    /// Depth for a 16:9 frame whose extent starts at the origin.
    func depth(_ frame: CIImage, context: CIContext) throws -> DepthMap {
        if verticalFOVs.count < Self.fovSamples {  // like Apple's demo: median of the first 16 frames
            try fill(fovInput, from: frame, via: fovScaled, context: context)
            let out = try fovModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["frame": fovInput]))
            if let fov = out.featureValue(for: "fov")?.multiArrayValue {
                verticalFOVs.append(fov[1].floatValue)
            }
        }

        try fill(input, from: frame, via: scaled, context: context)
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["frame": input]), using: state)
        guard let inverse = out.featureValue(for: "inverse_depth")?.multiArrayValue else {
            throw NSError(domain: "DepthKey", code: 1, userInfo: [NSLocalizedDescriptionKey: "No inverse_depth output"])
        }

        // depth = focal / (width * inverse depth), as in Apple's package README
        let scale = focalPixels() / Float(width)
        var meters = [Float](repeating: .infinity, count: width * height)
        let rowStride = inverse.strides[1].intValue
        let colStride = inverse.strides[2].intValue
        inverse.withUnsafeBufferPointer(ofType: Float16.self) { src in
            meters.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    for x in 0..<width {
                        let v = Float(src[y * rowStride + x * colStride])
                        if v > 0 { dst[y * width + x] = scale / v }
                    }
                }
            }
        }
        return DepthMap(width: width, height: height, meters: meters)
    }

    private func focalPixels() -> Float {
        let fovs = verticalFOVs.sorted()
        let v = fovs.isEmpty ? 60 : fovs[(fovs.count - 1) / 2]
        return 0.5 * Float(height) / tan(v * .pi / 180 / 2)
    }

    /// Scale `frame` into `buffer`, then write it as RGB float16 in [0, 1], planar (1, 3, H, W).
    private func fill(_ array: MLMultiArray, from frame: CIImage, via buffer: CVPixelBuffer, context: CIContext) throws {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = frame
        lanczos.scale = Float(Double(h) / frame.extent.height)
        lanczos.aspectRatio = Float((Double(w) / Double(h)) / (frame.extent.width / frame.extent.height))
        guard let small = lanczos.outputImage else { return }
        context.render(small, to: buffer, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let lut = Self.toUnit
        let plane = array.strides[1].intValue, row = array.strides[2].intValue
        let dst = array.dataPointer.assumingMemoryBound(to: Float16.self)
        for y in 0..<h {
            let src = base + y * rowBytes
            let o = y * row
            for x in 0..<w {
                let p = src + 4 * x  // BGRA
                dst[o + x] = lut[Int(p[2])]
                dst[plane + o + x] = lut[Int(p[1])]
                dst[2 * plane + o + x] = lut[Int(p[0])]
            }
        }
    }

    private static func makeBuffer(_ width: Int, _ height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "DepthKey", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Cannot allocate a frame buffer"])
        }
        return buffer
    }
}
