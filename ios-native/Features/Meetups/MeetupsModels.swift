import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class MeetupsModel {
    enum State: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// The web reads fifty.
    static let limit = 50

    private(set) var items: [Meetup] = []
    private(set) var state: State = .loading
    var filter: MeetupFilter = .upcoming {
        didSet {
            guard filter != oldValue else { return }
            items = []
            loadTask?.cancel()
            loadTask = Task { await load() }
        }
    }

    let uid: String
    private let source: any MeetupsReading
    private let now: @Sendable () -> Date
    private var loadTask: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "meetups")

    init(uid: String, source: any MeetupsReading, now: @escaping @Sendable () -> Date = { Date() }) {
        self.uid = uid
        self.source = source
        self.now = now
    }

    func load() async {
        if items.isEmpty { state = .loading }
        let filter = filter
        do {
            let found: [Meetup]
            switch filter {
            case .upcoming:
                found = try await source.upcoming(limit: Self.limit)
            case .thisWeek:
                found = try await source.thisWeek(from: now(), limit: Self.limit)
            case .mine:
                found = try await source.mine(uid: uid)
            case .dogs, .cats, .otherPets:
                found = try await source.upcoming(limit: Self.limit).filter { $0.isFor(filter) }
            }
            guard filter == self.filter else { return }
            items = found
            state = .loaded
        } catch {
            guard !Task.isCancelled, filter == self.filter else { return }
            log.error("meetups read failed: \(String(describing: error), privacy: .public)")
            if items.isEmpty { state = .failed(GatheringWords.message(for: error, fallback: GatheringWords.listFailure)) }
        }
    }
}

@MainActor
@Observable
final class MeetupDetailModel {
    enum State: Equatable {
        case loading
        case loaded(Meetup)
        case missing
        case failed(String)
    }

    enum Action: Equatable {
        case joining, leaving, cancelling
    }

    private(set) var state: State = .loading
    private(set) var participants: [MeetupParticipant] = []
    private(set) var participantsFailed = false
    /// The real address, for the organiser and participants of a
    /// participants-only meetup. Nil for everyone else — the rules refuse it.
    private(set) var privatePlace: MeetupPlace?
    private(set) var pets: [Pet] = []
    private(set) var working: Action?
    /// What the last action came to, when it did not go through: the
    /// server's reason for a refused join, or why a request failed.
    private(set) var actionMessage: String?

    let meetupID: String
    let viewerID: String
    private let source: any MeetupsReading
    private let petSource: any PetChoiceProviding
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "meetups")

    init(
        meetupID: String, viewerID: String, source: any MeetupsReading, pets: any PetChoiceProviding,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.meetupID = meetupID
        self.viewerID = viewerID
        self.source = source
        self.petSource = pets
        self.now = now
    }

    var meetup: Meetup? {
        if case .loaded(let meetup) = state { meetup } else { nil }
    }

    var isOrganizer: Bool { meetup?.organizerID == viewerID }
    var hasJoined: Bool { participants.contains { $0.id == viewerID } }
    var canAct: Bool { meetup?.status == .upcoming && working == nil }

    /// The place to show: the real one when this person may see it.
    var shownPlace: MeetupPlace? {
        guard let meetup else { return nil }
        if meetup.isAddressPrivate { return privatePlace }
        return meetup.place
    }

    func load() async {
        do {
            guard var meetup = try await source.meetup(id: meetupID) else {
                state = .missing
                return
            }
            // Past its end and still "upcoming": the server settles it, as
            // the web asks on opening one. A failure leaves it as read.
            if meetup.hasEndedUnsettled(now: now()) {
                do {
                    try await source.settle(meetupID: meetupID)
                    meetup = try await source.meetup(id: meetupID) ?? meetup
                } catch {
                    log.error("settle failed: \(String(describing: error), privacy: .public)")
                }
            }
            state = .loaded(meetup)
        } catch {
            log.error("meetup read failed: \(String(describing: error), privacy: .public)")
            if case .loaded = state { return }
            state = .failed(GatheringWords.message(for: error, fallback: String(localized: "Could not load this meetup.")))
            return
        }
        do {
            participants = try await source.participants(meetupID: meetupID)
            participantsFailed = false
        } catch {
            log.error("participants read failed: \(String(describing: error), privacy: .public)")
            participantsFailed = true
        }
        if meetup?.isAddressPrivate == true, isOrganizer || hasJoined {
            privatePlace = await source.privateAddress(meetupID: meetupID)
        } else {
            privatePlace = nil
        }
        if pets.isEmpty, let owned = try? await petSource.pets(ownedBy: viewerID) {
            pets = owned
        }
    }

    /// With a pet, or — for the organiser only — without one, as the server
    /// allows.
    func join(petID: String?) async {
        guard canAct else { return }
        working = .joining
        actionMessage = nil
        defer { working = nil }
        do {
            switch try await source.join(meetupID: meetupID, petID: petID) {
            case .joined:
                await load()
            case .refused(let reason):
                actionMessage = reason
            }
        } catch {
            log.error("join failed: \(String(describing: error), privacy: .public)")
            actionMessage = GatheringWords.message(for: error, fallback: String(localized: "Couldn't join this meetup."))
        }
    }

    func leave() async {
        guard canAct, hasJoined else { return }
        working = .leaving
        actionMessage = nil
        defer { working = nil }
        do {
            try await source.leave(meetupID: meetupID, uid: viewerID)
            await load()
        } catch {
            log.error("leave failed: \(String(describing: error), privacy: .public)")
            actionMessage = GatheringWords.message(for: error, fallback: String(localized: "Couldn't leave this meetup."))
        }
    }

    func cancel() async {
        guard canAct, isOrganizer else { return }
        working = .cancelling
        actionMessage = nil
        defer { working = nil }
        do {
            try await source.cancel(meetupID: meetupID)
            await load()
        } catch {
            log.error("cancel failed: \(String(describing: error), privacy: .public)")
            actionMessage = GatheringWords.message(for: error, fallback: String(localized: "Couldn't cancel this meetup."))
        }
    }
}
