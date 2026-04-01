import { useEffect, useMemo, useRef, useState, type TouchEvent } from "react";
import type { MediaItem } from "../services/posts";
import LazyImage from "./LazyImage";

type MediaCarouselProps = {
  media?: MediaItem[];
  mediaUrl?: string;
  mediaType?: "image" | "video";
  onDoubleTap?: () => void;
  imageSize?: "medium" | "large";
};

const formatDuration = (value?: number) => {
  if (value === undefined) return "";
  const minutes = Math.floor(value / 60);
  const seconds = Math.floor(value % 60);
  return `${minutes}:${seconds.toString().padStart(2, "0")}`;
};

export function MediaCarousel({
  media,
  mediaUrl,
  mediaType,
  onDoubleTap,
  imageSize = "medium",
}: MediaCarouselProps) {
  const items = useMemo<MediaItem[]>(() => {
    if (media && media.length > 0) return media;
    if (mediaUrl) {
      return [
        {
          url: mediaUrl,
          type: mediaType || "image",
        },
      ];
    }
    return [];
  }, [media, mediaUrl, mediaType]);

  const [index, setIndex] = useState(0);
  const [dragX, setDragX] = useState(0);
  const [dragging, setDragging] = useState(false);
  const startXRef = useRef(0);
  const startYRef = useRef(0);
  const lastTapRef = useRef<{ time: number; x: number; y: number } | null>(
    null
  );
  const videoRefs = useRef<Array<HTMLVideoElement | null>>([]);
  const [videoPlaying, setVideoPlaying] = useState<Record<number, boolean>>({});
  const [durations, setDurations] = useState<Record<number, number>>({});

  const hasMultiple = items.length > 1;

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setIndex(0);
    setDragX(0);
  }, [items.length]);

  useEffect(() => {
    videoRefs.current.forEach((video, idx) => {
      if (!video) return;
      if (idx !== index) {
        video.pause();
        setVideoPlaying((prev) => ({ ...prev, [idx]: false }));
      }
    });
  }, [index]);

  const handleTouchStart = (event: TouchEvent<HTMLDivElement>) => {
    const touch = event.touches[0];
    startXRef.current = touch.clientX;
    startYRef.current = touch.clientY;
    if (hasMultiple) {
      setDragging(true);
    }
  };

  const handleTouchMove = (event: TouchEvent<HTMLDivElement>) => {
    if (!dragging) return;
    const currentX = event.touches[0].clientX;
    setDragX(currentX - startXRef.current);
  };

  const handleTouchEnd = (event: TouchEvent<HTMLDivElement>) => {
    const touch = event.changedTouches[0];
    const deltaX = touch.clientX - startXRef.current;
    const deltaY = touch.clientY - startYRef.current;
    const moved = Math.hypot(deltaX, deltaY);

    if (dragging) {
      if (dragX > 50 && index > 0) {
        setIndex((prev) => prev - 1);
      } else if (dragX < -50 && index < items.length - 1) {
        setIndex((prev) => prev + 1);
      }
    }

    if (moved < 10 && onDoubleTap) {
      const now = Date.now();
      const lastTap = lastTapRef.current;
      if (
        lastTap &&
        now - lastTap.time < 300 &&
        Math.hypot(touch.clientX - lastTap.x, touch.clientY - lastTap.y) < 30
      ) {
        onDoubleTap();
        lastTapRef.current = null;
      } else {
        lastTapRef.current = { time: now, x: touch.clientX, y: touch.clientY };
      }
    }

    setDragX(0);
    setDragging(false);
  };

  const handlePrev = () => {
    setIndex((prev) => Math.max(0, prev - 1));
  };

  const handleNext = () => {
    setIndex((prev) => Math.min(items.length - 1, prev + 1));
  };

  const toggleVideo = (idx: number) => {
    const node = videoRefs.current[idx];
    if (!node) return;
    if (node.paused) {
      void node.play();
      setVideoPlaying((prev) => ({ ...prev, [idx]: true }));
    } else {
      node.pause();
      setVideoPlaying((prev) => ({ ...prev, [idx]: false }));
    }
  };

  if (items.length === 0) {
    return <div className="aspect-video w-full bg-slate-100 dark:bg-slate-800" />;
  }

  return (
    <div
      className="relative w-full overflow-hidden rounded-lg bg-slate-100 dark:bg-slate-800"
      onTouchStart={handleTouchStart}
      onTouchMove={handleTouchMove}
      onTouchEnd={handleTouchEnd}
      onTouchCancel={handleTouchEnd}
    >
      <div
        className="flex w-full"
        style={{
          transform: `translateX(calc(${-index * 100}% + ${dragX}px))`,
          transition: dragging ? "none" : "transform 300ms ease-in-out",
        }}
      >
        {items.map((item, idx) => {
          const isVideo = item.type === "video";
          const isActive = idx === index;
          const playing = videoPlaying[idx] ?? true;
          return (
            <div
              key={`${item.url}-${idx}`}
              className="flex w-full flex-shrink-0 items-center justify-center bg-black/5 dark:bg-white/5"
              onDoubleClick={onDoubleTap}
            >
              {isVideo ? (
                <div className="relative w-full">
                  <video
                    ref={(node) => {
                      videoRefs.current[idx] = node;
                    }}
                    src={item.url}
                    muted
                    autoPlay={isActive}
                    loop
                    playsInline
                    className="max-h-[500px] w-full object-contain"
                    onClick={() => toggleVideo(idx)}
                    onPlay={() =>
                      setVideoPlaying((prev) => ({ ...prev, [idx]: true }))
                    }
                    onPause={() =>
                      setVideoPlaying((prev) => ({ ...prev, [idx]: false }))
                    }
                    onLoadedMetadata={(event) => {
                      const duration = event.currentTarget.duration;
                      setDurations((prev) => ({
                        ...prev,
                        [idx]: duration,
                      }));
                    }}
                  />
                  <button
                    type="button"
                    onClick={() => toggleVideo(idx)}
                    className="absolute inset-0 flex items-center justify-center"
                    aria-label="Toggle video"
                  >
                    <span className="rounded-full bg-black/50 px-3 py-2 text-sm text-white">
                      {playing ? "⏸" : "▶"}
                    </span>
                  </button>
                  {durations[idx] !== undefined ? (
                    <span className="absolute bottom-3 right-3 rounded-full bg-black/60 px-2 py-0.5 text-xs font-semibold text-white">
                      {formatDuration(durations[idx])}
                    </span>
                  ) : null}
                </div>
              ) : (
                Math.abs(idx - index) <= 1 ? (
                  <LazyImage
                    src={item.url}
                    alt="Post media"
                    className="max-h-[500px] w-full"
                    imgClassName="object-contain"
                    cloudinarySize={imageSize}
                  />
                ) : (
                  <div className="max-h-[500px] w-full bg-slate-200 dark:bg-slate-700" />
                )
              )}
            </div>
          );
        })}
      </div>

      {hasMultiple ? (
        <>
          <div className="pointer-events-none absolute bottom-3 left-1/2 -translate-x-1/2 rounded-full bg-black/40 px-2 py-1">
            <div className="flex items-center gap-1.5">
              {items.map((_, dotIdx) => (
                <span
                  key={dotIdx}
                  className={`h-1.5 w-1.5 rounded-full ${
                    dotIdx === index ? "bg-white" : "bg-white/50"
                  }`}
                />
              ))}
            </div>
          </div>
          <button
            type="button"
            onClick={handlePrev}
            className="absolute left-3 top-1/2 hidden -translate-y-1/2 items-center justify-center rounded-full bg-white/70 px-2 py-1 text-sm text-slate-700 shadow sm:flex dark:bg-slate-700/70 dark:text-white"
            aria-label="Previous"
          >
            ‹
          </button>
          <button
            type="button"
            onClick={handleNext}
            className="absolute right-3 top-1/2 hidden -translate-y-1/2 items-center justify-center rounded-full bg-white/70 px-2 py-1 text-sm text-slate-700 shadow sm:flex dark:bg-slate-700/70 dark:text-white"
            aria-label="Next"
          >
            ›
          </button>
        </>
      ) : null}
    </div>
  );
}
