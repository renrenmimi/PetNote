import FirebaseFunctions
import Foundation
import Testing

@testable import PetNote

@MainActor
struct ContactUsTests {
    final class FakeSender: FeedbackSending, @unchecked Sendable {
        var error: Error?
        private(set) var sent: [(type: FeedbackKind, subject: String, message: String)] = []

        func send(type: FeedbackKind, subject: String, message: String) async throws {
            sent.append((type, subject, message))
            if let error { throw error }
        }
    }

    @Test func whatIsSentIsTrimmedAndTyped() async {
        let sender = FakeSender()
        let model = ContactUsModel(sender: sender)
        model.kind = .feature
        model.subject = "  Dark mode  "
        model.message = "\n please \n"

        await model.send()

        #expect(sender.sent.count == 1)
        #expect(sender.sent.first?.type == .feature)
        #expect(sender.sent.first?.subject == "Dark mode")
        #expect(sender.sent.first?.message == "please")
        #expect(model.state == .sent)
    }

    @Test func bothFieldsAreRequired() async {
        let sender = FakeSender()
        let model = ContactUsModel(sender: sender)
        model.subject = "Hi"
        model.message = "   "
        #expect(!model.canSend)
        await model.send()
        #expect(sender.sent.isEmpty)
    }

    @Test func theLimitsAreTheServersInItsUnits() {
        let model = ContactUsModel(sender: FakeSender())
        model.subject = String(repeating: "🐱", count: 50)
        model.message = "m"
        #expect(model.subjectRemaining == 0)
        #expect(model.canSend)
        model.subject += "🐱"
        #expect(!model.canSend)
    }

    /// Feedback has no fixed id, so a resend of one that arrived arrives
    /// twice. The person is told that rather than offered a silent retry.
    @Test func anUnknownOutcomeSaysASecondSendMayArriveTwice() async {
        let sender = FakeSender()
        sender.error = FeedbackError.outcomeUnknown
        let model = ContactUsModel(sender: sender)
        model.subject = "s"
        model.message = "m"

        await model.send()

        #expect(model.state == .failed(ContactUsModel.message(for: .outcomeUnknown)))
        #expect(ContactUsModel.message(for: .outcomeUnknown).contains("twice"))
        #expect(sender.sent.count == 1, "nothing was resent on its own")
    }

    @Test func theServersAnswersMapToWhatTheyMean() {
        func functionsError(_ code: FunctionsErrorCode, _ message: String) -> NSError {
            NSError(domain: FunctionsErrorDomain, code: code.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: message])
        }
        #expect(FirestoreFeedbackSender.map(functionsError(.permissionDenied, "Banned users cannot submit feedback.")) == .banned)
        #expect(FirestoreFeedbackSender.map(functionsError(.resourceExhausted, "Too many requests")) == .rateLimited)
        #expect(FirestoreFeedbackSender.map(functionsError(.invalidArgument, "Invalid feedback type.")) == .rejected)
        #expect(FirestoreFeedbackSender.map(functionsError(.deadlineExceeded, "deadline")) == .outcomeUnknown)
    }
}
