export function digitsOnly(s: string): string {
  return (s || "").replace(/\D/g, "");
}

export function normalizeEmail(s: string | null | undefined): string {
  return (s || "").trim().toLowerCase();
}

export function normalizePhone(s: string | null | undefined): string {
  return digitsOnly(s || "");
}
