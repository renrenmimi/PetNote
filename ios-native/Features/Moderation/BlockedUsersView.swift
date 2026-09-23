import Observation
import OSLog
import SwiftUI

/// The people the signed-in person has blocked — the web client's
/// Settings → Blocked Users — each with a way to unblock.
@MainActor
@Observable
final class BlockedUsersModel {
    struct Row: Identifiable, Equatable {
        let id: String
        /// Nil when the profile could not be read or no longer exists; the row
        /// still offers Unblock, because the block is still there.
        let profile: PublicProfile?
    }

    enum State: Equatable {
        case loading
        case loaded([Row])
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var unblocking: Set<String> = []
    /// Per row, so one failure does not speak for the others.
    private(set) var failures: [String: String] = [:]

    private let viewerID: String
    private let social: any SocialRepository
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "moderation")

    init(viewerID: String, social: any SocialRepository) {
        self.viewerID = viewerID
        self.social = social
    }

    func load() async {
        if case .loaded = state {} else { state = .loading }
        do {
            let ids = try await social.blockedUserIDs(viewerID: viewerID).sorted()
            var rows: [Row] = []
            for id in ids {
                let profile = try? await social.profile(userID: id)
                rows.append(Row(id: id, profile: profile))
            }
            state = .loaded(rows)
        } catch {
            log.error("blocked users read failed: \(String(describing: error), privacy: .public)")
            state = .failed(String(localized: "Couldn't load the people you've blocked."))
        }
    }

    /// Returns whether the block is gone.
    @discardableResult
    func unblock(_ id: String) async -> Bool {
        guard !unblocking.contains(id), case .loaded(let rows) = state else { return false }
        unblocking.insert(id)
        failures[id] = nil
        defer { unblocking.remove(id) }
        do {
            try await social.unblock(userID: id, viewerID: viewerID)
            state = .loaded(rows.filter { $0.id != id })
            return true
        } catch {
            failures[id] = String(localized: "Couldn't unblock. Try again.")
            return false
        }
    }
}

struct BlockedUsersView: View {
    @State private var model: BlockedUsersModel
    private let onChanged: () -> Void

    init(viewerID: String, social: any SocialRepository, onChanged: @escaping () -> Void) {
        _model = State(initialValue: BlockedUsersModel(viewerID: viewerID, social: social))
        self.onChanged = onChanged
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("blocked.loading")
            case .failed(let message):
                VStack(spacing: Spacing.m) {
                    Text(message)
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                    Button { Task { await model.load() } } label: {
                        Text("Try again")
                            .frame(minHeight: Layout.minTouchTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityIdentifier("blocked.retry")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let rows) where rows.isEmpty:
                Text("You haven't blocked anyone.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("blocked.empty")
            case .loaded(let rows):
                List(rows) { row in
                    rowView(row)
                }
                .listStyle(.plain)
            }
        }
        .background(Palette.background)
        .navigationTitle("Blocked people")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private func rowView(_ row: BlockedUsersModel.Row) -> some View {
        let name = row.profile?.displayName ?? String(localized: "PetNote user")
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.m) {
                SocialAvatar(url: row.profile?.avatarURL, name: name, size: Layout.minTouchTarget)
                Text(name)
                    .font(Typography.body)
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(2)
                Spacer(minLength: Spacing.s)
                Button {
                    Task { if await model.unblock(row.id) { onChanged() } }
                } label: {
                    Text(model.unblocking.contains(row.id) ? "Unblocking…" : "Unblock")
                        .frame(minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(SocialButtonStyle(kind: .secondary))
                .disabled(model.unblocking.contains(row.id))
                .accessibilityLabel("Unblock \(name)")
                .accessibilityIdentifier("blocked.unblock.\(row.id)")
            }
            if let failure = model.failures[row.id] {
                Text(failure)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}
