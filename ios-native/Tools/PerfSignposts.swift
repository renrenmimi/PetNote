//  PerfSignposts.swift
//
//  NOT IN ANY TARGET YET. This file sits in `ios-native/Tools/` on purpose: it
//  is a proposal, and adding a file to the app target is a change to
//  `project.pbxproj`, which belongs to the coordinating agent. Nothing builds
//  differently until someone adds it.
//
//  WHY IT HAS TO EXIST AT ALL
//
//  The app has no timing instrumentation of any kind today — `grep -rn
//  "signpost\|OSSignposter" App Core Features Support` returns nothing, and the
//  eleven `Logger` instances all log events, never durations. So there is no
//  way to measure cold start, media latency or memory from outside the process
//  without either (a) adding these marks or (b) reporting a number that means
//  something other than what it is called.
//
//  Option (b) is what the acceptance matrix forbids: "不得用文件大小代替启动耗时".
//  `applicationDidFinishLaunching` is the same category of substitute — it fires
//  long before a person can use anything, and on this app it fires before the
//  session has resolved and before a single post exists.
//
//  WHERE EACH MARK GOES (exact call sites, for whoever wires this up)
//
//    Perf.firstInteractiveFrame()
//        `Features/Feed/FeedView.swift`, in the `list` branch, guarded so it
//        runs once, on the first render where `model.posts` is non-empty. It
//        must be scheduled so it fires *after* the frame is on glass — see
//        `afterNextFramePresented` below. Putting it in `.task` or in
//        `onAppear` measures when SwiftUI decided to build the view, not when
//        the person could touch it.
//
//    Perf.beginMedia(id:) / Perf.endMedia(id:outcome:)
//        `Core/Media/ImageLoader.swift` around the fetch, and
//        `Core/Media/VideoPlaybackCoordinator.swift` around the interval from
//        `player(for:url:)` to the first `.readyToPlay`.
//
//    Perf.memorySample(tag:)
//        Called by the UI test harness through a launch-argument-only debug
//        control, or on a 1s timer under `-petnote-perf` only.
//
//  WHAT IT DELIBERATELY DOES NOT DO
//
//  No timers, no periodic redraws, nothing published into the view tree. A
//  probe that keeps the app busy makes it unmeasurable and untestable — a
//  previous half-second `TimelineView` probe in this project cost one UI test
//  1070 seconds of waiting for an app that could never report itself idle.

import Foundation
import OSLog
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

enum Perf {
    static let subsystem = "dev.local.petnote.native"
    static let category = "perf"

    private static let log = Logger(subsystem: subsystem, category: category)
    private static let signposter = OSSignposter(subsystem: subsystem, category: category)

    /// Only under `-petnote-perf`, so a shipped build carries no cost.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-petnote-perf")
    }

    // MARK: - Cold start

    /// When this process was `exec`d, as the kernel recorded it.
    ///
    /// This is the only start point that means "cold start". Everything inside
    /// the process — `main`, `didFinishLaunching`, the first `body` call —
    /// happens after dyld has already done its work, and on a cold start dyld
    /// is a large part of the number. Taking it from `kinfo_proc` includes it.
    static let processStart: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    private static var firstFrameReported = false

    /// The **end point** of cold start: the first frame that contains real feed
    /// content and has been presented.
    ///
    /// "Presented", not "built". `CATransaction`'s completion block runs after
    /// the layer tree for this transaction has been committed and handed to the
    /// render server, which is the closest thing to "on glass" that is readable
    /// from inside the process. Calling this straight from `body` would report
    /// a time before anything had been drawn.
    static func firstInteractiveFrame(postCount: Int) {
        guard isEnabled, !firstFrameReported else { return }
        firstFrameReported = true
        afterNextFramePresented {
            guard let start = processStart else {
                log.error("perf: cold start unmeasurable — kinfo_proc unavailable")
                return
            }
            let elapsed = Date().timeIntervalSince(start)
            // One line, one number, machine-readable. `Tools/perf-measure.sh`
            // greps for exactly this prefix.
            log.info("""
                PERF cold_start_ms=\(Int(elapsed * 1000), privacy: .public) \
                posts=\(postCount, privacy: .public)
                """)
        }
    }

    /// Runs `work` after the frame currently being built has been presented.
    private static func afterNextFramePresented(_ work: @escaping () -> Void) {
        // Two hops on purpose. `CATransaction.setCompletionBlock` fires when the
        // *current* transaction commits; scheduling it from the next runloop
        // turn is what makes "current" mean the frame this render produced,
        // rather than whatever transaction happened to be open when the view's
        // body ran.
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setCompletionBlock(work)
            CATransaction.commit()
        }
    }

    // MARK: - Media latency

    private static var mediaIntervals: [String: OSSignpostIntervalState] = [:]
    private static var mediaStarts: [String: CFTimeInterval] = [:]
    private static let mediaLock = NSLock()

    /// Start point for media: the moment the app decides it needs this asset
    /// for a row that is on screen. Not the moment the row appears — a row can
    /// exist for several frames before its URL is known.
    static func beginMedia(id: String, kind: String) {
        guard isEnabled else { return }
        mediaLock.lock(); defer { mediaLock.unlock() }
        let name: StaticString = "media"
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        mediaIntervals[id] = state
        mediaStarts[id] = CACurrentMediaTime()
        log.debug("PERF media_begin id=\(id, privacy: .public) kind=\(kind, privacy: .public)")
    }

    /// End point for media: the decoded asset has been handed to the view.
    ///
    /// For images that is the assignment of the decoded `UIImage`, **not** the
    /// end of the network transfer — decode is a real cost and hiding it makes
    /// the number flattering and wrong. For video it is the item reaching
    /// `.readyToPlay`, which is the first moment a frame could be shown.
    static func endMedia(id: String, outcome: String) {
        guard isEnabled else { return }
        mediaLock.lock(); defer { mediaLock.unlock() }
        guard let state = mediaIntervals.removeValue(forKey: id),
              let started = mediaStarts.removeValue(forKey: id) else { return }
        let name: StaticString = "media"
        signposter.endInterval(name, state)
        let ms = Int((CACurrentMediaTime() - started) * 1000)
        log.info("""
            PERF media_ms=\(ms, privacy: .public) id=\(id, privacy: .public) \
            outcome=\(outcome, privacy: .public)
            """)
    }

    // MARK: - Memory

    /// `phys_footprint`, which is the number iOS actually kills apps over and
    /// the number Xcode's memory gauge shows. `resident_size` is not: it counts
    /// pages that are shared or purgeable and reads far higher, which makes a
    /// "peak memory" comparison meaningless.
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    static func memorySample(tag: String) {
        guard isEnabled, let bytes = footprintBytes() else { return }
        log.info("""
            PERF footprint_kb=\(bytes / 1024, privacy: .public) \
            tag=\(tag, privacy: .public)
            """)
    }
}
