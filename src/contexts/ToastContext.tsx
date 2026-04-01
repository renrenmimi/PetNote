import { createContext, useCallback, useContext, useMemo, useState } from "react";
import { Toast, type ToastItem, type ToastType } from "../components/Toast";

type ToastContextValue = {
  showToast: (message: string, type: ToastType) => void;
};

const ToastContext = createContext<ToastContextValue | undefined>(undefined);

const AUTO_DISMISS_MS = 2600;

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [toasts, setToasts] = useState<ToastItem[]>([]);

  const dismissToast = useCallback((id: string) => {
    setToasts((prev) => prev.filter((toast) => toast.id !== id));
  }, []);

  const showToast = useCallback((message: string, type: ToastType) => {
    const id = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    setToasts((prev) => [...prev, { id, message, type }]);
    window.setTimeout(() => dismissToast(id), AUTO_DISMISS_MS);
  }, [dismissToast]);

  const value = useMemo(() => ({ showToast }), [showToast]);

  return (
    <ToastContext.Provider value={value}>
      {children}
      <div className="fixed bottom-6 left-1/2 z-[60] flex w-full -translate-x-1/2 flex-col items-center gap-2 px-4">
        {toasts.map((toast) => (
          <Toast key={toast.id} toast={toast} onDismiss={dismissToast} />
        ))}
      </div>
    </ToastContext.Provider>
  );
}

// eslint-disable-next-line react-refresh/only-export-components
export function useToast() {
  const context = useContext(ToastContext);
  if (!context) {
    throw new Error("useToast must be used within ToastProvider");
  }
  return context;
}
