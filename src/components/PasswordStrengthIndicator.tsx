import { validatePassword } from "../utils/passwordValidator";

type PasswordStrengthIndicatorProps = {
  password: string;
};

const rules = [
  "At least 8 characters",
  "Maximum 64 characters",
  "At least one uppercase letter (A-Z)",
  "At least one lowercase letter (a-z)",
  "At least one number (0-9)",
  "At least one special character (!@#$%...)",
];

export function PasswordStrengthIndicator({
  password,
}: PasswordStrengthIndicatorProps) {
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
          const satisfied = !result.errors.includes(rule);
          return (
            <div
              key={rule}
              className={`flex items-center gap-2 ${
                satisfied ? "text-emerald-500" : "text-red-500"
              }`}
            >
              <span>{satisfied ? "✅" : "❌"}</span>
              <span className="text-slate-600 dark:text-slate-300">
                {rule}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
