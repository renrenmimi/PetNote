const ADJECTIVES = [
  "Happy",
  "Cute",
  "Fluffy",
  "Brave",
  "Sweet",
  "Lucky",
  "Sunny",
  "Cozy",
  "Gentle",
  "Playful",
  "Jolly",
  "Merry",
  "Bubbly",
  "Cheerful",
  "Sparkly",
];

const ANIMALS = [
  "Panda",
  "Kitten",
  "Bunny",
  "Puppy",
  "Fox",
  "Bear",
  "Otter",
  "Hamster",
  "Parrot",
  "Koala",
  "Penguin",
  "Dolphin",
  "Hedgehog",
  "Owl",
  "Corgi",
];

export function generateRandomUsername(): string {
  const adjective = ADJECTIVES[Math.floor(Math.random() * ADJECTIVES.length)];
  const animal = ANIMALS[Math.floor(Math.random() * ANIMALS.length)];
  const number = Math.floor(Math.random() * 90) + 10;
  return `${adjective}${animal}${number}`;
}
