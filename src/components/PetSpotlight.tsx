import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { PawPrint } from "lucide-react";
import { getPopularPosts, type Post } from "../services/posts";
import { optimizeCloudinaryUrl } from "../utils/cloudinaryUrl";

type PetSpotlightProps = {
  limitCount?: number;
};

const truncate = (value: string, max = 8) =>
  value.length > max ? `${value.slice(0, max)}…` : value;

const SEEN_KEY = "petnote_seen_spotlights";

const getSeenPosts = (): string[] => {
  try {
    return JSON.parse(localStorage.getItem(SEEN_KEY) || "[]");
  } catch {
    return [];
  }
};

const markAsSeen = (postId: string) => {
  const seen = getSeenPosts();
  if (!seen.includes(postId)) {
    seen.push(postId);
    if (seen.length > 100) seen.shift();
    localStorage.setItem(SEEN_KEY, JSON.stringify(seen));
  }
};

const PawAvatar = ({
  src,
  name,
  seen,
}: {
  src?: string | null;
  name: string;
  seen: boolean;
}) => {
  const [broken, setBroken] = useState(false);
  return (
    <div
      className="relative h-[62px] w-[62px] active:scale-95 transition-transform"
      style={{ clipPath: "url(#chubbyHeartClip)" }}
    >
      <div
        className={`absolute inset-0 ${
          seen
            ? "bg-gray-200 dark:bg-gray-700"
            : // Two stops, matching the brand gradient used by every other
              // accent surface. The third, orange stop appeared nowhere else
              // in the app and read as a different product.
              "bg-gradient-to-br from-purple-500 to-pink-500"
        }`}
      />
      <div className="absolute inset-[2.5px] bg-white dark:bg-gray-900" />
      <div className="absolute inset-[4px]">
        {src && !broken ? (
          <img
            src={optimizeCloudinaryUrl(src, "spotlight")}
            alt={name}
            // A heart-shaped clip around the browser's broken-image glyph
            // reads as "this app is broken", not "this pet has no photo".
            onError={() => setBroken(true)}
            className={`h-full w-full object-cover ${
              seen ? "opacity-70" : ""
            }`}
          />
        ) : (
          // A pet with no photo gets a flat brand tint. It used to get the
          // same gradient as the ring, which inside a heart-shaped clip read
          // as a broken image rather than an empty one.
          <div
            className={`flex h-full w-full items-center justify-center bg-purple-100 text-purple-500 dark:bg-purple-500/20 dark:text-purple-200 ${
              seen ? "opacity-70" : ""
            }`}
          >
            <PawPrint size={22} strokeWidth={1.8} aria-hidden="true" />
          </div>
        )}
      </div>
    </div>
  );
};

