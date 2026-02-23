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
- **Cross-platform testing** on desktop browser (Chrome DevTools) and mobile (iPhone Safari PWA)
- **Multi-account testing** using separate browser sessions to verify user interactions (follow, invite, notifications)
- **Console monitoring** — actively checking browser DevTools Console for errors after every change
- **Regression testing** before each Git commit and Vercel deployment

### Bug Tracking & Workflow

- Bugs identified during manual testing → documented with reproduction steps → prompt written for Codex to fix → re-tested after fix → committed only after verification
- Git branching strategy: `feature/*` for new features, `fix/*` for bug fixes, each merged via Pull Request

---

## 2. Test Cases & Checklists

### 2.1 Full Regression Test Suite (90 test cases)

A comprehensive test checklist was created and executed covering all major flows:

**Round 1: Registration & Onboarding (Steps 1–7)**

- Splash screen display
- Sign Up flow with password strength indicator
- Username selection (availability check, format validation)
- Add Pet during onboarding
- Complete onboarding → land on Feed

**Round 2: Feed & Posts (Steps 8–21)**

- Bottom navigation bar fixed position during scroll
- Create post with multi-photo upload (up to 3 images) + tags + filters
- Photo carousel swipe + dot indicators
- Single-tap like (heart icon + count increment)
- Double-tap like (large white heart animation)
- Comment creation, reply (@mention), and deletion
- Bookmark/save functionality
- Long-press quick action menu
- Edit post flow
- Share link → open in new window

**Round 3: Profile & Pets (Steps 22–32)**

- User profile layout (Pets | Following stats)
- Tab switching: My Pets / Saved / Check-ins
- Pet profile page (Posts | Followers | Likes stats)
- Family member display with relationship labels
- Invitation code generation and copy
- Settings → Edit username → verify update propagates to pet Family section
- Saved posts tab verification

**Round 4: Multi-Account Interaction (Steps 33–40)**

- Register second account in incognito browser
- Join existing pet via invitation code
- Verify Family shows both members
- Follow pet → verify follower count increment
- Cross-account post, like, and comment

**Round 5: Notifications (Steps 41–43)**

- Notification icon badge
- Like and comment notifications appear
- Notification tap → navigate to correct post

**Round 6: Search (Steps 44–50)**

- Search page loads without infinite loop
- Explore tab: Trending Tags, Trending Posts, Suggested Pets
- Search by username, pet name, and tag
- Search result navigation
- Clear search (X button) → reset to Explore

**Round 7: Places (Steps 51–58)**

- Add place with address autocomplete (Geoapify)
- Photo upload for places
- Facility selection and rating
- Place detail page display
- Write a review and submit
- Check-in with photo
- Category filter functionality
- Star rating display

**Round 8: Meetups (Steps 59–69)**

- Create Meetup with address autocomplete
- "Use My Location" functionality
- Safety reminder display
- Location privacy (city only before join, full address after join)
- Join Meetup with pet selection
- Participant list display

**Round 9: Settings (Steps 70–77)**

- Dark mode toggle across all pages
- Change password
- Notification preferences toggle
- Location update
- Contact Us / feedback submission
- Terms of Service and Privacy Policy display
- Sign Out

**Round 10: Admin Panel (Steps 78–86)**

- Admin Panel access (no redirect to home)
- Report post from second account
- View reports in Admin Panel
- View Full Post from report (same-tab navigation)
- Delete & Warn action with reason selection
- Warning notification received by target account
- Feedback tab in Admin Panel

**Round 11: Edge Cases (Steps 87–90)**

- Invalid URL → 404 page display
- 404 "Go Home" button navigation
- Unverified email → posting blocked with prompt
- Google OAuth login flow

---

## 3. Bugs Found & Resolved

### Bug 01: HEIC Image Preview Failure

- **Severity:** High
- **Steps to Reproduce:** Upload a photo taken on iPhone (HEIC format) → preview does not display
- **Expected:** Image preview should render regardless of format
- **Actual:** Preview was blank for HEIC files
- **Root Cause:** Browser does not natively support HEIC rendering
- **Fix:** Added HEIC-to-JPEG conversion before preview display
- **Commit:** `Fix HEIC image preview and replyTo undefined bug`

