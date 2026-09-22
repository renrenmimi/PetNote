import Foundation
import Testing

@testable import PetNote

// MARK: - Doubles

/// A `PetRepository` whose every answer is set by the test.
///
/// `@unchecked Sendable` and a class for the same reason as `FakeFeed`: the
/// protocol is `Sendable` and the tests are `@MainActor`, and the fields are
/// only ever touched from the test's own actor.
final class FakePetRepository: PetRepository, @unchecked Sendable {
    var pet: Pet?
    var petError: Error?
    var family: [PetFamilyMember] = []
    var familyError: Error?
    /// One entry per page, in order.
    var postPages: [[Post]] = []
    var postsError: Error?
    var checkins: [PetCheckin] = []
    var checkinsError: Error?
    var createResult: Result<String, Error> = .success("new-pet")
    var updateError: Error?
    var deleteResult: Result<PetDeletion, Error> = .success(PetDeletion(resumed: false))

    private(set) var petReads = 0
    private(set) var familyReads = 0
    private(set) var postCursors: [PageCursor?] = []
    private(set) var checkinReads = 0
    private(set) var created: [PetDraft] = []
    private(set) var updated: [(petID: String, changes: PetChanges)] = []
    private(set) var deleted: [String] = []

    private var issued: [PageCursor] = []

    func pet(id: String) async throws -> Pet? {
        petReads += 1
        if let petError { throw petError }
        return pet
    }

    func family(petID: String) async throws -> [PetFamilyMember] {
        familyReads += 1
        if let familyError { throw familyError }
        return family
    }

    func posts(petID: String, after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
        postCursors.append(cursor)
        if let postsError { throw postsError }
        // A first-page read retires every cursor, exactly as
        // `FirestorePetRepository` does with `resumePoints`. Without this the
        // tokens issued before a reload shift the position of every token
        // issued after one, and the fake stops standing for the thing it
        // replaces.
        if cursor == nil { issued.removeAll() }
        let index: Int
        if let cursor, let position = issued.firstIndex(of: cursor) {
            index = position + 1
        } else {
            index = 0
        }
        guard index < postPages.count else { return .empty }
        var next: PageCursor?
        if index + 1 < postPages.count {
            let token = PageCursor()
            issued.append(token)
            next = token
        }
        return Page(items: postPages[index], next: next)
    }

    func checkins(petID: String, limit: Int) async throws -> [PetCheckin] {
        checkinReads += 1
        if let checkinsError { throw checkinsError }
        return checkins
    }

    func create(_ draft: PetDraft) async throws -> String {
        created.append(draft)
        return try createResult.get()
    }

    func update(petID: String, changes: PetChanges) async throws {
        updated.append((petID, changes))
        if let updateError { throw updateError }
    }

    func delete(petID: String) async throws -> PetDeletion {
        deleted.append(petID)
        return try deleteResult.get()
    }
}

/// A `MediaUploading` whose answer is set by the test.
///
/// Conforms to the shared protocol rather than a pet-specific one, so what the
/// editor is exercised against is the same shape the real
/// `CloudinaryUploadClient` presents.
final class FakePetAvatarUploader: MediaUploading, @unchecked Sendable {
    static let landedURL = "https://res.cloudinary.com/demo/image/upload/new.jpg"

    var result: Result<UploadedAsset, Error> = .success(
        UploadedAsset(
            url: URL(string: landedURL) ?? URL(fileURLWithPath: "/"),
            publicID: "new",
            resourceType: .image,
            thumbnailURL: nil
        )
    )
    private(set) var uploads: [UploadItem] = []

    func upload(_ item: UploadItem) async throws -> UploadedAsset {
        uploads.append(item)
        return try result.get()
    }
}

// MARK: - Sample data

