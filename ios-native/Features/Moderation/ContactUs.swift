import FirebaseFunctions
import Foundation
import Observation
import OSLog
import SwiftUI

// Contact us — the web client's ContactUs page, sent through
// `submitFeedbackCallable`.

protocol FeedbackSending: Sendable {
    func send(type: FeedbackKind, subject: String, message: String) async throws
}

enum FeedbackKind: String, CaseIterable, Sendable {
    case bug, feature, complaint, other

    /// The web page's labels and marks, in its order.
    var label: String {
        switch self {
        case .bug: String(localized: "Bug Report")
        case .feature: String(localized: "Feature Request")
        case .complaint: String(localized: "Complaint")
        case .other: String(localized: "Other", comment: "Feedback type")
        }
    }

    var mark: String {
        switch self {
        case .bug: "🐛"
        case .feature: "💡"
        case .complaint: "😕"
        case .other: "💬"
        }
    }
}

enum FeedbackError: Error, Equatable {
    case banned, notSignedIn, rateLimited, offline, outcomeUnknown, rejected, unavailable
}

actor FirestoreFeedbackSender: FeedbackSending {
    private let functions: Functions
    private let environment: AppEnvironment
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "moderation")

    init(functions: Functions = .functions(), environment: AppEnvironment = .current) {
        self.functions = functions
        self.environment = environment
    }

    func send(type: FeedbackKind, subject: String, message: String) async throws {
        guard environment.supportsCallables else { throw FeedbackError.unavailable }
        do {
            try await CallableClient.callIgnoringResult(
                Callables.submitFeedback,
                ["type": type.rawValue, "subject": subject, "message": message],
                functions: functions
            )
        } catch {
            log.error("submitFeedback failed: \(String(describing: error), privacy: .public)")
            throw Self.map(error)
        }
    }

    static func map(_ error: Error) -> FeedbackError {
        if let already = error as? FeedbackError { return already }
        switch CallableFailure.classify(error) {
        case .neverSent: return .offline
        case .unavailable: return .unavailable
        case .unknownOutcome: return .outcomeUnknown
        case .server(let code, let message):
            switch code {
            case .permissionDenied: return message.contains("banned") ? .banned : .rejected
            case .unauthenticated: return .notSignedIn
            case .resourceExhausted: return .rateLimited
            default: return .rejected
            }
        }
    }
}

@MainActor
@Observable
final class ContactUsModel {
    /// The server's limits, in its units (UTF-16).
    static let subjectLimit = 100
    static let messageLimit = 1000

    enum State: Equatable {
        case editing
        case sending
        case sent
        case failed(String)
    }

    var kind: FeedbackKind = .bug
    var subject = ""
    var message = ""
    private(set) var state: State = .editing

    private let sender: any FeedbackSending

    init(sender: any FeedbackSending) {
        self.sender = sender
    }

    var subjectRemaining: Int { Self.subjectLimit - subject.utf16.count }
    var messageRemaining: Int { Self.messageLimit - message.utf16.count }

    var canSend: Bool {
        guard state != .sending, state != .sent else { return false }
        return !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && subjectRemaining >= 0 && messageRemaining >= 0
    }

    func send() async {
        guard canSend else { return }
        state = .sending
        do {
            try await sender.send(
                type: kind,
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            state = .sent
        } catch let error as FeedbackError {
            state = .failed(Self.message(for: error))
        } catch {
            state = .failed(String(localized: "Your message wasn't sent."))
        }
    }

    /// Editing after a failure is starting again.
    func edited() {
        if case .failed = state { state = .editing }
    }

    static func message(for error: FeedbackError) -> String {
        switch error {
        case .banned: String(localized: "This account can't send feedback.")
        case .notSignedIn: String(localized: "Sign in again to send feedback.")
        case .rateLimited: String(localized: "You've sent several messages recently. Try again in a little while.")
        case .offline: String(localized: "You're offline, so your message wasn't sent.")
        // Feedback has no fixed id: a second send of one that did arrive
        // arrives twice. The person is told, and decides.
        case .outcomeUnknown:
            String(localized: "We couldn't confirm your message arrived. If you send it again, we may get it twice.")
        case .rejected: String(localized: "Your message wasn't accepted.")
        case .unavailable: String(localized: "Feedback isn't available in this build.")
        }
    }
}

struct ContactUsView: View {
    @State private var model: ContactUsModel

    init(sender: any FeedbackSending) {
        _model = State(initialValue: ContactUsModel(sender: sender))
    }

    var body: some View {
        Group {
            if model.state == .sent {
                VStack(spacing: Spacing.l) {
                    Image(systemName: "checkmark.circle")
                        .font(Typography.sectionTitle)
                        .foregroundStyle(Palette.brandPrimary)
                        .accessibilityHidden(true)
                    Text("Thanks for your feedback!")
                        .font(Typography.body)
                        .foregroundStyle(Palette.primaryText)
                        .accessibilityIdentifier("contact.sent")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
        .background(Palette.background)
        .navigationTitle("Contact us")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var form: some View {
        Form {
            Section {
                Text("Found a bug, have a feature idea, or just want to say hi? Send us a message.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.secondaryText)
            }
            Section("Type") {
                ForEach(FeedbackKind.allCases, id: \.self) { kind in
                    Button {
                        model.kind = kind
                        model.edited()
                    } label: {
                        HStack {
                            Text("\(kind.mark)  \(kind.label)")
                                .font(Typography.body)
                                .foregroundStyle(Palette.primaryText)
                            Spacer(minLength: Spacing.s)
                            if model.kind == kind {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Palette.brandPrimary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(kind.label)
                    .accessibilityAddTraits(model.kind == kind ? .isSelected : [])
                    .accessibilityIdentifier("contact.type.\(kind.rawValue)")
                }
            }
            Section {
                TextField("Brief description of your feedback", text: $model.subject)
                    .onChange(of: model.subject) { model.edited() }
                    .accessibilityIdentifier("contact.subject")
            } header: {
                Text("Subject")
            } footer: {
                counter(used: model.subject.utf16.count, limit: ContactUsModel.subjectLimit)
            }
            Section {
                TextField("Your message", text: $model.message, axis: .vertical)
                    .lineLimit(4...12)
                    .onChange(of: model.message) { model.edited() }
                    .accessibilityIdentifier("contact.message")
            } header: {
                Text("Message")
            } footer: {
                counter(used: model.message.utf16.count, limit: ContactUsModel.messageLimit)
            }
            if case .failed(let message) = model.state {
                Section {
                    Text(message)
                        .font(Typography.body)
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("contact.failure")
                }
            }
            Section {
                Button { Task { await model.send() } } label: {
                    HStack {
                        Spacer()
                        if model.state == .sending { ProgressView() }
                        Text(model.state == .sending ? "Sending…" : "Send")
                        Spacer()
                    }
                    .frame(minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
                }
                .disabled(!model.canSend)
                .accessibilityIdentifier("contact.send")
            }
        }
    }

    /// Typed over limit, as every other counter in the app reads.
    private func counter(used: Int, limit: Int) -> some View {
        Text("\(used)/\(limit)")
            .foregroundStyle(used > limit ? Palette.danger : Palette.secondaryText)
    }
}
