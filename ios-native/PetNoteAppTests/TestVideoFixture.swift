import AVFoundation
import CoreVideo
import Foundation
import UIKit

/// A real video file, made on the spot, so playback tests do not depend on a
/// CDN.
///
/// Why not point the tests at Cloudinary's demo clips, which the seed already
/// uses: a test that fails because someone else's network hiccuped teaches
/// nothing, and — worse — a test that passes because a CDN was fast says
/// nothing about this code either. This clip is four seconds of flat colour
/// that changes every second with a white bar that moves every frame, written
/// to a temp file. Everything about it is known in advance: its size, its
/// duration, and what colour is on screen at any moment. That is what makes
/// "the picture on the glass is the video, not the poster" a checkable claim.
@MainActor
enum TestVideoFixture {
    static let size = CGSize(width: 320, height: 240)
    static let duration: Double = 4
    static let framesPerSecond: Int32 = 15

    /// Second 0 is red, second 1 green, second 2 blue, second 3 magenta.
    /// Distinct in the Y/Cb/Cr the encoder actually stores, so they survive
    /// compression and a screenshot's own resampling.
    static let coloursBySecond: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
        (1, 0.15, 0.15),
        (0.15, 0.85, 0.2),
        (0.2, 0.3, 1),
        (0.9, 0.2, 0.9),
    ]

    private static var cached: URL?

    /// The shared clip, written once per test process.
    static func clip() async throws -> URL {
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }
        let url = try await write(to: temporaryURL(named: "a2-clip"))
        cached = url
        return url
    }

    /// A second copy at a caller-chosen path — used by the retry test, which
    /// needs a URL that is missing first and present afterwards.
    @discardableResult
    static func writeClip(to url: URL) async throws -> URL {
        try? FileManager.default.removeItem(at: url)
        return try await write(to: url)
    }

    static func temporaryURL(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).mp4")
    }

    /// A URL that is certainly not a video: no server, no file, no ambiguity.
    /// A 404 from a CDN would do the same job on a good day and a different job
    /// on a bad one.
    static func missingFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("a2-missing-\(UUID().uuidString).mp4")
    }

    /// A file that exists and is not a movie — the other half of "broken",
    /// and the one that gets past any existence check.
    static func garbageFileURL() throws -> URL {
        let url = temporaryURL(named: "a2-garbage")
        try Data(repeating: 0x41, count: 4096).write(to: url)
        return url
    }

    static func colour(atSecond second: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        coloursBySecond[min(max(second, 0), coloursBySecond.count - 1)]
    }

    // MARK: - Writing

    private static func write(to url: URL) async throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
        )
        guard writer.canAdd(input) else { throw FixtureError.cannotWrite("writer refused the input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.cannotWrite(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let total = Int(duration * Double(framesPerSecond))
        for index in 0..<total {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let buffer = pixelBuffer(forFrame: index, pool: adaptor.pixelBufferPool) else {
                throw FixtureError.cannotWrite("no pixel buffer for frame \(index)")
            }
            let time = CMTime(value: CMTimeValue(index), timescale: framesPerSecond)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw FixtureError.cannotWrite(
                    "append failed at frame \(index): \(writer.error?.localizedDescription ?? "?")"
                )
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FixtureError.cannotWrite(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        return url
    }

    private static func pixelBuffer(forFrame index: Int, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(
                nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                &buffer
            )
        }
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        let second = index / Int(framesPerSecond)
        let tint = colour(atSecond: second)
        context.setFillColor(red: tint.r, green: tint.g, blue: tint.b, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        // Moves every frame, so two frames from the same second are still
        // different pictures — which is what "the picture changed" needs.
        let barX = CGFloat((index * 17) % Int(size.width - 20))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: barX, y: 0, width: 20, height: size.height))
        return buffer
    }

    enum FixtureError: Error, CustomStringConvertible {
        case cannotWrite(String)
        var description: String {
            switch self {
            case .cannotWrite(let why): return "could not write the test clip: \(why)"
            }
        }
    }
}

/// Polls until something becomes true, and says what it last saw when it does
/// not. Used instead of a flat sleep because "still buffering" and "broken"
/// look the same from a fixed six-second wait — a lesson that cost a day.
@MainActor
func waitUntil(
    _ what: String,
    timeout: Double = 20,
    describe: @escaping () -> String = { "" },
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw WaitedTooLong(what: what, lastSeen: describe())
}

struct WaitedTooLong: Error, CustomStringConvertible {
    let what: String
    let lastSeen: String
    var description: String {
        "timed out waiting for \(what)" + (lastSeen.isEmpty ? "" : " — last seen: \(lastSeen)")
    }
}
