import { describe, expect, it } from "vitest";
import { decideAssetReclaim, type PublishAttempt } from "../mediaReclaim";
import type { UploadedAsset } from "../../services/cloudinary";

/**
 * The rule: uploaded media is deleted only when the attempt is *known* never to
 * have been handed to a publish call. Everything else keeps it.
 *
 * Every "kept" case below is a path the composer actually takes after a publish
 * that may have committed. Deleting there leaves a live post pointing at images
 * that no longer exist, and nothing can undo that — unlike an orphaned asset,
 * which a future reference model or reaper can collect.
 *
 * The decision asks the server nothing. That is the point of the last round's
 * finding: `published: false` is document existence at one instant, and a
 * publish paused before its write reports exactly that and then commits.
 */

const asset = (publicId: string): UploadedAsset => ({
  url: `https://res.cloudinary.com/dgeunvmmn/image/upload/${publicId}.jpg`,
  publicId,
  resourceType: "image",
  type: "image",
});

const attempt = (over: Partial<PublishAttempt> = {}): PublishAttempt => ({
  operationId: "op-abcdef123456",
  handedOff: true,
  assets: [asset("petnote/users/alice/one")],
  ...over,
});

describe("an attempt that reached the publish call", () => {
  it("keeps its media", () => {
    // Whether it committed is unknowable from here, so it is treated as
    // committed. This covers the response-lost case and the still-in-flight
    // case with one rule instead of two guesses.
    expect(decideAssetReclaim(attempt())).toEqual({
      reclaim: false,
      reason: "automatic-reclaim-disabled",
    });
  });

  it("keeps its media even with an operation id available to check", () => {
    // Having an operation id changes nothing: the only answer the server can
    // give is "no post *yet*", and a paused publish gives that answer and then
    // writes. Reproduced in the emulator against the real publish handler,
    // which is why the decision no longer consults it.
    expect(
      decideAssetReclaim(attempt({ operationId: "op-still-in-flight-1" }))
    ).toEqual({ reclaim: false, reason: "automatic-reclaim-disabled" });
  });

  it("keeps its media when there is no operation id at all", () => {
    expect(decideAssetReclaim(attempt({ operationId: null }))).toEqual({
      reclaim: false,
      reason: "automatic-reclaim-disabled",
    });
  });
});

describe("an attempt whose handoff was never recorded", () => {
  it("keeps its media, because a missing marker is not a 'no'", () => {
    // An older draft, or one whose marker write failed while the publish went
    // ahead anyway. `handedOff === true` was the old test, and it read absence
    // as false — asserting something the data does not say.
    expect(decideAssetReclaim(attempt({ handedOff: undefined }))).toEqual({
      reclaim: false,
      reason: "automatic-reclaim-disabled",
    });
  });
});

describe("an attempt recorded as never handed off", () => {
  it("still does not reclaim, because the record itself can be stale", () => {
    // The path this closes: assets are saved into the draft with an explicit
    // `handedOff: false`, then the update to `true` fails — sessionStorage
    // full or blocked — and publishing continues anyway and commits. After a
    // reload the restored draft still says false, and a policy that trusts it
    // deletes the images of a published post.
    //
    // Three-state handling fixed "the field is missing". It cannot fix "the
    // field is present and out of date": an in-memory true does not correct a
    // false already written to the browser. Since the composer cannot
    // guarantee it recorded the handoff before publishing, no persisted value
    // can license a deletion.
    const assets = [
      asset("petnote/users/alice/one"),
      asset("petnote/users/alice/two"),
    ];

    expect(decideAssetReclaim(attempt({ handedOff: false, assets }))).toEqual({
      reclaim: false,
      reason: "automatic-reclaim-disabled",
    });
  });

  it("does nothing when there are no assets", () => {
    expect(
      decideAssetReclaim(attempt({ handedOff: false, assets: [] }))
    ).toEqual({ reclaim: false, reason: "no-assets" });
  });

  it("never reclaims, whatever the attempt looks like", () => {
    // The invariant the composer now depends on. Enumerated rather than
    // reasoned about, so that re-opening automatic reclaim has to come past a
    // test that says it is closed.
    const assets = [asset("petnote/users/alice/one")];
    for (const handedOff of [true, false, undefined]) {
      for (const operationId of ["op-abcdef123456", null]) {
        expect(
          decideAssetReclaim({ handedOff, operationId, assets }).reclaim,
          `handedOff=${String(handedOff)} operationId=${String(operationId)}`
        ).toBe(false);
      }
    }
  });
});
