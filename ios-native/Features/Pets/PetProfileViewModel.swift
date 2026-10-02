import Foundation
import Observation
import OSLog

/// A pet's profile: who it is, what it has posted, and where it has been.
///
/// Four reads that fail independently, because they fail for different
/// reasons and one of them failing must not take the page down. The web client
/// learned that the expensive way: check-ins go through a callable, so they
/// fail when the function is cold, unavailable, or — in a local environment —
/// not deployed at all, and with all four in one `Promise.all` a pet whose
/// name, photos, family and posts were every one of them readable rendered as
/// "Could not load this pet". Its source comment records the review where that
/// was seen.
@MainActor
@Observable
final class PetProfileViewModel {
    /// The pet itself. This one *is* the page.
    enum LoadState: Equatable {
        case loading
        case loaded(Pet)
        /// Read successfully, and there is no such pet. Distinct from
        /// `failed`: "this pet no longer exists" and "we could not reach
        /// PetNote" are different sentences and only one of them is worth a
        /// retry button.
        case missing
        case failed(String)
    }

    /// A part of the page that can be absent without the page being absent.
    enum SectionState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    enum DeleteState: Equatable {
        case idle
        case confirming
        case deleting
        /// The pet is gone. The screen it was on has to leave.
        case deleted
        case failed(String)
    }

    private(set) var state: LoadState = .loading
    private(set) var checkins: [PetCheckin] = []
    private(set) var checkinsState: SectionState = .loading
    private(set) var family: [PetFamilyMember] = []
    private(set) var familyState: SectionState = .loading
    private(set) var deleteState: DeleteState = .idle

    /// Who the viewer is to this pet.
    ///
    /// **Nil means "not determined", and that is not the same as "nobody".**
    /// It is nil until the family read succeeds, and it stays nil if that read
    /// fails — see `ownershipOrNothing` for why the difference is the whole
    /// point.
    private(set) var ownership: PetOwnership?

    /// What the screen is allowed to offer, when ownership could not be
    /// determined.
    ///
    /// A failed family read hands back an empty array, and an empty array run
    /// through `PetOwnership.resolve` is **not** harmless: `legacyOwnerFallback`
    /// fires on an empty family, so a viewer whose uid happens to sit in a
    /// stale `ownerId` would be handed `isPrimary` — and therefore a Delete
    /// button — on the strength of a read that failed. The same shape as the
    /// Firestore-rules trap this project has already been bitten by, where
    /// `!exists()` also means "deleted".
    ///
    /// So a failure degrades to offering nothing. The server would refuse
    /// anyway; the point is not to show a person a destructive control whose
    /// justification is a read that did not happen.
    var permissions: PetOwnership { ownership ?? .none }

    let petID: String
    /// The posts and their hearts: the feed's model over this pet's posts
    /// (`PetPostsFeed`). The page reads the posts through the properties
    /// below, and likes through this.
    let postList: FeedViewModel
    private let repository: any PetRepository
    private let viewerID: String?
    private let viewerIsAdmin: Bool
    private let postPageSize: Int
    private let checkinLimit: Int
    private let places: (any PlacesByID)?
    /// Where the check-ins are, for those at a place from Apple Maps.
    let lookups: PlaceLookups
    /// The check-ins' places, by id, once read; nil until then, or when the
    /// read failed.
    private(set) var checkinPlaces: [String: Place]?
    private let log = Logger(subsystem: "dev.local.petnote.native", category: "pet")

    init(
        petID: String,
        repository: any PetRepository,
        likes: any LikeRepository,
        postLookup: any FeedRepository,
        viewerID: String?,
        viewerIsAdmin: Bool = false,
        postPageSize: Int = 20,
        // The server caps this at 100 whatever is asked for
        // (`PET_CHECKIN_MAX_PAGE_SIZE`); asking for the cap is what the web
        // page does.
        checkinLimit: Int = 100,
        places: (any PlacesByID)? = nil,
        lookups: PlaceLookups = PlaceLookups()
    ) {
        self.petID = petID
        self.repository = repository
        self.postList = FeedViewModel(
            feed: PetPostsFeed(petID: petID, pets: repository, lookup: postLookup),
            likes: likes,
            accountID: viewerID,
            pageSize: postPageSize
        )
        self.viewerID = viewerID
        self.viewerIsAdmin = viewerIsAdmin
        self.postPageSize = postPageSize
        self.checkinLimit = checkinLimit
        self.places = places
        self.lookups = lookups
    }

    // MARK: - Loading

