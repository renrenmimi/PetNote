export type ImageSize =
  | "thumbnail"
  | "small"
  | "medium"
  | "large"
  | "full"
  | "avatar"
  | "spotlight";

const sizeConfig: Record<ImageSize, string> = {
  thumbnail: "w_300,h_300,c_fill,q_auto,f_auto",
  small: "w_400,q_auto,f_auto",
  medium: "w_800,q_auto,f_auto",
  large: "w_1200,q_auto,f_auto",
  full: "q_auto,f_auto",
  avatar: "w_100,h_100,c_fill,q_auto,f_auto",
  spotlight: "w_200,h_200,c_fill,q_auto,f_auto",
};

const hasTransformationSegment = (segment: string): boolean => {
  if (!segment) return false;
  if (/^v\d+$/i.test(segment)) return false;
  if (/^\d+$/.test(segment)) return false;
  return segment.includes(",") || segment.includes("_");
};

export function optimizeCloudinaryUrl(
  url: string,
  size: ImageSize = "medium"
): string {
  if (!url) return url;
  if (!url.includes("res.cloudinary.com")) return url;
  if (url.includes("/video/upload/")) return url;

  const marker = "/image/upload/";
  const markerIndex = url.indexOf(marker);
  if (markerIndex === -1) return url;

  const prefix = url.slice(0, markerIndex + marker.length);
  const suffix = url.slice(markerIndex + marker.length);
  if (!suffix) return url;

  const firstSegment = suffix.split("/")[0] ?? "";
  if (hasTransformationSegment(firstSegment)) return url;
  if (!/^v\d+/i.test(firstSegment) && !/^\d+/.test(firstSegment)) return url;

  return `${prefix}${sizeConfig[size]}/${suffix}`;
}

export function getVideoThumbnail(
  url: string,
  size: ImageSize = "thumbnail"
): string {
  if (!url) return url;
  if (!url.includes("res.cloudinary.com")) return url;
  if (!url.includes("/video/upload/")) return url;

  const marker = "/video/upload/";
  const markerIndex = url.indexOf(marker);
  if (markerIndex === -1) return url;

  const prefix = url.slice(0, markerIndex + marker.length);
  const suffix = url.slice(markerIndex + marker.length);
  if (!suffix) return url;

  const firstSegment = suffix.split("/")[0] ?? "";
  const hasTransforms = hasTransformationSegment(firstSegment);
  const transformedSuffix = hasTransforms
    ? suffix
    : `${sizeConfig[size]}/${suffix}`;

  return `${prefix}so_0,${transformedSuffix}`.replace(/\.[^/.]+(\?.*)?$/, ".jpg");
}

