import { useNavigate } from "react-router-dom";

export function TermsOfService() {
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
            Terms of Service
          </h1>
        </div>
      </header>

      <main className="mx-auto w-full max-w-2xl space-y-4 px-4 py-6 text-sm text-gray-700 dark:text-gray-300">
        <p>Welcome to PetNote. By using our app, you agree to these terms.</p>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">1. About PetNote</h2>
          <p>
            PetNote is a pet-focused social platform where pet lovers can share
            photos, discover pet-friendly places, and organize meetups. The
            service is provided as-is and may change over time.
          </p>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">2. Your Account</h2>
          <ul className="space-y-1">
            <li>• You must be at least 13 years old to use PetNote.</li>
            <li>• You are responsible for keeping your login credentials secure.</li>
            <li>• You may only have one account per person.</li>
            <li>• We may suspend or delete accounts that violate these terms.</li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">3. Content You Post</h2>
          <ul className="space-y-1">
            <li>• You own the content you post (photos, videos, text).</li>
            <li>
              • By posting, you grant PetNote a non-exclusive license to
              display, distribute, and store your content within the app.
            </li>
            <li>
              • You must not post content that is illegal, abusive, hateful, or
              harmful to animals.
            </li>
            <li>
              • We reserve the right to remove any content that violates these
              terms.
            </li>
            <li>
              • Deleted posts are removed from the app but may take time to be
              fully removed from our storage services.
            </li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">4. Pet Safety</h2>
          <ul className="space-y-1">
            <li>• PetNote has zero tolerance for animal abuse content.</li>
            <li>
              • Content depicting or promoting animal cruelty will be
              immediately removed and the account will be banned.
            </li>
            <li>
              • If you witness animal abuse, please report it to local
              authorities in addition to reporting within the app.
            </li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">5. Meetups</h2>
          <ul className="space-y-1">
            <li>• Meetups are organized by users, not by PetNote.</li>
            <li>• PetNote is not responsible for what happens at meetups.</li>
            <li>
              • Always meet in public places and prioritize your safety and your
              pet&apos;s safety.
            </li>
            <li>
              • Make sure your pets are vaccinated and well-behaved before
              attending meetups.
            </li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">6. Places</h2>
          <ul className="space-y-1">
            <li>
              • Place recommendations are submitted by users and are not
              verified by PetNote unless marked as &quot;Verified.&quot;
            </li>
            <li>
              • Always assess a location&apos;s safety yourself before visiting
              with your pet.
            </li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">7. Prohibited Behavior</h2>
          <ul className="space-y-1">
            <li>• Harassment, bullying, or threatening other users.</li>
            <li>• Posting spam or misleading content.</li>
            <li>• Impersonating other users or pets.</li>
            <li>• Attempting to hack or disrupt the service.</li>
            <li>
              • Using the service for commercial advertising without permission.
            </li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">8. Account Termination</h2>
          <ul className="space-y-1">
            <li>• You can delete your account at any time in Settings.</li>
            <li>• We may suspend or terminate accounts that violate these terms.</li>
            <li>
              • Upon deletion, your data will be removed, though some data may
              persist in backups for a limited time.
            </li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">9. Limitation of Liability</h2>
          <ul className="space-y-1">
            <li>• PetNote is provided &quot;as is&quot; without warranties.</li>
            <li>
              • We are not liable for user-generated content, meetup incidents,
              or place recommendations.
            </li>
            <li>
              • We are not liable for any damages arising from your use of the
              service.
            </li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">10. Changes to Terms</h2>
          <ul className="space-y-1">
            <li>• We may update these terms from time to time.</li>
            <li>
              • Continued use of PetNote after changes means you accept the
              updated terms.
            </li>
          </ul>
        </section>

        <section className="space-y-2">
          <h2 className="font-semibold text-slate-900 dark:text-white">11. Contact</h2>
          <p>
            If you have questions about these terms, contact us through the
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