export function PetSpotlight({ limitCount = 10 }: PetSpotlightProps) {
  const navigate = useNavigate();
  const [posts, setPosts] = useState<Post[]>([]);
  const [loading, setLoading] = useState(true);
  const [seenPosts, setSeenPosts] = useState<string[]>([]);

  useEffect(() => {
    let ignore = false;

    const load = async () => {
      setLoading(true);
      try {
        const recent = await getPopularPosts(limitCount, 24);
        if (!ignore && recent.length < limitCount) {
          const fallback = await getPopularPosts(limitCount, 24 * 7);
          if (!ignore) setPosts(fallback);
        } else if (!ignore) {
          setPosts(recent);
        }
      } catch {
        // Decorative, and above the content somebody came for. A failure here
        // renders nothing at all — see the note on the early return below.
        if (!ignore) setPosts([]);
      } finally {
        if (!ignore) setLoading(false);
      }
    };

    void load();
    return () => {
      ignore = true;
    };
  }, [limitCount]);

  useEffect(() => {
    setSeenPosts(getSeenPosts());
  }, []);

  const sortedPosts = useMemo(() => {
    /*
     * One entry per pet, because the section is called "Popular Pets".
     *
     * The query returns popular *posts*, and a pet with four of the five
     * most-liked posts filled the strip with its own name four times — which
     * reads either as a bug or as the app having exactly one pet. Keeping the
     * first occurrence keeps the ordering the query gave us; it just stops the
     * same subject appearing twice under a heading that promises subjects.
     *
     * Posts with no pet fall back to the author for their label, so they are
     * de-duplicated by author for the same reason.
     */
    const seen = new Set<string>();
    const list: Post[] = [];
    for (const post of posts) {
      const subject = post.petId || post.authorId;
      if (!subject || seen.has(subject)) continue;
      seen.add(subject);
      list.push(post);
      if (list.length >= limitCount) break;
    }
    return list.sort((a, b) => {
      const aSeen = seenPosts.includes(a.id);
      const bSeen = seenPosts.includes(b.id);
      if (aSeen && !bSeen) return 1;
      if (!aSeen && bSeen) return -1;
      return 0;
    });
  }, [posts, limitCount, seenPosts]);

  /*
   * Nothing to show means nothing rendered — no heading, no card, no space.
   *
   * This module sits above the feed, so anything it occupies is space the
   * photos somebody came for do not get. It used to render a full-width card
   * whose only content was "Share your pet to get featured!", which is a
   * pseudo-empty state: it reads as a prompt the product is making, when in
   * fact the popularity query returned nothing or failed. On a feed that
   * already has posts that is simply wrong — the user is not short of
   * content, the decoration is.
   *
   * The loading state is included in this. A skeleton that resolves to
   * nothing has still taken the space and still moved the feed, so there is
   * no skeleton: the strip appears if and when it has pets. An empty result
   * and a failed query are deliberately the same silent outcome, because
   * neither is something to ask the reader to act on.
   */
  if (loading || sortedPosts.length === 0) return null;

  return (
    /*
     * A strip, not a card. Card chrome around a row of avatars put a border
     * and a shadow between the reader and the first photo for no gain; the
     * heading plus the row is the whole module.
     */
    <section aria-label="Popular pets">
      <h2 className="text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
        Popular Pets
      </h2>
      <svg width="0" height="0" className="absolute">
        <defs>
          <clipPath id="chubbyHeartClip" clipPathUnits="objectBoundingBox">
            <path d="M0.5,0.93 C0.1,0.7 0,0.45 0,0.3 C0,0.12 0.15,0 0.35,0 C0.48,0 0.5,0.15 0.5,0.25 C0.5,0.15 0.52,0 0.65,0 C0.85,0 1,0.12 1,0.3 C1,0.45 0.9,0.7 0.5,0.93 Z" />
          </clipPath>
        </defs>
      </svg>

      <div className="mt-2 flex gap-3 overflow-x-auto overflow-y-visible pb-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
          {sortedPosts.map((post) => {
            const isSeen = seenPosts.includes(post.id);
            const mediaUrl =
              post.media && post.media.length > 0
                ? post.media[0].thumbUrl || post.media[0].url
                : post.mediaUrl;

            return (
              <button
                key={post.id}
                type="button"
                onClick={() => {
                  markAsSeen(post.id);
                  setSeenPosts((prev) =>
                    prev.includes(post.id) ? prev : [...prev, post.id]
                  );
                  navigate(`/post/${post.id}`);
                }}
                className="flex flex-shrink-0 flex-col items-center"
                style={{ width: 72 }}
              >
                <PawAvatar
                  src={mediaUrl ? optimizeCloudinaryUrl(mediaUrl, "spotlight") : mediaUrl}
                  name={post.petName || post.authorName || "Pet"}
                  seen={isSeen}
                />
                <span
                  className={`mt-1.5 w-full truncate text-center text-[11px] font-medium ${
                    isSeen
                      ? "text-gray-400"
                      : "text-gray-700 dark:text-gray-300"
                  }`}
                >
                  {/* Section is "Popular Pets" — label with the pet, not the
                      owner's username (legacy posts without petName fall
                      back to the author). */}
                  {truncate(post.petName || post.authorName || "Pet")}
                </span>
              </button>
            );
          })}
      </div>
    </section>
  );
}