    /// Loads everything. Safe to call again; it is what the retry buttons and
    /// pull-to-refresh both go through.
    ///
    /// **`async let` rather than a task group.** The three are genuinely
    /// concurrent — each one's network wait overlaps
    /// the others', which is the whole reason they are not sequential — and
    /// they all mutate this object, so they run *on* the main actor and
    /// interleave only at their `await`s. A task group of `@MainActor`
    /// closures expresses the same thing and does not compile: the
    /// region-based isolation checker rejects the capture pattern outright.
    func load() async {
        async let petAndFamily: Void = loadPetAndFamily()
        async let posts: Void = postList.reload()
        async let checkins: Void = loadCheckins()
        _ = await (petAndFamily, posts, checkins)
    }

    /// The pet and its family, together.
    ///
    /// Together and not in parallel with each other, because the two answer
    /// one question between them: `PetOwnership.resolve` needs both, and the
    /// fallback it applies depends on the family read having actually
    /// happened. Keeping them in one function is what makes "the family read
    /// failed" a state this object can hold rather than an empty array
    /// somebody downstream mistakes for an empty family.
    private func loadPetAndFamily() async {
        do {
            guard let pet = try await repository.pet(id: petID) else {
                state = .missing
                // Nothing else on the page means anything now.
                familyState = .loaded
                ownership = .none
                return
            }
            state = .loaded(pet)
            do {
                let members = try await repository.family(petID: petID)
                family = members
                familyState = .loaded
                ownership = PetOwnership.resolve(
                    pet: pet, family: members, viewerID: viewerID, isAdmin: viewerIsAdmin
                )
            } catch {
                log.error("pet family read failed: \(error.localizedDescription, privacy: .public)")
                familyState = .failed(Self.wording(for: error, doing: .loadingFamily))
                ownership = nil
            }
        } catch {
            log.error("pet read failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(Self.wording(for: error, doing: .loadingPet))
        }
    }

    // MARK: - Posts

    /// This pet's posts, as far as they have been read.
    var posts: [Post] { postList.posts }

    /// The section as a whole. A page that fails after the first is not
    /// this: what is already on screen stays, with its own retry at the end
    /// (`morePostsFailed`), as in the feed.
    ///
    /// On a failure the list is left as it was rather than emptied: an empty
    /// list is how "this pet has not posted" looks, and a failure must never
    /// borrow that appearance.
    var postsState: SectionState {
        switch postList.state {
        case .idle, .loadingFirstPage: .loading
        case .loaded: .loaded
        case .failed: .failed(Self.generic(.loadingPosts))
        }
    }

    var hasMorePosts: Bool { postList.hasMore }
    var morePostsFailed: Bool { postList.pagingFailure != nil }

    func loadMorePostsIfNeeded(currentItem: Post?) async {
        await postList.loadMoreIfNeeded(currentItem: currentItem)
    }

    func retryMorePosts() async { await postList.retryPaging() }

    /// A tab, not the page. See the type's doc comment.
    private func loadCheckins() async {
        checkinsState = .loading
        do {
            checkins = try await repository.checkins(petID: petID, limit: checkinLimit)
            checkinsState = .loaded
        } catch {
            checkinsState = .failed(Self.wording(for: error, doing: .loadingCheckins))
            return
        }
        await loadCheckinPlaces()
    }

    /// The web's `batchGetLocations` for the check-ins (`PetProfile.tsx`):
    /// each place once, after the check-ins are on screen, and Apple asked
    /// about those from Apple Maps. A failed read leaves the check-ins shown
    /// without names, not called unknown.
    private func loadCheckinPlaces() async {
        guard let places else { return }
        var seen: Set<String> = []
        let ids = checkins.map(\.locationID).filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ids.isEmpty else {
            checkinPlaces = [:]
            return
        }
        do {
            let found = try await places.places(ids: ids)
            checkinPlaces = found
            await lookups.lookUp(Array(found.values))
        } catch {
            log.error("places of a pet's check-ins failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The name a check-in shows: its place's, Apple's for one from Apple
    /// Maps, or the web's "Unknown location" for a place that is gone. Nil
    /// while the places are not known.
    func placeName(for checkin: PetCheckin) -> String? {
        guard let checkinPlaces else { return nil }
        guard let place = checkinPlaces[checkin.locationID] else { return String(localized: "Unknown location") }
        if place.applePlaceID != nil { return lookups.name(of: place) }
        return place.name.isEmpty ? String(localized: "Unknown location") : place.name
    }

    func retryPosts() async { await postList.reload() }
    func retryCheckins() async { await loadCheckins() }
    func retryPetAndFamily() async {
        state = .loading
        familyState = .loading
        await loadPetAndFamily()
    }

    // MARK: - Deleting

    func askToDelete() {
        guard permissions.canDelete else { return }
        deleteState = .confirming
    }

    func cancelDelete() {
        deleteState = .idle
    }

    /// What deleting this pet actually costs, in the words the confirmation
    /// has to use.
    ///
    /// Taken from `onPetDeleted` (functions/src/cleanup.ts) rather than
    /// guessed, because the surprising half is what *survives*: the posts are
    /// not deleted. The trigger strips `petId`, `petName` and `petAvatarUrl`
    /// from every post tagged with this pet — with `FieldValue.delete()`
    /// rather than empty strings, since an empty string still indexes — so the
    /// photos and text stay in the feed and simply stop being about anybody.
    /// Every follower's `followingPets` entry is removed, and the family,
    /// followers and invitation subcollections go with the cascade.
    ///
    /// A person told only "this cannot be undone" would reasonably expect
    /// their photos to go too.
    static let deletionConsequences = String(localized: """
        The pet's profile, its list of owners and its followers are removed. \
        Posts are not deleted — they stay in the feed, but they stop \
        being about this pet.
        """)

    func confirmDelete() async {
        guard permissions.canDelete else {
            deleteState = .failed(Self.wording(for: PetError.notAnOwner, doing: .deleting))
            return
        }
        deleteState = .deleting
        do {
            let outcome = try await repository.delete(petID: petID)
            if outcome.resumed {
                // The pet document was already gone and this call finished a
                // cleanup that had been left half-done. Still a success from
                // here, and worth a line in the log because the record it
                // cleared exists to make an unfinished deletion visible.
                log.info("deletePetCallable resumed an unfinished cascade")
            }
            deleteState = .deleted
        } catch {
            deleteState = .failed(Self.wording(for: error, doing: .deleting))
        }
    }

    // MARK: - Words

    enum Doing: Sendable {
        case loadingPet
        case loadingFamily
        case loadingPosts
        case loadingCheckins
        case saving
        case deleting
    }

    /// One place that turns a `PetError` into a sentence.
    ///
    /// Separate from the errors themselves so the same failure can read
    /// differently depending on what was being attempted, and static so a test
    /// can check the wording without driving a whole screen.
    static func wording(for error: Error, doing: Doing) -> String {
        guard let petError = error as? PetError else {
            return generic(doing)
        }
        switch petError {
        case .notSignedIn:
            return String(localized: "Sign in again to do that.")
        case .banned:
            return String(localized: "This account cannot make changes.")
        case .accountDeleted:
            return String(localized: "This account has been deleted.")
        case .petLimitReached:
            return String(localized: "You already have \(PetValidation.maxPetsPerOwner) pets.")
        case .petNotFound:
            return String(localized: "This pet no longer exists.")
        case .notAnOwner:
            // Deliberately not "you are not the owner". Every family member is
            // an owner; this says the caller is not one of them.
            return String(localized: "You are not one of this pet's owners.")
        case .petHasOtherOwners:
            // The server's way out is to leave instead, which hands the pet on
            // rather than taking it away — and leaving is batch 3, so this
            // says what can be done today rather than naming a control that is
            // not there.
            return String(localized: """
                This pet has other owners, so it cannot be deleted. \
                Ask the other owners to leave first.
                """)
        case .rateLimited:
            return String(localized: "Too many requests just now. Wait a moment and try again.")
        case .rejected(let message):
            return message
        case .outcomeUnknown:
            return doing == .deleting
                ? String(localized: "We could not tell whether that finished. Reload to check.")
                : generic(doing)

        case .transport(let detail):
            if detail == FirestorePetRepository.Transport.unavailable {
                return String(localized: "This build cannot reach PetNote's server.")
            }
            if detail == FirestorePetRepository.Transport.offline {
                return String(localized: "No connection. Check your network and try again.")
            }
            return generic(doing)
        }
    }

    private static func generic(_ doing: Doing) -> String {
        switch doing {
        case .loadingPet: return String(localized: "Could not load this pet.")
        case .loadingFamily: return String(localized: "Could not load this pet's owners.")
        case .loadingPosts: return String(localized: "Could not load this pet's posts.")
        case .loadingCheckins: return String(localized: "Could not load check-ins.")
        case .saving: return String(localized: "Could not save this pet.")
        case .deleting: return String(localized: "Could not delete this pet.")
        }
    }
}
