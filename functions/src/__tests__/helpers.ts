import { admin, db } from "../platform";

/**
 * Firestore trigger handlers are driven directly through the `.run()` hook
 * that firebase-functions v2 attaches to every onDocument* function, rather
 * than through the functions emulator.
 *
 * That is not a shortcut, it is the point: the functions emulator delivers each
 * event exactly once and gives no control over ordering, so it cannot express
 * either failure these tests exist to pin down. Driving `.run()` lets a test
 * hand the same event id to a handler twice, or deliver a delete before the
 * create it undoes.
 *
 * (The functions emulator also cannot run this codebase at all at the moment:
 * firebase-tools stubs firebase-admin with a proxy that does
 * `value.bind(target)` on `admin.firestore`, and bind() drops a function's own
 * properties, so `admin.firestore.FieldValue` is undefined inside it.)
 */
type TriggerFn<E> = { run: (event: E) => unknown };

// The handlers are typed against firebase-functions' full FirestoreEvent, which
// carries a dozen CloudEvent envelope fields none of these handlers read. The
// cast keeps the tests to the three fields that matter — id, params and the
// document snapshot — rather than constructing a fake envelope that would go
// stale the moment firebase-functions adds a field.
const asEvent = <E>(event: Record<string, unknown>) => event as unknown as E;

let eventCounter = 0;
/** A CloudEvent id that is unique unless a test deliberately reuses it. */
export function newEventId(label = "evt"): string {
  eventCounter += 1;
  return `${label}-${Date.now()}-${eventCounter}`;
}

/** Delivers a create event carrying the document's current snapshot. */
export async function deliverCreate<E>(
  fn: TriggerFn<E>,
  path: string,
  params: Record<string, string>,
  eventId: string
): Promise<void> {
  await fn.run(asEvent<E>({ id: eventId, params, data: await db.doc(path).get() }));
}

/**
 * Captures a document's snapshot so a delete event can be delivered later —
 * including before the create event that produced it, which is what makes the
 * out-of-order tests possible.
 */
export async function captureSnapshot(
  path: string
): Promise<admin.firestore.DocumentSnapshot> {
  return db.doc(path).get();
}

/** Delivers a delete event carrying a previously captured snapshot. */
export async function deliverDelete<E>(
  fn: TriggerFn<E>,
  snapshot: admin.firestore.DocumentSnapshot,
  params: Record<string, string>,
  eventId: string
): Promise<void> {
  await fn.run(asEvent<E>({ id: eventId, params, data: snapshot }));
}

/** Delivers an onDocumentWritten event with explicit before/after snapshots. */
export async function deliverWritten<E>(
  fn: TriggerFn<E>,
  before: admin.firestore.DocumentSnapshot | undefined,
  after: admin.firestore.DocumentSnapshot | undefined,
  params: Record<string, string>,
  eventId: string
): Promise<void> {
  await fn.run(asEvent<E>({ id: eventId, params, data: { before, after } }));
}

export async function fieldOf<T>(path: string, field: string): Promise<T> {
  const snap = await db.doc(path).get();
  return snap.data()?.[field] as T;
}

/** Removes a document and everything under it. */
export async function purge(...paths: string[]): Promise<void> {
  await Promise.all(paths.map((p) => db.recursiveDelete(db.doc(p))));
}

/** Empties the processed-event ledger between tests. */
export async function clearEventLedger(): Promise<void> {
  const snap = await db.collection("processedEvents").get();
  await Promise.all(snap.docs.map((d) => d.ref.delete()));
}

export const serverTime = () => admin.firestore.FieldValue.serverTimestamp();
export const timestampAt = (iso: string) =>
  admin.firestore.Timestamp.fromMillis(Date.parse(iso));
