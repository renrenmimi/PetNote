import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

/**
 * Nothing may claim "nearby", or show a distance, without a centre to measure
 * from.
 *
 * This is a source guard rather than a render test, and deliberately so. Both
 * pages assemble these strings from several branches, and mounting them means
 * mocking Firestore, geo services, the auth context and a router — at which
 * point the test is mostly mock and would still only cover the one branch the
 * mocks happened to select. What actually went wrong was simpler than any of
 * that: the word was a literal in a constant, printed unconditionally, while
 * the query it described silently fell back to "most recent" or "upcoming".
 *
 * So: every occurrence of the claim in these two files must sit next to the
 * condition that licenses it. If someone adds `label: "Nearby"` back into a
 * constant array, this fails and says why.
 */

const FILES = ["src/pages/Places.tsx", "src/pages/Meetups.tsx"];

/** The names of the things that decide whether a centre is actually known. */
const GUARDS = ["activeCenter", "hasArea", "locationStatus"];

function claimLines(file: string) {
  const lines = readFileSync(file, "utf8").split("\n");
  return lines
    .map((line, index) => ({
      line,
      number: index + 1,
      // A ternary legitimately puts the condition on one line and the string
      // on the next, so the guard is looked for in a small window rather
      // than on the same line.
      window: lines.slice(Math.max(0, index - 2), index + 2).join(" "),
    }))
    .filter(({ line }) => /["'`][^"'`]*\bNearby\b/.test(line))
    // Comments explain the rule; they do not print anything.
    .filter(({ line }) => !/^\s*(\*|\/\/|\/\*)/.test(line.trim()));
}

describe("nearby claims", () => {
  it.each(FILES)("%s only says Nearby next to a guard", (file) => {
    const offenders = claimLines(file).filter(
      ({ window }) => !GUARDS.some((guard) => window.includes(guard))
    );
    expect(
      offenders.map(({ number, line }) => `${file}:${number} ${line.trim()}`)
    ).toEqual([]);
  });

  it.each(FILES)("%s still says it somewhere, when licensed", (file) => {
    // The other half of the rule: dropping the word entirely would pass the
    // test above and would also be wrong, because a person who has set an
    // area should see that the list is scoped to it.
    expect(claimLines(file).length).toBeGreaterThan(0);
  });

  it("Places computes distance only from a centre", () => {
    const source = readFileSync("src/pages/Places.tsx", "utf8");
    const call = source.indexOf("calculateDistance(");
    expect(call).toBeGreaterThan(-1);
    // The ternary that guards it is on the preceding lines.
    expect(source.slice(Math.max(0, call - 200), call)).toContain(
      "activeCenter"
    );
  });
});
