import Observation
import SwiftUI

/// Deleting the account: prove it is the person, type DELETE, and let the
/// server's cascade run (`deleteUserAccount`, functions/src/users.ts).
///
/// What the web client does, plus what it lacked:
///
///   - **Re-authentication first.** The web never asked; the owner requires
///     it. A password account types its password; a Google-only account goes
///     through Google again. Nothing is sent until that succeeds.
///   - **Cancel until it starts, not after.** Once the request is out the
///     server carries on whatever the screen does, so the sheet cannot be
///     dismissed while it runs — the web left Cancel enabled, and closing
///     the dialog did not stop anything.
///   - **An answer that never came is checked, not guessed.** The cascade can
///     run for minutes. If the reply is lost, the profile is read back: gone
///     means it finished; still there means it did not, and the account stays
///     marked as being deleted until a retry finishes it (the settings screen
///     then says so).
@MainActor
@Observable
final class DeleteAccountModel {
    enum Phase: Equatable {
        case editing
        case confirming
        case deleting
        case deleted
    }

    static let keyword = "DELETE"

    var password = ""
    var typed = ""
    private(set) var phase: Phase = .editing
    private(set) var failure: String?

    let uid: String
    let hasPassword: Bool
    let hasGoogle: Bool
    private let security: any AccountSecurity
    private let google: (any GoogleTokenProviding)?

    init(
        uid: String,
        hasPassword: Bool,
        hasGoogle: Bool,
        security: any AccountSecurity,
        google: (any GoogleTokenProviding)?
    ) {
        self.uid = uid
        self.hasPassword = hasPassword
        self.hasGoogle = hasGoogle
        self.security = security
        self.google = google
    }

    var isWorking: Bool { phase == .confirming || phase == .deleting }

    /// Some way to prove it is the person exists on this build.
    var canReauthenticate: Bool {
        hasPassword || (hasGoogle && google?.isAvailable == true)
    }

    var canSubmit: Bool {
        typed == Self.keyword
            && canReauthenticate
            && (!hasPassword || !password.isEmpty)
            && !isWorking
            && phase != .deleted
    }

    func submit() async {
        guard canSubmit else { return }
        failure = nil
        phase = .confirming
        guard await reauthenticate() else {
            if phase == .confirming { phase = .editing }
            return
        }
        phase = .deleting
        do throws(AccountDeletionError) {
            try await security.deleteAccount(uid: uid)
            phase = .deleted
        } catch .notFinished {
            // No answer, or a server that stopped part-way. Ask the server.
            if await security.profileExists(uid: uid) == false {
                phase = .deleted
            } else {
                failure = AccountDeletionError.notFinished.message
                phase = .editing
            }
        } catch {
            failure = error.message
            phase = .editing
        }
    }

    /// True when the person has just proved it is them. False otherwise, with
    /// `failure` set — or not, when they backed out of Google's page.
    private func reauthenticate() async -> Bool {
        do throws(ReauthenticationError) {
            if hasPassword {
                try await security.reauthenticate(password: password)
                return true
            }
            guard let google else { failure = AccountDeletionError.notSignedIn.message; return false }
            let tokens: GoogleTokens?
            do throws(AuthError) {
                tokens = try await google.tokens()
            } catch {
                failure = error.message
                return false
            }
            guard let tokens else { return false }
            try await security.reauthenticate(google: tokens)
            return true
        } catch {
            failure = error.message
            return false
        }
    }
}

struct DeleteAccountView: View {
    @State private var model: DeleteAccountModel
    @Environment(\.dismiss) private var dismiss
    private let onDeleted: () -> Void

    init(model: DeleteAccountModel, onDeleted: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onDeleted = onDeleted
    }

    var body: some View {
        Form {
            Section {
                // The web client's two sentences, word for word.
                Text("Type DELETE to confirm. This action cannot be undone.")
                Text("Pets you share with someone else stay with them — the longest-standing remaining owner becomes the primary owner. Pets only you own are deleted, along with your posts.")
                    .foregroundStyle(Palette.secondaryText)
            }
            .font(Typography.body)

            Section {
                if model.hasPassword {
                    SecureField("Current password", text: $model.password)
                        .textContentType(.password)
                        .accessibilityIdentifier("deleteAccount.password")
                } else if model.canReauthenticate {
                    Text("You'll sign in with Google again to confirm it's you.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                } else {
                    Text("This build can't confirm a Google account. Delete it from the web app, or from a build with Google sign-in.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("deleteAccount.cannotConfirm")
                }
            } header: {
                Text("Confirm it's you")
            }

            Section {
                TextField("DELETE", text: $model.typed)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Type DELETE to confirm")
                    .accessibilityIdentifier("deleteAccount.keyword")
            }

            if let failure = model.failure {
                Section {
                    Text(failure)
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("deleteAccount.error")
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { await model.submit() }
                } label: {
                    HStack {
                        Spacer()
                        if model.isWorking { ProgressView() }
                        Text(model.isWorking ? "Deleting..." : "Delete Account")
                        Spacer()
                    }
                    .frame(minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
                }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("deleteAccount.delete")
            }
        }
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("deleteAccount.cancel")
            }
        }
        .interactiveDismissDisabled(model.isWorking)
        .onChange(of: model.phase) { _, phase in
            if phase == .deleted { onDeleted() }
        }
    }
}
