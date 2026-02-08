import { getUserProfile } from "../services/users";
import type { UserProfile } from "../services/users";

const userCache = new Map<string, { data: UserProfile; timestamp: number }>();
const CACHE_TTL = 5 * 60 * 1000;

export async function getCachedUser(
  userId: string
): Promise<UserProfile | null> {
  const cached = userCache.get(userId);
  if (cached && Date.now() - cached.timestamp < CACHE_TTL) {
    return cached.data;
  }

  const profile = await getUserProfile(userId);
  if (profile) {
    userCache.set(userId, { data: profile, timestamp: Date.now() });
    return profile;
  }

  return null;
}
