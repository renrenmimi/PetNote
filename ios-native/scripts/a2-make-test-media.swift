import AVFoundation
import AppKit
import CoreVideo
import Foundation

// Writes the same clip the unit-test fixture writes, but on the host, so a
// local HTTP server can serve it to the simulator. Colours: second 0 red,
// 1 green, 2 blue, 3 magenta, then round again; a white bar moves every frame.
// The poster is solid yellow — a colour that appears nowhere in the clip, so a
// screenshot can tell "the poster is showing" from "the video is showing".
//
// Two lengths, for two different questions:
//
//   a2-clip.mp4  4s   — is there a picture, is it the right picture, does it
//                       change. Short on purpose: every test that waits for it
//                       waits for four seconds and not sixteen.
//   a2-long.mp4  16s  — does playback survive the stream breaking *while it is
//                       playing*. A four-second clip served from loopback is
//                       buffered whole before the first frame is drawn, so
//                       there is no "middle" to break: cutting it produces a
//                       file that never opens, which is a different defect.
//                       Sixteen seconds of media data is long enough that the
//                       cut lands after playback has visibly started.

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let size = CGSize(width: 320, height: 240)
let fps: Int32 = 15
let colours: [(CGFloat, CGFloat, CGFloat)] = [
    (1, 0.15, 0.15), (0.15, 0.85, 0.2), (0.2, 0.3, 1), (0.9, 0.2, 0.9),
]

func buffer(frame index: Int, pool: CVPixelBufferPool?) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    if let pool {
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
    // Wraps, so the sixteen-second clip is the same four colours four times
    // over and a screenshot can still be matched against a known palette.
    let tint = colours[(index / Int(fps)) % colours.count]
    context.setFillColor(red: tint.0, green: tint.1, blue: tint.2, alpha: 1)
    context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: CGFloat((index * 17) % Int(size.width - 20)), y: 0, width: 20, height: size.height))
    return pixels
}

func write(seconds: Double, to url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
        // Fixed and generous. The default for a flat-colour clip is a few
        // kilobits, which would make a sixteen-second file smaller than a
        // four-second photo — and a file that fits in one read has no middle
        // to break. This is what makes the cut-off scenario possible at all.
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 900_000,
            AVVideoMaxKeyFrameIntervalKey: Int(fps),
        ],
    ])
    input.expectsMediaDataInRealTime = false
    // **`moov` at the front, not the back.**
    //
    // Measured, not preferred: with the default layout AVFoundation asks for
    // `bytes=0-1` and then the whole file in one range, and looks for `moov` at
    // the end of what came back. Cutting that response therefore takes the
    // index away too, and the item goes straight to `.failed` without ever
    // opening — which is the *first-load* failure, a case that already had a
    // test. Nothing stalls, because nothing ever played. With the index at the
    // front the same truncated response opens fine, knows it is sixteen seconds
    // long, and has five of them: that is a stream that breaks in the middle,
    // which is the thing under test. It is also how a file meant for streaming
    // is laid out in the first place.
    writer.shouldOptimizeForNetworkUse = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
    ])
    writer.add(input)
    guard writer.startWriting() else { fatalError("startWriting: \(writer.error?.localizedDescription ?? "?")") }
    writer.startSession(atSourceTime: .zero)

    let total = Int(seconds * Double(fps))
    for index in 0..<total {
        while !input.isReadyForMoreMediaData { usleep(2000) }
        let time = CMTime(value: CMTimeValue(index), timescale: fps)
        guard adaptor.append(buffer(frame: index, pool: adaptor.pixelBufferPool), withPresentationTime: time) else {
            fatalError("append \(index): \(writer.error?.localizedDescription ?? "?")")
        }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { fatalError("finish: \(writer.error?.localizedDescription ?? "?")") }
}

let clipURL = out.appendingPathComponent("a2-clip.mp4")
let longURL = out.appendingPathComponent("a2-long.mp4")
try write(seconds: 4, to: clipURL)
try write(seconds: 16, to: longURL)

// Poster: solid yellow, nowhere in the clip.
let poster = NSImage(size: size)
poster.lockFocus()
NSColor(calibratedRed: 1, green: 0.85, blue: 0.1, alpha: 1).setFill()
NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
poster.unlockFocus()
let tiff = poster.tiffRepresentation!
let jpeg = NSBitmapImageRep(data: tiff)!.representation(using: .jpeg, properties: [:])!
try jpeg.write(to: out.appendingPathComponent("a2-poster.jpg"))

let short = try Data(contentsOf: clipURL).count
let long = try Data(contentsOf: longURL).count
print("wrote a2-clip.mp4 (\(short) bytes), a2-long.mp4 (\(long) bytes) and a2-poster.jpg to \(out.path)")
