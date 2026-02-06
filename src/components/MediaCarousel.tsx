import { useEffect, useMemo, useRef, useState, type TouchEvent } from "react";
import type { MediaItem } from "../services/posts";

type MediaCarouselProps = {
  media?: MediaItem[];
  mediaUrl?: string;
  mediaType?: "image" | "video";
  onDoubleTap?: () => void;
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
  const videoRefs = useRef<Array<HTMLVideoElement | null>>([]);
  const [videoPlaying, setVideoPlaying] = useState<Record<number, boolean>>({});
  const [durations, setDurations] = useState<Record<number, number>>({});

  const hasMultiple = items.length > 1;

  useEffect(() => {
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
    if (!hasMultiple) return;
    startXRef.current = event.touches[0].clientX;
    setDragging(true);
  };

  const handleTouchMove = (event: TouchEvent<HTMLDivElement>) => {
    if (!dragging) return;
    const currentX = event.touches[0].clientX;
    setDragX(currentX - startXRef.current);
  };

  const handleTouchEnd = () => {
    if (!dragging) return;
    if (dragX > 50 && index > 0) {
      setIndex((prev) => prev - 1);
    } else if (dragX < -50 && index < items.length - 1) {
      setIndex((prev) => prev + 1);
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
    return <div className="aspect-video w-full bg-slate-100" />;
  }

  return (
    <div
      className="relative w-full overflow-hidden rounded-lg bg-slate-100"
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
              className="flex w-full flex-shrink-0 items-center justify-center bg-black/5"
              onDoubleClick={isVideo ? undefined : onDoubleTap}
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
                <img
                  src={item.url}
                  alt="Post media"
                  className="max-h-[500px] w-full object-contain"
                />
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
            className="absolute left-3 top-1/2 hidden -translate-y-1/2 items-center justify-center rounded-full bg-white/70 px-2 py-1 text-sm text-slate-700 shadow sm:flex"
            aria-label="Previous"
          >
            ‹
          </button>
          <button
            type="button"
            onClick={handleNext}
            className="absolute right-3 top-1/2 hidden -translate-y-1/2 items-center justify-center rounded-full bg-white/70 px-2 py-1 text-sm text-slate-700 shadow sm:flex"
            aria-label="Next"
          >
            ›
          </button>
        </>
      ) : null}
    </div>
  );
}
