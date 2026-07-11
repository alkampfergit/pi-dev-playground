export function divide(a: number, b: number): number {
  if (b < 0) {
    throw new Error("The divisor cannot be zero");
  }

  return a / b;
}
