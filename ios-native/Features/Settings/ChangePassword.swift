import Observation
import SwiftUI

/// Change Password, the web client's rules: the current password proves it
/// is really the person (a re-authentication, not a comparison), and the new
/// one meets the same rules as sign-up.
@MainActor
@Observable
final class ChangePasswordModel {
    var current = ""
    var new = ""
    var confirm = ""
    private(set) var isSaving = false
    private(set) var failure: String?
    private(set) var done = false

    private let security: any AccountSecurity

    init(security: any AccountSecurity) {
        self.security = security
    }

    var newIsValid: Bool { PasswordPolicy.isValid(new) }
    var mismatch: Bool { !confirm.isEmpty && confirm != new }

    var canSubmit: Bool {
        !current.isEmpty && newIsValid && confirm == new && !isSaving && !done
    }

    func submit() async {
        guard canSubmit else { return }
        isSaving = true
        failure = nil
        defer { isSaving = false }
        do throws(PasswordChangeError) {
            try await security.changePassword(current: current, to: new)
            current = ""
            new = ""
            confirm = ""
            done = true
        } catch {
            failure = error.message
        }
    }
}

struct ChangePasswordView: View {
    @State private var model: ChangePasswordModel
    @Environment(\.dismiss) private var dismiss

    init(security: any AccountSecurity) {
        _model = State(initialValue: ChangePasswordModel(security: security))
    }

    var body: some View {
        Form {
            if model.done {
                Section {
                    Text("Password updated")
                        .foregroundStyle(Palette.success)
                        .accessibilityIdentifier("changePassword.done")
                }
            } else {
                Section {
                    SecureField("Current password", text: limited(\.current))
                        .textContentType(.password)
                        .accessibilityIdentifier("changePassword.current")
                    SecureField("New password", text: limited(\.new))
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("changePassword.new")
                    SecureField("Confirm new password", text: limited(\.confirm))
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("changePassword.confirm")
                } footer: {
                    guidance
                }
                if let failure = model.failure {
                    Section {
                        Text(failure)
                            .foregroundStyle(Palette.danger)
                            .accessibilityIdentifier("changePassword.error")
                    }
                }
                Section {
                    Button {
                        Task { await model.submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.isSaving { ProgressView() }
                            Text(model.isSaving ? "Saving..." : "Change Password")
                            Spacer()
                        }
                        .frame(minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                    }
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier("changePassword.save")
                }
            }
        }
        .navigationTitle("Change Password")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(model.done ? "Done" : "Cancel") { dismiss() }
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("changePassword.close")
            }
        }
        .interactiveDismissDisabled(model.isSaving)
    }

    /// The sign-up screen's own rules, so the two cannot drift.
    @ViewBuilder
    private var guidance: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if !model.new.isEmpty {
                ForEach(PasswordPolicy.requirements(for: model.new)) { requirement in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        Image(systemName: requirement.isMet ? "checkmark.circle.fill" : "circle")
                            .accessibilityHidden(true)
                        Text(requirement.text)
                    }
                    .foregroundStyle(requirement.isMet ? Palette.success : Palette.secondaryText)
                }
            }
            if model.mismatch {
                Text("Passwords don't match")
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("changePassword.mismatch")
            }
        }
        .font(Typography.caption)
    }

    /// The web's 64-character cap on each field.
    private func limited(_ path: ReferenceWritableKeyPath<ChangePasswordModel, String>) -> Binding<String> {
        Binding(
            get: { model[keyPath: path] },
            set: { model[keyPath: path] = String($0.prefix(PasswordPolicy.maxLength)) }
        )
    }
}
