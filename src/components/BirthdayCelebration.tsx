import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { getBirthdayPets, isBirthdayToday, type Pet } from "../services/pets";
import { optimizeCloudinaryUrl } from "../utils/cloudinaryUrl";
import { getSpeciesMeta } from "../utils/petHelpers";

type BirthdayCelebrationProps = {
  ownerId?: string | null;
};

export function BirthdayCelebration({ ownerId }: BirthdayCelebrationProps) {
  const navigate = useNavigate();
  const [pets, setPets] = useState<Pet[]>([]);
  const [dismissed, setDismissed] = useState(false);

  useEffect(() => {
    let ignore = false;
    if (!ownerId) return;
    const load = async () => {
      const list = await getBirthdayPets(ownerId);
      if (!ignore) setPets(list);
    };
    void load();
    return () => {
      ignore = true;
    };
  }, [ownerId]);

  const birthdayPet = pets[0];
  const ageLabel = useMemo(() => {
    if (!birthdayPet?.birthday || !isBirthdayToday(birthdayPet.birthday)) {
      return "";
    }
    const date =
      birthdayPet.birthday instanceof Date
        ? birthdayPet.birthday
        : typeof birthdayPet.birthday === "object" &&
          birthdayPet.birthday !== null &&
          "toDate" in birthdayPet.birthday &&
          typeof (birthdayPet.birthday as { toDate: () => Date }).toDate ===
            "function"
        ? (birthdayPet.birthday as { toDate: () => Date }).toDate()
        : null;
    if (!date) return "";
    const today = new Date();
    const years = today.getFullYear() - date.getFullYear();
    const label = years === 1 ? "1 year" : `${years} years`;
    return `Turning ${label} old today!`;
  }, [birthdayPet]);

  if (!ownerId || dismissed || !birthdayPet) {
    return null;
  }

  const meta = getSpeciesMeta(birthdayPet.species);
  const extraCount = pets.length - 1;

  return (
    <div className="relative overflow-hidden rounded-2xl bg-gradient-to-r from-amber-400 via-pink-400 to-purple-500 px-4 py-4 text-white shadow-[0_18px_40px_-28px_rgba(15,23,42,0.5)]">
      <div className="absolute inset-0 opacity-30">
        <div className="absolute left-6 top-2 h-2 w-2 rounded-full bg-white/80 animate-bounce" />
        <div className="absolute left-1/3 top-6 h-2 w-2 rounded-full bg-white/70 animate-bounce [animation-delay:200ms]" />
        <div className="absolute right-10 top-4 h-2 w-2 rounded-full bg-white/60 animate-bounce [animation-delay:400ms]" />
        <div className="absolute right-1/3 top-8 h-2 w-2 rounded-full bg-white/70 animate-bounce [animation-delay:600ms]" />
      </div>

      <div className="relative flex items-center justify-between gap-4">
        <div className="flex items-center gap-3">
          <div className="rounded-full bg-gradient-to-r from-amber-200 to-amber-500 p-1">
            {birthdayPet.avatarUrl ? (
              <img
                src={optimizeCloudinaryUrl(birthdayPet.avatarUrl, "avatar")}
                alt={birthdayPet.name}
                className="h-12 w-12 rounded-full border-2 border-white object-cover"
              />
            ) : (
              <div className="flex h-12 w-12 items-center justify-center rounded-full border-2 border-white bg-white text-lg text-amber-600">
                {meta.emoji}
              </div>
            )}
          </div>
          <div>
            <p className="text-sm font-semibold drop-shadow">
              🎂🎉 Happy Birthday, {birthdayPet.name}! 🎉🎂
              {extraCount > 0 ? ` +${extraCount}` : ""}
            </p>
            {ageLabel ? (
              <p className="text-xs text-white/90 drop-shadow">{ageLabel}</p>
            ) : null}
          </div>
        </div>
        <button
          type="button"
          onClick={() => setDismissed(true)}
          className="text-sm text-white/80 transition hover:text-white"
          aria-label="Dismiss"
        >
          ✕
        </button>
      </div>

      <div className="relative mt-3">
        <button
          type="button"
          onClick={() => navigate(`/create?petId=${birthdayPet.id}`)}
          className="rounded-full bg-white/90 px-4 py-2 text-xs font-semibold text-amber-600 transition-all duration-200 hover:scale-105"
        >
          Share a birthday post
        </button>
      </div>
    </div>
  );
}
