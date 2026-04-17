import { validatePassword } from "../utils/passwordValidator";
import { useLanguage } from "../hooks/useLanguage";

type PasswordStrengthIndicatorProps = {
  password: string;
};

const rules = [
  {
    error: "At least 8 characters",
    key: "password.rule.minLength" as const,
  },
  {
    error: "Maximum 64 characters",
    key: "password.rule.maxLength" as const,
  },
  {
    error: "At least one uppercase letter (A-Z)",
    key: "password.rule.uppercase" as const,
  },
  {
    error: "At least one lowercase letter (a-z)",
    key: "password.rule.lowercase" as const,
  },
  {
    error: "At least one number (0-9)",
    key: "password.rule.number" as const,
  },
  {
    error: "At least one special character (!@#$%...)",
    key: "password.rule.special" as const,
  },
];

export function PasswordStrengthIndicator({
  password,
}: PasswordStrengthIndicatorProps) {
  const { t } = useLanguage();
  if (!password) return null;
  const result = validatePassword(password);

  const barClass = (index: number) => {
    if (result.strength === "weak") {
      return index === 0 ? "bg-red-500" : "bg-slate-200 dark:bg-slate-700";
    }
    if (result.strength === "medium") {
      return index < 2 ? "bg-amber-500" : "bg-slate-200 dark:bg-slate-700";
    }
    return "bg-emerald-500";
  };

  return (
    <div className="space-y-2">
      <div className="flex gap-2">
        {[0, 1, 2].map((index) => (
          <span
            key={index}
            className={`h-2 flex-1 rounded-full transition-all duration-200 ${barClass(
              index
            )}`}
          />
        ))}
      </div>
      <div className="space-y-1 text-xs">
        {rules.map((rule) => {
          const satisfied = !result.errors.includes(rule.error);
          return (
            <div
              key={rule.error}
              className={`flex items-center gap-2 ${
                satisfied ? "text-emerald-500" : "text-red-500"
              }`}
            >
              <span>{satisfied ? "✅" : "❌"}</span>
              <span className="text-slate-600 dark:text-slate-300">
                {t(rule.key)}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
