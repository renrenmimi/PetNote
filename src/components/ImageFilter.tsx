export type FilterName =
  | "normal"
  | "warm"
  | "cool"
  | "bright"
  | "contrast"
  | "vintage"
  | "bw"
  | "vivid"
  | "soft"
  | "rose";

// eslint-disable-next-line react-refresh/only-export-components
export const FILTERS: Array<{
  key: FilterName;
  label: string;
  css: string;
}> = [
  { key: "normal", label: "Normal", css: "none" },
  { key: "warm", label: "Warm", css: "sepia(0.3) saturate(1.4) brightness(1.1)" },
  { key: "cool", label: "Cool", css: "saturate(0.8) brightness(1.1) hue-rotate(15deg)" },
  { key: "bright", label: "Bright", css: "brightness(1.3)" },
  { key: "contrast", label: "Contrast", css: "contrast(1.4)" },
  { key: "vintage", label: "Vintage", css: "sepia(0.4) saturate(0.8) brightness(0.9)" },
  { key: "bw", label: "B&W", css: "grayscale(1)" },
  { key: "vivid", label: "Vivid", css: "saturate(1.8) contrast(1.1)" },
  { key: "soft", label: "Soft", css: "brightness(1.1) contrast(0.9) blur(0.5px)" },
  { key: "rose", label: "Rose", css: "sepia(0.2) saturate(1.3) hue-rotate(-10deg) brightness(1.05)" },
];

export const FILTER_MAP = FILTERS.reduce<Record<FilterName, string>>(
  (acc, item) => {
    acc[item.key] = item.css;
    return acc;
  },
  {} as Record<FilterName, string>
);

type ImageFilterProps = {
  previewUrl: string;
  selected: FilterName;
  onSelect: (filter: FilterName) => void;
};

export function ImageFilter({
  previewUrl,
  selected,
  onSelect,
}: ImageFilterProps) {
  return (
    <div className="rounded-2xl bg-slate-50 p-3 dark:bg-slate-800">
      <div className="flex gap-3 overflow-x-auto pb-2">
        {FILTERS.map((filter) => {
          const isActive = selected === filter.key;
          return (
            <button
              key={filter.key}
              type="button"
              onClick={() => onSelect(filter.key)}
              className={`flex flex-col items-center gap-1 transition-all duration-200 ${
                isActive ? "scale-105" : "opacity-80 hover:opacity-100"
              }`}
            >
              <div
                className={`h-16 w-16 overflow-hidden rounded-xl border-2 ${
                  isActive
                    ? "border-purple-500"
                    : "border-transparent bg-white/80 dark:bg-slate-700"
                }`}
              >
                <img
                  src={previewUrl}
                  alt={filter.label}
                  className="h-full w-full object-cover"
                  style={{ filter: filter.css }}
                />
              </div>
              <span className="text-[10px] font-semibold text-slate-600 dark:text-slate-300">
                {filter.label}
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );
}
