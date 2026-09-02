# Replacing the production test data

The live site currently shows a primary user named `666` and a first video that
is a screen recording of a browser inside a browser. Places and Meetups are
empty. The README screenshots show the same content. None of it is a code
defect, but it is the first thing any visitor sees.

This is the runbook for fixing that. **Steps 2 and 3 remove data and cannot be
undone.** Step 1 is not optional.

Everything here needs the `gcloud` CLI and a service account key, neither of
which is set up on this machine — that is why these are scripts for you to run
rather than something already done.

---

## Before you start

You need:

- `gcloud` installed and authenticated against the `petnote-a9dac` project
- a service account key at the repository root as `serviceAccountKey.json`
  (it is gitignored; generate one in Firebase Console → Project settings →
  Service accounts → Generate new private key)
- a Cloud Storage bucket you can write to, for the backup

Check whether any real users have signed up before you delete anything:

```
cd functions && GOOGLE_APPLICATION_CREDENTIALS=../serviceAccountKey.json \
  npx ts-node scripts/reset-production-data.ts --project=petnote-a9dac
```

That reports and exits without changing anything. If the list contains accounts
you recognise as real, pass their uids with `--keep=uid1,uid2` when you run the
delete step. It is a flag rather than something you edit in the file, so the
script you reviewed and the script you run are the same file.

---

## 1. Back up Firestore

```
gcloud firestore export gs://<your-bucket>/petnote-backup-$(date +%Y%m%d-%H%M) \
  --project=petnote-a9dac
```

Wait for it to finish and confirm the objects exist:

```
gsutil ls -r gs://<your-bucket>/petnote-backup-*
```

A Firestore export is the only way back. There is no undo on the next step.

Auth users are **not** included in a Firestore export. If you want those too:

```
firebase auth:export auth-backup.json --project petnote-a9dac
```

---

## 2. Clear the test data

Report first (again — it costs nothing and confirms you are pointed at the
right project):

```
cd functions && GOOGLE_APPLICATION_CREDENTIALS=../serviceAccountKey.json \
  npx ts-node scripts/reset-production-data.ts --project=petnote-a9dac
```

Then apply:

```
cd functions && GOOGLE_APPLICATION_CREDENTIALS=../serviceAccountKey.json \
  npx ts-node scripts/reset-production-data.ts --project=petnote-a9dac --confirm
```

The script refuses to run without `--project`, on purpose: naming the project is
the difference between clearing a scratch project and clearing production.

**Cloudinary is not touched.** Media uploaded by the deleted accounts stays
under `petnote/users/{uid}/`. Remove those in the Cloudinary console, or leave
them — they are unreachable once the posts are gone, they just cost storage.

---

## 3. Seed presentable content

```
cd functions && GOOGLE_APPLICATION_CREDENTIALS=../serviceAccountKey.json \
  npx ts-node scripts/seed-demo-content.ts --project=petnote-a9dac
```

This creates three complete accounts — profile, bio, city, one pet each, two or
three posts each — plus one place with a review and one meetup with all three
joined. Avatars are generated dicebear URLs, which are on the trusted avatar
host list, so profiles do not look empty.

The script prints a sign-in email and password for each account, once. It stores
them nowhere.

**Photos are deliberately not seeded.** Post media must be a `res.cloudinary.com`
URL — enforced by `TRUSTED_MEDIA_URL_HOSTS` in `functions/src/shared.ts` — and
inventing URLs would produce broken images. Sign in as each account and upload
through the app; that is also the only path that puts the assets under the right
`petnote/users/{uid}/` folder.

---

## 4. Reshoot the README screenshots

`docs/screenshot.jpg` is referenced by `README.md`. Retake it against the seeded
content, on a device width that matches how the app is actually used.

---

## Afterwards

Confirm the site looks right, then delete the backup only once you are sure —
or better, keep it. It is a few megabytes.

If anything went wrong, restore with:

```
gcloud firestore import gs://<your-bucket>/petnote-backup-<timestamp> \
  --project=petnote-a9dac
```
