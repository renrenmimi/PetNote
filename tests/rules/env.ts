import { readFileSync } from "node:fs";
import {
  initializeTestEnvironment,
  type RulesTestEnvironment,
  type RulesTestContext,
} from "@firebase/rules-unit-testing";

const FIRESTORE_PORT = Number(
  process.env.FIRESTORE_EMULATOR_HOST?.split(":")[1] ?? 8088
);

export async function makeTestEnv(): Promise<RulesTestEnvironment> {
  return initializeTestEnvironment({
    projectId: "petnote-rules-test",
    firestore: {
      rules: readFileSync("firestore.rules", "utf8"),
      host: "127.0.0.1",
      port: FIRESTORE_PORT,
    },
  });
}

/**
 * A signed-in context whose token carries no custom claims at all.
 *
 * This is what every ordinary user actually looks like: onAdminStateWritten
 * only ever sets {banned: true} or {admin: true}, so a normal account's token
 * has neither key. Rules that read `request.auth.token.banned` without first
 * checking `'banned' in request.auth.token` fail the whole expression for these
 * users rather than returning false, which is what broke likes and bookmarks
 * for everyone until #149. Tests that pass a `banned: false` claim would never
 * have caught it, so nothing here does that.
 */
export const plainUser = (env: RulesTestEnvironment, uid: string): RulesTestContext =>
  env.authenticatedContext(uid);

/** A signed-in context carrying the banned custom claim. */
export const bannedUser = (env: RulesTestEnvironment, uid: string): RulesTestContext =>
  env.authenticatedContext(uid, { banned: true });

/** A signed-in context carrying the admin custom claim. */
export const adminUser = (env: RulesTestEnvironment, uid: string): RulesTestContext =>
  env.authenticatedContext(uid, { admin: true });
