import PawIcon from "./PawIcon";

type SplashScreenProps = {
  visible: boolean;
};

export function SplashScreen({ visible }: SplashScreenProps) {
  return (
    <div
      className={`fixed inset-0 z-50 flex flex-col items-center justify-center bg-white transition-opacity duration-500 dark:bg-slate-900 ${
        visible ? "opacity-100" : "pointer-events-none opacity-0"
      }`}
    >
      <PawIcon size={64} className="animate-pulse" />
      <h1 className="mt-4 bg-gradient-to-r from-purple-500 to-pink-500 bg-clip-text text-2xl font-bold text-transparent">
        PetNote
      </h1>
      <div className="mt-6 flex items-center gap-1">
        <span className="h-2 w-2 animate-bounce rounded-full bg-purple-400 [animation-delay:0ms]" />
        <span className="h-2 w-2 animate-bounce rounded-full bg-purple-400 [animation-delay:120ms]" />
        <span className="h-2 w-2 animate-bounce rounded-full bg-purple-400 [animation-delay:240ms]" />
      </div>
    </div>
  );
}
