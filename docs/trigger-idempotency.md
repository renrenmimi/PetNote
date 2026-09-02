# Trigger idempotency

Firestore delivers trigger events **at least once** and **in no particular
order**. A handler that reacts to an event by adjusting a counter therefore has
two ways to be wrong, and neither shows up in normal use:

- the same event is delivered twice and the counter moves twice;
- a delete is delivered before the create it undoes, and the counter is
  decremented for something that was never counted.

Clamping the result at zero hides the second one. It does not fix it, and it
does nothing at all about the first.

## The two mechanisms

### 1. `processedEvents/{eventId}` — the ledger

`runEventOnce(event.id, body)` in `functions/src/shared.ts` opens a
transaction, reads the ledger, runs `body` on that same transaction, and writes
the event id as the last step. The counter and the record of having counted
commit together or not at all, so a redelivery finds the marker and does
nothing.

`body` returns whether it applied anything. When it declines — the source
document is gone, the target is gone, the work was already done — nothing is
recorded, so a later redelivery is free to try again and reach the same
conclusion.

**This collection needs a TTL policy on `expiresAt` or it grows forever.**
Documents are written with a 30-day expiry: Firestore retries a failed trigger
for up to 7 days, so the ledger has to outlive that window, and TTL deletion is
allowed to lag by up to 24 hours. The project already runs a TTL policy on
`userDeletionTombstones.expiresAt`, so this is the same operation:

```
gcloud firestore fields ttls update expiresAt \
  --collection-group=processedEvents --enable-ttl --project=<project>
```

Rules deny all client access to the collection. A client that could write there
could suppress a counter update; one that could read it could enumerate
activity.

### 2. The `counted` stamp — ordering

The ledger makes an event apply once. It says nothing about whether a delete's
matching create ever ran. That is what the stamp on the source document is for,
and it has three states:

| `counted` | meaning | delete should |
|---|---|---|
| `true` | the create trigger applied the count | subtract |
| `false` | the document exists, its create trigger has not counted it yet | do nothing |
| absent | written before this shipped, by code that counted unconditionally | subtract |

Every writer of a counted document writes `counted: false`, and the counting
transaction flips it to `true` alongside the increment. The absent case is what
makes this deployable without backfilling every existing like, comment, review
and check-in, and what keeps clients running cached JS working.

There is no date and nothing to reconfigure at deploy time. An earlier draft
resolved the absent case by comparing `createdAt` against a cutoff constant;
that constant had to equal the deploy instant to be correct, and being wrong in
either direction was a silent counting bug.

Likes are the only counted document written by the client, so `firestore.rules`
pins `counted` to `false` on create. Without that pin a user could write
`counted: true` on a like that was never counted and then unlike, subtracting a
like that was never added — repeatable, against any post.

## Tests

`functions/src/__tests__/idempotency.test.ts` drives the real handlers through
the `.run()` hook that firebase-functions v2 exposes, rather than through the
functions emulator. That is the point rather than a shortcut: the emulator
delivers each event exactly once and gives no control over ordering, so it
cannot express either failure. Driving `.run()` lets a test hand the same event
id to a handler twice, or deliver a delete before its create.

Run them with `npm run test:emulator` in `functions/` (needs JDK 21+ — the
Firestore emulator refuses to start below that). CI runs them as the
`trigger idempotency` job, alongside `flows.test.ts` and
`invitations.test.ts`, which cover the callable layer the same way.

Against the code as it stood before this was written, 16 of these tests fail.
