import CoreImage
import Foundation

/// Builds the output image from the camera frame and its depth, on the GPU via Core Image.
enum Compositor {
    /// `frame` is the 16:9 camera crop at the origin; the result fills `size`.
    static func compose(frame: CIImage, depth: DepthMap?, params p: Params, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let s = size.width / frame.extent.width
        let camera = frame.samplingLinear().transformed(by: CGAffineTransform(scaleX: s, y: s)).cropped(to: rect)
        guard let depth, p.mode != .off else { return camera }

        let toOutput = CGAffineTransform(scaleX: size.width / CGFloat(depth.width), y: size.height / CGFloat(depth.height))
        if p.mode == .depth {
            return colorized(depth).samplingLinear().transformed(by: toOutput).cropped(to: rect)
        }

        // alpha = 1 nearer than the cut-off, 0 beyond it, a ramp of `softness` meters in between
        var alpha = [UInt8](repeating: 0, count: depth.width * depth.height)
        let top = Float(p.cutoff + p.softness / 2), soft = Float(max(p.softness, 0.005))
        for i in 0..<alpha.count {
            let a = (top - depth.meters[i]) / soft  // inf depth gives -inf, so 0
            alpha[i] = a >= 1 ? 255 : (a > 0 ? UInt8(a * 255) : 0)
        }
        let mask = CIImage(bitmapData: Data(alpha), bytesPerRow: depth.width,
                           size: CGSize(width: depth.width, height: depth.height), format: .L8, colorSpace: nil)
            .samplingLinear().transformed(by: toOutput)
            .clampedToExtent().applyingGaussianBlur(sigma: 1.5 * size.width / 1280).cropped(to: rect)

        let blurred = { camera.clampedToExtent().applyingGaussianBlur(sigma: p.blur * size.width / 1280).cropped(to: rect) }
        let background: CIImage
        switch p.mode {
        case .blur:
            background = blurred()
        case .color:
            background = CIImage(color: CIColor(red: p.color.r, green: p.color.g, blue: p.color.b,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: rect)
        case .image, .video:
            // Blur until there is a picture (none chosen, or the video still loading).
            background = p.image.map { aspectFill($0, rect) } ?? blurred()
        case .depth, .off:
            return camera
        }
        return camera.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask,
        ])
    }

    private static func aspectFill(_ image: CIImage, _ rect: CGRect) -> CIImage {
        let e = image.extent
        let s = max(rect.width / e.width, rect.height / e.height)
        let w = e.width * s, h = e.height * s
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: (rect.width - w) / 2, y: (rect.height - h) / 2)))
            .cropped(to: rect)
    }

    /// Depth as color, near warm and far cold, on a log scale from 0.3 to 6 m (turbo colormap).
    private static func colorized(_ depth: DepthMap) -> CIImage {
        var pixels = [UInt8](repeating: 255, count: depth.width * depth.height * 4)
        let lo = log(Float(0.3)), range = log(Float(6)) - lo
        for i in 0..<depth.meters.count {
            let d = min(max(depth.meters[i], 0.3), 6)
            let v = 1 - (log(d) - lo) / range
            let c = Int(v * 255) * 4
            pixels[i * 4] = turbo[c]
            pixels[i * 4 + 1] = turbo[c + 1]
            pixels[i * 4 + 2] = turbo[c + 2]
        }
        return CIImage(bitmapData: Data(pixels), bytesPerRow: depth.width * 4,
                       size: CGSize(width: depth.width, height: depth.height), format: .BGRA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Google's polynomial fit of the turbo colormap, as BGRA bytes.
    private static let turbo: [UInt8] = (0..<256).flatMap { i -> [UInt8] in
        let x = Double(i) / 255
        let r = 0.13572138 + x * (4.61539260 + x * (-42.66032258 + x * (132.13108234 + x * (-152.94239396 + x * 59.28637943))))
        let g = 0.09140261 + x * (2.19418839 + x * (4.84296658 + x * (-14.18503333 + x * (4.27729857 + x * 2.82956604))))
        let b = 0.10667330 + x * (12.64194608 + x * (-60.58204836 + x * (110.36276771 + x * (-89.90310912 + x * 27.34824973))))
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }
        return [byte(b), byte(g), byte(r), 255]
    }
}
