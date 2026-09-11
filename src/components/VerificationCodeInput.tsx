import { useId } from "react";

type VerificationCodeInputProps = {
  value: string;
  onChange: (value: string) => void;
  length: number;
  label: string;
  hint?: string;
  disabled?: boolean;
  autoFocus?: boolean;
};

/**
 * Entry for an emailed numeric code.
 *
 * One input, not one box per digit. Split boxes look tidier and are worse at
 * the two things that actually happen: pasting the whole code from the mail
 * app, and a screen reader reading the field. A single field pastes correctly
 * for free, announces as one value, and still gets the number pad.
 *
 * `autocomplete="one-time-code"` lets iOS offer the code from the message
 * above the keyboard — an offer, not a guarantee. Nothing here assumes it
 * fires, which is why the field is normal, typeable and pasteable.
 *
 * Font size is governed by the control rules in index.css, so focusing this
 * does not zoom the page.
 */
export function VerificationCodeInput({
  value,
  onChange,
  length,
  label,
  hint,
  disabled = false,
  autoFocus = false,
}: VerificationCodeInputProps) {
  const id = useId();
  const hintId = `${id}-hint`;

  return (
    <div className="block">
      {/*
        The hint sits outside the label on purpose. Inside it, its text became
        part of the field's accessible name — a screen reader announced
        "Verification code 6 digits from the email" as the label. aria-describedby
        keeps it available as a description instead.
      */}
      <label
        htmlFor={id}
        className="mb-1 block text-sm font-medium text-slate-600 dark:text-slate-300"
      >
        {label}
      </label>
      <input
        id={id}
        type="text"
        // `numeric` rather than type="number": a number input brings
        // spinners, accepts "-" and "e", and silently drops a leading zero,
        // which a zero-padded code can start with.
        inputMode="numeric"
        autoComplete="one-time-code"
        autoCorrect="off"
        autoCapitalize="none"
        spellCheck={false}
        maxLength={length + 8}
        disabled={disabled}
        autoFocus={autoFocus}
        aria-describedby={hint ? hintId : undefined}
        className="w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2.5 text-center tracking-[0.4em] text-slate-800 outline-none transition-all duration-200 focus:border-purple-400 focus:ring-2 focus:ring-purple-200 disabled:opacity-60 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
        value={value}
        onChange={(event) =>
          // Keep digits only, from typing or from a paste that carried
          // spaces, dashes or surrounding words.
          onChange(event.target.value.replace(/\D/g, "").slice(0, length))
        }
      />
      {hint ? (
        <span
          id={hintId}
          className="mt-1 block text-xs text-slate-400 dark:text-slate-500"
        >
          {hint}
        </span>
      ) : null}
    </div>
  );
}