### Bug 02: Comment replyTo Undefined Error

- **Severity:** Medium
- **Steps to Reproduce:** Post a regular comment (not a reply) → console error `replyTo undefined`
- **Expected:** No error for non-reply comments
- **Actual:** `replyTo` field was referenced without null check
- **Fix:** Added optional chaining for replyTo field
- **Commit:** `Fix HEIC image preview and replyTo undefined bug`

### Bug 03: Delete Button Not Showing After Posting Comment

- **Severity:** Medium
- **Steps to Reproduce:** Post a comment → delete button not visible → collapse and reopen comments → delete button appears
- **Expected:** Delete button should be visible immediately after posting
- **Actual:** Component state not refreshed after new comment insertion
- **Fix:** Force re-render of comment list after posting

### Bug 04: Search Tab Switching Flash Bug

- **Severity:** High
- **Steps to Reproduce:** On Search page, tap Tags/People/Pets tab → page flashes → returns to Explore tab
- **Expected:** Should switch to selected tab
- **Actual:** A `useEffect` was resetting the active tab state on every render
- **Root Cause:** Search input `onChange` or `useEffect` forced tab back to "explore" when input was empty
- **Fix:** Removed the unintended state reset in useEffect
- **Commit:** `Fix search clear bug and unify filter tags with Lucide icons`

### Bug 05: Bottom Navigation Bar Not Fixed on Mobile

- **Severity:** High
- **Steps to Reproduce:** Open app on mobile → scroll down → bottom nav scrolls away
- **Expected:** Bottom nav should remain fixed at screen bottom
- **Actual:** `PageTransition` component used CSS `transform`, which broke `position: fixed` inside it
- **Root Cause:** CSS `transform` creates a new containing block, causing fixed positioning to fail
- **Fix:** Moved `BottomNav` outside of `PageTransition` wrapper in App.tsx
- **Commit:** `Fix BottomNav fixed position, remove Profile back button, fix search infinite loop`

### Bug 06: PetSpotlight.tsx 404 Not Found

- **Severity:** High
- **Steps to Reproduce:** Open Feed page → console shows `GET PetSpotlight.tsx 404`
- **Expected:** Component should load normally
- **Actual:** File was not created by Codex or path was incorrect
- **Fix:** Created the missing PetSpotlight.tsx component file

### Bug 07: Notification Loading Forever

- **Severity:** High
- **Steps to Reproduce:** Click notification icon → shows "Loading notifications" indefinitely
- **Expected:** Notifications list should load
- **Actual:** Firestore composite index was missing for the notification query
- **Fix:** Created required Firestore index via Firebase Console link in error message

### Bug 08: Firebase Permission Error on Pet Creation

- **Severity:** Critical
- **Steps to Reproduce:** Register new account → Add Pet in onboarding → error: `Missing or insufficient permissions`
- **Expected:** Authenticated user should be able to create pet
- **Actual:** Firestore security rules did not allow the new collection path
- **Root Cause:** Security rules were not updated after the pet-centric data model refactor
- **Fix:** Updated `firestore.rules` to cover all new collection paths including pets subcollections
- **Console Error:** `FirebaseError: Missing or insufficient permissions` at `pets.ts:74`

### Bug 09: Invitation Code Validation Failure

- **Severity:** High
- **Steps to Reproduce:** User A generates invitation code → User B enters code → "Unable to validate invitation code"
- **Expected:** Code should be validated and pet shared
- **Actual:** `collectionGroup` query field name mismatch between code generation and validation
- **Fix:** Standardized field names, added code normalization (uppercase, trim whitespace)

### Bug 10: Family Member Name Not Updating

- **Severity:** Medium
- **Steps to Reproduce:** Change display name in Edit Profile → go to pet's Family section → old name still shown
- **Expected:** Name change should propagate to all Family entries
- **Actual:** Family subcollection documents stored a snapshot of the name, not a reference
- **Fix:** Added `updateFamilyNames()` function using `collectionGroup` query + `writeBatch` to update all family entries on name change

