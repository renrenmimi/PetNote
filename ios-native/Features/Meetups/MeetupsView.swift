import SwiftUI

/// The Meetups tab.
struct MeetupsView: View {
    @State private var model: MeetupsModel
    private let onOpen: (String) -> Void

    init(model: MeetupsModel, onOpen: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.onOpen = onOpen
    }

    var body: some View {
        List {
            Section {
                filters
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            content
        }
        .listStyle(.plain)
        .background(Palette.background)
        .navigationTitle("Meetups")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.items.isEmpty { await model.load() } }
        .refreshable { await model.load() }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                ForEach(MeetupFilter.allCases, id: \.self) { filter in
                    Button { model.filter = filter } label: {
                        Text(filter.label)
                            .font(Typography.caption)
                            .padding(.horizontal, Spacing.m)
                            .frame(minHeight: Layout.minTouchTarget)
                            .foregroundStyle(model.filter == filter ? Palette.textOnBrand : Palette.primaryText)
                            .background(model.filter == filter ? Palette.brandPrimary : Palette.secondaryBackground, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.filter == filter ? .isSelected : [])
                    .accessibilityIdentifier("meetups.filter.\(filter.rawValue)")
                }
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.s)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading where model.items.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("meetups.loading")
        case .failed(let message) where model.items.isEmpty:
            FeedErrorView(message: message) { Task { await model.load() } }
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("meetups.error")
        default:
            if model.items.isEmpty {
                // The web's words, less its "Create Meetup": creating one
                // needs the address lookup (docs/places-meetups-plan.md).
                VStack(spacing: Spacing.s) {
                    Text(model.filter.emptyTitle)
                        .font(Typography.sectionTitle)
                        .foregroundStyle(Palette.primaryText)
                    Text("Be the first to organize one!")
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xl)
                .listRowSeparator(.hidden)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("meetups.empty")
            } else {
                ForEach(model.items) { meetup in
                    Button { onOpen(meetup.id) } label: {
                        MeetupSummary(meetup: meetup)
                            .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("meetup.\(meetup.id)")
                }
            }
        }
    }
}

/// A meetup in a list: when, where, how many, and whether it is still on.
struct MeetupSummary: View {
    let meetup: Meetup

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(meetup.title)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
                Spacer(minLength: Spacing.s)
                MeetupStatusBadge(status: meetup.status)
            }
            if let date = meetup.date {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
            Text(MeetupSummary.whereLine(meetup))
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
            Text(MeetupSummary.countLine(meetup))
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    /// A participants-only meetup shows only its city, or "City hidden" —
    /// the web's rule. The server keeps the street off the public document.
    static func whereLine(_ meetup: Meetup) -> String {
        if meetup.isAddressPrivate {
            let city = meetup.place.cityLine
            return city.isEmpty ? String(localized: "City hidden") : city
        }
        let city = meetup.place.cityLine
        return [meetup.place.name, city].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func countLine(_ meetup: Meetup) -> String {
        if meetup.requirements.maxPets > 0 {
            return String(localized: "\(meetup.participantCount)/\(meetup.requirements.maxPets) pets")
        }
        return String(localized: "\(meetup.participantCount) going")
    }
}

struct MeetupStatusBadge: View {
    let status: MeetupStatus

    var body: some View {
        Text(status.label)
            .font(Typography.caption.weight(.semibold))
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            // Dark text on a tint, not white on a colour: white caption text on
            // the success green is the pairing the contrast tests have not
            // measured.
            .foregroundStyle(Palette.primaryText)
            .background(background, in: .capsule)
            .accessibilityIdentifier("meetup.status")
    }

    private var background: Color {
        switch status {
        case .upcoming: Palette.success.opacity(0.2)
        case .completed: Palette.secondaryBackground
        case .cancelled: Palette.danger.opacity(0.2)
        }
    }
}
