import { afterAll, beforeAll, beforeEach, describe, it } from "vitest";
import {
  assertFails,
  assertSucceeds,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc, deleteDoc, updateDoc } from "firebase/firestore";
import { adminUser, makeTestEnv, plainUser } from "./env";

// A meetup's public document deliberately carries only a coarse location. The
// exact address and coordinates live in meetups/{id}/private, and getting that
// boundary wrong hands a stranger the place and time a specific person will be
// standing with their pet.

let env: RulesTestEnvironment;
const ORGANIZER = "organizer";
const PARTICIPANT = "participant";
const STRANGER = "stranger";
const ADMIN = "root-admin";
const MEETUP = "meetup-1";
const PRIVATE_DOC = `meetups/${MEETUP}/private/location`;

beforeAll(async () => {
  env = await makeTestEnv();
});
afterAll(async () => {
  await env.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, "meetups", MEETUP), {
      title: "Park day",
      organizerId: ORGANIZER,
      locationVisibility: "participants_only",
      status: "upcoming",
      participantCount: 2,
    });
    await setDoc(doc(db, PRIVATE_DOC), {
      address: "12 Private Lane, Boston MA",
      lat: 42.3601,
      lng: -71.0589,
    });
    await setDoc(doc(db, `meetups/${MEETUP}/participants/${ORGANIZER}`), {
      userId: ORGANIZER,
      counted: true,
    });
    await setDoc(doc(db, `meetups/${MEETUP}/participants/${PARTICIPANT}`), {
      userId: PARTICIPANT,
      counted: true,
    });
    await setDoc(doc(db, `users/${ADMIN}/admin/state`), { role: "admin" });
  });
});

describe("meetup private address", () => {
  it("lets the organizer read it", async () => {
    await assertSucceeds(
      getDoc(doc(plainUser(env, ORGANIZER).firestore(), PRIVATE_DOC))
    );
  });

  it("lets a confirmed participant read it", async () => {
    await assertSucceeds(
      getDoc(doc(plainUser(env, PARTICIPANT).firestore(), PRIVATE_DOC))
    );
  });

  it("lets an admin read it", async () => {
    await assertSucceeds(
      getDoc(doc(adminUser(env, ADMIN).firestore(), PRIVATE_DOC))
    );
  });

  it("refuses a signed-in user who has not joined", async () => {
    await assertFails(
      getDoc(doc(plainUser(env, STRANGER).firestore(), PRIVATE_DOC))
    );
  });

  it("refuses an unauthenticated reader", async () => {
    await assertFails(
      getDoc(doc(env.unauthenticatedContext().firestore(), PRIVATE_DOC))
    );
  });

  it("refuses a user who left the meetup", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await deleteDoc(
        doc(ctx.firestore(), `meetups/${MEETUP}/participants/${PARTICIPANT}`)
      );
    });
    await assertFails(
      getDoc(doc(plainUser(env, PARTICIPANT).firestore(), PRIVATE_DOC))
    );
  });

  it("refuses every client write, including the organizer's", async () => {
    // The address is written by the meetup callables with the Admin SDK. A
    // client write here could silently move the meetup for everyone.
    const organizerDb = plainUser(env, ORGANIZER).firestore();
    await assertFails(updateDoc(doc(organizerDb, PRIVATE_DOC), { address: "elsewhere" }));
    await assertFails(
      setDoc(doc(organizerDb, `meetups/${MEETUP}/private/extra`), { address: "x" })
    );
  });

  it("lets the organizer delete it but not a participant", async () => {
    await assertFails(
      deleteDoc(doc(plainUser(env, PARTICIPANT).firestore(), PRIVATE_DOC))
    );
    await assertSucceeds(
      deleteDoc(doc(plainUser(env, ORGANIZER).firestore(), PRIVATE_DOC))
    );
  });
});

describe("meetup participants", () => {
  it("refuses a client to add itself as a participant", async () => {
    // Joining goes through joinMeetup, which checks capacity and requirements
    // and stamps counted:true in the same transaction as participantCount.
    // A direct write would skip all of it and desync the count.
    await assertFails(
      setDoc(
        doc(plainUser(env, STRANGER).firestore(), `meetups/${MEETUP}/participants/${STRANGER}`),
        { userId: STRANGER, counted: true }
      )
    );
  });

  it("lets a participant remove themselves and the organizer remove anyone", async () => {
    await assertSucceeds(
      deleteDoc(
        doc(plainUser(env, PARTICIPANT).firestore(), `meetups/${MEETUP}/participants/${PARTICIPANT}`)
      )
    );
    await assertSucceeds(
      deleteDoc(
        doc(plainUser(env, ORGANIZER).firestore(), `meetups/${MEETUP}/participants/${ORGANIZER}`)
      )
    );
  });

  it("refuses a stranger to remove someone else", async () => {
    await assertFails(
      deleteDoc(
        doc(plainUser(env, STRANGER).firestore(), `meetups/${MEETUP}/participants/${PARTICIPANT}`)
      )
    );
  });

  it("refuses every client write to the meetup document itself", async () => {
    await assertFails(
      updateDoc(doc(plainUser(env, ORGANIZER).firestore(), "meetups", MEETUP), {
        participantCount: 999,
      })
    );
  });
});
