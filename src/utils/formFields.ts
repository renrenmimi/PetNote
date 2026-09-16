/**
 * Shared attribute sets for the form controls that appear on more than one
 * page, so the keyboard, autofill and autocorrect behaviour is decided once
 * per kind of field rather than per call site.
 *
 * The minimum font size that stops iOS zooming the page on focus lives in
 * index.css, on the control selectors — it is a property of the control, not
 * of any one form, and there are far too many call sites to repeat it.
 */

/**
 * Email entry.
 *
 * `inputMode` is what actually gets the @-and-dot keyboard on iOS; `type`
 * alone leaves validation and autofill right but the keyboard unchanged in
 * some contexts. Capitalisation, autocorrect and spellcheck are all off
 * because an address is not prose — iOS otherwise capitalises the first
 * letter and underlines the local part as a misspelling.
 */
export const emailFieldProps = {
  type: "email",
  inputMode: "email",
  autoComplete: "email",
  autoCapitalize: "none",
  autoCorrect: "off",
  spellCheck: false,
} as const;

/**
 * Password entry. `current-password` on sign-in and `new-password` on
 * sign-up / reset are what let the iOS keychain offer the right thing:
 * the saved password in one case, a generated suggestion in the other.
 */
export const currentPasswordFieldProps = {
  autoComplete: "current-password",
  autoCapitalize: "none",
  autoCorrect: "off",
  spellCheck: false,
} as const;

export const newPasswordFieldProps = {
  autoComplete: "new-password",
  autoCapitalize: "none",
  autoCorrect: "off",
  spellCheck: false,
} as const;
