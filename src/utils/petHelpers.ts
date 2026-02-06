export type PetSpecies =
  | "dog"
  | "cat"
  | "bird"
  | "rabbit"
  | "hamster"
  | "fish"
  | "reptile"
  | "other";

export type PetGender = "male" | "female" | "unknown";

export const PET_SPECIES: Array<{
  value: PetSpecies;
  label: string;
  emoji: string;
  gradient: string;
}> = [
  { value: "dog", label: "Dog", emoji: "🐕", gradient: "from-amber-600 to-yellow-500" },
  { value: "cat", label: "Cat", emoji: "🐱", gradient: "from-orange-500 to-amber-400" },
  { value: "bird", label: "Bird", emoji: "🐦", gradient: "from-sky-400 to-blue-500" },
  { value: "rabbit", label: "Rabbit", emoji: "🐰", gradient: "from-rose-400 to-pink-500" },
  { value: "hamster", label: "Hamster", emoji: "🐹", gradient: "from-amber-400 to-orange-400" },
  { value: "fish", label: "Fish", emoji: "🐠", gradient: "from-cyan-400 to-blue-400" },
  { value: "reptile", label: "Reptile", emoji: "🦎", gradient: "from-lime-400 to-green-500" },
  { value: "other", label: "Other", emoji: "🐾", gradient: "from-purple-500 to-pink-500" },
];

export const getSpeciesMeta = (species?: PetSpecies) => {
  return (
    PET_SPECIES.find((item) => item.value === species) ??
    PET_SPECIES[PET_SPECIES.length - 1]
  );
};

export const getGenderMeta = (gender?: PetGender) => {
  if (gender === "male") {
    return { label: "Male", icon: "♂", color: "#3B82F6" };
  }
  if (gender === "female") {
    return { label: "Female", icon: "♀", color: "#EC4899" };
  }
  return { label: "Unknown", icon: "?", color: "#94A3B8" };
};
