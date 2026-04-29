import { useEffect, useRef, useState } from "react";
import {
  searchAddresses,
  type AddressLocation,
} from "../services/geoapify";

type AddressAutocompleteProps = {
  value: string;
  onChange: (address: string, location: AddressLocation | null) => void;
  placeholder?: string;
};

type AddressResult = AddressLocation;

export function AddressAutocomplete({
  value,
  onChange,
  placeholder = "Search for a location",
}: AddressAutocompleteProps) {
  const wrapperRef = useRef<HTMLDivElement | null>(null);
  const [results, setResults] = useState<AddressResult[]>([]);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [confirmed, setConfirmed] = useState(false);

  useEffect(() => {
    if (!open) return;
    const handleClick = (event: MouseEvent) => {
      if (!wrapperRef.current) return;
      if (!wrapperRef.current.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    window.addEventListener("mousedown", handleClick);
    return () => window.removeEventListener("mousedown", handleClick);
  }, [open]);

  useEffect(() => {
    if (!value.trim()) {
      setResults([]);
      setConfirmed(false);
      return;
    }
    setLoading(true);
    const handle = window.setTimeout(async () => {
      try {
        setResults(await searchAddresses(value));
      } catch {
        setResults([]);
      } finally {
        setLoading(false);
      }
    }, 300);

    return () => window.clearTimeout(handle);
  }, [value]);

  const handleSelect = (result: AddressResult) => {
    onChange(result.fullAddress, result);
    setConfirmed(true);
    setOpen(false);
  };

  return (
    <div ref={wrapperRef} className="relative">
      <input
        type="text"
        value={value}
        onChange={(event) => {
          onChange(event.target.value, null);
          setConfirmed(false);
          setOpen(true);
        }}
        onFocus={() => setOpen(true)}
        placeholder={placeholder}
        className="w-full rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-700 outline-none transition focus:border-purple-400 focus:ring-2 focus:ring-purple-200 dark:border-slate-700 dark:bg-slate-800 dark:text-white"
      />
      {loading ? (
        <div className="absolute right-3 top-3 h-5 w-5 animate-spin rounded-full border-2 border-slate-300 border-t-transparent dark:border-slate-600" />
      ) : null}
      {confirmed ? (
        <p className="mt-2 text-xs text-emerald-500">✓ Location confirmed</p>
      ) : null}
      {open && value.trim() ? (
        <div className="absolute left-0 right-0 top-[calc(100%+6px)] z-20 max-h-60 overflow-auto rounded-lg border border-slate-100 bg-white p-2 shadow-lg dark:border-slate-700 dark:bg-slate-800">
          {loading ? (
            <div className="px-3 py-2 text-xs text-slate-400">
              Searching...
            </div>
          ) : results.length === 0 ? (
            <div className="px-3 py-2 text-xs text-slate-400">
              No results found
            </div>
          ) : (
            results.map((result) => (
              <button
                key={`${result.fullAddress}-${result.lat}-${result.lng}`}
                type="button"
                onClick={() => handleSelect(result)}
                className="flex w-full flex-col gap-1 rounded-lg px-3 py-2 text-left transition-all duration-200 hover:bg-slate-100 dark:hover:bg-slate-700"
              >
                <span className="text-sm font-semibold text-slate-700 dark:text-white">
                  📍 {result.name}
                </span>
                <span className="text-xs text-slate-500 dark:text-slate-300">
                  {result.fullAddress}
                </span>
              </button>
            ))
          )}
        </div>
      ) : null}
    </div>
  );
}
