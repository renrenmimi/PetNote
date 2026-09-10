import { useEffect, useRef, useState } from "react";
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
  const imgRef = useRef<HTMLDivElement>(null);
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
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoaded(false);
    setError(false);
  }, [resolvedSrc]);

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
        <div className="absolute inset-0 flex items-center justify-center bg-gray-200 text-gray-400 dark:bg-gray-700 dark:text-gray-500">
          🖼️
        </div>
      ) : null}

      {inView && !error ? (
        <img
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
