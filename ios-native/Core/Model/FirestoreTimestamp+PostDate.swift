import FirebaseFirestore
import Foundation

/// Lets `PostDecoder` read Firestore's `Timestamp` without the model layer
/// importing Firebase.
///
/// Not `@retroactive`: that attribute is for conforming someone else's type to
/// someone else's protocol, and `PostDate` is ours.
extension FirebaseFirestore.Timestamp: PostDate {
    public var postDate: Date { dateValue() }
}
