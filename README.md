# PetNote

PetNote is a pet-centered social app built with React, TypeScript, Firebase, and Cloudinary. Users can share posts, manage pet profiles, discover pet-friendly places, organize meetups, follow pets, and receive real-time notifications.

## What the app does

- Social feed with text, image, and video posts
- Comments, replies, likes, bookmarks, and hashtag-based discovery
- Pet profiles with birthdays, bios, pet family members, and invitation-based family access
- Pet follow system and following feed
- Pet-friendly places with ratings, tags, photos, and check-ins
- Meetups with eligibility rules, participant management, and private-address support
- Real-time notifications for likes, comments, replies, pet follows, meetup joins, meetup cancellations, and admin warnings
- Admin tools for reports, moderation, warnings, and bans
- Account settings, blocked users, password reset, and account deletion

## Current architecture

PetNote uses a callable-first backend model for business writes.

- Firestore Rules
  - Mostly control read access
  - Allow only a very small set of simple owner-only writes
- Callable Functions
  - Handle business writes that need identity checks, validation, or transactions
  - Examples: create post, create comment, create pet, join meetup, submit review, check in, delete account
- Trigger Functions
  - Maintain counters and denormalized snapshots
  - Fan out notifications
  - Clean up related data after deletes

This means the client no longer directly writes most sensitive business data.

## Tech stack

| Layer | Technology |
| --- | --- |
| Frontend | React 19 + TypeScript 5.9 |
| Build tool | Vite 7 |
| Styling | Tailwind CSS 4 |
| Routing | React Router 7 |
| Backend | Firebase Auth + Firestore + Cloud Functions |
| Security | Firestore Rules + callable-first writes |
| Media | Cloudinary signed uploads |
| Geocoding | Geoapify |
| Images | heic2any for HEIC conversion, DiceBear for default avatars |
| Deployment | Vercel for frontend, Firebase for rules and functions |

## Core product areas

### Accounts and identity

- Email/password sign-up and login
- Google sign-in
- Email verification
- Password reset
- Random username generation for new accounts
- AuthProvider-based global auth/profile state

### Posts and feed

- Create posts with text plus image/video media
- Attach a post to a pet profile
- Like posts
- Comment and reply
- Bookmark posts
- Global feed and following feed
- Post editing and deletion

### Pets

- Create, edit, and delete pets
- Species, breed, birthday, gender, bio, and avatar
- Invitation-based pet family membership
- Primary and member family roles
- Pet followers and follower counts

### Places

- Create a place
- Add place photos
- Submit reviews with rating, tags, and photos
- Check in with media
- Browse place details and recent check-ins
- Private user location is used for nearby ranking without exposing exact coordinates publicly

### Meetups

- Create, edit, cancel, and join meetups
- Private or public meetup address handling
- Capacity and eligibility checks
- Post-meetup review flow
- Status changes such as upcoming, completed, and cancelled

### Notifications and moderation

- Real-time notifications
- Server-generated notification fan-out
- Admin warning notifications
- Report submission
- Feedback submission
- Admin moderation dashboard

## Cloudinary upload model

PetNote now uses signed uploads.

- Frontend uploads do not use an unsigned preset anymore
- The browser first requests a short-lived upload signature from Firebase Functions
- The browser then uploads directly to Cloudinary with that signature
- Separate signed presets are used for images and videos:
  - `petnote_image_signed`
  - `petnote_video_signed`

## Local setup

### Prerequisites

- Node.js 22 recommended
- npm
- A Firebase project with Auth, Firestore, and Cloud Functions enabled
- A Cloudinary account with these signed upload presets:
  - `petnote_image_signed`
  - `petnote_video_signed`
- Optional Geoapify API key

### Install dependencies

```bash
npm install
npm --prefix functions install
```

### Frontend environment variables

Create `.env.local` in the project root:

```env
VITE_FIREBASE_API_KEY=your_firebase_api_key
VITE_FIREBASE_AUTH_DOMAIN=your_project.firebaseapp.com
VITE_FIREBASE_PROJECT_ID=your_project_id
VITE_FIREBASE_STORAGE_BUCKET=your_project.firebasestorage.app
VITE_FIREBASE_MESSAGING_SENDER_ID=your_sender_id
VITE_FIREBASE_APP_ID=your_app_id
VITE_GEOAPIFY_KEY=your_geoapify_api_key
```

Cloudinary upload no longer needs any `VITE_CLOUDINARY_*` frontend variable because uploads now use Firebase-signed parameters.

Restrict the Geoapify key by HTTP referrer before production rollout.

- Production: your production Vercel or custom domain
- Preview: your Vercel preview domain pattern
- Local development: `http://localhost:5173/*`

The app currently serves root-relative Open Graph image URLs from `public/og-image.png`, so social cards resolve correctly on production, preview, and local builds without a hardcoded deployment host.

### Firebase Functions secrets

Set Cloudinary secrets for signed upload generation:

```bash
firebase functions:secrets:set CLOUDINARY_CLOUD_NAME
firebase functions:secrets:set CLOUDINARY_API_KEY
firebase functions:secrets:set CLOUDINARY_API_SECRET
```

### Start the frontend

```bash
npm run dev
```

## Build and deployment

### Verify locally

```bash
npm run build
npm run lint
npm --prefix functions run build
```

### Deploy Firebase rules and functions

```bash
firebase deploy --only firestore:rules,functions
```

### Deploy frontend

The repo is configured for Vercel. You can either:

- use GitHub-connected automatic deployments, or
- deploy manually with:

```bash
vercel --prod
```

## Firestore layout

This is the high-level structure the app uses today:

```text
users/{userId}
  bookmarks/{postId}
  blockedUsers/{blockedUserId}
  followingPets/{petId}
  settings/preferences
  settings/location

posts/{postId}
  likes/{userId}
  comments/{commentId}

pets/{petId}
  family/{userId}
  followers/{userId}
  invitations/{invitationCode}

meetups/{meetupId}
  participants/{userId}
  private/address

locations/{locationId}
  reviews/{reviewId}
  checkins/{checkinId}

notifications/{notificationId}
hashtags/{tagName}
reports/{reportId}
feedback/{feedbackId}
```

## Project structure

```text
src/
  components/   reusable UI building blocks
  contexts/     auth, theme, and toast providers
  hooks/        feed, notifications, auth, and UI hooks
  pages/        route-level pages
  services/     Firebase and third-party integrations
  types/        local type declarations
  utils/        formatting, upload, image, and validation helpers
functions/
  src/          Cloud Functions source
firestore.rules Firestore security rules
SECURITY_MODEL.md current security model and ownership boundaries
TECH_REPORT.md technical overview of the current implementation
QA_TESTING.md manual QA checklist
```

## Notes for maintainers

- Public `users` documents should not contain exact location coordinates
- Cloudinary uploads should remain signed
- Most business writes should stay in callable functions, not in the client
- Trigger functions are responsible for counters, notification fan-out, and cleanup

## Admin setup

To grant admin access, update the user document in Firestore:

- collection: `users`
- field: `role`
- value: `"admin"`

Admin users can access `/admin`.
