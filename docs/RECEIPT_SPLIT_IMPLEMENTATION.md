# Receipt Split — Implementation Tracker

Last updated: 2026-05-20 (Phase 2 wiring + backend hardening error handling)

---

## 1. Feature Status

**Phase 1 — Foundation:** Complete. Screens, local state, split math, camera input.
**Phase 2 — Backend wiring:** Complete. All Supabase tables and RPCs are wired. Full flow persists on confirm.

---

## 2. Screens

| Screen | File | Status |
|---|---|---|
| Entry / hub | `SplitReceiptScreen.tsx` | Done — routes to ReceiptCamera |
| Camera input | `ReceiptCameraScreen.tsx` | Done — real camera/library via expo-image-picker; sample receipt fallback |
| Review & confirm | `ReceiptReviewScreen.tsx` | Done — calls `persistReceiptSplit` on confirm; spinner during save |
| Participants | `ReceiptParticipantsScreen.tsx` | Done — calls `persistParticipants` on continue; friend list is **MOCK** (see §7) |
| Assign items | `AssignItemsScreen.tsx` | Done — debounced upsert + `calculate_receipt_split_totals` RPC + realtime subscription on `receipt_split_totals`; animated totals bar |
| Split summary | `ReceiptSummaryScreen.tsx` | Done — calls `generate_ious_from_receipt_split` RPC; demo fallback if no `splitId`; resets context and navigates Home on success |
| Payment confirm | `ReceiptPaymentConfirmScreen.tsx` | **NOT used in current flow** — orphaned stub, safe to remove later |

---

## 3. Services

| File | Purpose | Status |
|---|---|---|
| `receiptParser.ts` | Parses receipt image into a local draft | **MOCK** — hardcoded sample data, 1.2 s fake delay. Real OCR not yet wired. |
| `splitCalculator.ts` | Local split math (largest-remainder rounding) | **REAL** — no Supabase, pure math |
| `receiptDraftService.ts` | Local draft CRUD helpers (add/remove/update items, validate) | **REAL** — no Supabase, safe to call anywhere |
| `receiptPersistenceService.ts` | All Supabase persistence for receipt split | **REAL** — `persistReceiptSplit`, `persistParticipants`, `upsertAssignments`, `refreshSplitTotals`, `fetchSplitTotals`, `generateIousFromSplit` |
| `paymentService.ts` | Fallback mock IOU generation for demo mode | **MOCK** — kept as offline fallback only; real path goes through `generate_ious_from_receipt_split` RPC |

---

## 4. Supabase Tables Used

All tables managed by Sylienn (no client-side SQL).

| Table | When written | Notes |
|---|---|---|
| `receipt_splits` | ReceiptReview confirm | One row per split session |
| `receipt_split_items` | Same as above (batch insert) | One row per line item; includes `local_item_id` for client-side mapping |
| `receipt_split_participants` | ReceiptParticipants confirm | Includes `user_id` (null for participants without an account) and `local_participant_id` for client mapping |
| `receipt_item_assignments` | AssignItems (debounced, delete+reinsert on each sync) | References `receipt_split_participants.id` and `receipt_split_items.id` |
| `receipt_split_totals` | Read-only (view/materialized) | Computed by `calculate_receipt_split_totals` RPC; subscribed via Supabase Realtime in AssignItems + ReceiptSummary |

---

## 5. RPCs Used

| RPC | Called from | Params | Notes |
|---|---|---|---|
| `calculate_receipt_split_totals` | AssignItems (debounced after each upsert) | `p_receipt_split_id` | Refreshes `receipt_split_totals`; triggers realtime subscription |
| `generate_ious_from_receipt_split` | ReceiptSummary "Send IOUs" button | `p_receipt_split_id`, `p_due_date` | See §6 for generation rules |

**Not used:** Any Plaid, payment, or bank-transfer RPC. Receipt split only generates IOU records — the existing accept/sign flow handles everything after that.

---

## 6. What Is Fully Wired

- Local split math (`splitCalculator.ts`) — correct, no Supabase
- Camera/library image input (`expo-image-picker`) with simulator fallback
- Receipt review UI (edit items, tax, tip, quantities)
- `ReceiptReviewScreen.handleContinue` → `persistReceiptSplit` → `receipt_splits` + `receipt_split_items` created in Supabase; `splitId` + `itemDbIdMap` stored in context
- `ReceiptParticipantsScreen.handleContinue` → `persistParticipants` → `receipt_split_participants` created; `participantDbIdMap` stored in context
- `AssignItemsScreen` assignment toggle → 400 ms debounce → `upsertAssignments` (delete + reinsert `receipt_item_assignments`) → `calculate_receipt_split_totals` RPC → realtime subscription on `receipt_split_totals` → `displayTotals` updated → animated chips spring
- `ReceiptSummaryScreen` → realtime subscription on `receipt_split_totals`; `getTotalCents` prefers server totals; `handleSendIous` → `generate_ious_from_receipt_split(splitId, dueDate+7days)` → success alert → `reset()` context → navigate Home
- Demo mode fallback: if `draft.splitId` is absent (sample receipt, no auth), `generateSplitIous` mock is used instead; "Demo mode" label shown in UI

