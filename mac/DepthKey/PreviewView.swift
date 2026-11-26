import AppKit
import CoreVideo
import QuartzCore
import SwiftUI

/// Shows the latest output frame (an IOSurface-backed buffer) in a layer, without copying it.
final class PreviewSink {
    let layer = CALayer()
    private var current: CVPixelBuffer?  // held so the pool doesn't reuse the frame on screen

    init() {
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    var mirrored = false {
        didSet { layer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity) }
    }

    func show(_ buffer: CVPixelBuffer) {
        DispatchQueue.main.async { [self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
            current = buffer
            CATransaction.commit()
        }
    }
}

struct PreviewView: NSViewRepresentable {
    let sink: PreviewSink

    func makeNSView(context: Context) -> NSView {
        let view = HostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(sink.layer)
        view.sinkLayer = sink.layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class HostView: NSView {
        weak var sinkLayer: CALayer?
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sinkLayer?.bounds = bounds
            sinkLayer?.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
    }
}
