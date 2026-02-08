import type { ReactNode } from "react";

interface FilterTagProps {
  icon: ReactNode;
  label: string;
  active: boolean;
  onClick: () => void;
}

export default function FilterTag({ icon, label, active, onClick }: FilterTagProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`flex flex-shrink-0 items-center gap-1.5 rounded-full px-4 py-2 text-sm font-medium whitespace-nowrap transition-all duration-200 active:scale-95 ${
        active
          ? "bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-md"
          : "bg-gray-100 text-gray-700 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700"
      }`}
    >
      {icon}
      <span>{label}</span>
    </button>
  );
}
