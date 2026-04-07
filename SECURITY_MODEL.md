# PetNote Security Model

This document describes the current security ownership model in plain language.

## 1. Core split

PetNote uses three layers with different responsibilities:

### Firestore Rules

Rules mainly answer:

- who can read a path
- which very small set of simple owner-only writes are still allowed

Rules are **not** the main place for complex business logic anymore.

### Callable Functions

Callable Functions are the main write entry points for business actions that need:

- authentication checks
- ban checks
- field validation
- transactions
- server-derived identity

### Trigger Functions

Trigger Functions are responsible for:

- counters
- denormalized snapshot sync
- notification fan-out
- cleanup after deletes
- recomputing derived data

## 2. Design rules

These are the non-negotiable rules the project now follows:

1. Clients do not write aggregation fields directly.
2. Clients do not choose public identity snapshot fields for sensitive business writes.
3. Business writes that need identity or validation should go through callables.
4. Derived fields should have one clear writer.
5. Private data must not live in publicly readable documents.
6. Old direct-write paths should be closed once a callable replaces them.

## 3. Collection classes

### Public profile data

Examples:

- `users`
- `pets`
- `posts`
- `locations`
- `meetups`
- `hashtags`

These documents may be publicly readable, but their writable fields are tightly limited.

Important example:

- public `users.location` stores only coarse location such as `city` and `state`
- exact user coordinates live in the owner-only path `users/{userId}/settings/location`

### Private owner data

Examples:

- `users/{userId}/bookmarks`
- `users/{userId}/blockedUsers`
- `users/{userId}/settings/preferences`
- `users/{userId}/settings/location`

These paths are owner-only.

### Fact documents

Examples:

- `posts/{postId}/comments/{commentId}`
- `posts/{postId}/likes/{userId}`
- `users/{userId}/followingPets/{petId}`
- `pets/{petId}/followers/{userId}`
- `pets/{petId}/family/{userId}`
- `locations/{locationId}/reviews/{reviewId}`
- `locations/{locationId}/checkins/{checkinId}`
- `meetups/{meetupId}/participants/{userId}`

These represent actual user actions. Most are now created by callables or by tightly controlled server paths.

### Workflow and derived documents

Examples:

- `notifications`
- `reports`
- `feedback`
- invitation state
- counter fields
- rating aggregates

These are server-owned.

## 4. Current callable-owned business writes

The following write paths are now handled by callable functions:

- create, update, delete post
- create, delete comment
- follow, unfollow pet
- submit review
- submit check-in
- create, update, cancel meetup
- join meetup
- create invitation
- redeem invitation
- remove family member
- create, update, delete pet
- create place
- add place photos
- report content
- submit feedback
- delete account
- admin warning notification
- generate Cloudinary upload signatures

## 5. Current trigger-owned responsibilities

Trigger Functions currently handle:

- post like counts
- post comment counts
- meetup participant counts
- pet follower counts
- user following pet counts
- hashtag counts
- location rating / tag / photo aggregates
- location check-in aggregates
- notification generation for likes, comments, replies, pet follows, meetup joins, meetup cancellations
- user name / avatar sync into denormalized copies
- cleanup of mirror docs and references after deletes

## 6. Signed upload model

Cloudinary uploads now use signed upload instead of the old unsigned preset flow.

Current flow:

1. Frontend requests a short-lived upload signature from Firebase Functions.
2. The callable checks that the caller is logged in and not banned.
3. The callable returns Cloudinary upload parameters for either:
   - `petnote_image_signed`
   - `petnote_video_signed`
4. The browser uploads directly to Cloudinary using that signature.

This means the browser no longer uploads just by knowing an unsigned preset name.

## 7. Remaining simple client writes

A very small number of client writes still exist and are intentionally simple:

- updating basic profile fields on the current user
- managing bookmarks
- managing blocked users
- updating notification read state
- updating user settings/preferences

These are kept because they are simple owner-only writes and do not need complex transactions.

## 8. Data privacy rules

The current privacy boundaries are:

- notifications: only recipient, sender, or admin can read
- private meetup address: organizer, participant, or admin can read
- owner-only settings and saved location stay under user settings paths
- public user profile no longer stores exact coordinates

## 9. Why this model exists

The project originally had many issues caused by splitting write responsibility across:

- frontend writes
- Firestore Rules
- partial trigger cleanup

The current model reduces that by making the backend the authority for anything that needs:

- identity
- validation
- aggregation
- fan-out
- cleanup
- transactions

## 10. Maintenance rule for future changes

Before adding any new feature, answer these questions:

1. Is this a public document, private owner document, fact document, or derived/workflow document?
2. Does the client really need to write it directly?
3. If identity matters, can the server derive it instead of trusting the client?
4. If counters or status change, who is the single writer?
5. If deletion happens, which backend path owns cleanup?

If those answers are not clear, the feature is not ready to implement.
