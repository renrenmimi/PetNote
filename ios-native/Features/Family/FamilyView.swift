import SwiftUI
import UIKit

/// A pet's owners and its invitation code, for its owners.
///
/// The web client splits this across two dialogs opened from the pet page —
/// "Manage" and "Invite". Here it is one screen, because both are "who belongs
/// to this pet" and a person looking for one is usually about to want the
/// other.
struct FamilyView: View {
    @State private var model: FamilyModel
    @State private var invite: InviteModel
    private let onOpenUser: (String) -> Void
    private let onLeft: () -> Void

    init(
        model: FamilyModel,
        invite: InviteModel,
        onOpenUser: @escaping (String) -> Void,
        onLeft: @escaping () -> Void
    ) {
        _model = State(initialValue: model)
        _invite = State(initialValue: invite)
        self.onOpenUser = onOpenUser
        self.onLeft = onLeft
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                switch model.state {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("family.loading")
                case .missing:
                    SocialNotice(
                        title: "This pet no longer exists.",
                        detail: "It may have been deleted by its last owner.",
                        identifier: "family.missing"
                    )
                case .failed(let message):
                    SocialRetryNotice(message: message, identifier: "family.failed") {
                        await model.load()
                    }
                case .loaded where !model.permissions.isMember && !model.permissions.isAdmin:
                    SocialNotice(
                        title: "You are not one of \(model.petName)'s owners.",
                        detail: "Only its owners can invite people or change who owns it.",
                        identifier: "family.notOwner"
                    )
                case .loaded:
                    intro
                    noticeBanner
                    // Owners only: inviting is additive and equal, but the
                    // server has no admin override for it.
                    if model.permissions.isMember {
                        InviteSection(model: invite, petName: model.petName)
                    }
                    owners
                    leaveSection
                }
            }
            .padding(.horizontal, Layout.pageInset)
            .padding(.vertical, Spacing.l)
        }
        .background(Palette.background)
        .navigationTitle("Owners")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable {
            await model.load()
            if model.permissions.isMember { await invite.load() }
        }
        .overlay {
            if model.isWorking {
                ProgressView("Working…")
                    .padding(Spacing.l)
                    .background(Palette.cardBackground, in: .rect(cornerRadius: Radius.card))
                    .accessibilityIdentifier("family.working")
            }
        }
        .alert(
            model.pending.map { model.title(for: $0) } ?? "",
            isPresented: pendingBinding,
            presenting: model.pending
        ) { action in
            Button("Cancel", role: .cancel) { model.cancel() }
            Button(confirmLabel(action), role: action == .leave || isRemove(action) ? .destructive : nil) {
                Task { await model.perform(action) }
            }
        } message: { action in
            Text(model.consequence(of: action))
        }
        .onChange(of: model.didLeave) { _, left in
            if left { onLeft() }
        }
    }

    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { model.pending != nil },
            set: { presented in if !presented { model.cancel() } }
        )
    }

    private func isRemove(_ action: FamilyModel.Action) -> Bool {
        if case .remove = action { return true }
        return false
    }

    private func confirmLabel(_ action: FamilyModel.Action) -> String {
        switch action {
        case .remove: return "Remove"
        case .transfer: return "Make primary"
        case .leave: return "Leave"
        }
    }

    // MARK: - Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("\(model.petName)'s owners")
                .font(Typography.pageTitle)
                .foregroundStyle(Palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("""
                Every owner can edit \(model.petName), post, and invite. The primary owner \
                is the one who can remove someone.
                """)
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var noticeBanner: some View {
        switch model.notice {
        case .success(let text):
            banner(text, colour: Palette.success, identifier: "family.success")
        case .failure(let text):
            banner(text, colour: Palette.danger, identifier: "family.failure")
        case nil:
            EmptyView()
        }
    }

    private func banner(_ text: String, colour: Color, identifier: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Text(text)
                .font(Typography.body)
                .foregroundStyle(colour)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.dismissNotice() } label: {
                Image(systemName: "xmark")
                    .frame(minWidth: Layout.minTouchTarget, minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            .foregroundStyle(Palette.secondaryText)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, Spacing.l)
        .background(Palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityIdentifier(identifier)
    }

    private var owners: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(PetDisplay.ownerCount(max(model.members.count, model.permissions.memberCount)))
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.primaryText)
                .accessibilityAddTraits(.isHeader)
            if model.members.isEmpty {
                // A pet from before family documents existed. The viewer is
                // its owner by the legacy fallback, and the only one.
                Text("You are \(model.petName)'s only owner.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.secondaryText)
            }
            ForEach(model.members) { member in
                memberRow(member)
            }
        }
    }

    private func memberRow(_ member: PetFamilyMember) -> some View {
        SocialAdaptiveStack {
            Button { onOpenUser(member.id) } label: {
                HStack(spacing: Spacing.m) {
                    SocialAvatar(url: member.userAvatarURL, name: FamilyModel.name(member))
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(FamilyModel.name(member) + (model.isViewer(member) ? " (you)" : ""))
                            .font(Typography.body.weight(.semibold))
                            .foregroundStyle(Palette.primaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(roleLine(member))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: Layout.minTouchTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens their profile.")

            // Not on the primary's own row: the primary cannot be pushed out,
            // and handing them a role they hold is a no-op.
            if model.canManage(member), member.role != .primary {
                HStack(spacing: Spacing.s) {
                    Button("Make primary") { model.ask(.transfer(member)) }
                        .buttonStyle(SocialButtonStyle(kind: .secondary))
                        .accessibilityLabel("Make \(FamilyModel.name(member)) primary owner")
                        .accessibilityIdentifier("family.transfer")
                    Button("Remove") { model.ask(.remove(member)) }
                        .buttonStyle(SocialButtonStyle(kind: .destructive))
                        .accessibilityLabel("Remove \(FamilyModel.name(member))")
                        .accessibilityIdentifier("family.remove")
                }
                .disabled(model.isWorking)
            }
        }
        .padding(Spacing.m)
        .background(Palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }

    /// The role in the same line as the relationship, at the same weight: it
    /// is a different responsibility, not a higher rank.
    private func roleLine(_ member: PetFamilyMember) -> String {
        let relationship = PetDisplay.label(for: member.relationship, custom: member.customRelationship)
        return member.role == .primary ? "Primary owner · \(relationship)" : relationship
    }

    @ViewBuilder
    private var leaveSection: some View {
        if model.permissions.isMember {
            if model.canLeave {
                Button { model.ask(.leave) } label: {
                    Text("Leave \(model.petName)'s family")
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(SocialButtonStyle(kind: .destructive, fullWidth: true))
                .disabled(model.isWorking)
                .accessibilityIdentifier("family.leave")
            } else {
                SocialNotice(
                    title: "You are \(model.petName)'s only owner.",
                    detail: """
                        There is no one to hand \(model.petName) to. Invite someone before you \
                        leave, or delete \(model.petName) from its page.
                        """,
                    identifier: "family.onlyOwner"
                )
            }
        }
    }
}

/// The invitation code, and what can be done with it.
struct InviteSection: View {
    let model: InviteModel
    let petName: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Invite someone")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text("""
                Share a code so someone can join \(petName)'s family. Each code works once, \
                for 48 hours, and stops working if it is revoked or if the person who made \
                it leaves.
                """)
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            content

            if let message = model.message {
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("invite.message")
            } else if let confirmation = model.confirmation {
                Text(confirmation)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.success)
                    .accessibilityIdentifier("invite.confirmation")
            } else if copied {
                Text("Code copied.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.success)
            }
        }
        .padding(Spacing.l)
        .background(Palette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .task { if model.state == .loading { await model.load() } }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading invitation…")
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("invite.loading")
        case .notPermitted:
            Text("Only \(petName)'s owners can invite people.")
                .font(Typography.body)
                .foregroundStyle(Palette.secondaryText)
                .accessibilityIdentifier("invite.notPermitted")
        case .failed(let message):
            SocialRetryNotice(message: message, identifier: "invite.failed") { await model.load() }
        case .none, .active:
            if let invitation = model.liveInvitation {
                active(invitation)
            } else {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("No active invitation code.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                    Button { Task { await model.generate() } } label: {
                        HStack(spacing: Spacing.s) {
                            if model.isGenerating { ProgressView().tint(Palette.textOnBrand) }
                            Text(model.isGenerating ? "Generating…" : "Generate invitation code")
                        }
                    }
                    .buttonStyle(SocialButtonStyle(kind: .primary, fullWidth: true))
                    .disabled(model.isGenerating)
                    .accessibilityIdentifier("invite.generate")
                }
            }
        }
    }

    private func active(_ invitation: Invitation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(invitation.formattedCode)
                .font(Typography.pageTitle.monospaced().weight(.bold))
                .foregroundStyle(Palette.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                // Read one character at a time, so "A B C D" is not read as a
                // word somebody then has to spell back.
                .accessibilityLabel(
                    "Invitation code " + invitation.code.map(String.init).joined(separator: " ")
                )
                .accessibilityIdentifier("invite.code")
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(InviteModel.expiresLabel(invitation.expiresAt, now: context.date))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity)
            }
            SocialAdaptiveStack(spacing: Spacing.s) {
                Button("Copy code") {
                    UIPasteboard.general.string = invitation.code
                    copied = true
                }
                .buttonStyle(SocialButtonStyle(kind: .secondary, fullWidth: true))
                .accessibilityIdentifier("invite.copy")
                ShareLink(item: InviteModel.shareMessage(for: invitation, petName: petName)) {
                    Text("Share")
                }
                .buttonStyle(SocialButtonStyle(kind: .primary, fullWidth: true))
                .accessibilityIdentifier("invite.share")
            }
            Button { Task { await model.revoke() } } label: {
                HStack(spacing: Spacing.s) {
                    if model.isRevoking { ProgressView() }
                    Text(model.isRevoking ? "Revoking…" : "Revoke code")
                }
            }
            .buttonStyle(SocialButtonStyle(kind: .destructive, fullWidth: true))
            .disabled(model.isRevoking)
            .accessibilityIdentifier("invite.revoke")
        }
    }
}

#if DEBUG
#Preview("Owners — primary") {
    NavigationStack {
        FamilyView(
            model: FamilyModel(
                petID: "pet-1", viewerID: "me",
                pets: PreviewFamilyPets(), family: PreviewFamilyRepository()
            ),
            invite: InviteModel(petID: "pet-1", repository: PreviewFamilyRepository()),
            onOpenUser: { _ in },
            onLeft: {}
        )
    }
}
#endif
