import { useEffect, useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import Avatar from "../components/Avatar";
import LazyImage from "../components/LazyImage";
import { LocationRatingModal } from "../components/LocationRatingModal";
import { MediaCarousel } from "../components/MediaCarousel";
import { useAuth } from "../hooks/useAuth";
import { useToast } from "../contexts/ToastContext";
import { calculateDistance } from "../services/location";
import {
  getLocation,
  getReviews,
  getUserReview,
  type Location,
  type PlaceCategory,
  type Review,
} from "../services/locations";
import { getMeetupsByLocation, type Meetup } from "../services/meetups";
import { timeAgo } from "../utils/timeAgo";

type CategoryMeta = {
  label: string;
  emoji: string;
  badge: string;
};

const categoryMeta: Record<PlaceCategory, CategoryMeta> = {
  dog_park: {
    label: "Dog Park",
    emoji: "🐕",
    badge: "bg-emerald-100 text-emerald-700",
  },
  hiking_trail: {
    label: "Hiking Trail",
    emoji: "🥾",
    badge: "bg-amber-100 text-amber-700",
  },
  beach: {
    label: "Beach",
    emoji: "🏖️",
    badge: "bg-blue-100 text-blue-700",
  },
  community_park: {
    label: "Community Park",
    emoji: "🌳",
    badge: "bg-emerald-100 text-emerald-700",
  },
  cafe: {
    label: "Café",
    emoji: "☕",
    badge: "bg-orange-100 text-orange-700",
  },
  green_space: {
    label: "Green Space",
    emoji: "🌿",
    badge: "bg-teal-100 text-teal-700",
  },
  pet_store: {
    label: "Pet Store",
    emoji: "🏪",
    badge: "bg-purple-100 text-purple-700",
  },
  vet: {
    label: "Vet",
    emoji: "🏥",
    badge: "bg-red-100 text-red-700",
  },
  other: {
    label: "Other",
    emoji: "📍",
    badge: "bg-slate-100 text-slate-600",
  },
};

const featureLabels: Record<string, string> = {
  off_leash: "🐕‍🦺 Off-leash area",
  fenced: "🏗️ Fenced area",
  water_access: "💧 Water access",
  waste_bags: "🗑️ Waste bags",
  parking: "🅿️ Parking",
  restrooms: "🚽 Restrooms",
  seating: "🪑 Seating",
  shade: "🌳 Shade",
  lighting: "🌙 Well-lit",
  beach_access: "🏖️ Beach access",
  trails: "🏃 Trails",
  food_nearby: "☕ Food nearby",
};

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
  const { user, profile } = useAuth();
  const { showToast } = useToast();
  const [location, setLocation] = useState<Location | null>(null);
  const [reviews, setReviews] = useState<Review[]>([]);
  const [meetups, setMeetups] = useState<Meetup[]>([]);
  const [userReview, setUserReview] = useState<Review | null>(null);
  const [loading, setLoading] = useState(true);
  const [ratingOpen, setRatingOpen] = useState(false);
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);

  const refreshData = async (id: string, userId?: string) => {
    setLoading(true);
    const [loc, revs, meetupsData] = await Promise.all([
      getLocation(id),
      getReviews(id),
      getMeetupsByLocation(id),
    ]);
    setLocation(loc);
    setReviews(revs);
    setMeetups(meetupsData.filter((meetup) => meetup.status === "completed"));
    if (userId) {
      const existingReview = await getUserReview(id, userId);
      setUserReview(existingReview);
    } else {
      setUserReview(null);
    }
    setLoading(false);
  };

  useEffect(() => {
    let ignore = false;
    if (!locationId) return;
    const load = async () => {
      if (ignore) return;
      await refreshData(locationId, user?.uid);
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [locationId, user?.uid]);

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

  const distance = useMemo(() => {
    if (!location || !profile?.location) return null;
    return calculateDistance(
      profile.location.lat,
      profile.location.lng,
      location.lat,
      location.lng
    );
  }, [location, profile?.location]);

  const allPhotos = useMemo(() => {
    if (!location) return [];
    const collected = new Set<string>();
    (location.photos || []).forEach((photo) => collected.add(photo));
    reviews.forEach((review) => {
      (review.photos || []).forEach((photo) => collected.add(photo));
    });
    return Array.from(collected);
  }, [location, reviews]);

  const heroPhotos = useMemo(() => {
    if (!location) return [];
    return location.photos?.length ? location.photos : allPhotos;
  }, [location, allPhotos]);

  const handleShare = async () => {
    if (!location) return;
    const link = `${window.location.origin}/location/${location.id}`;
    try {
      if (navigator.share) {
        await navigator.share({
          title: location.name,
          text: "Check out this pet-friendly place on PetNote!",
          url: link,
        });
      } else {
        await navigator.clipboard.writeText(link);
        showToast("Link copied!", "success");
      }
    } catch {
      showToast("Unable to share this place.", "error");
    }
  };

  const openReview = () => {
    if (!user) {
      navigate("/login");
      return;
    }
    setRatingOpen(true);
  };

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

  const meta = categoryMeta[location.category] ?? categoryMeta.other;

  return (
    <div className="min-h-screen bg-slate-50 pb-24 dark:bg-slate-900">
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
        <section className="overflow-hidden rounded-2xl bg-white shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          {heroPhotos.length > 0 ? (
            <MediaCarousel
              media={heroPhotos.map((photo) => ({ url: photo, type: "image" }))}
            />
          ) : (
            <div className="flex h-44 items-center justify-center bg-gradient-to-br from-purple-400 to-pink-400 text-4xl text-white">
              {meta.emoji}
            </div>
          )}
        </section>

        <section className="space-y-3 rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <div className="flex items-start justify-between gap-3">
            <div>
              <h2 className="text-lg font-semibold text-slate-900 dark:text-white">
                {location.name}
              </h2>
              <span
                className={`mt-1 inline-flex rounded-full px-2 py-0.5 text-xs font-semibold ${meta.badge}`}
              >
                {meta.emoji} {meta.label}
              </span>
            </div>
            {location.totalRatings > 0 ? (
              <div className="text-right text-sm text-amber-500">
                ⭐ {location.averageRating.toFixed(1)}
                <div className="text-[11px] text-slate-400 dark:text-slate-500">
                  {location.totalRatings} reviews
                </div>
              </div>
            ) : (
              <span className="text-xs text-slate-400">No reviews yet</span>
            )}
          </div>

          <p className="text-sm text-slate-500 dark:text-slate-300">
            📍 {location.address}
          </p>
          {distance !== null ? (
            <p className="text-xs text-blue-500">{distance} mi away</p>
          ) : null}
          {location.description ? (
            <p className="text-sm text-slate-600 dark:text-slate-300">
              {location.description}
            </p>
          ) : null}

          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              onClick={() =>
                window.open(
                  `https://maps.google.com/?q=${location.lat},${location.lng}`,
                  "_blank"
                )
              }
              className="inline-flex items-center gap-2 rounded-full border border-slate-200 px-3 py-1 text-xs font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:border-slate-700 dark:text-slate-200 dark:hover:bg-slate-700"
            >
              Open in Maps
            </button>
            <button
              type="button"
              onClick={handleShare}
              className="inline-flex items-center gap-2 rounded-full border border-slate-200 px-3 py-1 text-xs font-semibold text-slate-600 transition-all duration-200 hover:bg-slate-100 dark:border-slate-700 dark:text-slate-200 dark:hover:bg-slate-700"
            >
              Share
            </button>
          </div>
        </section>

        {location.features?.length ? (
          <section className="rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
            <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
              Features & Amenities
            </h3>
            <div className="mt-3 grid grid-cols-2 gap-2 text-xs text-slate-600 dark:text-slate-300">
              {location.features.map((feature) => (
                <span
                  key={feature}
                  className="rounded-full border border-slate-200 px-3 py-1 text-center dark:border-slate-700"
                >
                  {featureLabels[feature] || feature}
                </span>
              ))}
            </div>
          </section>
        ) : null}

        <section className="rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
            Pet-friendly scores
          </h3>
          <div className="mt-3 space-y-3 text-xs text-slate-600 dark:text-slate-300">
            {[
              { label: "Space", value: ratingStats.space },
              { label: "Safety", value: ratingStats.safety },
              { label: "Cleanliness", value: ratingStats.cleanliness },
            ].map((item) => (
              <div key={item.label} className="flex items-center gap-3">
                <span className="w-20 font-semibold">{item.label}</span>
                <div className="h-2 flex-1 rounded-full bg-slate-200 dark:bg-slate-700">
                  <div
                    className="h-2 rounded-full bg-gradient-to-r from-purple-500 to-pink-500"
                    style={{ width: `${(item.value / 5) * 100}%` }}
                  />
                </div>
                <span className="w-8 text-right text-slate-500 dark:text-slate-400">
                  {item.value ? item.value.toFixed(1) : "-"}
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
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
              Photos ({allPhotos.length})
            </h3>
          </div>
          {allPhotos.length === 0 ? (
            <p className="mt-2 text-xs text-slate-400">No photos yet.</p>
          ) : (
            <div className="mt-3 grid grid-cols-3 gap-2">
              {allPhotos.map((photo, idx) => (
                <button
                  key={photo}
                  type="button"
                  onClick={() => setLightboxIndex(idx)}
                  className="aspect-square overflow-hidden rounded-xl"
                >
                  <LazyImage src={photo} alt="Location" className="h-full w-full" />
                </button>
              ))}
            </div>
          )}
        </section>

        <section className="rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
              Reviews ({reviews.length})
            </h3>
            {!userReview ? (
              <button
                type="button"
                onClick={openReview}
                className="rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-3 py-1 text-xs font-semibold text-white"
              >
                Write a Review ⭐
              </button>
            ) : null}
          </div>
          <div className="mt-3 space-y-4">
            {reviews.length === 0 ? (
              <p className="text-xs text-slate-400">No reviews yet.</p>
            ) : (
              reviews.map((review) => (
                <div key={review.id} className="space-y-2">
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
                  {review.tags?.length ? (
                    <div className="flex flex-wrap gap-2 text-xs text-slate-500 dark:text-slate-400">
                      {review.tags.map((tag) => (
                        <span key={tag} className="rounded-full border border-slate-200 px-2 py-0.5 dark:border-slate-700">
                          {tag}
                        </span>
                      ))}
                    </div>
                  ) : null}
                  {review.photos?.length ? (
                    <div className="grid grid-cols-3 gap-2">
                      {review.photos.map((photo) => (
                        <div key={photo} className="aspect-square overflow-hidden rounded-lg">
                          <LazyImage src={photo} alt="Review" className="h-full w-full" />
                        </div>
                      ))}
                    </div>
                  ) : null}
                </div>
              ))
            )}
          </div>
        </section>

        <section className="rounded-2xl bg-white p-4 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
          <h3 className="text-sm font-semibold text-slate-900 dark:text-white">
            Meetups at this place
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

      <div className="fixed bottom-0 left-0 right-0 z-20 border-t border-slate-200 bg-white/90 px-4 py-3 backdrop-blur dark:border-slate-800 dark:bg-slate-900/90">
        <div className="mx-auto w-full max-w-md">
          {userReview ? (
            <button
              type="button"
              disabled
              className="w-full rounded-full border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-400 dark:border-slate-700"
            >
              You reviewed this place ⭐ {userReview.rating}/5
            </button>
          ) : (
            <button
              type="button"
              onClick={openReview}
              className="w-full rounded-full bg-gradient-to-r from-purple-500 to-pink-500 px-4 py-2 text-sm font-semibold text-white shadow-[0_12px_25px_-15px_rgba(168,85,247,0.8)] transition-all duration-200 hover:scale-[1.01]"
            >
              Write a Review ⭐
            </button>
          )}
        </div>
      </div>

      <LocationRatingModal
        open={ratingOpen}
        onClose={() => setRatingOpen(false)}
        locationId={location.id}
        locationName={location.name}
        locationAddress={location.address}
        onSubmitted={() => refreshData(location.id, user?.uid)}
      />

      {lightboxIndex !== null ? (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/90 px-4"
          onClick={() => setLightboxIndex(null)}
        >
          <button
            type="button"
            onClick={(event) => {
              event.stopPropagation();
              setLightboxIndex(null);
            }}
            className="absolute right-4 top-4 text-2xl text-white"
          >
            ✕
          </button>
          <button
            type="button"
            onClick={(event) => {
              event.stopPropagation();
              if (lightboxIndex === null) return;
              setLightboxIndex(
                lightboxIndex === 0 ? allPhotos.length - 1 : lightboxIndex - 1
              );
            }}
            className="absolute left-4 text-2xl text-white"
          >
            ‹
          </button>
          <img
            src={allPhotos[lightboxIndex]}
            alt="Location"
            className="max-h-[80vh] w-full max-w-md rounded-xl object-contain"
            onClick={(event) => event.stopPropagation()}
          />
          <button
            type="button"
            onClick={(event) => {
              event.stopPropagation();
              if (lightboxIndex === null) return;
              setLightboxIndex(
                lightboxIndex === allPhotos.length - 1 ? 0 : lightboxIndex + 1
              );
            }}
            className="absolute right-4 text-2xl text-white"
          >
            ›
          </button>
        </div>
      ) : null}
    </div>
  );
}
