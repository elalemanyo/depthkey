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
        let small = CIImage(bitmapData: Data(alpha), bytesPerRow: depth.width,
                            size: CGSize(width: depth.width, height: depth.height), format: .L8, colorSpace: nil)
        let k = size.width / 1920  // filter sizes are tuned at 1080p
        let mask: CIImage
        if p.sharpEdges {
            // Scale the mask up, then refine it with a guided filter steered by the camera image,
            // so the cut follows real edges (hair, fingers) instead of the blocky low-res depth.
            // Fed the small mask directly, the filter leaves ghosts of the room in the background; a
            // light blur first keeps it from sharpening the upscaled pixels into stair-steps.
            // It writes its result to the red channel; copy that to green and blue, which the blend reads.
            let red = CIVector(x: 1, y: 0, z: 0, w: 0)
            mask = small.samplingLinear().transformed(by: toOutput)
                .clampedToExtent().applyingGaussianBlur(sigma: 2 * k).cropped(to: rect)
                .applyingFilter("CIGuidedFilter", parameters: [
                    "inputGuideImage": camera,
                    "inputRadius": 8 * k,
                    "inputEpsilon": 0.004,
                ])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": red, "inputGVector": red, "inputBVector": red,
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
                .applyingFilter("CIColorClamp")
                .cropped(to: rect)
        } else {
            mask = small.samplingLinear().transformed(by: toOutput)
                .clampedToExtent().applyingGaussianBlur(sigma: 2.25 * k).cropped(to: rect)
        }

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
        let composite = camera.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background,
            kCIInputMaskImageKey: mask,
        ])
        guard p.lightWrap > 0, p.mode != .color else { return composite }  // a wrap would spoil a chroma key

        // Light wrap: the background's light spills a little over your outline, so you sit in the
        // scene instead of on top of it. Spill = how much background is nearby, inside the foreground.
        let r = 16 * k
        let nearBackground = mask.applyingFilter("CIColorInvert")
            .clampedToExtent().applyingGaussianBlur(sigma: r).cropped(to: rect)
        let a = CGFloat(min(1, p.lightWrap * 1.6))
        let spill = nearBackground
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
            ])
        // Screen, not mix: the scene's light can only brighten your edges with its color; mixing
        // its blurred image in made the edges look out of focus.
        let glow = background.clampedToExtent().applyingGaussianBlur(sigma: r).cropped(to: rect)
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: spill])
        return glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: composite])
            .cropped(to: rect)
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
