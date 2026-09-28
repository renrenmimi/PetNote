import FirebaseFirestore
import Foundation

/// The pets a person may post about.
///
/// **TEMPORARY, and narrower than it looks.** The model is the shared `Pet`
/// (Features/Pets/PetDomain.swift) rather than a second copy of it — a
/// duplicated domain type is exactly what the ownership contract forbids.
/// What is local is the *query*: `PetRepository` can fetch a pet by id but has
/// no "the pets this person is in the family of", which is what a composer
/// needs. When that lands on `PetRepository`, this protocol becomes a one-line
/// adapter or goes away, and nothing above it changes.
protocol PetChoiceProviding: Sendable {
    func pets(ownedBy uid: String) async throws -> [Pet]
}

/// Reads the pets a person can post about.
///
/// Mirrors `getUserPets` (src/services/pets.ts): one collection-group read of
/// `family` for the memberships, then chunked `documentId() in` reads for the
/// pet documents. The shape matters — the version before it issued one
/// `getDoc` per membership, which is the N+1 the engineering spec forbids.
actor FirestorePetChoiceSource: PetChoiceProviding {
    private let db: Firestore

    /// The web client's chunk size for a `documentId() in` read.
    private static let batchSize = 10

    init(db: Firestore = .firestore()) {
        self.db = db
    }

    func pets(ownedBy uid: String) async throws -> [Pet] {
        let memberships = try await db.collectionGroup("family")
            .whereField("userId", isEqualTo: uid)
            .getDocuments()

        // The pet id is the grandparent of a family document:
        // pets/{petId}/family/{userId}.
        var petIDs: [String] = []
        var seen: Set<String> = []
        for document in memberships.documents {
            guard let petID = document.reference.parent.parent?.documentID,
                  !seen.contains(petID) else { continue }
            seen.insert(petID)
            petIDs.append(petID)
        }
        guard !petIDs.isEmpty else { return [] }

        var byID: [String: Pet] = [:]
        for start in stride(from: 0, to: petIDs.count, by: Self.batchSize) {
            let chunk = Array(petIDs[start..<min(start + Self.batchSize, petIDs.count)])
            let snapshot = try await db.collection("pets")
                .whereField(FieldPath.documentID(), in: chunk)
                .getDocuments()
            for document in snapshot.documents {
                // Decoded through the shared `PetDecoder`, so a pet looks the
                // same here as it does on its own profile — including the
                // normalisation a nameless document gets, which is to be
                // dropped rather than shown untitled.
                if let pet = PetDecoder.pet(id: document.documentID, from: document.data()) {
                    byID[document.documentID] = pet
                }
            }
        }
        // Membership order, so the list does not reshuffle between reads.
        return petIDs.compactMap { byID[$0] }
    }
}
