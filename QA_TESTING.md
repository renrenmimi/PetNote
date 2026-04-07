# PetNote — QA Testing Documentation

**Project:** PetNote — Pet-Centric Social Media Platform  
**Role:** Solo Developer & QA Tester  
**Tech Stack:** React + TypeScript + Firebase + Cloudinary + Geoapify + Vercel  
**Period:** January – February 2026  
**Repository:** github.com/renrenmimi/PetNote

---

## 1. QA Approach & Methodology

### Testing Strategy

- **Manual functional testing** after every feature implementation and bug fix
- **Cross-platform testing** on desktop browser (Chrome DevTools) and mobile browser (iPhone Safari)
- **Multi-account testing** using separate browser sessions to verify user interactions (follow, invite, notifications)
- **Console monitoring** — actively checking browser DevTools Console for errors after every change
- **Network monitoring** — using DevTools Network tab (Img filter) to verify API calls, image optimization, and response sizes
- **Regression testing** before each Git commit and Vercel deployment
- **Build verification** — running `npm run build` locally before pushing to catch TypeScript errors

### Bug Tracking & Workflow

- Bugs identified during manual testing → documented with reproduction steps → prompt written for Codex to fix → re-tested after fix → committed only after verification
- Git branching strategy: `feature/*` for new features, `fix/*` for bug fixes, each merged via Pull Request
- Vercel deployment logs monitored for build failures that don't appear in local development

---

## 2. Test Cases & Checklists

### 2.1 Full Regression Test Suite (90 test cases)

A comprehensive test checklist was created and executed covering all major flows:

**Round 1: Registration & Onboarding (Steps 1–7)**

- Splash screen display (PawIcon animation, no loading dots)
- Sign Up flow with password strength indicator (uppercase + lowercase + number + special char)
- Terms of Service and Privacy Policy links on registration page
- Email verification banner after registration
- Username selection (availability check, format validation: 3-20 chars, letters/numbers/underscore)
- Add Pet during onboarding with relationship selection (11 options)
- Existing Pet option with invitation code input
- Complete onboarding → land on Feed

**Round 2: Feed & Posts (Steps 8–21)**

- Bottom navigation bar fixed position during scroll (not affected by CSS transform)
- Create post with multi-photo upload (up to 9 images) + tags + filters
- Mandatory pet selection when posting
- Email verification required to post
- Photo carousel swipe + dot indicators
- Single-tap like (heart icon + count increment)
- Double-tap like (large white heart animation)
- Comment creation, reply (@mention), and deletion
- Post author can delete any comment on their post
- Bookmark/save functionality
- Long-press quick action menu (mobile) / right-click (desktop)
- Edit post flow (text + tags editable, media not editable)
- Share: copy link, native share, share card image generation
- Post draft auto-save (sessionStorage) and recovery banner

**Round 3: Profile & Pets (Steps 22–32)**

