import { Eye, EyeOff } from "lucide-react";

type PasswordVisibilityButtonProps = {
  visible: boolean;
  onToggle: () => void;
  showLabel: string;
  hideLabel: string;
};

export function PasswordVisibilityButton({
  visible,
  onToggle,
  showLabel,
  hideLabel,
}: PasswordVisibilityButtonProps) {
  const label = visible ? hideLabel : showLabel;
  const Icon = visible ? EyeOff : Eye;

  return (
    <button
      type="button"
      onClick={onToggle}
      className="rounded-full p-1.5 text-slate-400 transition-all duration-200 hover:bg-slate-100 hover:text-purple-500 focus:outline-none focus:ring-2 focus:ring-purple-200 dark:text-slate-500 dark:hover:bg-slate-700 dark:hover:text-purple-300"
      aria-label={label}
      title={label}
    >
      <Icon className="h-4 w-4" aria-hidden="true" />
    </button>
  );
}
