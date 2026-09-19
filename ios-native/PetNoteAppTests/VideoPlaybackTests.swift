import AVFoundation
import Foundation
import Testing

@testable import PetNote

/// Acceptance 5D.1–5D.7, at the level where the rules are actually decidable.
///
/// What these prove: the coordinator's rules hold — the visibility threshold,
/// the ceiling on live players, that離 screen tears a player down, and that
/// everything returns to zero. What they do not prove: that frames reach the
/// glass, that the first frame is not black, or that scrolling stays smooth.
/// Those are L5, need a device and Instruments, and no amount of this
/// substitutes for them.
@MainActor
struct VideoPlaybackTests {
    private let a = URL(string: "https://res.cloudinary.com/demo/video/upload/v1/dog.mp4")!
    private let b = URL(string: "https://res.cloudinary.com/demo/video/upload/v1/sea_turtle.mp4")!
    private let c = URL(string: "https://res.cloudinary.com/demo/video/upload/v1/elephants.mp4")!

    // MARK: - The visibility rule

    @Test func belowTheThresholdGetsNoPlayerAtAll() {
        let coordinator = VideoPlaybackCoordinator()
        // 59% visible — just under.
        coordinator.reportVisibility(id: "a", fraction: 0.59, distanceFromCentre: 0)
        #expect(coordinator.player(for: "a", url: a) == nil)
        #expect(coordinator.livePlayerCount == 0)
        #expect(coordinator.playingID == nil)
    }

    @Test func atTheThresholdGetsOne() {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.6, distanceFromCentre: 0)
        #expect(coordinator.player(for: "a", url: a) != nil)
        #expect(coordinator.livePlayerCount == 1)
    }

    /// 5D.1: among eligible videos, the one nearest the middle plays — and it
    /// is exactly one.
    @Test func onlyTheMostCentredEligibleVideoPlays() {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 300)
        coordinator.reportVisibility(id: "b", fraction: 0.8, distanceFromCentre: 40)
        _ = coordinator.player(for: "a", url: a)
        _ = coordinator.player(for: "b", url: b)

        #expect(coordinator.playingID == "b", "nearest the centre wins, not the most visible")
    }

    @Test func scrollingChangesWhichOnePlays() {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 20)
        _ = coordinator.player(for: "a", url: a)
        #expect(coordinator.playingID == "a")

        // "b" scrolls into the middle while "a" slides up.
        coordinator.reportVisibility(id: "b", fraction: 0.9, distanceFromCentre: 10)
        _ = coordinator.player(for: "b", url: b)
        coordinator.reportVisibility(id: "a", fraction: 0.7, distanceFromCentre: 400)

        #expect(coordinator.playingID == "b")
    }

    /// 5D.2: falling below the threshold pauses; leaving entirely releases.
    @Test func leavingTheScreenTearsThePlayerDown() {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: a)
        #expect(coordinator.livePlayerCount == 1)

        coordinator.reportOffscreen(id: "a")
        #expect(coordinator.livePlayerCount == 0, "the decoder is freed, not just paused")
        #expect(coordinator.playingID == nil)
    }

    // MARK: - The ceiling

    /// 5D.3: the limit is a number in the code, and it holds.
    @Test func neverMoreThanTheCeiling() {
        let coordinator = VideoPlaybackCoordinator()
        for (id, url) in [("a", a), ("b", b), ("c", c)] {
            coordinator.reportVisibility(id: id, fraction: 0.9, distanceFromCentre: 100)
            _ = coordinator.player(for: id, url: url)
        }
        #expect(VideoPlaybackCoordinator.maximumPlayers == 2)
        #expect(coordinator.livePlayerCount <= VideoPlaybackCoordinator.maximumPlayers)
    }

    /// Scrolling past many videos must not accumulate players — this is the
    /// shape of 5D.7's "does it leak", checkable without Instruments.
    @Test func scrollingPastManyVideosDoesNotAccumulate() {
        let coordinator = VideoPlaybackCoordinator()
        let urls = [a, b, c]
        for index in 0..<30 {
            let id = "video-\(index)"
            coordinator.reportVisibility(id: id, fraction: 0.9, distanceFromCentre: 0)
            _ = coordinator.player(for: id, url: urls[index % urls.count])
            // The previous one scrolls away, as it would in a list.
            if index > 0 { coordinator.reportOffscreen(id: "video-\(index - 1)") }
            #expect(
                coordinator.livePlayerCount <= VideoPlaybackCoordinator.maximumPlayers,
                "after \(index + 1) videos there are \(coordinator.livePlayerCount) players"
            )
        }
    }

    /// 5D.7: back to zero.
    @Test func everythingReturnsToZero() {
        let coordinator = VideoPlaybackCoordinator()
        for (id, url) in [("a", a), ("b", b)] {
            coordinator.reportVisibility(id: id, fraction: 0.9, distanceFromCentre: 50)
            _ = coordinator.player(for: id, url: url)
        }
        #expect(coordinator.livePlayerCount > 0)

        coordinator.releaseAll(reason: "test")
        #expect(coordinator.livePlayerCount == 0)
        #expect(coordinator.playingID == nil)
    }

    /// 5D.6: backgrounding stops playback and does not silently resume.
    @Test func suspendingStopsPlaybackWithoutDestroyingState() {
        let coordinator = VideoPlaybackCoordinator()
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        _ = coordinator.player(for: "a", url: a)
        #expect(coordinator.playingID == "a")

        coordinator.suspendAll(reason: "background")
        #expect(coordinator.playingID == nil, "nothing is playing after backgrounding")
        #expect(coordinator.livePlayerCount == 1, "the player is kept, so returning is instant")
    }

    // MARK: - Audio

    /// 5D.4: muted by default, so entering a feed cannot interrupt music.
    @Test func mutedByDefault() {
        let coordinator = VideoPlaybackCoordinator()
        #expect(coordinator.isMuted)
        coordinator.reportVisibility(id: "a", fraction: 0.9, distanceFromCentre: 0)
        let player = coordinator.player(for: "a", url: a)
        #expect(player?.isMuted == true)
    }

    @Test func unmutingAppliesToEveryPlayer() {
        let coordinator = VideoPlaybackCoordinator()
        for (id, url) in [("a", a), ("b", b)] {
            coordinator.reportVisibility(id: id, fraction: 0.9, distanceFromCentre: 50)
            _ = coordinator.player(for: id, url: url)
        }
        coordinator.toggleMute()
        #expect(!coordinator.isMuted)
        // A second video scrolling in after unmuting inherits the choice.
        coordinator.reportVisibility(id: "c", fraction: 0.95, distanceFromCentre: 5)
        coordinator.reportOffscreen(id: "a")
        let third = coordinator.player(for: "c", url: c)
        #expect(third?.isMuted == false)
    }
}
