import FirebaseFunctions
import Foundation
import Observation
import OSLog
import SwiftUI

// Reporting a post — the web client's `ReportModal`, which is offered on a
// post and nowhere else (not on comments, not on people).

/// Sends a report through `reportContentCallable`. The client never writes
/// `reports/*`; the rules forbid it.
protocol ContentReporting: Sendable {
    func reportPost(id: String, reason: String, description: String?) async throws
}

enum ReportError: Error, Equatable {
    /// `already-exists`: the report id is `{reporter}_{type}_{target}`, so a
    /// second report of the same post is refused — which is also what a retry
    /// of a report that did land gets back.
    case alreadyReported
    case banned
    case notSignedIn
    case postGone
    case rateLimited
    case offline
    /// Sent, and no answer came back. Safe to send again: the deterministic id
    /// makes a second copy impossible.
    case outcomeUnknown
    case rejected
    case unavailable
}

actor FirestoreContentReporter: ContentReporting {
    private let functions: Functions
    private let environment: AppEnvironment
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "moderation")

    init(functions: Functions = .functions(), environment: AppEnvironment = .current) {
        self.functions = functions
        self.environment = environment
    }

    func reportPost(id: String, reason: String, description: String?) async throws {
        guard environment.supportsCallables else { throw ReportError.unavailable }
        guard let postID = DeepLink.validDocumentID(id) else { throw ReportError.postGone }
        var payload: [String: Any] = ["targetType": "post", "targetId": postID, "reason": reason]
        // Absent rather than empty, as the web client sends it.
        if let description { payload["description"] = description }
        do {
            try await CallableClient.callIgnoringResult(Callables.reportContent, payload, functions: functions)
        } catch {
            log.error("reportContent failed: \(String(describing: error), privacy: .public)")
            throw Self.map(error)
        }
    }

    static func map(_ error: Error) -> ReportError {
        if let already = error as? ReportError { return already }
        switch CallableFailure.classify(error) {
        case .neverSent: return .offline
        case .unavailable: return .unavailable
        case .unknownOutcome: return .outcomeUnknown
        case .server(let code, let message):
            switch code {
            case .alreadyExists: return .alreadyReported
            case .permissionDenied: return message.contains("banned") ? .banned : .rejected
            case .unauthenticated: return .notSignedIn
            case .notFound: return .postGone
            case .resourceExhausted: return .rateLimited
            default: return .rejected
            }
        }
    }
}

@MainActor
@Observable
final class ReportModel {
    /// The web client's list, word for word, in its order.
    static let reasons = [
        "Spam", "Inappropriate content", "Harassment", "Animal abuse 🐾", "Misinformation", "Other",
    ]
    static let other = "Other"

    /// What a reason reads as on screen. The reason itself, in English, is
    /// what is sent, so only the words drawn are translated.
    static func label(for reason: String) -> String {
        switch reason {
        case "Spam": String(localized: "Spam", comment: "Report reason")
        case "Inappropriate content": String(localized: "Inappropriate content", comment: "Report reason")
        case "Harassment": String(localized: "Harassment", comment: "Report reason")
        case "Animal abuse 🐾": String(localized: "Animal abuse 🐾", comment: "Report reason")
        case "Misinformation": String(localized: "Misinformation", comment: "Report reason")
        case "Other": String(localized: "Other", comment: "Report reason")
        default: reason
        }
    }

    /// The server's `reportReason` limit, in its units: for "Other" the text
    /// typed *is* the reason, and JavaScript counts UTF-16.
    static let detailLimit = 500

    enum State: Equatable {
        case choosing
        case sending
        case sent(alreadyReported: Bool)
        case failed(String, canRetry: Bool)
    }

    var selected: String?
    var detail = ""
    private(set) var state: State = .choosing

    let postID: String
    private let reporter: any ContentReporting

    init(postID: String, reporter: any ContentReporting) {
        self.postID = postID
        self.reporter = reporter
    }

    var isOther: Bool { selected == Self.other }
    var detailRemaining: Int { Self.detailLimit - detail.utf16.count }

    var canSubmit: Bool {
        guard selected != nil, detailRemaining >= 0 else { return false }
        switch state {
        case .choosing: return true
        case .failed(_, let canRetry): return canRetry
        case .sending, .sent: return false
        }
    }