### Bug 11: lucide-react Dependency Conflict

- **Severity:** Medium (Build blocker)
- **Steps to Reproduce:** `npm install lucide-react@0.263.1` → `ERESOLVE unable to resolve dependency tree`
- **Expected:** Package should install
- **Actual:** lucide-react 0.263.1 requires React 16/17/18, project uses React 19
- **Fix:** Installed latest version with `npm install lucide-react --legacy-peer-deps`

### Bug 12: Comment Text Alignment Issue

- **Severity:** Low (UI)
- **Steps to Reproduce:** View any comment → text is flush left against container edge
- **Expected:** Comment text should align with username (Instagram-style layout)
- **Fix:** Restructured comment layout — avatar left, content container right, text aligns with username start position

### Bug 13: Cloudinary Bandwidth Overconsumption

- **Severity:** High (Cost/operational)
- **Discovery:** Storage only 204MB but bandwidth reached 6.3GB
- **Root Cause:** Full-resolution original images served on every page load
- **Fix:** Added Cloudinary URL transformation parameters (`q_auto,f_auto,w_800`) to automatically compress and resize images without quality loss
- **Verification:** Checked via DevTools Network → Img filter → confirmed transformed URLs

---

## 4. Testing Tools & Techniques Used

| Tool/Technique                        | Purpose                                                       |
| ------------------------------------- | ------------------------------------------------------------- |
| Chrome DevTools Console               | Monitor runtime errors, Firebase permission errors            |
| Chrome DevTools Network (Img filter)  | Verify Cloudinary image optimization URLs and sizes           |
| Multiple browser sessions / Incognito | Multi-account testing for social features                     |
| iPhone Safari                         | Mobile-specific testing (PWA, fixed positioning, HEIC upload) |
| Firebase Console                      | Verify Firestore data, create indexes, check security rules   |
| Vercel Deployment Logs                | Catch TypeScript build errors before production               |
| Git branching (feature/_, fix/_)      | Isolate changes, traceable bug fixes via commit history       |

---

## 5. Key QA Insights & Lessons Learned

1. **CSS `transform` breaks `position: fixed`** — A subtle browser behavior that caused the mobile nav bar bug. Learned to keep fixed-position elements outside of any parent with transform properties.

2. **Firestore security rules must be updated with every data model change** — The pet-centric refactor introduced new collection paths that weren't covered by existing rules, causing silent permission failures.

3. **Cross-platform image formats matter** — iPhone HEIC photos are not universally supported in browsers. Testing only on desktop would have missed this.

4. **Firestore `collectionGroup` queries require specific indexes** — Unlike regular collection queries, group queries across subcollections need manually created composite indexes.

5. **Dependency version conflicts are common in React 19** — Many popular packages haven't updated their peer dependency ranges. `--legacy-peer-deps` is a practical workaround.

6. **Bandwidth costs can exceed storage costs by 30x** — Serving unoptimized images is the fastest way to burn through free tier limits. URL-based transformation is a zero-cost optimization.

7. **Multi-account testing is essential for social features** — Follow, invite, notification, and family features cannot be properly tested with a single account.

---

## 6. Environment & Deployment Testing

| Environment       | URL                     | Purpose                                |
| ----------------- | ----------------------- | -------------------------------------- |
| Local Development | `http://localhost:5173` | Feature development & initial testing  |
| Vercel Production | `petnote.vercel.app`    | Production deployment & mobile testing |

### Deployment Verification Checklist

- [ ] `npm run build` passes locally (TypeScript compilation)
- [ ] Environment variables configured in Vercel dashboard
- [ ] Vercel Authentication disabled for public access
- [ ] Production domain assigned (not preview URL)
- [ ] Mobile PWA "Add to Home Screen" functional
- [ ] All Firestore indexes created in production project
- [ ] Cloudinary upload preset exists and configured

---

_This document was compiled from development conversation logs and reflects real testing activities performed throughout the PetNote development lifecycle._