- User profile layout (Pets | Following stats, no Followers)
- No back button on Profile (it's a main tab)
- Tab switching: My Pets / Saved / Check-ins
- Pet profile page (Posts | Followers | Likes stats)
- Family member display with relationship labels and primary star
- Invitation code generation (8-char, 48hr expiry) and copy/share
- Settings → Edit username → verify uniqueness check → verify update propagates to pet Family section
- Saved posts tab verification
- Profile displays `@displayName` instead of exposing user email

**Round 4: Multi-Account Interaction (Steps 33–40)**

- Register second account in incognito browser
- Join existing pet via invitation code (Existing Pet tab)
- Select relationship when joining
- Verify Family shows both members with correct relationships
- Follow pet → verify follower count increment
- Following tab shows followed pet's posts
- Cross-account post, like, and comment

**Round 5: Notifications (Steps 41–43)**

- Notification icon badge (red dot for unread)
- Like, comment, reply, follow, and warning notifications appear
- Notification tap → navigate to correct post (same-tab, no new tab)

**Round 6: Search & Explore (Steps 44–50)**

- Search page loads without infinite loop (no Maximum update depth error)
- No tab switching — single page with Explore + mixed search results
- Explore content: Trending Tags, Trending Posts, Suggested Pets, Top Places, Upcoming Meetups
- Search by username, pet name, and tag — mixed results display
- "See all" expansion for each result category
- Search result navigation to correct pages
- Trending tag click fills search → X button clears successfully
- Clear search (X button) → reset to Explore

**Round 7: Places (Steps 51–58)**

- Add place with Geoapify address autocomplete (US + Canada only)
- "Use My Location" with watchPosition (works on repeated clicks)
- Photo upload for places (up to 5)
- Facility/feature tag selection (12 options)
- Category filter with unified FilterTag component + Lucide icons
- Place detail page: photos, rating, reviews, check-ins, meetup history
- Write a review with star rating + pet-friendliness breakdown
- Check-in with photo → "Verified" badge after 3 check-ins
- Star rating display on place cards

**Round 8: Meetups (Steps 59–69)**

- Create Meetup with Geoapify address autocomplete
- "Use My Location" functionality (watchPosition)
- Safety tips banner (collapsible)
- Pet type: Dogs / Cats / Other (custom input)
- Location privacy: Everyone / Participants Only
- City-only display before joining, full address after joining
- Join Meetup with pet selection and requirement validation
- Participant list display with avatars
- Filter tags: Nearby / This Week / My Meetups / Dogs / Cats / Other

**Round 9: Settings (Steps 70–77)**

- Unified SettingRow component — consistent height and alignment
- Dark mode toggle across all pages
- Change password with strength validation
- Notification preferences: Likes / Comments / Follows toggles
- My Location: update via bottom sheet, clear location
- Contact Us / feedback submission (4 types)
- Terms of Service and Privacy Policy full content display
- Sign Out in Settings (not on Profile page)
- Email display (read-only)

**Round 10: Admin Panel (Steps 78–86)**

- Admin Panel access with loading state (no premature redirect to home)
- Clean, professional layout (no colored badges or emoji)
- Report post from second account (6 reason types)
- View reports → expand to see original post content + thumbnail
- View Full Post → same-tab navigation (not new tab)
- Delete & Warn: reason tag selection (single select) + optional details textarea
- Block User: confirmation dialog + optional reason
- Warning notification received by target account (red-tinted notification)
- Feedback tab: view, resolve, delete feedback entries

**Round 11: Edge Cases (Steps 87–90)**

- Invalid URL → 404 page with PawIcon + "Go Home" button
- Unverified email → posting/commenting blocked with verification prompt
- Google OAuth login flow + automatic user document creation
- Google account password reset → appropriate message ("Use Google Sign-In")
- Banned user experience → creation actions blocked
- Duplicate image upload detection
- HEIC photo upload from iPhone → automatic conversion

---

## 3. Bugs Found & Resolved

### Critical Severity

#### Bug 01: Firebase Permission Error on Pet Creation

- **Steps to Reproduce:** Register new account → Add Pet in onboarding → error
- **Console Error:** `FirebaseError: Missing or insufficient permissions` at `pets.ts:74`
- **Root Cause:** Firestore security rules `isNotBanned()` function failed for new users whose documents hadn't fully propagated; also new collection paths from pet-centric refactor not covered by rules
- **Fix:** Simplified security rules, removed `isNotBanned()` from create operations, added all new subcollection paths
- **Lesson:** Security rules must be updated with every data model change

#### Bug 02: Search Page Infinite Loop (Maximum Update Depth)

- **Steps to Reproduce:** Navigate to Search page → page freezes, browser becomes unresponsive
- **Console Error:** `Maximum update depth exceeded` at `Search.tsx:304`
- **Root Cause:** A `useEffect` was calling `setState` which changed its own dependency, creating an infinite render loop
- **Fix:** Removed circular dependency — search useEffect now only depends on `searchQuery` string, explore data loads in separate useEffect with empty dependency array
- **Lesson:** Always audit useEffect dependency arrays; setState inside useEffect must not modify its own dependencies

### High Severity

#### Bug 03: HEIC Image Preview Failure

- **Steps to Reproduce:** Upload iPhone photo (HEIC format) → preview blank in development, visible in production
- **Root Cause:** Browsers don't natively render HEIC; Cloudinary auto-converts on CDN but local preview uses raw file
- **Fix:** Added `heic2any` library for client-side HEIC-to-JPEG conversion before preview
- **Verification:** Tested with multiple HEIC files from iPhone Camera Roll

#### Bug 04: Bottom Navigation Not Fixed on Mobile

- **Steps to Reproduce:** Open on mobile → scroll down → bottom nav scrolls away
- **Root Cause:** `PageTransition` component used CSS `transform` for slide animation, which creates a new containing block and breaks `position: fixed` for child elements
- **Fix:** Moved BottomNav rendering outside PageTransition wrapper in App.tsx; changed PageTransition to opacity-only animation
- **Lesson:** CSS `transform` on a parent element breaks `position: fixed` on all descendants — a subtle browser behavior

#### Bug 05: Admin Panel Redirects to Home

- **Steps to Reproduce:** Click "Admin Panel" in Profile → redirected to / instead of /admin
- **Root Cause:** `RequireAdmin` component checked `isAdmin` before Firestore query completed; during loading state `isAdmin` was `false`, triggering immediate redirect
- **Fix:** Added `loading` state to `useAdmin` hook; `RequireAdmin` shows spinner during loading instead of redirecting

#### Bug 06: PetSpotlight.tsx 404 Not Found

- **Steps to Reproduce:** Open Feed → console shows `GET PetSpotlight.tsx 404`
- **Root Cause:** Codex failed to create the file during a large batch of changes
- **Fix:** Created the missing component file with correct implementation

#### Bug 07: Notification Loading Forever

- **Steps to Reproduce:** Click notification icon → "Loading notifications" indefinitely
- **Root Cause:** Firestore composite index missing for `notifications` collection query (userId + createdAt DESC)
- **Fix:** Created required index via Firebase Console using the link provided in the error message
- **Lesson:** Firestore collectionGroup and compound queries require manually created indexes

#### Bug 08: Invitation Code Validation Failure

- **Steps to Reproduce:** User A generates code → User B enters code → "Unable to validate invitation code"
- **Root Cause:** `collectionGroup` query for `invitations` used field names that didn't match the documents; also code input wasn't normalized (whitespace, case)
- **Fix:** Standardized field names; added `.toUpperCase().replace(/\s/g, '')` normalization; added proper error handling with specific error messages

#### Bug 09: Geoapify API 400 Bad Request

- **Steps to Reproduce:** Type address in Meetup creation → no results, console shows 400 error
- **Root Cause:** `type=amenity,street,locality` parameter — Geoapify doesn't support comma-separated type values
- **Fix:** Removed the `type` parameter entirely, kept `filter=countrycode:us,ca` for region restriction

#### Bug 10: Use My Location Timeout on Second Click

- **Steps to Reproduce:** Click "Use My Location" → success → clear address → click again → "Location request timed out"
- **Root Cause:** `getCurrentPosition` with `maximumAge: 0` forces fresh GPS acquisition which times out on subsequent calls in some browsers
- **Fix:** Replaced with `watchPosition` (more reliable), set `maximumAge: 60000` to allow 1-minute cache, increased timeout to 15 seconds

#### Bug 11: Cloudinary Bandwidth Overconsumption

- **Discovery:** Cloudinary dashboard showed 204MB storage but 6.3GB bandwidth (6.59/25 credits used by single tester)
- **Root Cause:** Full-resolution original images served on every page load; no CDN optimization
- **Fix:** Created `optimizeCloudinaryUrl()` utility that inserts transformation parameters (`q_auto,f_auto,w_800`) into Cloudinary URLs at display time
- **Verification:** DevTools Network → Img filter confirmed transformed URLs; largest image reduced from 2,653KB to 98KB (96% reduction)
- **Result:** Estimated bandwidth reduction of 70-90%, extending free tier capacity from ~50 users to 500+ users

#### Bug 12: AddPlace React Hooks Order Error

- **Steps to Reproduce:** Navigate to Add Place page → page crashes
- **Console Error:** `Rendered more hooks than during the previous render` at `AddPlace.tsx:201`
- **Root Cause:** A `useMemo` hook was placed after a conditional `return` statement, violating React's Rules of Hooks
- **Fix:** Moved all hook calls to the top of the component, before any early returns

### Medium Severity

#### Bug 13: Comment replyTo Undefined Error

- **Steps to Reproduce:** Post a regular comment (not a reply) → console error
- **Console Error:** `Unsupported field value: undefined (found in field replyTo)`
- **Root Cause:** Firestore does not accept `undefined` values; non-reply comments had `replyTo: undefined`
- **Fix:** Conditionally include `replyTo` field only when it has a value; created `removeUndefined()` utility for all Firestore writes

#### Bug 14: Report Submit Undefined Field Error

- **Steps to Reproduce:** Submit a report without filling description → error
- **Console Error:** `Unsupported field value: undefined (found in field description)`
- **Root Cause:** Same pattern as Bug 13 — optional `description` field passed as `undefined`
- **Fix:** Applied `removeUndefined()` utility; also audited all other Firestore write operations for similar issues

#### Bug 15: Family Member Name Not Updating

- **Steps to Reproduce:** Change display name → go to pet Family section → old name still shown
- **Root Cause:** Family subcollection stores name snapshot, not a reference; name change didn't propagate
- **Fix:** Added `updateFamilyNames()` function using `collectionGroup('family')` query + `writeBatch` to update all family entries on name change

#### Bug 16: Delete Button Not Showing After Posting Comment

- **Steps to Reproduce:** Post comment → no delete button → collapse/reopen comments → delete button appears
- **Root Cause:** Newly inserted comment object missing complete `authorId` field for ownership comparison
- **Fix:** Ensured new comment includes full authorId; re-render triggered after local state update

#### Bug 17: lucide-react Dependency Conflict

- **Steps to Reproduce:** `npm install lucide-react@0.263.1` → `ERESOLVE unable to resolve dependency tree`
- **Root Cause:** lucide-react 0.263.1 peer dependency requires React 16/17/18, project uses React 19
- **Fix:** `npm install lucide-react --legacy-peer-deps`
- **Lesson:** React 19 ecosystem is still maturing; many packages need `--legacy-peer-deps`

#### Bug 18: Sign Up Button Disabled Despite Valid Input

- **Steps to Reproduce:** Enter valid email + password + matching confirm password → Create Account button remains disabled
- **Root Cause:** Button disabled condition had logic error — checking variables that didn't align with actual form state
- **Fix:** Simplified disabled condition to explicit checks: email not empty, password valid, passwords match, not loading

#### Bug 19: Google Login Avatar Not Displaying

- **Steps to Reproduce:** Sign in with Google → avatar shows broken image icon
- **Root Cause:** Google photoURL sometimes blocked by browser or expired; no fallback mechanism
- **Fix:** Created unified `Avatar` component with `onError` handler that falls back to DiceBear generated avatar

#### Bug 20: TypeScript Build Errors on Vercel (Multiple Occurrences)

- **Steps to Reproduce:** Push code → Vercel build fails
- **Errors:** Various — unused variables (`remainingTitle`, `spotsLeft`), unused imports (`writeBatch`, `UserProfile`)
- **Root Cause:** Codex-generated code sometimes declares variables used in comments/planning but not in actual code; `tsc` strict mode rejects these
- **Fix:** Removed all unused declarations; ran `npm run build` locally before every push
- **Lesson:** Always verify builds locally before pushing; TypeScript strict mode catches issues that don't appear in development

### Low Severity (UI/UX)

#### Bug 21: Comment Text Alignment

- **Issue:** Comment text centered instead of left-aligned with username
- **Fix:** Restructured comment layout — avatar left, content container right, text aligns with username

#### Bug 22: Reply Comment Avatar Indent

- **Issue:** Reply comments had extra left margin on avatar, making them misaligned with regular comments
- **Fix:** Removed conditional padding/margin for reply comments; all comments share identical layout

#### Bug 23: Pet Breed "?" Placeholder

- **Issue:** Pets without breed showed "?" character
- **Fix:** Conditionally render breed only when it has a value; searched and removed all `|| "?"` patterns

#### Bug 24: Settings Page Layout Inconsistencies

- **Issue:** Different setting items had different heights, toggle labels misaligned, Dark Mode had extra subtitle text
- **Fix:** Created unified `SettingRow` component and `Toggle` component with consistent sizing (h-6 w-11 toggle, py-3.5 rows, text-sm)

#### Bug 25: Filter Tags Clipped and Inconsistent

- **Issue:** Places/Meetups filter tags partially hidden by header, different sizes
- **Fix:** Created shared `FilterTag` component with consistent `rounded-full px-4 py-2` styling; added `py-2` padding to scroll container

---

## 4. Performance Testing & Optimization

### Cloudinary Bandwidth Optimization

**Problem Identified:** Single-tester usage consumed 6.59/25 monthly credits, primarily due to unoptimized image delivery (6.3GB bandwidth for only 204MB storage).

**Testing Method:**

1. Chrome DevTools → Network tab → Img filter
2. Compared image request sizes before and after optimization
3. Verified URL transformation parameters present in requests

**Results:**

| Image Type      | Before      | After    | Reduction |
| --------------- | ----------- | -------- | --------- |
| Feed post image | 500KB–2.6MB | 98–200KB | 70-90%    |
| Grid thumbnail  | 500KB–1MB   | 7–50KB   | 90-95%    |
| Avatar          | 100–500KB   | 5–10KB   | 95%+      |
| Spotlight       | 500KB       | 15–25KB  | 95%       |

**Optimization Technique:** URL-based transformation (no backend needed)

```
Original:  /image/upload/v123/abc.jpg                    → 2,653 KB
Optimized: /image/upload/q_auto,f_auto,w_800/v123/abc.jpg → 98 KB
```

**Capacity Impact:** Extended free tier from ~50 concurrent users to 500+ users without any cost increase.

---

## 5. Security Testing

### Firestore Security Rules Evolution

| Phase                | Rules                                        | Risk                                   |
| -------------------- | -------------------------------------------- | -------------------------------------- |
| Initial (test mode)  | `allow read, write: if true`                 | Anyone can read/write all data         |
| Development          | `allow read, write: if request.auth != null` | Any logged-in user can modify any data |
| Production (planned) | Role-based, owner-only writes                | Proper access control                  |

### Security Issues Identified

1. **API Secret Exposure Risk** — Investigated whether `VITE_CLOUDINARY_API_SECRET` in `.env.local` could be exposed in production build. Confirmed: Vite only bundles variables that are actually referenced in code via `import.meta.env`. Searched entire codebase — no code references to API Secret. **No exposure risk.**

2. **Firestore Rules Coverage Gaps** — Pet-centric refactor introduced new collection paths (`pets/{petId}/family`, `pets/{petId}/invitations`, `users/{uid}/followingPets`) that weren't covered by existing rules. Required comprehensive rules update covering all subcollections and collectionGroup queries.

3. **Signed Upload Migration** — Cloudinary upload flow was moved from unsigned preset upload to Firebase-generated signed upload parameters. This removes the old risk where knowing a preset name was enough to attempt uploads.

---

## 6. Testing Tools & Techniques

| Tool/Technique                        | Purpose                                                                     |
| ------------------------------------- | --------------------------------------------------------------------------- |
| Chrome DevTools Console               | Runtime errors, Firebase permission errors, React hook violations           |
| Chrome DevTools Network (Img filter)  | Cloudinary image optimization verification, API call monitoring             |
| Chrome DevTools Network (XHR filter)  | Firestore request count for performance analysis                            |
| Multiple browser sessions / Incognito | Multi-account testing for social features                                   |
| iPhone Safari                         | Mobile browser testing, fixed positioning, HEIC upload, touch interactions  |
| Firebase Console — Firestore          | Data verification, manual field editing (admin role), collection management |
| Firebase Console — Authentication     | User management, provider verification, password reset testing              |
| Firebase Console — Rules              | Security rule deployment and testing                                        |
| Cloudinary Console — Usage Dashboard  | Credit monitoring, bandwidth/storage tracking                               |
| Vercel Deployment Logs                | TypeScript build error detection, deployment verification                   |
| Git branching (feature/\*, fix/\*)    | Isolated changes, traceable bug fixes via commit history                    |

---

## 7. Key QA Insights & Lessons Learned

1. **CSS `transform` breaks `position: fixed`** — A subtle browser behavior where any parent element with `transform`, `perspective`, or `filter` creates a new containing block, causing descendant `fixed` elements to become `absolute` relative to that parent. Discovered through mobile testing.

2. **Firestore security rules must be updated with every data model change** — The pet-centric refactor introduced 5+ new collection paths that all needed explicit rule coverage. Silent permission failures are hard to debug without checking the Console.

3. **Firestore does not accept `undefined` field values** — Unlike JavaScript objects, Firestore rejects writes containing `undefined`. Every optional field must be explicitly omitted rather than set to `undefined`. Created a `removeUndefined()` utility to handle this pattern globally.

4. **Cross-platform image format testing is essential** — iPhone HEIC photos aren't supported in most browsers. This would have been missed entirely without mobile device testing.

5. **Firestore `collectionGroup` queries require explicit indexes** — Regular collection queries auto-index on single fields, but cross-subcollection group queries need manually created composite indexes. The error message helpfully includes a direct link to create the index.

6. **React 19 ecosystem compatibility** — Many popular packages (lucide-react, etc.) haven't updated peer dependencies for React 19. `--legacy-peer-deps` is a necessary workaround. Build verification catches these issues.

7. **Bandwidth costs can exceed storage costs by 30x** — Serving unoptimized images is the fastest way to exhaust free tier limits. Cloudinary URL-based transformation provides 70-95% size reduction at zero additional cost. Discovered by monitoring the Cloudinary usage dashboard.

8. **React Hooks rules violations cause cryptic errors** — Placing hooks after conditional returns causes "Rendered more hooks" errors. Always place all hooks at the top of components before any early returns.

9. **Multi-account testing is essential for social features** — Follow, invite, notification, family, and admin features fundamentally require 2+ accounts to verify. Single-account testing would miss most interaction bugs.

10. **Local build verification prevents deployment failures** — Running `npm run build` locally catches TypeScript strict-mode errors that `npm run dev` ignores. Established as a mandatory pre-push step after multiple Vercel build failures.

---

## 8. Test Coverage Analysis

### Tested Thoroughly

- User registration and authentication flows (email + Google)
- Post creation, editing, deletion with multi-media
- Pet profile and family system
- Admin panel operations
- Cross-platform (desktop + mobile)
- Image handling (HEIC, compression, Cloudinary optimization)

### Tested but Limited

- Meetup full lifecycle (creation → join → completion → rating) — tested basic flow, not all edge cases
- Places check-in verification (3-checkin threshold) — tested with limited accounts
- Offline behavior — not formally tested
- High-volume data (100+ posts) — not tested

### Not Tested (Known Gaps)

- Automated testing (unit tests, integration tests, E2E)
- Load/stress testing
- Accessibility (screen reader, keyboard navigation)
- Internationalization
- Browser compatibility beyond Chrome and Safari

### Future Testing Recommendations

- Implement Playwright or Cypress for E2E regression testing
- Add Firebase Emulator for local security rule testing
- Conduct accessibility audit (WCAG 2.1 compliance)
- Performance profiling with Lighthouse

---

## 9. Environment & Deployment

| Environment       | URL                     | Purpose                                |
| ----------------- | ----------------------- | -------------------------------------- |
| Local Development | `http://localhost:5173` | Feature development & initial testing  |
| Vercel Production | Vercel deployment URL   | Production deployment & mobile testing |

**Note:** Both environments share the same Firebase project and Cloudinary account. For production launch, separate development and production environments are recommended.

### Deployment Verification Checklist

- [x] `npm run build` passes locally
- [x] Environment variables configured in Vercel dashboard
- [x] Vercel Authentication disabled for public access
- [x] Production domain assigned
- [x] Mobile Safari browser flows functional
- [x] All required Firestore indexes created
- [x] Cloudinary signed upload presets and Firebase Functions secrets configured
- [x] Firestore security rules deployed
- [x] Terms of Service and Privacy Policy pages live
- [x] Admin role configured in Firestore
- [x] Test data cleaned before public launch

---

_This document was compiled from real development and testing activities performed throughout the PetNote development lifecycle (January – February 2026)._
