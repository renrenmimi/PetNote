import FirebaseFirestore
import Foundation
import Observation
import OSLog
import SwiftUI

// The signed-in person's own check-ins — the web client's profile
// "Check-ins" tab (`Profile.tsx:123-157` and `:479-543`,
// `services/checkins.ts` `getUserCheckins`, `services/locations.ts`
// `batchGetLocations`). Read only: making a check-in goes through
// `checkInCallable`, which needs a photo upload.

/// One of the person's check-ins, and the place it was at.
struct CheckinHistoryEntry: Identifiable, Equatable, Sendable {
    let placeID: String
    let checkin: PlaceCheckin

    /// The place and the check-in together. A check-in's own id is
    /// `{uid}_{day}` (`checkInCallable`, functions/src/places.ts), which is
    /// unique within one place only: checking in at two places on one day
    /// makes two documents with the same id.
    var id: String { "\(placeID)/\(checkin.id)" }

    /// `getUserCheckins`' mapping: the place is the document's parent, unless
    /// the document names one itself — the web spreads the stored fields over
    /// the parent's id, so a stored `locationId` wins.
    ///
    /// A stored id that could not name a document (a "/" in it, say) is
    /// treated as no place at all: it would reach a Firestore document or
    /// `in` query, which throws on such an id rather than failing. The server
    /// never writes one; data edited by hand could.
    static func decode(id: String, pathPlaceID: String?, _ data: [String: Any]) -> CheckinHistoryEntry {
        let stored = (data["locationId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CheckinHistoryEntry(
            placeID: DeepLink.validDocumentID(stored ?? pathPlaceID ?? "") ?? "",
            checkin: PlaceCheckin.decode(id: id, data)
        )
    }
}

/// A check-in as the list shows it: with its place looked up, or without one
/// when the place is gone.
struct CheckinHistoryRow: Identifiable, Equatable, Sendable {
    let entry: CheckinHistoryEntry
    /// Nil when no place has this id any more.
    let place: Place?

    var id: String { entry.id }

    /// `location?.name || t("profile.unknownLocation")` (`Profile.tsx:499-500`):
    /// a place that is gone, or has no name, is "Unknown location".
    var placeName: String {
        if let name = place?.name, !name.isEmpty { return name }
        return String(localized: "Unknown location")
    }

    /// The place's first photo (`location?.photos?.[0]`), not the check-in's.
    var placePhoto: URL? { place?.photos.first }
}

protocol CheckinHistoryReading: Sendable {
    /// The person's newest `limit` check-ins, newest first.
    func checkins(uid: String, limit: Int) async throws -> [CheckinHistoryEntry]
    /// The places with these ids that still exist, by id. One that is gone is
    /// simply not in the answer.
    func places(ids: [String]) async throws -> [String: Place]
}

actor FirestoreCheckinHistorySource: CheckinHistoryReading {
    /// `DOCUMENT_ID_BATCH_SIZE` in `services/locations.ts`: Firestore's `in`
    /// takes at most thirty values.
    static let placeBatchSize = 30

    private let db: Firestore

    init(db: Firestore = .firestore()) { self.db = db }

    /// `getUserCheckins`, as the web asks it: the `checkins` collection group,
    /// this person's, newest first. The rules answer it only for the signed-in
    /// person's own uid (`firestore.rules`, the `{path=**}/checkins` match),
    /// and the (userId, createdAt desc) collection-group index in
    /// `firestore.indexes.json` serves it.
    func checkins(uid: String, limit: Int) async throws -> [CheckinHistoryEntry] {
        let snapshot = try await db.collectionGroup("checkins")
            .whereField("userId", isEqualTo: uid)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)
            .getDocuments()
        return snapshot.documents.map { document in
            CheckinHistoryEntry.decode(
                id: document.documentID,
                pathPlaceID: document.reference.parent.parent?.documentID,
                document.data()
            )
        }
    }

    /// `batchGetLocations`, step for step: the places by id, thirty at a time.
    func places(ids: [String]) async throws -> [String: Place] {
        var found: [String: Place] = [:]
        for batch in Self.batches(of: ids, size: Self.placeBatchSize) {
            let snapshot = try await db.collection("locations")
                .whereField(FieldPath.documentID(), in: batch)
                .getDocuments()
            for document in snapshot.documents {
                found[document.documentID] = Place.decode(id: document.documentID, document.data())
            }
        }
        return found
    }

    static func batches(of ids: [String], size: Int) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }
}

@MainActor
@Observable
final class CheckinHistoryModel {
    enum State: Equatable {
        case loading
        case loaded([CheckinHistoryRow])
        /// No check-ins — or, as on the web, a read the rules refused.
        case empty
        case failed(String)
    }

    /// `getUserCheckins`' default page, which is what the profile asks for.
    static let limit = 100

    private(set) var state: State = .loading
    /// A reload that failed while a list was already showing. The list stays;
    /// this says it may be out of date.
    private(set) var refreshFailed = false

