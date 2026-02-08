import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { BottomNav } from "../components/BottomNav";
import { Navbar } from "../components/Navbar";
import { AddressAutocomplete } from "../components/AddressAutocomplete";
import { EmptyState } from "../components/EmptyState";
import LazyImage from "../components/LazyImage";
import FilterTag from "../components/FilterTag";
import { useAuth } from "../hooks/useAuth";
import { Coffee, Leaf, Mountain, PawPrint, ShoppingBag, Stethoscope, Trees, Waves } from "lucide-react";
import {
  getPlaces,
  searchPlaces,
  type Location,
  type PlaceCategory,
} from "../services/locations";
import { calculateDistance } from "../services/location";

const categoryEmoji: Record<PlaceCategory, string> = {
  dog_park: "🐕",
  hiking_trail: "🥾",
  beach: "🏖️",
  community_park: "🌳",
  cafe: "☕",
  green_space: "🌿",
  pet_store: "🏪",
  vet: "🏥",
  other: "📍",
};

const categoryLabels: Record<PlaceCategory, string> = {
  dog_park: "🐕 Dog Park",
  hiking_trail: "🥾 Hiking Trail",
  beach: "🏖️ Beach",
  community_park: "🌳 Community Park",
  cafe: "☕ Café",
  green_space: "🌿 Green Space",
  pet_store: "🏪 Pet Store",
  vet: "🏥 Vet",
  other: "📍 Other",
};

const categoryBadges: Record<PlaceCategory, string> = {
  dog_park: "bg-emerald-100 text-emerald-700",
  hiking_trail: "bg-amber-100 text-amber-700",
  beach: "bg-blue-100 text-blue-700",
  community_park: "bg-emerald-100 text-emerald-700",
  cafe: "bg-orange-100 text-orange-700",
  green_space: "bg-teal-100 text-teal-700",
  pet_store: "bg-purple-100 text-purple-700",
  vet: "bg-red-100 text-red-700",
  other: "bg-slate-100 text-slate-600",
};

const featureIcons: Record<string, string> = {
  off_leash: "🐕‍🦺",
  water_access: "💧",
  parking: "🅿️",
  restrooms: "🚽",
  seating: "🪑",
  fenced: "🏗️",
  shade: "🌳",
  lighting: "🌙",
  trails: "🏃",
  beach_access: "🏖️",
  food_nearby: "☕",
  waste_bags: "🗑️",
};

const sortOptions = [
  { key: "nearby", label: "Nearby" },
  { key: "top_rated", label: "Top Rated" },
  { key: "most_reviewed", label: "Most Reviewed" },
  { key: "newest", label: "Newest" },
] as const;

const categoryFilters: Array<{
  key: PlaceCategory | "all";
  label: string;
  Icon: typeof PawPrint;
  color: string;
}> = [
  { key: "all", label: "All", Icon: PawPrint, color: "text-purple-500" },
  { key: "dog_park", label: "Dog Parks", Icon: PawPrint, color: "text-green-500" },
  { key: "hiking_trail", label: "Hiking Trails", Icon: Mountain, color: "text-amber-700" },
  { key: "beach", label: "Beaches", Icon: Waves, color: "text-blue-500" },
  { key: "community_park", label: "Parks", Icon: Trees, color: "text-emerald-500" },
  { key: "cafe", label: "Cafés", Icon: Coffee, color: "text-orange-500" },
  { key: "green_space", label: "Green Spaces", Icon: Leaf, color: "text-teal-500" },
  { key: "pet_store", label: "Pet Stores", Icon: ShoppingBag, color: "text-purple-500" },
  { key: "vet", label: "Vets", Icon: Stethoscope, color: "text-red-500" },
];

