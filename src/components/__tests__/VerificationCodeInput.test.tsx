import { useState } from "react";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { VerificationCodeInput } from "../VerificationCodeInput";

function Harness({ length = 6 }: { length?: number }) {
  const [value, setValue] = useState("");
  return (
    <>
      <VerificationCodeInput
        value={value}
        onChange={setValue}
        length={length}
        label="Verification code"
        hint="6 digits from the email"
      />
      <span data-testid="value">{value}</span>
    </>
  );
}

const field = () => screen.getByLabelText("Verification code") as HTMLInputElement;
const current = () => screen.getByTestId("value").textContent;

/**
 * Sets the value the way a paste or a keystroke does. fireEvent.change, not a
 * direct assignment: React tracks a controlled input's value through a
 * property descriptor, and writing to .value behind its back produces no
 * onChange at all.
 */
function type(text: string) {
  fireEvent.change(field(), { target: { value: text } });
}

describe("VerificationCodeInput", () => {
  it("asks for the number pad without using a number input", () => {
    render(<Harness />);
    const input = field();
    // type=number would bring spinners, accept "e" and "-", and drop a
    // leading zero — which a zero-padded code can start with.
    expect(input.getAttribute("type")).toBe("text");
    expect(input.getAttribute("inputmode")).toBe("numeric");
  });

  it("offers the emailed code to the keychain without depending on it", () => {
    render(<Harness />);
    expect(field().getAttribute("autocomplete")).toBe("one-time-code");
    // Still an ordinary field, because autofill is an offer, not a promise.
    expect(field().hasAttribute("readonly")).toBe(false);
    expect(field().hasAttribute("disabled")).toBe(false);
  });

  it("accepts a whole code pasted with the surrounding noise", () => {
    render(<Harness />);
    type("Code: 123 456");
    expect(current()).toBe("123456");
  });

  it("keeps a leading zero", () => {
    render(<Harness />);
    type("012345");
    expect(current()).toBe("012345");
  });

  it("stops at the code length", () => {
    render(<Harness />);
    type("1234567890");
    expect(current()).toBe("123456");
  });

  it("ignores letters and punctuation as they are typed", () => {
    render(<Harness />);
    type("1a2-b3");
    expect(current()).toBe("123");
  });

  it("is labelled and described for a screen reader", () => {
    render(<Harness />);
    const input = field();
    const describedBy = input.getAttribute("aria-describedby");
    expect(describedBy).toBeTruthy();
    expect(document.getElementById(describedBy!)?.textContent).toBe(
      "6 digits from the email"
    );
    // No capitalisation or spellcheck noise on a numeric secret.
    expect(input.getAttribute("autocapitalize")).toBe("none");
    expect(input.getAttribute("spellcheck")).toBe("false");
  });
});
