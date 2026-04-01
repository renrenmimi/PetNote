export interface PasswordValidation {
  isValid: boolean;
  errors: string[];
  strength: "weak" | "medium" | "strong";
}

export function validatePassword(password: string): PasswordValidation {
  const errors: string[] = [];

  if (password.length < 8) errors.push("At least 8 characters");
  if (password.length > 64) errors.push("Maximum 64 characters");
  if (!/[A-Z]/.test(password)) errors.push("At least one uppercase letter (A-Z)");
  if (!/[a-z]/.test(password)) errors.push("At least one lowercase letter (a-z)");
  if (!/[0-9]/.test(password)) errors.push("At least one number (0-9)");
  if (!/[!@#$%^&*()_+\-=[\]{};':"\\|,.<>/?]/.test(password)) {
    errors.push("At least one special character (!@#$%...)");
  }

  const isValid = errors.length === 0;
  let strength: "weak" | "medium" | "strong" = "weak";
  if (errors.length <= 2 && password.length >= 6) strength = "medium";
  if (isValid && password.length >= 12) strength = "strong";
  else if (isValid) strength = "medium";

  return { isValid, errors, strength };
}