    private let uid: String
    private let source: any CheckinHistoryReading
    /// Bumped by every load, so a read that started earlier and answers later
    /// is dropped instead of replacing a newer one.
    private var generation = 0
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "checkins")

    init(uid: String, source: any CheckinHistoryReading) {
        self.uid = uid
        self.source = source
    }

    /// Run every time the screen appears, as the web reads the tab each time
    /// it is opened.
    func load() async {
        generation += 1
        let mine = generation
        let hadList: Bool = { if case .loaded = state { return true } else { return false } }()
        if !hadList { state = .loading }
        do {
            let entries = try await source.checkins(uid: uid, limit: Self.limit)
            guard mine == generation else { return }
            let ids = Self.placeIDs(in: entries)
            var places: [String: Place] = [:]
            if !ids.isEmpty { places = try await source.places(ids: ids) }
            guard mine == generation else { return }
            let rows = entries.map { CheckinHistoryRow(entry: $0, place: places[$0.placeID]) }
            state = rows.isEmpty ? .empty : .loaded(rows)
            refreshFailed = false
        } catch {
            guard mine == generation else { return }
            log.error("check-in history read failed: \(String(describing: error), privacy: .public)")
            if Self.isPermissionDenied(error) {
                // The web's handling (`Profile.tsx:141-146`): a refused read
                // is logged and shown as no check-ins.
                state = .empty
                refreshFailed = false
            } else if hadList {
                refreshFailed = true
            } else {
                // Not the empty state: "No check-ins yet" after a read that
                // did not happen would be saying something that is not known.
                state = .failed(String(localized: "Couldn't load your check-ins."))
            }
        }
    }

    /// Each place once, in the order the check-ins name them, and none for a
    /// check-in without one — the web's `new Set(…).filter(Boolean)`.
    nonisolated static func placeIDs(in entries: [CheckinHistoryEntry]) -> [String] {
        var seen: Set<String> = []
        return entries.map(\.placeID).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    nonisolated static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == FirestoreErrorDomain && ns.code == FirestoreErrorCode.permissionDenied.rawValue
    }
}

struct CheckinHistoryView: View {
    @State private var model: CheckinHistoryModel
    private let onOpenPlace: (String) -> Void

    init(uid: String, source: any CheckinHistoryReading, onOpenPlace: @escaping (String) -> Void) {
        _model = State(initialValue: CheckinHistoryModel(uid: uid, source: source))
        self.onOpenPlace = onOpenPlace
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("checkins.loading")
            case .failed(let message):
                VStack(spacing: Spacing.m) {
                    Text(message)
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("checkins.failed")
                    Button { Task { await model.load() } } label: {
                        Text("Try again")
                            .frame(minHeight: Layout.minTouchTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityIdentifier("checkins.retry")
                }
                .padding(.horizontal, Layout.pageInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                // The web client's empty state, word for word.
                VStack(spacing: Spacing.s) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(Typography.pageTitle)
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityHidden(true)
                    Text("No check-ins yet")
                        .font(Typography.sectionTitle)
                        .foregroundStyle(Palette.primaryText)
                    Text("Visit a pet-friendly place and check in")
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Layout.pageInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("checkins.empty")
            case .loaded(let rows):
                list(rows)
            }
        }
        .background(Palette.background)
        .navigationTitle("Check-ins")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private func list(_ rows: [CheckinHistoryRow]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.s) {
                if model.refreshFailed {
                    Text("Couldn't refresh. Pull down to try again.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityIdentifier("checkins.refreshFailed")
                }
                ForEach(rows) { row in
                    CheckinHistoryRowView(row: row) { onOpenPlace(row.entry.placeID) }
                }
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.l)
        }
        .refreshable { await model.load() }
    }
}

/// The web's row (`Profile.tsx:497-540`): the place's photo, its name and
/// when, and the check-in's own photo — with the caption and the pet added,
/// which the web's row leaves out.
private struct CheckinHistoryRowView: View {
    let row: CheckinHistoryRow
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: Spacing.m) {
                placeThumbnail
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(row.placeName)
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(Palette.primaryText)
                    if !row.entry.checkin.caption.isEmpty {
                        Text(row.entry.checkin.caption)
                            .font(Typography.body)
                            .foregroundStyle(Palette.primaryText)
                    }
                    if let petName = row.entry.checkin.petName {
                        Label(petName, systemImage: "pawprint")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    if let date = row.entry.checkin.createdAt {
                        Text(date, format: .relative(presentation: .named))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let photo = row.entry.checkin.photoURL {
                    RemoteImage(url: photo, aspectRatio: 1, cornerRadius: Radius.control, size: .thumbnail)
                        .frame(width: Layout.checkinRowThumbnail, height: Layout.checkinRowThumbnail)
                        .accessibilityHidden(true)
                }
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget, alignment: .leading)
            .background(Palette.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // A check-in with no place has nowhere to go, and an empty id must
        // never reach a Firestore document read.
        .disabled(row.entry.placeID.isEmpty)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("checkins.row.\(row.entry.placeID).\(row.entry.checkin.id)")
    }

    /// The place's photo, or the web's pin on the brand gradient when it has
    /// none — or is gone.
    private var placeThumbnail: some View {
        Group {
            if let photo = row.placePhoto {
                RemoteImage(url: photo, aspectRatio: 1, cornerRadius: Radius.control, size: .thumbnail)
            } else {
                LinearGradient(
                    colors: [Palette.brandGradientStart, Palette.brandGradientEnd],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay { Text(verbatim: "📍").font(Typography.sectionTitle) }
                .clipShape(.rect(cornerRadius: Radius.control))
            }
        }
        .frame(width: Layout.checkinRowThumbnail, height: Layout.checkinRowThumbnail)
        .accessibilityHidden(true)
    }
}

extension Layout {
    /// The web row's `h-14 w-14`: both pictures in a check-in row.
    static let checkinRowThumbnail: CGFloat = 56
}
