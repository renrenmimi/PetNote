import AVFoundation
import AppKit
import CoreVideo
import Foundation

// Writes the same clip the unit-test fixture writes, but on the host, so a
// local HTTP server can serve it to the simulator. Colours: second 0 red,
// 1 green, 2 blue, 3 magenta; a white bar moves every frame. The poster is
// solid yellow — a colour that appears nowhere in the clip, so a screenshot
// can tell "the poster is showing" from "the video is showing".

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let size = CGSize(width: 320, height: 240)
let fps: Int32 = 15
let seconds = 4.0
let colours: [(CGFloat, CGFloat, CGFloat)] = [
    (1, 0.15, 0.15), (0.15, 0.85, 0.2), (0.2, 0.3, 1), (0.9, 0.2, 0.9),
]

let clipURL = out.appendingPathComponent("a2-clip.mp4")
try? FileManager.default.removeItem(at: clipURL)

let writer = try AVAssetWriter(outputURL: clipURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(size.width),
    AVVideoHeightKey: Int(size.height),
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: Int(size.width),
    kCVPixelBufferHeightKey as String: Int(size.height),
    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
])
writer.add(input)
guard writer.startWriting() else { fatalError("startWriting: \(writer.error?.localizedDescription ?? "?")") }
writer.startSession(atSourceTime: .zero)

func buffer(frame index: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    if let pool = adaptor.pixelBufferPool {
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    }
    if buffer == nil {
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
    }
    let pixels = buffer!
    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixels),
        width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    let tint = colours[min(index / Int(fps), colours.count - 1)]
    context.setFillColor(red: tint.0, green: tint.1, blue: tint.2, alpha: 1)
    context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: CGFloat((index * 17) % Int(size.width - 20)), y: 0, width: 20, height: size.height))
    return pixels
}

let total = Int(seconds * Double(fps))
for index in 0..<total {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    guard adaptor.append(buffer(frame: index), withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)) else {
        fatalError("append \(index): \(writer.error?.localizedDescription ?? "?")")
    }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fatalError("finish: \(writer.error?.localizedDescription ?? "?")") }

// Poster: solid yellow, nowhere in the clip.
let poster = NSImage(size: size)
poster.lockFocus()
NSColor(calibratedRed: 1, green: 0.85, blue: 0.1, alpha: 1).setFill()
NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
poster.unlockFocus()
let tiff = poster.tiffRepresentation!
let jpeg = NSBitmapImageRep(data: tiff)!.representation(using: .jpeg, properties: [:])!
try jpeg.write(to: out.appendingPathComponent("a2-poster.jpg"))

let bytes = try Data(contentsOf: clipURL).count
print("wrote a2-clip.mp4 (\(bytes) bytes) and a2-poster.jpg to \(out.path)")
