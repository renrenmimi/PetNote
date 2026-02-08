# 🐾 PetNote

A social media platform for pet lovers to share photos, discover pet-friendly places, organize meetups, and connect with other pet owners. Built with React, TypeScript, and Firebase.

## ✨ Features

- **Social Feed** — Share pet photos & videos with captions, hashtags, likes, comments, and bookmarks
- **Pet Profiles** — Create dedicated profiles for your pets with breed, age, and personality info
- **Pet-Friendly Places** — Discover and rate dog parks, hiking trails, cafés, vet clinics, and more
- **Meetups** — Organize and join local pet meetups with RSVP, location, and scheduling
- **User Profiles** — Follow other users, view pet spotlights, and browse user posts
- **Search & Explore** — Search for users, posts, hashtags, and places
- **Notifications** — Real-time notifications for likes, comments, follows, and meetup updates
- **Dark Mode** — System-aware theme with manual light / dark / system toggle
- **Admin Panel** — Moderation dashboard for managing users, posts, and reports
- **PWA Support** — Installable as a Progressive Web App on mobile devices

## 🛠 Tech Stack

| Layer              | Technology                                                                         |
| ------------------ | ---------------------------------------------------------------------------------- |
| **Framework**      | [React 19](https://react.dev/) + [TypeScript 5.9](https://www.typescriptlang.org/) |
| **Build Tool**     | [Vite 7](https://vite.dev/)                                                        |
| **Styling**        | [Tailwind CSS 4](https://tailwindcss.com/)                                         |
| **Routing**        | [React Router 7](https://reactrouter.com/)                                         |
| **Icons**          | [Lucide React](https://lucide.dev/)                                                |
| **Backend / Auth** | [Firebase](https://firebase.google.com/) (Authentication, Firestore)               |
| **Media Storage**  | [Cloudinary](https://cloudinary.com/) (image & video uploads)                      |
| **Geocoding**      | [Geoapify](https://www.geoapify.com/) (reverse geocoding & address autocomplete)   |
| **Deployment**     | [Vercel](https://vercel.com/)                                                      |

## 📦 Prerequisites

- [Node.js](https://nodejs.org/) >= 18
- [npm](https://www.npmjs.com/) (or yarn / pnpm)
- A [Firebase](https://console.firebase.google.com/) project with **Authentication** (Email/Password + Google) and **Firestore** enabled
- A [Cloudinary](https://cloudinary.com/) account with an unsigned upload preset named `petnote_unsigned`
- (Optional) A [Geoapify](https://www.geoapify.com/) API key for location features

## 🚀 Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/renrenmimi/PetNote.git
cd PetNote
```

### 2. Install dependencies

```bash
npm install
```

### 3. Configure environment variables

Create a `.env` (or `.env.local`) file in the project root:

```env
# Firebase
VITE_FIREBASE_API_KEY=your_firebase_api_key
VITE_FIREBASE_AUTH_DOMAIN=your_project.firebaseapp.com
VITE_FIREBASE_PROJECT_ID=your_project_id
VITE_FIREBASE_STORAGE_BUCKET=your_project.appspot.com
VITE_FIREBASE_MESSAGING_SENDER_ID=your_sender_id
VITE_FIREBASE_APP_ID=your_app_id

# Cloudinary
VITE_CLOUDINARY_CLOUD_NAME=your_cloud_name

# Geoapify (optional — location features degrade gracefully without it)
VITE_GEOAPIFY_KEY=your_geoapify_api_key
```

### 4. Start the development server

```bash
npm run dev
```

The app will be available at `http://localhost:5173`.

## 🏗 Production Build & Deployment

### Build for production

```bash
npm run build
```

This runs TypeScript type-checking (`tsc -b`) followed by the Vite production build. The output goes to the `dist/` directory.

### Preview the production build locally

```bash
npm run preview
```

### Deploy to Vercel

The project includes a `vercel.json` configured with SPA rewrites. To deploy:

1. Install the [Vercel CLI](https://vercel.com/docs/cli):
   ```bash
   npm i -g vercel
   ```
2. Add the environment variables listed above in **Vercel → Project Settings → Environment Variables**.
3. Deploy:
   ```bash
   vercel --prod
   ```

Or connect the GitHub repo (`renrenmimi/PetNote`) to Vercel for automatic deployments on every push.

## 🔒 Firestore Security Rules

Security rules live in the project root at `firestore.rules`.

### Deploy rules (Console)

1. Open Firebase Console → Firestore → Rules
2. Copy the contents of `firestore.rules`
3. Click Publish

### Deploy rules (Firebase CLI)

1. Install the CLI:
   ```bash
   npm install -g firebase-tools
   ```
2. Log in:
   ```bash
   firebase login
   ```
3. Initialize Firestore (first time only):
   ```bash
   firebase init firestore
   ```
4. Deploy rules:
   ```bash
   firebase deploy --only firestore:rules
   ```

## 🧱 Firebase Storage Rules

The app currently uploads media to Cloudinary, so Firebase Storage is not used. A `storage.rules` file is included with a deny-by-default policy. If you later enable Firebase Storage, update `storage.rules` and deploy with:

```bash
firebase deploy --only storage:rules
```

## 🗂 Project Structure

```
src/
├── assets/             # Static assets (images, etc.)
├── components/         # Reusable UI components
│   ├── AddressAutocomplete.tsx   # Geoapify address search
│   ├── BottomNav.tsx             # Mobile bottom navigation
│   ├── CommentSection.tsx        # Post comments
│   ├── MediaCarousel.tsx         # Image/video carousel
│   ├── Navbar.tsx                # Top navigation bar
│   ├── OnboardingFlow.tsx        # New-user onboarding
│   ├── PostCard.tsx              # Feed post card
│   ├── ShareMenu.tsx             # Share / copy-link menu
│   └── ...
├── contexts/           # React Contexts
│   ├── ThemeContext.tsx           # Dark mode provider
│   └── ToastContext.tsx          # Toast notification provider
├── hooks/              # Custom React hooks
│   ├── useAuth.ts                # Authentication state & methods
│   ├── useBookmark.ts            # Bookmark management
│   ├── useFollow.ts              # Follow / unfollow logic
│   ├── useLike.ts                # Like / unlike logic
│   ├── useNotifications.ts       # Real-time notifications
│   └── usePosts.ts               # Feed pagination & post CRUD
├── pages/              # Route-level page components
│   ├── Feed.tsx                  # Home feed
│   ├── Create.tsx                # Create a new post
│   ├── Places.tsx                # Pet-friendly places directory
│   ├── Meetups.tsx               # Meetups listing
│   ├── Profile.tsx               # Current user profile
│   ├── Search.tsx                # Search users, posts, hashtags
│   ├── AdminPanel.tsx            # Admin moderation dashboard
│   └── ...
├── services/           # Firebase & third-party API integrations
│   ├── firebase.ts               # Firebase app init (Auth + Firestore)
│   ├── cloudinary.ts             # Cloudinary media uploads
│   ├── location.ts               # Geoapify geocoding & user location
│   ├── locations.ts              # Places CRUD & ratings
│   ├── meetups.ts                # Meetups CRUD & RSVP
│   ├── posts.ts                  # Posts CRUD, likes, comments
│   ├── users.ts                  # User profiles
│   ├── follow.ts                 # Follow relationships
│   ├── notifications.ts          # Notification creation & queries
│   └── ...
├── types/              # TypeScript type declarations
├── utils/              # Utility helpers
│   ├── imageCompressor.ts        # Client-side image compression
│   ├── passwordValidator.ts      # Password strength rules
│   ├── petHelpers.ts             # Pet breed / species helpers
│   ├── timeAgo.ts                # Relative time formatting
│   └── randomName.ts             # Random username generator
├── App.tsx             # Root component & route definitions
├── main.tsx            # Entry point (renders App with providers)
└── index.css           # Global / Tailwind styles
```

## 🔌 APIs & External Services

### Firebase Authentication

- Email / Password sign-up & sign-in
- Google OAuth sign-in
- Email verification & password reset

### Firebase Firestore

Real-time NoSQL database powering all app data:

- **Collections:** `users`, `posts`, `pets`, `meetups`, `locations`, `notifications`, `reports`, `feedback`, `hashtags`

### Cloudinary (REST API)

- Unsigned image & video uploads (`upload_preset: petnote_unsigned`)
- Automatic video thumbnail generation
- Endpoint: `https://api.cloudinary.com/v1_1/<cloud_name>/<resource_type>/upload`

### Geoapify

- **Reverse Geocoding** — convert coordinates to city/state (`/v1/geocode/reverse`)
- **Address Autocomplete** — search suggestions filtered to US & Canada (`/v1/geocode/autocomplete`)

### Browser Geolocation API

- Used to get the user's current coordinates for nearby places & meetups

## ⚙️ Admin Setup

To grant admin access, update a user document in Firestore:

1. Open **Firebase Console → Firestore → `users/{uid}`**
2. Add field `role` with value `"admin"`

Admin users can access the moderation dashboard at `/admin`.

## 📜 Available Scripts

| Command           | Description                          |
| ----------------- | ------------------------------------ |
| `npm run dev`     | Start Vite dev server with HMR       |
| `npm run build`   | Type-check & build for production    |
| `npm run preview` | Preview the production build locally |
| `npm run lint`    | Run ESLint across the project        |

## 📄 License

This project is for personal / educational use.
