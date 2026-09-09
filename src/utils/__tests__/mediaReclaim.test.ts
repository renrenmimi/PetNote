import { describe, expect, it, vi } from "vitest";
import { decideAssetReclaim, type PublishAttempt } from "../mediaReclaim";
import type { UploadedAsset } from "../../services/cloudinary";

/**
 * The rule: media whose publish outcome is not known to have failed is never
 * deleted.
 *
 * Every case below is a path the composer actually takes after a publish that
 * committed but whose response was lost. Deleting the assets on any of them
 * leaves a live post pointing at images that no longer exist, and there is no
 * way back from that — unlike keeping an orphan asset, which a future reaper
 * can clean up.
 *
 * No CDN and no network: the server lookup is injected.
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

describe("media whose publish committed but whose response was lost", () => {
  it("is kept when the server says the operation published", async () => {
    const lookup = vi.fn().mockResolvedValue({ published: true });

    const decision = await decideAssetReclaim(attempt(), lookup);

    expect(decision).toEqual({ reclaim: false, reason: "published" });
    expect(lookup).toHaveBeenCalledWith("op-abcdef123456");
  });

  it("is kept when the outcome cannot be checked because the lookup failed", async () => {
    // Fails closed. An unanswered question is not a "no".
    const lookup = vi.fn().mockRejectedValue(new Error("offline"));

    const decision = await decideAssetReclaim(attempt(), lookup);

    expect(decision).toEqual({ reclaim: false, reason: "outcome-unknown" });
  });

  it("is kept when there is no operation id to check with", async () => {
    // An attempt from before idempotency shipped, or a draft that lost it.
    // Nothing can establish that the post does not exist, so nothing is deleted.
    const lookup = vi.fn();

    const decision = await decideAssetReclaim(
      attempt({ operationId: null }),
      lookup
    );

    expect(decision).toEqual({ reclaim: false, reason: "outcome-unknown" });
    expect(lookup).not.toHaveBeenCalled();
  });
});

describe("media that is genuinely unreferenced", () => {
  it("is reclaimed when the server says the operation did not publish", async () => {
    const assets = [asset("petnote/users/alice/one"), asset("petnote/users/alice/two")];
    const lookup = vi.fn().mockResolvedValue({ published: false });

    const decision = await decideAssetReclaim(attempt({ assets }), lookup);

    expect(decision).toEqual({ reclaim: true, assets });
  });

  it("is reclaimed without asking when it never reached the backend", async () => {
    // The upload phase failed before any publish call, so no post can exist.
    const assets = [asset("petnote/users/alice/one")];
    const lookup = vi.fn();

    const decision = await decideAssetReclaim(
      attempt({ handedOff: false, assets }),
      lookup
    );

    expect(decision).toEqual({ reclaim: true, assets });
    expect(lookup).not.toHaveBeenCalled();
  });

  it("does nothing when there are no assets at all", async () => {
    const lookup = vi.fn();

    const decision = await decideAssetReclaim(attempt({ assets: [] }), lookup);

    expect(decision).toEqual({ reclaim: false, reason: "no-assets" });
    expect(lookup).not.toHaveBeenCalled();
  });
});
