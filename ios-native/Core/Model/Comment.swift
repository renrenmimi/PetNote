import Foundation

struct Comment: Sendable, Equatable, Identifiable {
    let id: String
    let authorID: String
    let authorName: String
    let authorAvatarURL: URL?
    let text: String
    let createdAt: Date
    let replyTo: ReplyTarget?

    /// A comment the person has just sent, which the server has not confirmed
    /// yet. It renders in place immediately and is replaced by the real one, so
    /// sending never looks like nothing happened.
    let isPending: Bool

    struct ReplyTarget: Sendable, Equatable {
        let commentID: String
        let authorName: String
    }
}
