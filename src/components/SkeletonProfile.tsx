export function SkeletonProfile() {
  return (
    <div className="space-y-6">
      <div className="rounded-3xl bg-white p-6 shadow-sm ring-1 ring-slate-100 dark:bg-slate-800 dark:ring-slate-700">
        <div className="flex flex-col items-center text-center">
          <div className="h-24 w-24 rounded-full bg-slate-200 dark:bg-slate-700" />
          <div className="mt-4 h-4 w-32 rounded bg-slate-200 dark:bg-slate-700" />
          <div className="mt-2 h-3 w-24 rounded bg-slate-200 dark:bg-slate-700" />
        </div>
        <div className="mt-6 grid grid-cols-3 gap-4 text-center">
          {Array.from({ length: 3 }).map((_, idx) => (
            <div
              key={idx}
              className="h-12 rounded-xl bg-slate-200 dark:bg-slate-700"
            />
          ))}
        </div>
      </div>
      <div className="grid grid-cols-3 gap-2">
        {Array.from({ length: 6 }).map((_, idx) => (
          <div
            key={idx}
            className="aspect-square rounded-2xl bg-slate-200 dark:bg-slate-700"
          />
        ))}
      </div>
    </div>
  );
}
