import CoreImage
import Foundation
import Vision

/// Picks a cut-off from the depth: behind your face, or behind the middle of the frame without one.
enum AutoCutoff {
    static let margin = 0.4  // meters behind you that still stay (hair, shoulders, a held object)

    /// `frame` is the 16:9 camera crop the depth was computed from.
    static func measure(_ depth: DepthMap, frame: CIImage) -> (cutoff: Double, face: Bool) {
        if let face = largestFace(in: frame), let d = median(depth, inner(face, 0.5)) {
            return (d + margin, true)
        }
        // The middle of the frame, where you usually sit.
        let center = CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4)
        return ((median(depth, center) ?? 1.1) + margin, false)
    }

    /// The largest face, in normalized coordinates with the origin at the top left.
    private static func largestFace(in frame: CIImage) -> CGRect? {
        let s = min(1, 640 / frame.extent.width)  // faces are found as well at 640 px, faster
        let small = frame.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(ciImage: small).perform([request])
        guard let box = request.results?.max(by: { area($0.boundingBox) < area($1.boundingBox) })?.boundingBox
        else { return nil }
        return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)  // Vision's origin is bottom left
    }

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    private static func inner(_ r: CGRect, _ fraction: CGFloat) -> CGRect {
        r.insetBy(dx: r.width * (1 - fraction) / 2, dy: r.height * (1 - fraction) / 2)
    }

    /// Median finite depth in a normalized, top-left-origin rectangle of the depth map.
    private static func median(_ depth: DepthMap, _ rect: CGRect) -> Double? {
        let x0 = max(0, Int(rect.minX * CGFloat(depth.width))), x1 = min(depth.width, Int(rect.maxX * CGFloat(depth.width)))
        let y0 = max(0, Int(rect.minY * CGFloat(depth.height))), y1 = min(depth.height, Int(rect.maxY * CGFloat(depth.height)))
        guard x1 > x0, y1 > y0 else { return nil }
        var values: [Float] = []
        values.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let d = depth.meters[y * depth.width + x]
                if d.isFinite { values.append(d) }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return Double(values[values.count / 2])
    }
}