    func submit() async {
        guard canSubmit, let selected else { return }
        state = .sending
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        // As the web client builds it: "Other" sends what was typed as the
        // reason (or "Other" if nothing was), and the same text as the
        // description; any other reason sends only itself.
        let reason = selected == Self.other ? (trimmed.isEmpty ? Self.other : trimmed) : selected
        let description = selected == Self.other && !trimmed.isEmpty ? trimmed : nil
        do {
            try await reporter.reportPost(id: postID, reason: reason, description: description)
            state = .sent(alreadyReported: false)
        } catch ReportError.alreadyReported {
            state = .sent(alreadyReported: true)
        } catch let error as ReportError {
            state = .failed(Self.message(for: error), canRetry: Self.canRetry(error))
        } catch {
            state = .failed(String(localized: "Couldn't send the report."), canRetry: true)
        }
    }

    /// A choice made after a failure starts again from choosing, so the
    /// failure does not sit under a reason it was not about.
    func choose(_ reason: String) {
        selected = reason
        if case .failed = state { state = .choosing }
    }

    static func message(for error: ReportError) -> String {
        switch error {
        case .alreadyReported: String(localized: "You've already reported this post.")
        case .banned: String(localized: "This account can't send reports.")
        case .notSignedIn: String(localized: "Sign in again to send a report.")
        case .postGone: String(localized: "That post no longer exists.")
        case .rateLimited: String(localized: "Too many reports in a short time. Try again in a little while.")
        case .offline: String(localized: "You're offline, so the report wasn't sent.")
        case .outcomeUnknown:
            String(localized: "We couldn't confirm the report arrived. Sending it again won't file it twice.")
        case .rejected: String(localized: "The report wasn't accepted.")
        case .unavailable: String(localized: "Reporting isn't available in this build.")
        }
    }

    static func canRetry(_ error: ReportError) -> Bool {
        switch error {
        case .offline, .outcomeUnknown, .rateLimited: true
        case .alreadyReported, .banned, .notSignedIn, .postGone, .rejected, .unavailable: false
        }
    }
}

/// Owns the model for one presentation, so a re-render of the screen behind
/// the sheet does not start the report over.
struct ReportPostSheet: View {
    @State private var model: ReportModel
    private let onClose: () -> Void

    init(postID: String, reporter: any ContentReporting, onClose: @escaping () -> Void) {
        _model = State(initialValue: ReportModel(postID: postID, reporter: reporter))
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            Group {
                if case .sent(let already) = model.state {
                    sent(alreadyReported: already)
                } else {
                    form
                }
            }
            .navigationTitle("Report post")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var form: some View {
        List {
            Section {
                ForEach(Array(ReportModel.reasons.enumerated()), id: \.offset) { index, reason in
                    Button { model.choose(reason) } label: {
                        HStack {
                            Text(ReportModel.label(for: reason))
                                .font(Typography.body)
                                .foregroundStyle(Palette.primaryText)
                            Spacer(minLength: Spacing.s)
                            if model.selected == reason {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Palette.brandPrimary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: Layout.minTouchTarget)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.selected == reason ? .isSelected : [])
                    .accessibilityIdentifier("report.reason.\(index)")
                }
            } header: {
                Text("Why are you reporting this post?")
            }

            if model.isOther {
                Section {
                    TextField("Tell us more (optional)", text: $model.detail, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("report.detail")
                } footer: {
                    Text("\(max(model.detailRemaining, 0)) characters left")
                        .foregroundStyle(model.detailRemaining < 0 ? Palette.danger : Palette.secondaryText)
                }
            }

            if case .failed(let message, let canRetry) = model.state {
                Section {
                    Text(message)
                        .font(Typography.body)
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("report.failure")
                    if !canRetry {
                        Button("Close", action: onClose)
                            .accessibilityIdentifier("report.giveUp")
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onClose)
                    .accessibilityIdentifier("report.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.state == .sending {
                    ProgressView().accessibilityLabel("Sending report")
                } else {
                    Button("Send") { Task { await model.submit() } }
                        .disabled(!model.canSubmit)
                        .accessibilityIdentifier("report.send")
                }
            }
        }
    }

    private func sent(alreadyReported: Bool) -> some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "checkmark.circle")
                .font(Typography.sectionTitle)
                .foregroundStyle(Palette.brandPrimary)
                .accessibilityHidden(true)
            Text(alreadyReported
                 ? "You've already reported this post. We'll review it."
                 : "Thank you for reporting. We'll review this shortly.")
                .font(Typography.body)
                .foregroundStyle(Palette.primaryText)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("report.sent")
            Button { onClose() } label: {
                Text("Done")
                    .frame(maxWidth: .infinity, minHeight: Layout.minTouchTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.brandPrimary)
            .accessibilityIdentifier("report.done")
        }
        .padding(Layout.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }
}
