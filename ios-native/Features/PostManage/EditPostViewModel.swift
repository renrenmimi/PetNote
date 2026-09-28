import Foundation
import Observation
import OSLog

/// Editing a published post: text, tags and which pet it is about.
///
/// **Media is not editable, and that is the contract rather than a simplification.**
/// `updatePostCallable` takes text, tags and petId and nothing else, so an
/// editor that offered to change the photos would be offering something the
/// server will not do. The web client says so on the screen; so does this.
@MainActor
@Observable
final class EditPostViewModel {
    enum State: Equatable {
        case loading
        case ready
        case notFound
        /// Loading failed. Distinct from `notFound`: "we could not find out" and
        /// "it is not there" must not look the same.
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var pets: [Pet] = []
    var caption: String = "" {
        didSet {
            if caption.count > ComposeViewModel.maxCharacters {
                caption = String(caption.prefix(ComposeViewModel.maxCharacters))
            }
        }
    }
    private(set) var tags: [String] = []
    var tagInput: String = ""
    var selectedPetID: String?
    private(set) var isSaving = false
    private(set) var didSave = false
    var failureMessage: String?

    let postID: String
    private let uid: String
    private let feed: any FeedRepository
    private let writes: any PostWriteRepository
    private let petSource: any PetChoiceProviding
    private let onSaved: (@MainActor () -> Void)?
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "postmanage")

    private(set) var post: Post?

    init(
        postID: String,
        uid: String,
        feed: any FeedRepository,
        writes: any PostWriteRepository,
        pets petSource: any PetChoiceProviding,
        onSaved: (@MainActor () -> Void)? = nil
    ) {
        self.postID = postID
        self.uid = uid
        self.feed = feed
        self.writes = writes
        self.petSource = petSource
        self.onSaved = onSaved
    }

    func load() async {
        state = .loading
        do {
            async let loadedPost = feed.post(id: postID)
            async let loadedPets = petSource.pets(ownedBy: uid)
            guard let post = try await loadedPost else {
                state = .notFound
                return
            }
            self.post = post
            pets = (try? await loadedPets) ?? []
            caption = post.text
            tags = post.tags
            selectedPetID = post.petID
            state = .ready
        } catch {
            // Without this the screen sat on "Loading…" forever whenever the
            // read failed — the same defect the web client fixed on three
            // screens at once.
            log.error("could not load post for editing: \(error.localizedDescription, privacy: .public)")
            state = .failed(String(localized: "Could not load that post."))
        }
    }

    /// Whether the viewer is allowed to save. Checked here as well as on the
    /// server so somebody who reached this screen for a post that is not theirs
    /// is told, rather than being allowed to type and then refused.
    var canEdit: Bool { post?.authorID == uid }

    var canSave: Bool {
        guard case .ready = state, canEdit, !isSaving, !didSave else { return false }
        // The server rejects a post with no pet, so the button says no first.
        return selectedPetID != nil
    }

    func commitTagInput() {
        // Same filter as the composer, and the same reason to say so:
        // `updatePostCallable` refuses the whole edit over one unusable tag.
        if let refusal = ComposeViewModel.tagRefusal(in: tagInput) { failureMessage = refusal }
        let next = ComposeViewModel.normalized(tagInput, addingTo: tags)
        tagInput = ""
        tags = next
    }

    func removeTag(_ tag: String) { tags.removeAll { $0 == tag } }

    func save() async {
        guard canSave, let petID = selectedPetID else { return }
        isSaving = true
        failureMessage = nil
        defer { isSaving = false }
        do {
            try await writes.update(
                postID: postID,
                text: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                tags: tags,
                petID: petID
            )
            didSave = true
            onSaved?()
        } catch let error as PostWriteError {
            // Safe to press Save again whatever happened: `updatePostCallable`
            // sets fields on a known document, so repeating it reaches the same
            // state. That is why there is no "we don't know" branch here and
            // there is one in the composer.
            failureMessage = ComposeViewModel.describe(error)
        } catch {
            failureMessage = String(localized: "Could not save those changes.")
        }
    }
}
