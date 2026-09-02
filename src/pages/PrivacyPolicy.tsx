import { useNavigate } from "react-router-dom";

export function PrivacyPolicy() {
  const navigate = useNavigate();

  return (
    <div className="min-h-screen bg-white dark:bg-slate-900">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white dark:border-slate-800 dark:bg-slate-900">
        <div className="mx-auto flex w-full max-w-2xl items-center px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="mr-3 text-xl text-slate-500 transition-colors hover:text-slate-700 dark:text-slate-300 dark:hover:text-white"
            aria-label="Go back"
          >
            ←
          </button>
          <h1 className="text-xl font-bold text-slate-900 dark:text-white">
            Privacy Policy
          </h1>
        </div>
      </header>

      <main className="mx-auto w-full max-w-2xl space-y-4 px-4 py-6 text-sm text-gray-700 dark:text-gray-300">
        <p>
          Your privacy matters to us. This policy explains what data we collect
          and how we use it.
        </p>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">1. Data We Collect</h2>
          <p className="font-medium text-slate-900 dark:text-white">Account Information:</p>
          <ul className="space-y-1">
            <li>• Email address (for login and communication)</li>
            <li>• Display name (chosen by you)</li>
            <li>• Profile photo (uploaded by you)</li>
          </ul>
          <p className="font-medium text-slate-900 dark:text-white">Pet Information:</p>
          <ul className="space-y-1">
            <li>• Pet name, species, breed, gender, birthday, bio, and photos</li>
          </ul>
          <p className="font-medium text-slate-900 dark:text-white">Content You Create:</p>
          <ul className="space-y-1">
            <li>• Posts (photos, videos, text, tags)</li>
            <li>• Comments and replies</li>
            <li>• Reviews and check-ins at places</li>
            <li>• Meetup details</li>
          </ul>
          <p className="font-medium text-slate-900 dark:text-white">Location Data:</p>
          <ul className="space-y-1">
            <li>• Your approximate location (city/state) if you choose to enable it</li>
            <li>• Used to show distances to meetups and places</li>
            <li>• You can clear your location at any time in Settings</li>
          </ul>
          <p className="font-medium text-slate-900 dark:text-white">Usage Data:</p>
          <ul className="space-y-1">
            <li>• Pages you visit within the app</li>
            <li>• Features you use</li>
            <li>• We do not track you across other websites</li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">2. How We Use Your Data</h2>
          <ul className="space-y-1">
            <li>
              • To provide the PetNote service (showing your posts, connecting
              with other pet lovers)
            </li>
            <li>
              • To send notifications about likes, comments, and meetup updates
            </li>
            <li>• To improve the app experience</li>
            <li>• To enforce our Terms of Service and protect users</li>
            <li>• We do NOT sell your data to anyone</li>
            <li>• We do NOT use your data for advertising</li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">3. Third-Party Services</h2>
          <p>We use the following third-party services to operate PetNote:</p>
          <p className="font-medium text-slate-900 dark:text-white">Firebase (Google):</p>
          <ul className="space-y-1">
            <li>• Authentication (login)</li>
            <li>• Firestore (database)</li>
            <li>• Hosted in the United States</li>
          </ul>
          <p className="font-medium text-slate-900 dark:text-white">Cloudinary:</p>
          <ul className="space-y-1">
            <li>• Photo and video storage</li>
            <li>• Hosted on AWS/Google Cloud</li>
          </ul>
          <p className="font-medium text-slate-900 dark:text-white">Geoapify:</p>
          <ul className="space-y-1">
            <li>• Address search and geocoding</li>
            <li>• Location data is sent to their servers for processing</li>
          </ul>
          <p className="font-medium text-slate-900 dark:text-white">DiceBear:</p>
          <ul className="space-y-1">
            <li>• Random avatar generation</li>
            <li>• No personal data is shared</li>
          </ul>
          <p className="font-medium text-slate-900 dark:text-white">Vercel:</p>
          <ul className="space-y-1">
            <li>• Web hosting</li>
            <li>• Hosted in the United States</li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">4. Data Storage and Security</h2>
          <ul className="space-y-1">
            <li>
              • Your data is stored on Firebase (Google Cloud) servers in the
              United States.
            </li>
            <li>
              • Passwords are handled entirely by Firebase Authentication.
              PetNote never sees or stores your password.
            </li>
            <li>• We use Firestore security rules to protect your data.</li>
            <li>• We use HTTPS for all data transmission.</li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">5. Your Rights</h2>
          <p>You can:</p>
          <ul className="space-y-1">
            <li>• View your data in your Profile and Settings</li>
            <li>• Edit your profile, pets, and posts at any time</li>
            <li>• Delete individual posts, pets, or your entire account</li>
            <li>• Clear your location data</li>
            <li>• Control notification preferences</li>
            <li>
              • Request a copy of your data by contacting us through the
              feedback form
            </li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">6. Data Deletion</h2>
          <p>When you delete your account:</p>
          <ul className="space-y-1">
            <li>• Your profile, pets, posts, comments, and likes are deleted from our database</li>
            <li>
              • Photos may take additional time to be removed from Cloudinary
              storage
            </li>
            <li>• Some anonymized data may remain in backups for up to 30 days</li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">7. Children&apos;s Privacy</h2>
          <p>
            PetNote is not intended for children under 13. We do not knowingly
            collect data from children under 13. If we discover a child under
            13 has created an account, we will delete it.
          </p>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">8. Cookies and Local Storage</h2>
          <ul className="space-y-1">
            <li>• We use session storage for draft posts (cleared when you close the browser)</li>
            <li>• We use local storage for dark mode preference and seen posts</li>
            <li>• We do not use tracking cookies</li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">9. Changes to This Policy</h2>
          <p>
            We may update this policy from time to time. We will notify users of
            significant changes through the app.
          </p>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">10. Contact</h2>
          <p>
            For privacy questions or data requests, contact us through the
            in-app feedback form.
          </p>
        </section>

        <p className="pt-2 text-xs text-gray-500 dark:text-gray-400">
          Last updated: February 2026
        </p>
      </main>
    </div>
  );
}
