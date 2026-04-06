## PetNote Security Model

### Core split

- `firestore.rules`: read access control plus a very small set of owner-only writes
- `Callable Functions`: all business writes and all writes that need identity, validation, or transactions
- `Trigger Functions`: aggregation, denormalized snapshot sync, and cleanup

### Non-negotiable rules

- Clients never write aggregation fields.
- Clients never choose identity snapshot fields for public business data.
- All identity-bearing business writes are created server-side from `auth.uid` plus the current profile.
- All uniqueness constraints use deterministic document IDs.
- Each aggregation field has exactly one writer.

### Collection classes

#### Profile

- `users`
- `pets`

Owner-only writes with field whitelists. Sensitive fields and counters are server-maintained.

#### Facts

- `posts/{postId}/likes/{userId}`
- `posts/{postId}/comments/{commentId}`
- `users/{userId}/followingPets/{petId}`
- `pets/{petId}/followers/{userId}`
- `meetups/{meetupId}/participants/{userId}`
- `locations/{locationId}/reviews/{reviewId}`
- `locations/{locationId}/checkins/{checkinId}`

Created by callable functions or tightly constrained owner-only writes. Deterministic IDs are preferred.

#### Derived

- `posts.likeCount`
- `posts.commentCount`
- `pets.followerCount`
- `users.followingPetsCount`
- `meetups.participantCount`
- `locations.averageRating`
- `locations.totalRatings`
- `locations.totalPhotos`
- `locations.totalCheckins`
- `locations.verifiedByCheckins`
- `hashtags.postCount`

Only backend code writes these fields.

#### Workflow

- `notifications`
- `reports`
- `feedback`
- `invitations`

Workflow state is created by callable functions or trusted triggers. Clients do not create workflow docs directly.

### Callable-owned write paths

- `createPost`
- `updatePost`
- `createComment`
- `followPet`
- `unfollowPet`
- `submitReview`
- `checkIn`
- `joinMeetup`
- `reportContent`
- `submitFeedback`
- `sendWarning`
- `deleteUserAccount`

### Trigger-owned responsibilities

- maintain counts
- sync denormalized name/avatar snapshots
- fan-out notifications
- cleanup mirror docs and references
