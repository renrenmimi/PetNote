import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import Avatar from "../components/Avatar";
import { getLocation, getReviews, type Location, type Review } from "../services/locations";
import { getMeetupsByLocation, type Meetup } from "../services/meetups";
import { timeAgo } from "../utils/timeAgo";

const toDate = (value: unknown): Date | null => {
  if (!value) return null;
  if (value instanceof Date) return value;
  if (
    typeof value === "object" &&
    value !== null &&
    "toDate" in value &&
    typeof (value as { toDate: () => Date }).toDate === "function"
  ) {
    return (value as { toDate: () => Date }).toDate();
  }
  return null;
};

export function LocationDetail() {
  const navigate = useNavigate();
  const { locationId = "" } = useParams();
  const [location, setLocation] = useState<Location | null>(null);
  const [reviews, setReviews] = useState<Review[]>([]);
  const [meetups, setMeetups] = useState<Meetup[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let ignore = false;
    if (!locationId) return;
    const load = async () => {
      setLoading(true);
      const [loc, revs, meetupsData] = await Promise.all([
        getLocation(locationId),
        getReviews(locationId),
        getMeetupsByLocation(locationId),
      ]);
      if (!ignore) {
        setLocation(loc);
        setReviews(revs);
        setMeetups(meetupsData.filter((meetup) => meetup.status === "completed"));
        setLoading(false);
      }
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [locationId]);

  const ratingStats = useMemo(() => {
    if (reviews.length === 0) {
      return { space: 0, safety: 0, cleanliness: 0 };
    }
    const totals = reviews.reduce(
      (acc, review) => {
        acc.space += review.petFriendly?.space || 0;
        acc.safety += review.petFriendly?.safety || 0;
        acc.cleanliness += review.petFriendly?.cleanliness || 0;
        return acc;
      },
      { space: 0, safety: 0, cleanliness: 0 }
    );
    return {
      space: totals.space / reviews.length,
      safety: totals.safety / reviews.length,
      cleanliness: totals.cleanliness / reviews.length,
    };
  }, [reviews]);

  const tagCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    reviews.forEach((review) => {
      (review.tags || []).forEach((tag) => {
        counts[tag] = (counts[tag] || 0) + 1;
      });
    });
    return Object.entries(counts).sort((a, b) => b[1] - a[1]);
  }, [reviews]);

  if (loading) {
    return (
      <div className="min-h-screen bg-slate-50 px-4 py-6 text-sm text-slate-500 dark:bg-slate-900">
        Loading location...
      </div>
    );
  }

  if (!location) {
    return (
      <div className="min-h-screen bg-slate-50 px-4 py-6 text-sm text-slate-500 dark:bg-slate-900">
        Location not found.
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-slate-50 pb-16 dark:bg-slate-900">
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white/90 backdrop-blur dark:border-slate-800 dark:bg-slate-900/90">
        <div className="mx-auto flex w-full max-w-md items-center justify-between px-4 py-3">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="text-xl text-slate-500 hover:text-slate-700 dark:text-slate-300"
          >
            ←
          </button>
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">
            Location
          </h1>
          <div className="w-6" />
        </div>
      </header>

      <main className="mx-auto w-full max-w-md space-y-5 px-4 py-5">
        <section className="space-y-2 rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <h2 className="text-lg font-semibold text-slate-900 dark:text-white">
            {location.name}
          </h2>
          <p className="text-sm text-slate-500 dark:text-slate-300">
            {location.address}
          </p>
          <div className="flex items-center gap-2 text-sm text-amber-500">
            ⭐ {location.averageRating.toFixed(1)} ({location.totalRatings} reviews)
          </div>
          <button
            type="button"
            onClick={() =>
              window.open(
                `https://maps.google.com/?q=${location.lat},${location.lng}`,
                "_blank"
              )
            }
            className="mt-2 inline-flex items-center gap-2 rounded-full border border-slate-200 px-3 py-1 text-xs font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:border-slate-700 dark:text-slate-200 dark:hover:bg-slate-700"
          >
            Open in Maps
          </button>
        </section>

        <section className="rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
            Pet-friendly scores
          </h3>
          <div className="mt-3 space-y-2 text-sm text-slate-600 dark:text-slate-300">
            {[
              { label: "Space", value: ratingStats.space },
              { label: "Safety", value: ratingStats.safety },
              { label: "Cleanliness", value: ratingStats.cleanliness },
            ].map((item) => (
              <div key={item.label} className="flex items-center justify-between">
                <span>{item.label}</span>
                <span className="text-amber-500">
                  {"⭐".repeat(Math.round(item.value || 0))}
                </span>
              </div>
            ))}
          </div>
        </section>

        <section className="rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
            Popular tags
          </h3>
          <div className="mt-3 flex flex-wrap gap-2">
            {tagCounts.length === 0 ? (
              <span className="text-xs text-slate-400">No tags yet.</span>
            ) : (
              tagCounts.map(([tag, count]) => (
                <span
                  key={tag}
                  className="rounded-full border border-slate-200 px-3 py-1 text-xs text-slate-600 dark:border-slate-700 dark:text-slate-300"
                >
                  {tag} ({count})
                </span>
              ))
            )}
          </div>
        </section>

        <section className="rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
            Reviews
          </h3>
          <div className="mt-3 space-y-4">
            {reviews.length === 0 ? (
              <p className="text-xs text-slate-400">No reviews yet.</p>
            ) : (
              reviews.map((review) => (
                <div key={review.id} className="space-y-1">
                  <div className="flex items-center gap-2">
                    <Avatar
                      src={review.userAvatar || undefined}
                      alt={review.userName}
                      userId={review.userId}
                      size={28}
                      className="h-7 w-7"
                    />
                    <div>
                      <p className="text-sm font-semibold text-slate-900 dark:text-white">
                        {review.userName}
                      </p>
                      <p className="text-xs text-amber-500">
                        {"⭐".repeat(review.rating)}
                      </p>
                    </div>
                    <span className="ml-auto text-[11px] text-slate-400">
                      {review.createdAt ? timeAgo(toDate(review.createdAt) || new Date()) : ""}
                    </span>
                  </div>
                  {review.comment ? (
                    <p className="text-sm text-slate-600 dark:text-slate-300">
                      {review.comment}
                    </p>
                  ) : null}
                </div>
              ))
            )}
          </div>
        </section>

        <section className="rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
            Meetups hosted here
          </h3>
          <div className="mt-3 space-y-2 text-sm text-slate-600 dark:text-slate-300">
            {meetups.length === 0 ? (
              <p className="text-xs text-slate-400">No meetups yet.</p>
            ) : (
              meetups.map((meetup) => (
                <button
                  key={meetup.id}
                  type="button"
                  onClick={() => navigate(`/meetups/${meetup.id}`)}
                  className="w-full text-left text-sm font-semibold text-purple-600 hover:text-purple-700"
                >
                  {meetup.title}
                </button>
              ))
            )}
          </div>
        </section>
      </main>
    </div>
  );
}
