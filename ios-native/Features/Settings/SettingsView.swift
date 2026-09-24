import SwiftUI

/// Settings — the web client's page (`src/pages/Settings.tsx`), section for
/// section, with what the iPhone does differently said where it applies:
///
///   - **Appearance** follows the iPhone's own setting; there is no switch.
///   - **Language** is chosen in the iPhone's Settings for this app, the way
///     every iOS app is switched; this row opens it.
///   - **My Location** is not here yet: it needs location permission and the
///     address lookup, which the test project does not have (Geoapify).
struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @State private var model: SettingsModel
    @State private var isConfirmingSignOut = false
    @State private var isChangingPassword = false
    @State private var isDeleting = false
    @State private var legal: LegalDocument?

    private let email: String
    private let security: any AccountSecurity
    private let onBlocked: () -> Void
    private let onContact: () -> Void

    init(
        uid: String,
        email: String,
        store: any PreferencesStoring,
        security: any AccountSecurity,
        onBlocked: @escaping () -> Void,
        onContact: @escaping () -> Void
    ) {
        _model = State(initialValue: SettingsModel(uid: uid, store: store, security: security))
        self.email = email
        self.security = security
        self.onBlocked = onBlocked
        self.onContact = onContact
    }

    var body: some View {
        Form {
            if model.deletionPending { unfinishedDeletion }
            account
            notifications
            language
            privacy
            danger
            about
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .confirmationDialog("Sign Out", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { try? session.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
        .sheet(isPresented: $isChangingPassword) {
            NavigationStack { ChangePasswordView(security: security) }
        }
        .sheet(isPresented: $isDeleting, onDismiss: { Task { await model.load() } }) {
            NavigationStack {
                DeleteAccountView(
                    model: DeleteAccountModel(
                        uid: model.uid,
                        hasPassword: model.hasPassword,
                        hasGoogle: model.hasGoogle,
                        security: security,
                        google: GoogleSignInProvider.make()
                    ),
                    onDeleted: {
                        let uid = model.uid
                        Task { await AccountLocalData.forget(uid: uid) }
                        session.accountDeleted()
                    }
                )
            }
        }
        .sheet(item: $legal) { document in
            LegalPageSheet(document: document).ignoresSafeArea()
        }
    }

    /// A deletion that stopped part-way. The server has marked the account as
    /// being deleted, which refuses every change to it, so the only way on is
    /// to finish.
    private var unfinishedDeletion: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Deleting your account didn't finish.")
                    .font(Typography.body.weight(.semibold))
                Text("Some of it may already be gone, and it can't be changed until the deletion finishes.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                Button { isDeleting = true } label: {
                    Text("Finish deleting")
                        .frame(minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                }
                .accessibilityIdentifier("settings.finishDeleting")
            }
            .foregroundStyle(Palette.danger)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.deletionPending")
        }
    }

    private var account: some View {
        Section("Account") {
            LabeledContent("Email", value: email)
                .accessibilityIdentifier("settings.email")
            if model.hasPassword {
                row("Change Password") { isChangingPassword = true }
                    .accessibilityIdentifier("settings.changePassword")
            }
            row("Sign Out") { isConfirmingSignOut = true }
                .accessibilityIdentifier("settings.signOut")
        }
    }

    private var notifications: some View {
        Section {
            switch model.preferencesState {
            case .loading:
                ProgressView().accessibilityLabel("Loading settings...")
            case .failed:
                Text("Failed to load settings.")
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityIdentifier("settings.preferencesFailed")
            case .loaded:
                toggle("Likes", .likes)
                toggle("Comments", .comments)
                toggle("Follows", .follows)
            }
        } header: {
            Text("Notifications")
        } footer: {
            if let failure = model.saveFailure {
                Text(failure)
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("settings.saveFailed")
            }
        }
    }

    private func toggle(_ title: LocalizedStringKey, _ key: NotificationPreferences.Key) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.preferences[key] },
            set: { value in Task { await model.set(key, to: value) } }
        ))
        .disabled(model.saving.contains(key))
        .accessibilityIdentifier("settings.notify.\(key.rawValue)")
    }

    private var language: some View {
        Section {
            row("Language") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .accessibilityIdentifier("settings.language")
        } footer: {
            Text("PetNote uses your iPhone's language. To change it for PetNote only, choose Language in the iPhone's Settings for this app.")
        }
    }

    private var privacy: some View {
        Section("Privacy") {
            row("Blocked people", action: onBlocked)
                .accessibilityIdentifier("settings.blocked")
        }
    }

    private var danger: some View {
        Section("Danger Zone") {
            Button(role: .destructive) { isDeleting = true } label: {
                Text("Delete Account")
                    .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget, alignment: .leading)
                    .contentShape(.rect)
            }
            .accessibilityIdentifier("settings.deleteAccount")
        }
    }

    private var about: some View {
        Section("About") {
            row("Contact Us & Feedback", action: onContact)
                .accessibilityIdentifier("settings.contact")
            ForEach(LegalDocument.allCases) { document in
                row(document.title) { legal = document }
                    .accessibilityIdentifier("settings.legal.\(document.rawValue)")
            }
            LabeledContent("Version", value: Self.version)
                .accessibilityIdentifier("settings.version")
        }
    }

    /// From the bundle, not written in: the web hard-codes "1.0.0".
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// A tappable row. Identifiers go on at the call site, as literals: the
    /// identifier guard reads the source, and a name passed in is one it
    /// cannot see.
    private func row(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Palette.primaryText)
                Spacer(minLength: Spacing.s)
                Image(systemName: "chevron.right")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Layout.minTouchTarget)
            .contentShape(.rect)
        }
    }
}
