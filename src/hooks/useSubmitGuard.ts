import { useCallback, useRef } from "react";

/**
 * One submit at a time, decided synchronously.
 *
 * `disabled={saving}` is a render-time hint, and React batches the state
 * update that sets it. Between a first tap and the re-render that disables
 * the button there is a real window — long enough for a double tap, a
 * repeated Return, or an Enter that confirms an IME candidate and then
 * submits. A ref latches on the first call, before any awaiting begins.
 *
 * Create already had exactly this (`submitLockedRef`) for the composer, held
 * across the post-success navigation so the delay window could not accept a
 * second submit. This is that pattern, shared.
 *
 * The latch is released in a `finally`, so a thrown submit leaves the form
 * usable rather than permanently wedged.
 */
export function useSubmitGuard() {
  const lockedRef = useRef(false);

  /** False when a submit is already running, in which case do nothing. */
  const tryAcquire = useCallback(() => {
    if (lockedRef.current) return false;
    lockedRef.current = true;
    return true;
  }, []);

  /** Release in a `finally`, so a thrown submit does not wedge the form. */
  const release = useCallback(() => {
    lockedRef.current = false;
  }, []);

  return { tryAcquire, release };
}

/**
 * True while an input method is mid-composition.
 *
 * Pressing Return to accept a Chinese, Japanese or Korean candidate fires a
 * keydown with `isComposing` set. A form that submits on Return would take
 * that keystroke as "submit" and send a half-typed value, so every
 * Return-to-submit path has to ask first.
 */
export function isComposing(
  event: Pick<KeyboardEvent, "isComposing"> & { keyCode?: number }
): boolean {
  // keyCode 229 is the legacy signal some IMEs still send instead.
  return event.isComposing === true || event.keyCode === 229;
}
