import { getUserProfile } from "../services/users";
import type { UserProfile } from "../services/users";

const userCache = new Map<string, { data: UserProfile; timestamp: number }>();
const CACHE_TTL = 5 * 60 * 1000;
const CACHE_MAX_ENTRIES = 500;

function setUserCacheEntry(userId: string, data: UserProfile): void {
  const now = Date.now();
  for (const [key, value] of userCache) {
    if (now - value.timestamp >= CACHE_TTL) {
      userCache.delete(key);
    }
  }
  while (userCache.size >= CACHE_MAX_ENTRIES) {
    const oldestKey = userCache.keys().next().value;
    if (!oldestKey) break;
    userCache.delete(oldestKey);
  }
  userCache.set(userId, { data, timestamp: now });
}

export async function getCachedUser(
  userId: string
): Promise<UserProfile | null> {
  const cached = userCache.get(userId);
  if (cached && Date.now() - cached.timestamp < CACHE_TTL) {
    return cached.data;
  }

  const profile = await getUserProfile(userId);
  if (profile) {
    setUserCacheEntry(userId, profile);
    return profile;
  }

  return null;
}
