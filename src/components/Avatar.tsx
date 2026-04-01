import { useEffect, useMemo, useState } from "react";
import { optimizeCloudinaryUrl } from "../utils/cloudinaryUrl";

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
  const optimizedSrc = useMemo(
    () => (src ? optimizeCloudinaryUrl(src, "avatar") : undefined),
    [src]
  );

  const fallbackUrl = useMemo(
    () =>
      userId
        ? `https://api.dicebear.com/7.x/thumbs/svg?seed=${userId}`
        : `https://api.dicebear.com/7.x/thumbs/svg?seed=${encodeURIComponent(
            alt
          )}`,
    [alt, userId]
  );
  const [imgSrc, setImgSrc] = useState(optimizedSrc || fallbackUrl);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setImgSrc(optimizedSrc || fallbackUrl);
  }, [optimizedSrc, fallbackUrl]);

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
