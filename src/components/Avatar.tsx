import { useEffect, useMemo, useState } from "react";

interface AvatarProps {
  src?: string;
  alt?: string;
  size?: number;
  className?: string;
  userId?: string;
}

export default function Avatar({
  src,
  alt = "User",
  size = 40,
  className = "",
  userId,
}: AvatarProps) {
  const fallbackUrl = useMemo(
    () =>
      userId
        ? `https://api.dicebear.com/7.x/thumbs/svg?seed=${userId}`
        : `https://api.dicebear.com/7.x/thumbs/svg?seed=${encodeURIComponent(
            alt
          )}`,
    [alt, userId]
  );
  const [imgSrc, setImgSrc] = useState(src || fallbackUrl);

  useEffect(() => {
    setImgSrc(src || fallbackUrl);
  }, [src, fallbackUrl]);

  return (
    <img
      src={imgSrc}
      alt={alt}
      width={size}
      height={size}
      className={`rounded-full object-cover ${className}`}
      onError={() => setImgSrc(fallbackUrl)}
    />
  );
}
