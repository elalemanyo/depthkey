import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

/// Sends frames into the OBS Virtual Camera (OBS 30+ camera extension) through its sink stream,
/// the way OBS itself does. Apps then pick "OBS Virtual Camera" as their camera.
/// Not thread-safe: use from one queue.
final class OBSVirtualCamera {
    static let deviceUID = "7626645E-4425-469E-9D8B-97E0FA59AC75"

    private(set) var isConnected = false
    private(set) var dimensions = CMVideoDimensions(width: 1920, height: 1080)
    private var device: CMIOObjectID = 0
    private var stream: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var formatDescription: CMVideoFormatDescription?

    static var isInstalled: Bool { findDevice() != nil }

    /// Finds the device and its sink stream and starts it. False if OBS's extension is missing.
    @discardableResult
    func connect() -> Bool {
        if isConnected, Self.findDevice() == device { return true }
        disconnect()
        guard let device = Self.findDevice() else { return false }
        let streams = Self.objects(device, kCMIODevicePropertyStreams)
        guard let sink = streams.first(where: { Self.uint32(of: $0, kCMIOStreamPropertyDirection) == 0 }) else { return false }

        var unmanaged: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &unmanaged) == noErr,
              let queue = unmanaged?.takeRetainedValue() else { return false }
        guard CMIODeviceStartStream(device, sink) == noErr else { return false }

        if let format = Self.format(of: sink) {
            dimensions = CMVideoFormatDescriptionGetDimensions(format)
        }
        self.device = device
        self.stream = sink
        self.queue = queue
        formatDescription = nil
        isConnected = true
        return true
    }

    func disconnect() {
        if isConnected {
            CMIODeviceStopStream(device, stream)
        }
        isConnected = false
        queue = nil
        device = 0
        stream = 0
    }

    /// Queues one BGRA frame of `dimensions`; drops it when OBS hasn't taken the previous ones yet.
    func send(_ pixelBuffer: CVPixelBuffer) {
        guard isConnected, let queue else { return }
        if CMSimpleQueueGetCount(queue) >= CMSimpleQueueGetCapacity(queue) { return }

        if formatDescription == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }

        // The queue takes ownership of one retain; the extension releases it after use.
        let element = Unmanaged.passRetained(sample).toOpaque()
        if CMSimpleQueueEnqueue(queue, element: element) != noErr {
            Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
        }
    }

    // MARK: CoreMediaIO helpers

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func findDevice() -> CMIOObjectID? {
        objects(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
            .first { string(of: $0, kCMIODevicePropertyDeviceUID) == deviceUID }
    }

    private static func objects(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var a = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &a, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func string(of object: CMIOObjectID, _ selector: Int) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value) == noErr
        else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func uint32(of object: CMIOObjectID, _ selector: Int) -> UInt32? {
        var a = address(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &a, 0, nil, 4, &used, &value) == noErr else { return nil }
        return value
    }

    private static func format(of object: CMIOObjectID) -> CMFormatDescription? {
        var a = address(kCMIOStreamPropertyFormatDescription)
        var value: Unmanaged<CMFormatDescription>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CMFormatDescription>?>.size), &used, &value) == noErr
        else { return nil }
        return value?.takeRetainedValue()
    }
}
