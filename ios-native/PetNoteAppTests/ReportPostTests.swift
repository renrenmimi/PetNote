import FirebaseFunctions
import Foundation
import Testing

@testable import PetNote

/// Reporting a post, checked by what would reach `reportContentCallable`
/// rather than by what the model says about itself.
@MainActor
struct ReportPostTests {
    final class FakeReporter: ContentReporting, @unchecked Sendable {
        var error: Error?
        private(set) var sent: [(id: String, reason: String, description: String?)] = []

        func reportPost(id: String, reason: String, description: String?) async throws {
            sent.append((id, reason, description))
            if let error { throw error }
        }
    }

    private func functionsError(_ code: FunctionsErrorCode, _ message: String) -> NSError {
        NSError(domain: FunctionsErrorDomain, code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - What is sent

    @Test func aListedReasonIsSentOnItsOwn() async {
        let reporter = FakeReporter()
        let model = ReportModel(postID: "p1", reporter: reporter)
        model.choose("Harassment")
        model.detail = "typed before switching away from Other"

        await model.submit()

        #expect(reporter.sent.count == 1)
        #expect(reporter.sent.first?.id == "p1")
        #expect(reporter.sent.first?.reason == "Harassment")
        #expect(reporter.sent.first?.description == nil, "only Other carries a description")
        #expect(model.state == .sent(alreadyReported: false))
    }

    /// The web client's rule: the typed text is the reason, and the same text
    /// the description.
    @Test func otherSendsWhatWasTypedAsTheReason() async {
        let reporter = FakeReporter()
        let model = ReportModel(postID: "p1", reporter: reporter)
        model.choose(ReportModel.other)
        model.detail = "  someone's selling puppies  "

        await model.submit()

        #expect(reporter.sent.first?.reason == "someone's selling puppies")
        #expect(reporter.sent.first?.description == "someone's selling puppies")
    }

    @Test func otherWithNothingTypedSendsOther() async {
        let reporter = FakeReporter()
        let model = ReportModel(postID: "p1", reporter: reporter)
        model.choose(ReportModel.other)

        await model.submit()

        #expect(reporter.sent.first?.reason == "Other")
        #expect(reporter.sent.first?.description == nil)
    }

    @Test func nothingIsSentWithoutAReason() async {
        let reporter = FakeReporter()
        let model = ReportModel(postID: "p1", reporter: reporter)

        #expect(!model.canSubmit)
        await model.submit()
        #expect(reporter.sent.isEmpty)
    }

    /// In the server's units. 250 emoji are 250 characters and 500 UTF-16
    /// units — at the limit; one more is over it.
    @Test func theLimitIsCountedTheWayTheServerCountsIt() {
        let model = ReportModel(postID: "p1", reporter: FakeReporter())
        model.choose(ReportModel.other)
        model.detail = String(repeating: "🐶", count: 250)
        #expect(model.detailRemaining == 0)
        #expect(model.canSubmit)
        model.detail += "🐶"
        #expect(model.detailRemaining < 0)
        #expect(!model.canSubmit)
    }

    @Test func aSentReportCannotBeSentAgain() async {
        let reporter = FakeReporter()
        let model = ReportModel(postID: "p1", reporter: reporter)
        model.choose("Spam")
        await model.submit()
        await model.submit()
        #expect(reporter.sent.count == 1)
    }

    // MARK: - What the answers mean

    /// A second report of the same post, or a retry of one that landed.
    /// Neither is a failure the person has to do anything about.
    @Test func alreadyReportedIsNotAFailure() async {
        let reporter = FakeReporter()
        reporter.error = ReportError.alreadyReported
        let model = ReportModel(postID: "p1", reporter: reporter)
        model.choose("Spam")
        await model.submit()
        #expect(model.state == .sent(alreadyReported: true))
    }

    @Test func anUnknownOutcomeOffersASafeRetry() async {
        let reporter = FakeReporter()
        reporter.error = ReportError.outcomeUnknown
        let model = ReportModel(postID: "p1", reporter: reporter)
        model.choose("Spam")

        await model.submit()
        #expect(model.state == .failed(ReportModel.message(for: .outcomeUnknown), canRetry: true))
        #expect(model.canSubmit)

        reporter.error = nil
        await model.submit()
        #expect(reporter.sent.count == 2)
        #expect(model.state == .sent(alreadyReported: false))
    }

    @Test func aBannedAccountIsNotOfferedARetry() async {
        let reporter = FakeReporter()
        reporter.error = ReportError.banned
        let model = ReportModel(postID: "p1", reporter: reporter)
        model.choose("Spam")
        await model.submit()
        #expect(model.state == .failed(ReportModel.message(for: .banned), canRetry: false))
        #expect(!model.canSubmit)
    }

    // MARK: - Mapping the callable's answers

    @Test func theServersAnswersMapToWhatTheyMean() {
        #expect(FirestoreContentReporter.map(functionsError(.alreadyExists, "You have already reported this content.")) == .alreadyReported)
        #expect(FirestoreContentReporter.map(functionsError(.permissionDenied, "Banned users cannot submit reports.")) == .banned)
        #expect(FirestoreContentReporter.map(functionsError(.notFound, "Reported comment not found.")) == .postGone)
        #expect(FirestoreContentReporter.map(functionsError(.invalidArgument, "Invalid targetType.")) == .rejected)
        #expect(FirestoreContentReporter.map(functionsError(.deadlineExceeded, "deadline-exceeded")) == .outcomeUnknown)
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(FirestoreContentReporter.map(offline) == .offline)
    }
}
