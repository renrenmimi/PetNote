import "./setup";
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Transaction } from "firebase-admin/firestore";
import { admin, db } from "../platform";
import { joinMeetupCallable } from "../meetups";
import { createPetCallable } from "../pets";
import { CONTENTION_RETRY } from "../shared";
import { callAs, clearRateLimits, errorCodeOf, purge } from "./helpers";

// Everyone joining one meetup reads and writes the same document. Two hundred
// at once on the test project had two joins aborted for contention, past the
// client library's own retries, and those two were told "internal". A
// contended join now waits and tries again. Running it again is safe: someone
// already on the roster is answered as joined.

const ORGANIZER = "jc-organizer";
const JOINER = "jc-joiner";
const MEETUP_ID = "jc-meetup";
const MEETUP = `meetups/${MEETUP_ID}`;

const aborted = () =>
  Object.assign(new Error("10 ABORTED: Aborted due to cross-transaction contention."), { code: 10 });

/** Thrown inside the transaction to roll it back; the library does not retry it. */
class GiveUp extends Error {}

/**
 * The first `failures` transactions that read the meetup end as though the
 * client library had given up on them for contention. Others, such as the
 * rate limit's, run as they are.
 */
function joinsContended(failures: number) {
  const real = db.runTransaction.bind(db);
  let joins = 0;
  vi.spyOn(db, "runTransaction").mockImplementation((async (
    update: (t: Transaction) => Promise<unknown>,
    options?: Parameters<typeof db.runTransaction>[1]
  ) => {
    try {
      return await real(async (t) => {
        let readsTheMeetup = false;
        const get = t.get.bind(t) as (ref: unknown) => unknown;
        (t as unknown as { get: (ref: { path?: string }) => unknown }).get = (ref) => {
          if (ref?.path === MEETUP) readsTheMeetup = true;
          return get(ref);
        };
        const result = await update(t);
        if (readsTheMeetup && joins < failures) {
          joins += 1;
          throw new GiveUp();
        }
        return result;
      }, options);
    } catch (error) {
      if (error instanceof GiveUp) throw aborted();
      throw error;
    }
  }) as typeof db.runTransaction);
  return { aborted: () => joins };
}

let petId = "";
const saved = { ...CONTENTION_RETRY };

beforeEach(async () => {
  Object.assign(CONTENTION_RETRY, { baseMs: 1, capMs: 2 });
  await purge(MEETUP, `users/${ORGANIZER}`, `users/${JOINER}`);
  await clearRateLimits();
  await db.doc(`users/${ORGANIZER}`).set({ displayName: ORGANIZER });
  await db.doc(`users/${JOINER}`).set({ displayName: JOINER });
  await db.doc(MEETUP).set({
    organizerId: ORGANIZER,
    title: "A crowded walk",
    status: "upcoming",
    participantCount: 1,
    requirements: { maxPets: 20 },
    date: admin.firestore.Timestamp.fromMillis(Date.now() + 86_400_000),
  });
  const pet = await callAs<{ id?: string; petId?: string }>(createPetCallable, JOINER, { name: "Crowd", species: "dog", gender: "male" });
  petId = (pet.id ?? pet.petId) as string;
});
afterEach(() => {
  vi.restoreAllMocks();
  Object.assign(CONTENTION_RETRY, saved);
});
afterAll(async () => {
  await purge(MEETUP, `users/${ORGANIZER}`, `users/${JOINER}`, `pets/${petId}`);
  await clearRateLimits();
});

describe("joining a meetup a crowd is joining", () => {
  it("waits and tries again when the join is aborted for contention, and joins once", async () => {
    const contention = joinsContended(3);

    const result = await callAs<{ success: boolean }>(joinMeetupCallable, JOINER, { meetupId: MEETUP_ID, petId });

    expect(result.success).toBe(true);
    expect(contention.aborted()).toBe(3);
    expect((await db.doc(`${MEETUP}/participants/${JOINER}`).get()).exists).toBe(true);
    expect((await db.doc(MEETUP).get()).get("participantCount")).toBe(2);
  });

  it("still fails when every try is contended", async () => {
    const contention = joinsContended(Number.POSITIVE_INFINITY);

    const code = await errorCodeOf(() => callAs(joinMeetupCallable, JOINER, { meetupId: MEETUP_ID, petId }));

    expect(code).toContain("ABORTED");
    expect(contention.aborted()).toBe(CONTENTION_RETRY.retries + 1);
    expect((await db.doc(`${MEETUP}/participants/${JOINER}`).get()).exists).toBe(false);
    expect((await db.doc(MEETUP).get()).get("participantCount")).toBe(1);
  });
});