---

## 7. Mock / Demo Only — Not Real Backend

| Item | Why it is mock | When it becomes real |
|---|---|---|
| **Receipt parsing** | No OCR API connected. `parseReceiptImage()` returns hardcoded sample data after 1.2 s. | When AI/OCR backend is ready |
| **Friend list in ReceiptParticipants** | Shows `MOCK_FRIENDS` array (ids: `f1`–`f5`). These are not Supabase users. | Replace with real search (reuse `search-counterparty` edge function) |
| **generateSplitIous() in paymentService.ts** | Mock fallback used when `draft.splitId` is absent (offline / demo mode). Generates fake `MockIou[]` objects. Nothing is written to Supabase. | When persistence is fully wired, this path is bypassed; real path uses `generate_ious_from_receipt_split` RPC |

---

## 8. Intentionally Deferred

- **Real OCR / AI receipt parsing** — not part of Phase 1–2 scope
- **ReceiptPaymentConfirmScreen** — orphaned from an earlier design; not in the navigation stack
- **Manual amount splits** — UI allows long-press to open `SharedItemSelector` with `splitMode: 'manual'`, but `manualAmounts` are not yet persisted to `receipt_item_assignments`
- **Duplicate IOU guard (client-side)** — the server enforces this via `generated_iou_id` check; no client guard needed
- **Due date picker** — currently defaults to 7 days from now; no UI to select date
- **Error recovery UX** — if persistence fails mid-flow (e.g., after `receipt_splits` insert but before `receipt_split_items`), the user has no retry. Acceptable for Phase 2; cleanup needed before production.

---

## 8b. Backend Constraint Errors — Client Handling

Backend now enforces these constraints server-side. The client surfaces them as clean alerts and rolls back local UI state:

| Server error string | User-facing message | UI rollback |
|---|---|---|
| `"Item assignment exceeds 100 percent"` | "One item's split adds up to more than 100%. Adjust the amounts and try again." | `localAssignments` reset to last committed state |
| `"Participant does not belong to this receipt split"` | "A participant isn't part of this receipt. Go back and re-add friends." | Same rollback |
| `"Assignment receipt_split_id does not match item receipt_split_id"` | "There was a data mismatch. Go back and try again." | Same rollback |
| `"already exists"` / `"generated_iou_id"` on Send IOUs | "IOUs have already been created for this receipt." | No rollback needed — idempotent by design |
| `"not authorized"` / `"owner"` on Send IOUs | "Only the person who paid can send IOUs." | No rollback needed |

Views now available (not yet consumed by client): `receipt_split_detail_view`, `receipt_generated_ious_view`.

---

## 9. Known Edge Cases

| Case | Current behavior |
|---|---|
| Participant has no Supabase `user_id` (mock friends) | `persistParticipants` inserts them with `user_id = null`. `generate_ious_from_receipt_split` skips them server-side. No IOU created for them. |
| Owner assigns all items to themselves | RPC skips owner's share. No IOUs generated. Alert shows "0 IOUs created." |
| User cancels mid-flow after ReceiptReview persist | `receipt_splits` record exists in DB with no participants or assignments. Safe — it just sits there. A cleanup job or cascade delete could remove orphans later. |
| User retakes photo / goes back past ReceiptReview | Context `draft.splitId` is overwritten on next ReceiptReview confirm, creating a second split record. Previous orphan is not deleted. |
| Same receipt submitted twice | Server-side idempotency via `generated_iou_id` prevents duplicate IOUs. Duplicate `receipt_splits` rows are possible. |
| `calculate_receipt_split_totals` RPC fails | Local `splitCalculator.ts` result remains the UI source of truth. Error is swallowed silently. |

---

## 10. Next Steps (Priority Order)

1. **[Done]** Wire `ReceiptReviewScreen` → `persistReceiptSplit`
2. **[Done]** Wire `ReceiptParticipantsScreen` → `persistParticipants`
3. **[Done]** Wire `AssignItemsScreen` → debounced upsert + RPC + realtime
4. **[Done]** Animate `ReceiptTotalsBar` chips
5. **[Done]** Wire `ReceiptSummaryScreen` → `generate_ious_from_receipt_split`
6. **[Next]** Replace `MOCK_FRIENDS` in `ReceiptParticipantsScreen` with real user search (reuse `search-counterparty` edge function)
7. **[Next]** Connect real OCR/AI for `receiptParser.ts` (currently hardcoded sample)
8. **[Later]** Add due date picker before "Send IOUs" (currently defaults to +7 days)
9. **[Later]** Handle mid-flow cancellation — delete orphan `receipt_splits` if user exits before participants
10. **[Later]** Remove or repurpose `ReceiptPaymentConfirmScreen`
