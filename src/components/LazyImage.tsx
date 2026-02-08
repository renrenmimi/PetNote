import { useEffect, useRef, useState } from "react";

interface LazyImageProps {
  src: string;
  alt?: string;
  className?: string;
  imgClassName?: string;
  style?: React.CSSProperties;
  onClick?: () => void;
}

export default function LazyImage({
  src,
  alt = "",
  className = "",
  imgClassName = "",
  style,
  onClick,
}: LazyImageProps) {
  const [loaded, setLoaded] = useState(false);
  const [inView, setInView] = useState(false);
  const [error, setError] = useState(false);
  const imgRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
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
  }, []);

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
          src={src}
          alt={alt}
          className={`h-full w-full ${imgClassName || "object-cover"} transition-opacity duration-300 ${
            loaded ? "opacity-100" : "opacity-0"
          }`}
          style={style}
          onLoad={() => setLoaded(true)}
          onError={() => setError(true)}
          loading="lazy"
        />
      ) : null}
    </div>
  );
}
