import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Navbar } from "../components/Navbar";
import { EmptyState } from "../components/EmptyState";
import FilterTag from "../components/FilterTag";
import { useAuth } from "../hooks/useAuth";
import { Calendar, MapPin, PawPrint, User } from "lucide-react";
import {
  getMyMeetups,
  getNearbyMeetups,
  getThisWeekMeetups,
  getUpcomingMeetups,
  type Meetup,
} from "../services/meetups";
import { optimizeCloudinaryUrl } from "../utils/cloudinaryUrl";
import { calculateDistance } from "../services/location";
import { getLocation, type Location } from "../services/locations";

type FilterKey = "nearby" | "week" | "mine" | "dogs" | "cats" | "other";

const filters: Array<{ key: FilterKey; label: string; Icon: typeof MapPin; color: string }> = [
  { key: "nearby", label: "Nearby", Icon: MapPin, color: "text-blue-500" },
  { key: "week", label: "This Week", Icon: Calendar, color: "text-green-500" },
  { key: "mine", label: "My Meetups", Icon: User, color: "text-purple-500" },
  { key: "dogs", label: "Dogs", Icon: PawPrint, color: "text-amber-600" },
  { key: "cats", label: "Cats", Icon: PawPrint, color: "text-orange-500" },
  { key: "other", label: "Other", Icon: PawPrint, color: "text-slate-500" },
];

const formatDate = (value: unknown) => {
  if (!value) return "";
  const date =
    value instanceof Date
      ? value
      : typeof value === "object" &&
        value !== null &&
        "toDate" in value &&
        typeof (value as { toDate: () => Date }).toDate === "function"
      ? (value as { toDate: () => Date }).toDate()
      : null;
  if (!date) return "";
  return date.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
};

const formatTime = (value: unknown) => {
  if (!value) return "";
  const date =
    value instanceof Date
      ? value
      : typeof value === "object" &&
        value !== null &&
        "toDate" in value &&
        typeof (value as { toDate: () => Date }).toDate === "function"
      ? (value as { toDate: () => Date }).toDate()
      : null;
  if (!date) return "";
  return date.toLocaleTimeString(undefined, {
    hour: "numeric",
    minute: "2-digit",
  });
};

const statusStyles: Record<string, string> = {
  upcoming: "bg-emerald-500 text-white",
  ongoing: "bg-blue-500 text-white animate-pulse",
  completed: "bg-slate-300 text-slate-700",
  cancelled: "bg-red-500 text-white",
};

