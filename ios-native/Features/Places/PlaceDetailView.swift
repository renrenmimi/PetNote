import SwiftUI

/// One place: what it is and where, its photos, the latest check-ins, its
/// reviews and the meetups held there — the web's location page, read only.
struct PlaceDetailView: View {
    @State private var model: PlaceDetailModel
    private let onOpenMeetup: (String) -> Void

    init(model: PlaceDetailModel, onOpenMeetup: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.onOpenMeetup = onOpenMeetup
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("place.loading")
            case .missing:
                Text("This place is no longer on PetNote.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("place.missing")
            case .failed(let message):
                FeedErrorView(message: message) { Task { await model.load() } }
            case .loaded(let place):
                loaded(place)
            }
        }
        .background(Palette.background)
        .navigationTitle("Place")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private func loaded(_ place: Place) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header(place)
                if !place.features.isEmpty {
                    section(String(localized: "Features & Amenities")) {
                        Text(place.features.map(Place.featureLabel).joined(separator: " · "))
                            .font(Typography.body)
                            .foregroundStyle(Palette.primaryText)
                            .accessibilityIdentifier("place.features")
                    }
                }
                photos
                checkins
                reviews(place)
                meetups
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.m)
        }
    }

    private func header(_ place: Place) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let photo = place.photos.first {
                RemoteImage(url: photo, aspectRatio: 16.0 / 9.0, cornerRadius: Radius.control, size: .large)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(place.name)
                    .font(Typography.pageTitle)
                    .foregroundStyle(Palette.primaryText)
                    .accessibilityIdentifier("place.name")
                if place.verifiedByCheckins {
                    Text("✓ Verified")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Palette.success)
                }
            }
            Text("\(place.category.emoji) \(place.category.label)")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
            if !place.address.isEmpty {
                Text(place.address)
                    .font(Typography.body)
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityIdentifier("place.address")
            }
            Text(place.ratingLine.map { "⭐ \($0)" } ?? String(localized: "No reviews yet"))
                .font(Typography.body)
                .foregroundStyle(Palette.primaryText)
                .accessibilityIdentifier("place.rating")
            if !place.description.isEmpty {
                Text(place.description)
                    .font(Typography.body)
                    .foregroundStyle(Palette.primaryText)
            }
            HStack(spacing: Spacing.m) {
                if let directions = place.directionsURL {
                    Link(destination: directions) {
                        Label("Directions", systemImage: "map")
                            .frame(minHeight: Layout.minTouchTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityIdentifier("place.directions")
                }
                ShareLink(item: PostShareContent.site.appending(path: "location").appending(component: place.id)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .accessibilityIdentifier("place.share")
            }
            .font(Typography.body)
        }
    }

    @ViewBuilder
    private var photos: some View {
        let photos = model.photos
        section(String(localized: "Photos (\(photos.count))")) {
            if photos.isEmpty {
                Text("No photos yet.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        ForEach(photos, id: \.self) { url in
                            RemoteImage(url: url, aspectRatio: 1, cornerRadius: Radius.control, size: .thumbnail)
                                .frame(width: 96, height: 96)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "\(photos.count) photos"))
                .accessibilityIdentifier("place.photos")
            }
        }
    }

    private var checkins: some View {
        section(String(localized: "Recent Check-ins (\(model.checkins.count))")) {
            if model.failedSections.contains("checkins") {
                failure(String(localized: "Could not load check-ins."))
            } else if model.checkins.isEmpty {
                Text("No check-ins yet.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ForEach(model.checkins) { checkin in
                    HStack(alignment: .top, spacing: Spacing.s) {
                        SocialAvatar(url: checkin.userAvatarURL, name: checkin.userName)
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(checkin.petName.map { "\(checkin.userName) · \($0)" } ?? checkin.userName)
                                .font(Typography.caption.weight(.semibold))
                                .foregroundStyle(Palette.primaryText)
                            if !checkin.caption.isEmpty {
                                Text(checkin.caption)
                                    .font(Typography.body)
                                    .foregroundStyle(Palette.primaryText)
                            }
                            if let date = checkin.createdAt {
                                Text(date, format: .relative(presentation: .named))
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("place.checkin")
                }
            }
        }
    }

    private func reviews(_ place: Place) -> some View {
        section(String(localized: "Reviews (\(max(place.totalRatings, model.reviews.count)))")) {
            if model.failedSections.contains("reviews") {
                failure(String(localized: "Could not load reviews."))
            } else if model.reviews.isEmpty {
                Text("No reviews yet.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ForEach(model.reviews) { review in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(spacing: Spacing.s) {
                            SocialAvatar(url: review.userAvatarURL, name: review.userName)
                            Text(review.userName)
                                .font(Typography.caption.weight(.semibold))
                                .foregroundStyle(Palette.primaryText)
                            Spacer(minLength: 0)
                            Text(String(repeating: "★", count: max(0, min(review.rating, 5)))
                                 + String(repeating: "☆", count: max(0, 5 - min(review.rating, 5))))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.warning)
                                .accessibilityLabel(String(localized: "\(review.rating) out of 5"))
                        }
                        if !review.comment.isEmpty {
                            Text(review.comment)
                                .font(Typography.body)
                                .foregroundStyle(Palette.primaryText)
                        }
                        if !review.tags.isEmpty {
                            Text(review.tags.map { "#\($0)" }.joined(separator: " "))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.brandPrimary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("place.review")
                }
            }
        }
    }

    private var meetups: some View {
        section(String(localized: "Meetups at this place")) {
            if model.failedSections.contains("meetups") {
                failure(String(localized: "Could not load meetups."))
            } else if model.meetups.isEmpty {
                Text("No meetups yet.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ForEach(model.meetups) { meetup in
                    Button { onOpenMeetup(meetup.id) } label: {
                        MeetupSummary(meetup: meetup)
                            .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("place.meetup.\(meetup.id)")
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title)
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.primaryText)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func failure(_ message: String) -> some View {
        HStack(spacing: Spacing.s) {
            Text(message)
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
            Button { Task { await model.load() } } label: {
                Text("Try again")
                    .font(Typography.caption)
                    .frame(minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
        }
    }
}
