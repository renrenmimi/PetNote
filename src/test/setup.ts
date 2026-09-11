import { afterEach } from "vitest";
import { cleanup } from "@testing-library/react";

// Testing Library only registers its own cleanup when vitest runs with
// globals. This project runs with `globals: false`, so without this every
// test would render into the DOM left behind by the previous one and
// getByText would find two of everything.
afterEach(() => {
  cleanup();
});
