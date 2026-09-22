function GoogleIcon() {
  return (
    <svg className="h-5 w-5" viewBox="0 0 48 48" aria-hidden="true">
      <path
        fill="#EA4335"
        d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5Z"
      />
      <path
        fill="#4285F4"
        d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65Z"
      />
      <path
        fill="#FBBC05"
        d="M10.53 28.59A14.5 14.5 0 0 1 9.77 24c0-1.6.27-3.15.76-4.59l-7.98-6.19A23.94 23.94 0 0 0 0 24c0 3.83.92 7.46 2.56 10.78l7.97-6.19Z"
      />
      <path
        fill="#34A853"
        d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48Z"
      />
    </svg>
  );
}

type GoogleButtonProps = {
  onClick: () => void;
  loading: boolean;
  label: string;
  loadingLabel: string;
};

/**
 * Continue with Google, drawn once.
 *
 * The walkthrough flagged this button as looking different on sign-in and
 * sign-up. By the time I looked the two were byte-identical — same class
 * string, same `GoogleIcon` path data — so I could not reproduce the
 * difference and am not claiming to have fixed it.
 *
 * What was real is that both pages carried their own copy of a 24-line SVG
 * and a 9-utility class string. Two copies that happen to match today are one
 * edit away from not matching, which is how the pages diverged in the first
 * place. Making them the same component makes the consistency structural
 * rather than a coincidence, and leaves one place to change if the button
 * ever needs to.
 */
export function GoogleButton({
  onClick,
  loading,
  label,
  loadingLabel,
}: GoogleButtonProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={loading}
      className="flex min-h-11 w-full items-center justify-center gap-3 rounded-xl border border-slate-200 bg-white px-4 py-2.5 text-sm font-semibold text-slate-700 transition-colors duration-200 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-70 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-200 dark:hover:bg-slate-800"
    >
      <GoogleIcon />
      {loading ? loadingLabel : label}
    </button>
  );
}
