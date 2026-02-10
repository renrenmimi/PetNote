const isPlainObject = (value: unknown): value is Record<string, unknown> => {
  if (!value || typeof value !== "object") return false;
  const proto = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
};

export function removeUndefined<T>(input: T): T {
  if (Array.isArray(input)) {
    return input
      .filter((item): item is Exclude<typeof item, undefined> => item !== undefined)
      .map((item) => removeUndefined(item)) as T;
  }

  if (isPlainObject(input)) {
    const cleaned = Object.fromEntries(
      Object.entries(input)
        .filter(([, value]) => value !== undefined)
        .map(([key, value]) => [key, removeUndefined(value)])
    );
    return cleaned as T;
  }

  return input;
}
