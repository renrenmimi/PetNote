import Foundation

/// Every Cloud Function name the client calls, in one place.
///
/// **Why a registry and not string literals at the call sites.** The names are
/// a contract with a backend this client does not own and must not change. A
/// typo in a literal is a runtime failure on a path that may only be reached
/// by one user action; here it is one declaration that either matches the
/// deployed function or does not, and `CallableNameTests` checks the list
/// against `functions/src` so a rename on either side shows up as a test
/// failure rather than as a report from someone whose upload silently stopped
/// working.
///
/// Three separate holders had grown — `Callables`, `PetCallables`,
/// `UserCallable` — one per line of work, because this file did not exist yet.
/// That is a coordination failure rather than anyone's mistake, and merging
/// them is the fix.
///
/// **Deliberately absent.** `requestPasswordResetCodeCallable` and
/// `confirmPasswordResetCodeCallable` are the numeric-code password reset,
/// which is off in production: the secrets it needs do not exist there, and
/// calling it would send people who already cannot sign in into a flow that
/// cannot finish. The web client keeps using Firebase's own reset link and so
/// does this one.
enum Callables {
    // Account and profile
    static let ensureUserProfile = "ensureUserProfileCallable"
    static let updateUserProfile = "updateUserProfileCallable"
    static let checkDisplayNameAvailability = "checkDisplayNameAvailabilityCallable"
    static let deleteUserAccount = "deleteUserAccount"

    // Pets
    static let createPet = "createPetCallable"
    static let updatePet = "updatePetCallable"
    static let deletePet = "deletePetCallable"
    static let getPetCheckins = "getPetCheckinsCallable"
    static let followPet = "followPetCallable"
    static let unfollowPet = "unfollowPetCallable"
    static let recomputePetPostCount = "recomputePetPostCountCallable"

    // Posts and comments
    static let createPost = "createPostCallable"
    static let updatePost = "updatePostCallable"
    static let deletePost = "deletePostCallable"
    static let setPinnedPost = "setPinnedPostCallable"
    static let getPublishStatus = "getPublishStatusCallable"
    static let createComment = "createCommentCallable"
    static let deleteComment = "deleteCommentCallable"
    static let recomputePostInteractionCounts = "recomputePostInteractionCountsCallable"

    // Media
    static let cloudinaryUploadSignature = "getCloudinaryUploadSignature"
    static let deleteCloudinaryAssets = "deleteCloudinaryAssetsCallable"

    // Family / shared ownership
    static let createInvitation = "createInvitationCallable"
    static let validateInvitation = "validateInvitationCallable"
    static let redeemInvitation = "redeemInvitationCallable"
    static let revokeInvitation = "revokeInvitationCallable"
    static let getActiveInvitation = "getActiveInvitationCallable"
    static let removeFamilyMember = "removeFamilyMemberCallable"
    static let transferPetPrimary = "transferPetPrimaryCallable"

    // Places and check-ins
    static let addPlace = "addPlaceCallable"
    static let addLocationPhotos = "addLocationPhotosCallable"
    static let checkIn = "checkInCallable"
    static let submitReview = "submitReviewCallable"
    static let recomputeLocationReviewAggregates = "recomputeLocationReviewAggregatesCallable"
    static let reverseGeocode = "reverseGeocodeCallable"
    static let searchAddresses = "searchAddressesCallable"

    // Meetups
    static let createMeetup = "createMeetupCallable"
    static let updateMeetup = "updateMeetupCallable"
    static let cancelMeetupCallable = "cancelMeetupCallable"
    static let joinMeetup = "joinMeetupCallable"
    static let checkMeetupStatus = "checkMeetupStatusCallable"

    // Moderation, notifications, feedback
    static let reportContent = "reportContentCallable"
    static let markAllNotificationsAsRead = "markAllNotificationsAsReadCallable"
    static let submitFeedback = "submitFeedbackCallable"

    /// Every name above, for the test that checks them against the backend.
    static let all: [String] = [
        ensureUserProfile, updateUserProfile, checkDisplayNameAvailability, deleteUserAccount,
        createPet, updatePet, deletePet, getPetCheckins, followPet, unfollowPet,
        recomputePetPostCount,
        createPost, updatePost, deletePost, setPinnedPost, getPublishStatus,
        createComment, deleteComment, recomputePostInteractionCounts,
        cloudinaryUploadSignature, deleteCloudinaryAssets,
        createInvitation, validateInvitation, redeemInvitation, revokeInvitation,
        getActiveInvitation, removeFamilyMember, transferPetPrimary,
        addPlace, addLocationPhotos, checkIn, submitReview,
        recomputeLocationReviewAggregates, reverseGeocode, searchAddresses,
        createMeetup, updateMeetup, cancelMeetupCallable, joinMeetup, checkMeetupStatus,
        reportContent, markAllNotificationsAsRead, submitFeedback,
    ]
}