export function Places() {
  const navigate = useNavigate();
  const { profile } = useAuth();
  const [category, setCategory] = useState<PlaceCategory | "all">("all");
  const [sortBy, setSortBy] = useState<
    "nearby" | "top_rated" | "most_reviewed" | "newest"
  >("nearby");
  const [places, setPlaces] = useState<Location[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(true);
  const [lastDoc, setLastDoc] = useState<any>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [searchCenter, setSearchCenter] = useState<{ lat: number; lng: number } | null>(
    null
  );
  const [searchMode, setSearchMode] = useState<"none" | "text" | "address">("none");
  const sentinelRef = useRef<HTMLDivElement | null>(null);

  const userLocation = profile?.location;
  const activeCenter = searchCenter ?? userLocation ?? null;

  const loadPlaces = async (reset = false) => {
    if (loadingMore || (!reset && loading)) return;
    setLoadingMore(!reset);
    setLoading(reset);
    const result = await getPlaces({
      category: category === "all" ? undefined : category,
      sortBy,
      userLat: activeCenter?.lat,
      userLng: activeCenter?.lng,
      limit: 10,
      lastDoc: reset ? undefined : lastDoc,
    });
    setPlaces((prev) => (reset ? result.places : [...prev, ...result.places]));
    setLastDoc(result.lastDoc);
    setHasMore(result.hasMore);
    setLoading(false);
    setLoadingMore(false);
  };

  useEffect(() => {
    if (searchQuery.trim() && !searchCenter) return;
    setSearchMode(searchCenter ? "address" : "none");
    setPlaces([]);
    setLastDoc(null);
    setHasMore(true);
    void loadPlaces(true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [category, sortBy, searchCenter?.lat, searchCenter?.lng, userLocation?.lat, userLocation?.lng]);

  useEffect(() => {
    if (!sentinelRef.current || !hasMore || searchMode !== "none") return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries[0].isIntersecting && hasMore && !loadingMore && !loading) {
          void loadPlaces(false);
        }
      },
      { threshold: 0.1 }
    );
    observer.observe(sentinelRef.current);
    return () => observer.disconnect();
  }, [hasMore, loadingMore, loading, searchMode]);

  useEffect(() => {
    if (!searchQuery.trim() || searchCenter) return;
    const handle = window.setTimeout(async () => {
      const results = await searchPlaces(searchQuery);
      setPlaces(results);
      setSearchMode("text");
      setHasMore(false);
    }, 300);
    return () => window.clearTimeout(handle);
  }, [searchQuery, searchCenter]);

  const placeRows = useMemo(() => {
    return places.map((place) => {
      const distance =
        activeCenter?.lat && activeCenter?.lng
          ? calculateDistance(activeCenter.lat, activeCenter.lng, place.lat, place.lng)
          : null;
      return { place, distance };
    });
  }, [places, activeCenter]);

  return (
    <div className="min-h-screen bg-slate-50 pb-20 dark:bg-slate-900">
      <Navbar />

      <main className="mx-auto w-full max-w-md space-y-4 px-4 py-4">
        <div className="flex items-center justify-between">
          <h1 className="text-base font-semibold text-slate-900 dark:text-white">
            📍 Places
          </h1>
          <button
            type="button"
            onClick={() => navigate("/places/add")}
            className="flex h-9 w-9 items-center justify-center rounded-full bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-md transition-all duration-200 hover:scale-105"
          >
            +
          </button>
        </div>

        <AddressAutocomplete
          value={searchQuery}
          onChange={(value, location) => {
            setSearchQuery(value);
            if (location) {
              setSearchCenter({ lat: location.lat, lng: location.lng });
            } else {
              setSearchCenter(null);
            }
          }}
          placeholder="Search pet-friendly places..."
        />

        <div className="-mx-4 overflow-x-auto py-2 px-4 scrollbar-hide">
          <div className="flex gap-2">
            {categoryFilters.map((option) => {
              const active = category === option.key;
              const Icon = option.Icon;
              return (
                <FilterTag
                  key={option.key}
                  icon={<Icon size={14} className={active ? "text-white" : option.color} />}
                  label={option.label}
                  active={active}
                  onClick={() => setCategory(option.key)}
                />
              );
            })}
          </div>
        </div>

        <div className="flex items-center justify-between text-xs text-slate-400">
          <span>Sort by</span>
          <div className="flex gap-2">
            {sortOptions.map((option) => (
              <button
                key={option.key}
                type="button"
                onClick={() => setSortBy(option.key)}
                className={`rounded-full px-2 py-1 text-[11px] font-semibold ${
                  sortBy === option.key
                    ? "bg-purple-100 text-purple-600"
                    : "text-slate-400 hover:text-slate-600 dark:text-slate-500"
                }`}
              >
                {option.label}
              </button>
            ))}
          </div>
        </div>

        {loading ? (
          <div className="rounded-2xl bg-white p-6 text-center text-sm text-slate-400 shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] dark:bg-slate-800 dark:text-slate-500">
            Loading places...
          </div>
        ) : places.length === 0 ? (
          <EmptyState
            icon="📍"
            title="No places found nearby"
            description="Be the first to recommend one!"
            actionText="Add a Place"
            onAction={() => navigate("/places/add")}
          />
        ) : (
          <div className="space-y-3">
            {placeRows.map(({ place, distance }) => {
              const badgeClass =
                categoryBadges[place.category] ?? "bg-slate-100 text-slate-600";
              const badgeLabel =
                categoryLabels[place.category] ?? categoryLabels.other;
              return (
                <button
                  key={place.id}
                  type="button"
                  onClick={() => navigate(`/location/${place.id}`)}
                  className="flex w-full gap-3 rounded-xl bg-white p-3 text-left shadow-[0_18px_40px_-28px_rgba(15,23,42,0.4)] ring-1 ring-slate-100 transition-all duration-200 hover:-translate-y-0.5 dark:bg-slate-800 dark:ring-slate-700"
                >
                  {place.photos?.[0] ? (
                    <LazyImage
                      src={place.photos[0]}
                      alt={place.name}
                      className="h-20 w-20 rounded-xl"
                    />
                  ) : (
                    <div className="flex h-20 w-20 items-center justify-center rounded-xl bg-gradient-to-br from-purple-400 to-pink-400 text-2xl text-white">
                      {categoryEmoji[place.category] || "📍"}
                    </div>
                  )}
                  <div className="flex-1 space-y-1">
                    <div className="flex items-center justify-between">
                      <p className="text-sm font-semibold text-slate-900 dark:text-white">
                        {place.name}
                      </p>
                      <span className={`rounded-full px-2 py-0.5 text-[10px] font-semibold ${badgeClass}`}>
                        {badgeLabel}
                      </span>
                    </div>
                    {place.totalRatings > 0 ? (
                      <p className="text-xs text-amber-500">
                        ⭐ {place.averageRating.toFixed(1)} ({place.totalRatings} reviews)
                      </p>
                    ) : (
                      <p className="text-xs text-slate-400">No reviews yet</p>
                    )}
                    {distance !== null ? (
                      <p className="text-xs text-blue-500">
                        📍 {distance} mi away
                      </p>
                    ) : null}
                    {place.features?.length ? (
                      <div className="flex flex-wrap gap-1 text-xs text-slate-400">
                        {place.features.slice(0, 4).map((feature) => (
                          <span key={feature}>{featureIcons[feature] || "🐾"}</span>
                        ))}
                      </div>
                    ) : null}
                  </div>
                </button>
              );
            })}
            {searchMode !== "none" ? null : (
              <div ref={sentinelRef} className="py-2 text-center text-xs text-slate-400">
                {loadingMore ? "Loading more..." : hasMore ? "" : "You've reached the end"}
              </div>
            )}
          </div>
        )}
      </main>

      <BottomNav />
    </div>
  );
}