export function Meetups() {
  const navigate = useNavigate();
  const { user, profile } = useAuth();
  const [activeFilter, setActiveFilter] = useState<FilterKey>("nearby");
  const [meetups, setMeetups] = useState<Meetup[]>([]);
  const [loading, setLoading] = useState(true);
  const [locationRatings, setLocationRatings] = useState<
    Record<string, Location>
  >({});

  const userLocation = profile?.location;

  useEffect(() => {
    let ignore = false;
    const load = async () => {
      setLoading(true);
      let data: Meetup[] = [];
      if (activeFilter === "nearby") {
        if (userLocation) {
          data = await getNearbyMeetups(
            userLocation.lat,
            userLocation.lng,
            50
          );
        } else {
          const upcoming = await getUpcomingMeetups(50);
          data = upcoming.meetups;
        }
      } else if (activeFilter === "week") {
        data = await getThisWeekMeetups();
      } else if (activeFilter === "mine") {
        data = user ? await getMyMeetups(user.uid) : [];
      } else {
        const upcoming = await getUpcomingMeetups(50);
        data = upcoming.meetups.filter((meetup) => {
          const type = meetup.requirements.petType;
          if (activeFilter === "dogs") {
            return type === "dog" || type === "any_dog";
          }
          if (activeFilter === "cats") {
            return type === "cat" || type === "any_cat";
          }
          if (activeFilter === "other") {
            return type !== "dog" && type !== "any_dog" && type !== "cat" && type !== "any_cat";
          }
          return true;
        });
      }
      if (!ignore) {
        setMeetups(data);
        setLoading(false);
      }
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [activeFilter, user, userLocation]);

  useEffect(() => {
    let ignore = false;
    const loadRatings = async () => {
      const ids = Array.from(
        new Set(meetups.map((meetup) => meetup.locationId).filter(Boolean))
      ) as string[];
      if (ids.length === 0) {
        setLocationRatings({});
        return;
      }
      const entries = await Promise.all(
        ids.map(async (id) => [id, await getLocation(id)] as const)
      );
      if (!ignore) {
        const map: Record<string, Location> = {};
        entries.forEach(([id, data]) => {
          if (data) map[id] = data;
        });
        setLocationRatings(map);
      }
    };
    void loadRatings();
    return () => {
      ignore = true;
    };
  }, [meetups]);

  const cards = useMemo(() => {
    if (!userLocation) return meetups;
    return meetups.map((meetup) => {
      const distance = calculateDistance(
        userLocation.lat,
        userLocation.lng,
        meetup.location.lat,
        meetup.location.lng
      );
      return { meetup, distance };
    });
  }, [meetups, userLocation]);

  return (
    <div className="min-h-screen bg-slate-50 pb-20 dark:bg-slate-900">
      <Navbar />

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4">
        <div className="flex items-center justify-between">
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">
            Meetups 🐾
          </h1>
          <button
            type="button"
            onClick={() => navigate("/create-meetup")}
            className="flex h-9 w-9 items-center justify-center rounded-full bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-md transition-all duration-200 hover:scale-105"
          >
            +
          </button>
        </div>

        <div className="-mx-4 overflow-x-auto py-2 px-4 scrollbar-hide">
          <div className="flex gap-2">
            {filters.map((filter) => {
              const active = activeFilter === filter.key;
              const Icon = filter.Icon;
              return (
                <FilterTag
                  key={filter.key}
                  icon={<Icon size={14} className={active ? "text-white" : filter.color} />}
                  label={filter.label}
                  active={active}
                  onClick={() => setActiveFilter(filter.key)}
                />
              );
            })}
          </div>
        </div>

        {loading ? (
          <div className="rounded-2xl bg-white p-6 text-center text-sm text-slate-400 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] dark:bg-slate-800 dark:text-slate-500">
            Loading meetups...
          </div>
        ) : meetups.length === 0 ? (
          <EmptyState
            icon="📍"
            title="No meetups nearby"
            description="Be the first to organize one!"
            actionText="Create Meetup"
            onAction={() => navigate("/create-meetup")}
          />
        ) : (
          <div className="space-y-3">
            {cards.map((item) => {
              const meetup = "meetup" in item ? item.meetup : (item as Meetup);
              const distance =
                "distance" in item ? item.distance : undefined;
              const maxPets = meetup.requirements.maxPets;
              const visibility = meetup.locationVisibility ?? "participants_only";
              const cityLabel = [meetup.location.city, meetup.location.state]
                .filter(Boolean)
                .join(", ");
              const canSeeFullAddress =
                visibility === "everyone" || (user && meetup.organizerId === user.uid);
              const locationLabel = canSeeFullAddress
                ? meetup.location.name
                : cityLabel || "City hidden";
              const rating = meetup.locationId
                ? locationRatings[meetup.locationId]
                : null;
              const progress =
                maxPets > 0
                  ? Math.min(
                      100,
                      Math.round(
                        (meetup.participantCount / maxPets) * 100
                      )
                    )
                  : 0;

              return (
                <button
                  key={meetup.id}
                  type="button"
                  onClick={() => navigate(`/meetups/${meetup.id}`)}
                  className="flex w-full gap-3 rounded-xl bg-white p-3 text-left shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:-translate-y-0.5 dark:bg-slate-800 dark:ring-slate-700"
                >
                  {meetup.coverImage ? (
                    <img
                      src={optimizeCloudinaryUrl(meetup.coverImage, "small")}
                      alt={meetup.title}
                      className="h-20 w-20 rounded-xl object-cover"
                    />
                  ) : (
                    <div className="flex h-20 w-20 items-center justify-center rounded-xl bg-gradient-to-br from-purple-400 to-pink-400 text-2xl text-white">
                      🐾
                    </div>
                  )}
                  <div className="flex-1 space-y-1">
                    <div className="flex items-center justify-between">
                      <p className="text-sm font-semibold text-slate-900 dark:text-white">
                        {meetup.title}
                      </p>
                      <span
                        className={`rounded-full px-2 py-0.5 text-[10px] font-semibold ${
                          statusStyles[meetup.status] || "bg-slate-200 text-slate-700"
                        }`}
                      >
                        {meetup.status}
                      </span>
                    </div>
                    <p className="text-xs text-slate-500 dark:text-slate-300">
                      📅 {formatDate(meetup.date)} · {formatTime(meetup.date)}
                    </p>
                    <p className="text-xs text-slate-500 dark:text-slate-300">
                      📍 {locationLabel}
                    </p>
                    {rating && rating.totalRatings > 0 ? (
                      <p className="text-[11px] font-semibold text-amber-500">
                        ⭐ {rating.averageRating.toFixed(1)}
                      </p>
                    ) : null}
                    {distance !== undefined ? (
                      <span className="inline-flex rounded-full bg-blue-50 px-2 py-0.5 text-[10px] font-semibold text-blue-600 dark:bg-blue-500/10 dark:text-blue-200">
                        📍 {distance} mi
                      </span>
                    ) : null}
                    <div className="mt-2">
                      <div className="flex items-center justify-between text-[10px] text-slate-400 dark:text-slate-500">
                        <span>
                          👥 {meetup.participantCount}
                          {maxPets > 0 ? `/${maxPets}` : ""}
                        </span>
                      </div>
                      {maxPets > 0 ? (
                        <div className="mt-1 h-1.5 w-full rounded-full bg-slate-100 dark:bg-slate-700">
                          <div
                            className="h-1.5 rounded-full bg-gradient-to-r from-purple-500 to-pink-500"
                            style={{ width: `${progress}%` }}
                          />
                        </div>
                      ) : null}
                    </div>
                  </div>
                </button>
              );
            })}
          </div>
        )}
      </main>

    </div>
  );
}