enum PetFixture {
    /// A 1×1 PNG.
    ///
    /// Real bytes rather than `Data([0x1])`, because the editor now runs the
    /// picked photo through `UploadPreparation`, which decodes it with ImageIO
    /// — so arbitrary bytes are refused before the uploader is ever reached,
    /// and a test using them would be testing the refusal.
    ///
    /// PNG and one pixel, so `prepareImage` takes the passthrough branch and
    /// the bytes that reach the uploader are the bytes handed in.
    static let tinyPNG = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    ) ?? Data()

    static func pet(
        id: String = "pet-1",
        ownerID: String = "alice",
        primaryOwnerID: String? = nil,
        name: String = "Mochi",
        species: PetSpecies = .dog,
        breed: String = "Shiba",
        gender: PetGender = .female,
        bio: String = "TEST CONTENT bio",
        avatarURL: URL? = URL(string: "https://res.cloudinary.com/demo/image/upload/old.jpg"),
        birthday: Date? = nil,
        birthdayMonth: Int? = nil,
        birthdayDay: Int? = nil,
        followerCount: Int = 3,
        postCount: Int = 2
    ) -> Pet {
        Pet(
            id: id,
            ownerID: ownerID,
            primaryOwnerID: primaryOwnerID ?? ownerID,
            name: name,
            species: species,
            breed: breed,
            gender: gender,
            bio: bio,
            avatarURL: avatarURL,
            birthday: birthday,
            birthdayMonth: birthdayMonth,
            birthdayDay: birthdayDay,
            followerCount: followerCount,
            postCount: postCount,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func member(
        _ id: String,
        role: PetFamilyRole = .member,
        relationship: PetFamilyRelationship = .caretaker,
        custom: String? = nil,
        joinedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> PetFamilyMember {
        PetFamilyMember(
            id: id, userName: id.capitalized, userAvatarURL: nil,
            relationship: relationship, customRelationship: custom,
            role: role, joinedAt: joinedAt
        )
    }

    static func post(_ id: String) -> Post {
        Post(
            id: id, authorID: "alice", authorName: "Alice", authorAvatarURL: nil,
            text: "TEST CONTENT \(id)", media: [], petID: "pet-1", petName: "Mochi",
            petAvatarURL: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            likeCount: 0, commentCount: 0, tags: []
        )
    }

    static func checkin(_ id: String) -> PetCheckin {
        PetCheckin(
            id: id, locationID: "loc-1", petID: "pet-1", petName: "Mochi",
            photoURL: nil, caption: "TEST CONTENT \(id)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// A failure shaped like one Firestore produces, so anything that sorts
    /// errors by domain sorts this the same way it would sort a real one.
    static var readFailure: Error {
        NSError(
            domain: "FIRFirestoreErrorDomain", code: 13,
            userInfo: [NSLocalizedDescriptionKey: "injected pet read failure"]
        )
    }
}

// MARK: - The doubles are checked, not trusted

/// A test double that quietly succeeds is how four assertions in this project
/// once stayed green against a query the server was refusing. These check that
/// the two doubles above actually carry a failure through, so every test that
/// sets `…Error` and expects a failure is resting on something that was
/// measured rather than assumed.
@MainActor
struct PetFixturesTests {
    @Test func theRepositoryDoubleActuallyThrowsWhenItIsToldTo() async {
        let repository = FakePetRepository()
        repository.petError = PetFixture.readFailure

        var threw = false
        do {
            _ = try await repository.pet(id: "pet-1")
        } catch {
            threw = true
        }
        #expect(threw, "the fake swallowed the error it was given")
    }

    @Test func theUploaderDoubleActuallyThrowsWhenItIsToldTo() async {
        let uploader = FakePetAvatarUploader()
        uploader.result = .failure(UploadError.offline)

        var threw = false
        do {
            _ = try await uploader.upload(
                UploadItem(
                    data: PetFixture.tinyPNG, filename: "a.png",
                    mimeType: "image/png", resourceType: .image
                )
            )
        } catch {
            threw = true
        }
        #expect(threw, "the fake uploader swallowed the error it was given")
    }

    /// The fixture has to be a picture, or every photo test measures
    /// `UploadPreparation` refusing to decode it.
    @Test func theTinyPngFixtureIsAnImageImageIoCanRead() throws {
        #expect(!PetFixture.tinyPNG.isEmpty, "the base64 fixture did not decode")
        let prepared = try UploadPreparation.prepareImage(PetFixture.tinyPNG, filename: "a.png")
        #expect(prepared.mimeType == "image/png")
        #expect(!prepared.wasTranscoded, "a one-pixel PNG should go through untouched")
    }

    /// The paging fake has to page the way the real repository does, or every
    /// paging test is about the fake.
    @Test func theRepositoryDoubleHandsOutOnePageAtATime() async throws {
        let repository = FakePetRepository()
        repository.postPages = [[PetFixture.post("a")], [PetFixture.post("b")]]

        let first = try await repository.posts(petID: "pet-1", after: nil, limit: 1)
        #expect(first.items.map(\.id) == ["a"])
        let cursor = try #require(first.next)
        let second = try await repository.posts(petID: "pet-1", after: cursor, limit: 1)
        #expect(second.items.map(\.id) == ["b"])
        #expect(second.next == nil, "the last page must not offer another cursor")
    }
}
