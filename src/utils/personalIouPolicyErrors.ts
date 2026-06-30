// Safe user-facing copy for Personal IOU policy and backend constraint errors.
// Never expose raw PostgreSQL error messages, SQLSTATE, bps values, trigger
// names, function names, or state codes to normal users.

export const MSG_APR_EXCEEDS =
  "The agreed APR exceeds the limit for this borrower.";
export const MSG_MISSING_STATE =
  "The borrower needs to complete their state information before creating a Personal IOU.";
export const MSG_UNSUPPORTED_STATE =
  "Personal IOUs are not available for this borrower yet.";
export const MSG_BORROWER_UNAVAILABLE =
  "We could not verify this borrower's Personal IOU eligibility.";
export const MSG_GENERIC = "Something went wrong. Please try again.";
export const MSG_POLICY_LOAD_FAILED =
  "Could not verify Personal IOU availability. Please try again.";

const APR_PATTERNS = [
  /\bapr\s+\d+\s+bps\s+exceeds\s+the\s+\d+\s+bps\s+cap/i,
  /exceeds the.*bps cap/i,
  /exceeds.*limit.*state/i,
  /apr.*exceeds/i,
  /cap for state/i,
];
const MISSING_STATE_PATTERNS = [
  /borrower residence state is not set/i,
  /borrower state is not set/i,
  /state.*not set/i,
  /missing.state/i,
];
const UNSUPPORTED_STATE_PATTERNS = [
  /state .+ is not supported for personal ious/i,
  /not a supported.*state/i,
  /state.*not.*supported/i,
  /unsupported.state/i,
];
const BORROWER_NOT_FOUND_PATTERNS = [
  /borrower profile does not exist/i,
  /borrower.*not found/i,
  /profile.*not found/i,
  /user.*not found/i,
  /unavailable/i,
];

function extractMessage(err: unknown): string {
  if (err instanceof Error) return err.message;
  if (err && typeof err === "object" && "message" in err)
    return String((err as any).message);
  if (typeof err === "string") return err;
  return "";
}

export function mapPersonalIouPolicyError(err: unknown): string {
  const msg = extractMessage(err);
  if (APR_PATTERNS.some((p) => p.test(msg))) return MSG_APR_EXCEEDS;
  if (MISSING_STATE_PATTERNS.some((p) => p.test(msg))) return MSG_MISSING_STATE;
  if (UNSUPPORTED_STATE_PATTERNS.some((p) => p.test(msg))) return MSG_UNSUPPORTED_STATE;
  if (BORROWER_NOT_FOUND_PATTERNS.some((p) => p.test(msg))) return MSG_BORROWER_UNAVAILABLE;
  return MSG_GENERIC;
}

/** Translate a known policy_status string to safe user copy. */
export function policyStatusMessage(
  status: "supported" | "missing_state" | "unsupported_state" | "unavailable" | null
): string {
  switch (status) {
    case "missing_state":    return MSG_MISSING_STATE;
    case "unsupported_state": return MSG_UNSUPPORTED_STATE;
    case "unavailable":      return MSG_BORROWER_UNAVAILABLE;
    default:                 return MSG_BORROWER_UNAVAILABLE;
  }
}
