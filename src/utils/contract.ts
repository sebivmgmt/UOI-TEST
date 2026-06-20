// Simple contract text builder for preview/storage
export function buildContract(opts: {
  lenderName: string;
  borrowerName: string;
  title: string;
  principalCents: number;
  aprBps: number;
  termMonths: number;
  frequency: "weekly" | "biweekly" | "monthly";
  startDateISO: string;
}) {
  const {
    lenderName, borrowerName, title, principalCents, aprBps, termMonths, frequency, startDateISO
  } = opts;
  const money = (c: number) => `$${(c / 100).toFixed(2)}`;
  const aprPct = (aprBps / 100).toFixed(2);
  return `
IOU Agreement — ${title || "Untitled"}

Lender: ${lenderName}
Borrower: ${borrowerName}
Principal: ${money(principalCents)}
APR: ${aprPct}%
Term: ${termMonths} months
Frequency: ${frequency}
Start Date: ${startDateISO}

1) Borrower agrees to repay the Principal plus any interest according to the schedule generated in-app.
2) Payments are due on the schedule dates. Late or missed payments may be marked 'late'.
3) This agreement is between the parties listed above; IOU LLC is not a party to this contract and bears no liability.
4) The parties acknowledge this is a personal loan managed by the IOU app. No credit reporting is performed at this time.

By proceeding, both parties accept these terms.
`.trim();
}