import "./setup";
import { afterEach, describe, expect, it } from "vitest";
import {
  PRODUCTION_CLOUDINARY,
  cloudinaryAccount,
  cloudinaryAccountFor,
  runningProjectId,
} from "../platform";
import { deleteCloudinaryAssetsCallable, getCloudinaryUploadSignature } from "../media";
import { TRUSTED_MEDIA_URL_HOSTS, validateTrustedHttpsUrl } from "../shared";
import { callAs, clearRateLimits, errorCodeOf } from "./helpers";

// Which Cloudinary account a deployment uses is chosen by the Firebase project
// it runs in. Two things are being held here, and they are different claims:
//
//   - production gets exactly what it had before this table existed;
//   - the test project never gets production's account — with no account of
//     its own it refuses, and it refuses in all three places that use one
//     (signing an upload, deleting an upload, accepting a media URL).

const PRODUCTION_BEFORE = { cloudName: "dgeunvmmn", folder: "petnote" };

describe("which account a project gets", () => {
  it("production keeps the values it had", () => {
    expect(cloudinaryAccountFor("petnote-a9dac")).toEqual(PRODUCTION_BEFORE);
    expect(PRODUCTION_CLOUDINARY).toEqual(PRODUCTION_BEFORE);
  });

  it("the emulator and CI keep the values they had", () => {
    expect(cloudinaryAccountFor("petnote-test")).toEqual(PRODUCTION_BEFORE);
  });

  it("the test project has no account until one is configured, and is never given production's", () => {
    const account = cloudinaryAccountFor("petnote-devtest");
    expect(account).toBeNull();
    expect(account?.cloudName).not.toBe(PRODUCTION_BEFORE.cloudName);
  });

  it("an unknown or missing project gets nothing, not production", () => {
    for (const id of [undefined, "", "petnote-devtest-2", "petnote", "constructor", "__proto__", "toString"]) {
      expect(cloudinaryAccountFor(id)).toBeNull();
    }
  });

  it("this test process runs as the emulator project", () => {
    expect(runningProjectId()).toBe("petnote-test");
    expect(cloudinaryAccount()).toEqual(PRODUCTION_BEFORE);
  });
});

describe("the test project, without an account, refuses everywhere an account is used", () => {
  const saved = process.env.GCLOUD_PROJECT;
  afterEach(() => {
    process.env.GCLOUD_PROJECT = saved;
  });

  it("does not resolve an account", async () => {
    process.env.GCLOUD_PROJECT = "petnote-devtest";
    expect(await errorCodeOf(() => cloudinaryAccount())).toBe("failed-precondition");
  });

  it("does not sign an upload", async () => {
    await clearRateLimits();
    process.env.GCLOUD_PROJECT = "petnote-devtest";
    const code = await errorCodeOf(() =>
      callAs(getCloudinaryUploadSignature, "cloudinary-account-user", { resourceType: "image" })
    );
    expect(code).toBe("failed-precondition");
  });

  it("does not delete an upload", async () => {
    await clearRateLimits();
    process.env.GCLOUD_PROJECT = "petnote-devtest";
    const code = await errorCodeOf(() =>
      callAs(deleteCloudinaryAssetsCallable, "cloudinary-account-user", {
        assets: [{ publicId: "petnote/users/cloudinary-account-user/x", resourceType: "image" }],
      })
    );
    expect(code).toBe("failed-precondition");
  });

  it("does not accept a production media URL", async () => {
    process.env.GCLOUD_PROJECT = "petnote-devtest";
    const production =
      "https://res.cloudinary.com/dgeunvmmn/image/upload/v1700000000/petnote/users/u/photo.jpg";
    const code = await errorCodeOf(() =>
      validateTrustedHttpsUrl(production, "mediaUrl", TRUSTED_MEDIA_URL_HOSTS)
    );
    expect(code).toBe("failed-precondition");
  });

  it("while production still accepts its own URL", async () => {
    process.env.GCLOUD_PROJECT = "petnote-a9dac";
    const production =
      "https://res.cloudinary.com/dgeunvmmn/image/upload/v1700000000/petnote/users/u/photo.jpg";
    expect(validateTrustedHttpsUrl(production, "mediaUrl", TRUSTED_MEDIA_URL_HOSTS)).toBe(production);
  });
});
