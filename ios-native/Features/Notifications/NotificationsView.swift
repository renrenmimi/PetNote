import SwiftUI

/// The list of in-app notifications, newest first, with the web client's
/// states and one it lacked: a read that fails says so instead of looking
/// like an empty inbox.
struct NotificationsView: View {
    @State private var model: NotificationsModel
    private let onOpen: (Route) -> Void

    init(model: NotificationsModel, onOpen: @escaping (Route) -> Void) {
        _model = State(initialValue: model)
        self.onOpen = onOpen
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("notifications.loading")
            case .failed(let message):
                VStack(spacing: Spacing.m) {
                    Text(message)
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityIdentifier("notifications.error")
                    Button { Task { await model.load() } } label: {
                        Text("Try again")
                            .frame(minHeight: Layout.minTouchTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityIdentifier("notifications.retry")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded where model.items.isEmpty:
                VStack(spacing: Spacing.s) {
                    Image(systemName: "bell")
                        .font(Typography.pageTitle)
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityHidden(true)
                    // The web client's empty state, word for word.
                    Text("No notifications")
                        .font(Typography.sectionTitle)
                        .foregroundStyle(Palette.primaryText)
                    Text("When someone likes or comments, you'll see it here")
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Layout.pageInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("notifications.empty")
            case .loaded:
                list
            }
        }
        .background(Palette.background)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.markAllRead() }
                } label: {
                    Text("Mark all as read")
                        .frame(minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .disabled(model.unreadCount == 0 && !model.items.contains { !$0.read })
                .accessibilityIdentifier("notifications.markAllRead")
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private var list: some View {
        List {
            if model.unreadCount > 0 {
                Text("\(model.unreadCount) unread")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityIdentifier("notifications.unreadCount")
            }
            ForEach(model.items) { item in
                row(item)
                    .onAppear {
                        if item.id == model.items.last?.id { Task { await model.loadMore() } }
                    }
            }
            if model.isLoadingMore {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
    }

    private func row(_ item: AppNotification) -> some View {
        Button {
            Task { await model.open(item) }
            if let route = item.destination { onOpen(route) }
        } label: {
            if item.kind == .warning {
                warning(item)
            } else {
                HStack(alignment: .top, spacing: Spacing.m) {
                    SocialAvatar(url: item.fromUserAvatarURL, name: item.fromUserName, size: Layout.minTouchTarget)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(item.line)
                            .font(Typography.body)
                            .foregroundStyle(Palette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let date = item.createdAt {
                            Text(date, format: .relative(presentation: .named))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                    Spacer(minLength: Spacing.s)
                    if let image = item.postImageURL {
                        RemoteImage(url: image, aspectRatio: 1, cornerRadius: Radius.control, size: .thumbnail)
                            .frame(width: Layout.minTouchTarget, height: Layout.minTouchTarget)
                    }
                }
                .frame(minHeight: Layout.minTouchTarget)
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(item.read ? Palette.background : Palette.secondaryBackground)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(item.read ? "" : String(localized: "Unread"))
        .accessibilityIdentifier("notification.\(item.id)")
    }

    /// From the PetNote team — the web's red card. It opens nothing.
    private func warning(_ item: AppNotification) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("PetNote Team", systemImage: "exclamationmark.triangle.fill")
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.danger)
            Text(item.message)
                .font(Typography.body)
                .foregroundStyle(Palette.primaryText)
            if let details = item.warningDetails {
                Text("Details: \(details)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget, alignment: .leading)
        .contentShape(.rect)
    }
}
