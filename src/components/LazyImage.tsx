import { useEffect, useRef, useState } from "react";
import { ImageOff } from "lucide-react";
import {
  optimizeCloudinaryUrl,
  type ImageSize,
} from "../utils/cloudinaryUrl";

interface LazyImageProps {
  src: string;
  alt?: string;
  className?: string;
  imgClassName?: string;
  style?: React.CSSProperties;
  onClick?: () => void;
  cloudinarySize?: ImageSize;
  /**
   * Render the <img> immediately, eagerly, at high fetch priority.
   *
   * The default path keeps the element out of the DOM until an
   * IntersectionObserver fires, which means the browser's preload scanner
   * cannot see it at all. For an above-the-fold image that is the whole
   * problem: a mobile Lighthouse trace measured 2,324 ms of LCP *discovery*
   * delay against 45 ms of actual transfer. Lazy-loading the largest
   * contentful paint is the one case where lazy is strictly worse.
   *
   * Set this on the leading image of a list and nothing else — making
   * everything eager would just move the contention.
   */
  priority?: boolean;
}

export default function LazyImage({
  src,
  alt = "",
  className = "",
  imgClassName = "",
  style,
  onClick,
  cloudinarySize,
  priority = false,
}: LazyImageProps) {
  const [loaded, setLoaded] = useState(false);
  const [inView, setInView] = useState(priority);
  const [error, setError] = useState(false);
  // Bumped to re-request the same URL after a failure. Without it the error
  // state was terminal: one flaky response and that image stayed a grey box
  // with a picture glyph for as long as the card was mounted, with no way to
  // ask again short of leaving the page.
  const [attempt, setAttempt] = useState(0);
  // Whether there is room for words. A grid of failed thumbnails all saying
  // "Tap to retry" shouts louder than the content around it; at that size the
  // icon alone is the honest amount of emphasis, with the label carried by
  // the accessible name instead.
  const [roomForLabel, setRoomForLabel] = useState(true);
  const imgRef = useRef<HTMLDivElement>(null);
  const imgElRef = useRef<HTMLImageElement | null>(null);
  const resolvedSrc = cloudinarySize
    ? optimizeCloudinaryUrl(src, cloudinarySize)
    : src;

  useEffect(() => {
    // A priority image is already in the DOM; observing it would only cost a
    // callback to reach a conclusion it was mounted with.
    if (priority) return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) {
          setInView(true);
          observer.disconnect();
        }
      },
      { rootMargin: "200px" }
    );
    if (imgRef.current) observer.observe(imgRef.current);
    return () => observer.disconnect();
  }, [priority]);

  useEffect(() => {
    const node = imgRef.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    const measure = new ResizeObserver(([entry]) => {
      const { width, height } = entry.contentRect;
      setRoomForLabel(width >= 180 && height >= 120);
    });
    measure.observe(node);
    return () => measure.disconnect();
  }, []);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoaded(false);
    setError(false);

    /*
     * Ask the element, rather than waiting to be told.
     *
     * `loaded` used to be set only by `onLoad`, and an <img> can finish
     * before React attaches that handler — served from the HTTP cache, or
     * decoded straight away. The event then never fires, `loaded` stays
     * false, and because the <img> is `opacity-0` until it flips, a photo
     * that downloaded perfectly well is rendered invisible under a pulsing
     * grey placeholder, permanently.
     *
     * Seen on the device and nowhere else: a 464pt slab of pulsing gray-700
     * still there 25 s after launch, while the same feed in a browser was
     * fine. A diagnostic build settled it — `img[2] complete=true
     * natural=800x1003` sitting in the same wrapper as a live placeholder.
     * Repeated launches had warmed the WebView cache, which is exactly the
     * condition that loses the event.
     *
     * `naturalWidth` distinguishes the two ways an image can be complete:
     * decoded, or finished and broken.
     */
    const node = imgElRef.current;
    if (node?.complete) {
      if (node.naturalWidth > 0) setLoaded(true);
      else setError(true);
    }
  }, [resolvedSrc, attempt, inView]);

  return (
    <div
      ref={imgRef}
      className={`relative overflow-hidden ${className}`}
      style={style}
      onClick={onClick}
    >
      {!loaded && !error ? (
        <div className="absolute inset-0 bg-gray-200 dark:bg-gray-700 animate-pulse" />
      ) : null}

      {error ? (
        <button
          type="button"
          onClick={(event) => {
            // The wrapper may carry an onClick that opens the post; retrying
            // a broken image should not also navigate.
            event.stopPropagation();
            setError(false);
            setLoaded(false);
            setAttempt((value) => value + 1);
          }}
          className="absolute inset-0 flex flex-col items-center justify-center gap-1.5 bg-slate-100 text-slate-400 transition-colors hover:text-slate-500 dark:bg-slate-800 dark:text-slate-500"
          aria-label={alt ? `Retry loading ${alt}` : "Retry loading image"}
        >
          <ImageOff
            size={roomForLabel ? 26 : 18}
            strokeWidth={1.6}
            aria-hidden="true"
          />
          {roomForLabel ? (
            <span className="text-xs font-medium">Tap to retry</span>
          ) : null}
        </button>
      ) : null}

      {inView && !error ? (
        <img
          // The attempt counter is part of the key, not the URL: changing the
          // src would defeat the HTTP cache for every successful reload too.
          key={attempt}
          ref={imgElRef}
          src={resolvedSrc}
          alt={alt}
          className={`h-full w-full ${imgClassName || "object-cover"} transition-opacity duration-300 ${
            loaded ? "opacity-100" : "opacity-0"
          }`}
          style={style}
          onLoad={() => setLoaded(true)}
          onError={() => setError(true)}
          loading={priority ? "eager" : "lazy"}
          fetchPriority={priority ? "high" : undefined}
        />
      ) : null}
    </div>
  );
}
