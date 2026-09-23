import SwiftUI

/// One meetup: when and where, who is going, what it asks of a pet, and
/// joining, leaving or — for its organiser — cancelling it.
struct MeetupDetailView: View {
    @State private var model: MeetupDetailModel
    @State private var isChoosingPet = false
    @State private var isConfirmingLeave = false
    @State private var isConfirmingCancel = false
    private let onOpenPlace: (String) -> Void

    init(model: MeetupDetailModel, onOpenPlace: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.onOpenPlace = onOpenPlace
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("meetupDetail.loading")
            case .missing:
                Text("This meetup is no longer on PetNote.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("meetupDetail.missing")
            case .failed(let message):
                FeedErrorView(message: message) { Task { await model.load() } }
            case .loaded(let meetup):
                loaded(meetup)
            }
        }
        .background(Palette.background)
        .navigationTitle("Meetup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .confirmationDialog("Join with which pet?", isPresented: $isChoosingPet, titleVisibility: .visible) {
            ForEach(model.pets) { pet in
                Button(pet.name) { Task { await model.join(petID: pet.id) } }
            }
            if model.isOrganizer {
                Button("Without a pet") { Task { await model.join(petID: nil) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Leave this meetup?", isPresented: $isConfirmingLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { await model.leave() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Cancel this meetup?", isPresented: $isConfirmingCancel, titleVisibility: .visible) {
            Button("Cancel Meetup", role: .destructive) { Task { await model.cancel() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Everyone who joined will see it as cancelled.")
        }
    }

    private func loaded(_ meetup: Meetup) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if let cover = meetup.coverImageURL {
                    RemoteImage(url: cover, aspectRatio: 16.0 / 9.0, cornerRadius: Radius.control, size: .large)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        Text(meetup.title)
                            .font(Typography.pageTitle)
                            .foregroundStyle(Palette.primaryText)
                            .accessibilityIdentifier("meetupDetail.title")
                        Spacer(minLength: Spacing.s)
                        MeetupStatusBadge(status: meetup.status)
                    }
                    if let date = meetup.date {
                        Text("\(date.formatted(date: .complete, time: .shortened)) · \(meetup.durationMinutes) min")
                            .font(Typography.body)
                            .foregroundStyle(Palette.secondaryText)
                            .accessibilityIdentifier("meetupDetail.when")
                    }
                    HStack(spacing: Spacing.s) {
                        SocialAvatar(url: meetup.organizerAvatarURL, name: meetup.organizerName)
                        Text("Organized by \(meetup.organizerName)")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                    if !meetup.description.isEmpty {
                        Text(meetup.description)
                            .font(Typography.body)
                            .foregroundStyle(Palette.primaryText)
                    }
                }
                place(meetup)
                if !meetup.requirements.lines.isEmpty || !meetup.requirements.notes.isEmpty {
                    section(String(localized: "Requirements")) {
                        ForEach(meetup.requirements.lines, id: \.self) { line in
                            Text("• \(line)")
                                .font(Typography.body)
                                .foregroundStyle(Palette.primaryText)
                        }
                        if !meetup.requirements.notes.isEmpty {
                            Text(meetup.requirements.notes)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("meetupDetail.requirements")
                }
                actions(meetup)
                participants(meetup)
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.m)
        }
    }

    private func place(_ meetup: Meetup) -> some View {
        section(String(localized: "Location")) {
            if let place = model.shownPlace {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if !place.name.isEmpty {
                        Text(place.name)
                            .font(Typography.body.weight(.semibold))
                            .foregroundStyle(Palette.primaryText)
                    }
                    if !place.address.isEmpty {
                        Text(place.address)
                            .font(Typography.body)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("meetupDetail.address")
                HStack(spacing: Spacing.m) {
                    if let directions = place.directionsURL {
                        Link(destination: directions) {
                            Label("Directions", systemImage: "map")
                                .frame(minHeight: Layout.minTouchTarget)
                                .contentShape(.rect)
                        }
                        .accessibilityIdentifier("meetupDetail.directions")
                    }
                    if let placeID = meetup.locationID {
                        Button { onOpenPlace(placeID) } label: {
                            Label("View place", systemImage: "mappin.and.ellipse")
                                .frame(minHeight: Layout.minTouchTarget)
                                .contentShape(.rect)
                        }
                        .accessibilityIdentifier("meetupDetail.place")
                    }
                }
                .font(Typography.body)
            } else {
                // Participants-only, and this person is not one yet.
                Text("The address is shared with people who join.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityIdentifier("meetupDetail.addressHidden")
            }
        }
    }

    @ViewBuilder
    private func actions(_ meetup: Meetup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if meetup.status == .upcoming {
                if model.hasJoined {
                    Label("You're going", systemImage: "checkmark.circle.fill")
                        .font(Typography.body.weight(.semibold))
                        .foregroundStyle(Palette.success)
                        .accessibilityIdentifier("meetupDetail.going")
                    Button { isConfirmingLeave = true } label: {
                        Text(model.working == .leaving ? String(localized: "Leaving…") : String(localized: "Leave"))
                            .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canAct)
                    .accessibilityIdentifier("meetupDetail.leave")
                } else {
                    Button { startJoining() } label: {
                        Text(model.working == .joining ? String(localized: "Joining…") : String(localized: "Join"))
                            .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.brandPrimary)
                    .disabled(!model.canAct)
                    .accessibilityIdentifier("meetupDetail.join")
                }
                if model.isOrganizer {
                    Button(role: .destructive) { isConfirmingCancel = true } label: {
                        Text(model.working == .cancelling ? String(localized: "Cancelling…") : String(localized: "Cancel Meetup"))
                            .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canAct)
                    .accessibilityIdentifier("meetupDetail.cancel")
                }
            } else {
                Text(meetup.status == .cancelled
                     ? String(localized: "This meetup was cancelled.")
                     : String(localized: "This meetup has ended."))
                    .font(Typography.body)
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityIdentifier("meetupDetail.over")
            }
            if let message = model.actionMessage {
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("meetupDetail.error")
            }
        }
    }

    /// The organiser may come without a pet; anyone else brings one, and the
    /// server checks it against the meetup's rules.
    private func startJoining() {
        if model.pets.isEmpty {
            // The organiser joins as themselves; anyone else hears the
            // server's own words for having no pet to bring.
            Task { await model.join(petID: nil) }
        } else {
            isChoosingPet = true
        }
    }

    private func participants(_ meetup: Meetup) -> some View {
        section(String(localized: "Going (\(MeetupSummary.countLine(meetup)))")) {
            if model.participantsFailed {
                Text("Could not load who is going.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            } else if model.participants.isEmpty {
                Text("Nobody has joined yet.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
            } else {
                ForEach(model.participants) { participant in
                    HStack(spacing: Spacing.s) {
                        SocialAvatar(url: participant.userAvatarURL, name: participant.userName)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(participant.userName)
                                .font(Typography.body)
                                .foregroundStyle(Palette.primaryText)
                            if !participant.petName.isEmpty {
                                Text(participant.petName)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("meetupDetail.participant.\(participant.id)")
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
}
