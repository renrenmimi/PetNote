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
      // Without this the button takes focus on tap, the keyboard drops, and
      // the person has to tap back into a field they never left. preventDefault
      // on mousedown stops the focus shift while leaving the button reachable
      // by keyboard, where taking focus is the correct behaviour.
      onMouseDown={(event) => event.preventDefault()}
      onClick={onToggle}
      className="rounded-full p-1.5 text-slate-400 transition-all duration-200 hover:bg-slate-100 hover:text-purple-500 focus:outline-none focus:ring-2 focus:ring-purple-200 dark:text-slate-500 dark:hover:bg-slate-700 dark:hover:text-purple-300"
      aria-label={label}
      title={label}
    >
      <Icon className="h-4 w-4" aria-hidden="true" />
    </button>
  );
}
