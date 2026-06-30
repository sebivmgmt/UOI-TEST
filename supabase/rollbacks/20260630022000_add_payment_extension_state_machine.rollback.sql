begin;

-- ============================================================================
-- Restore the exact client privileges that existed immediately before
-- 20260630022000_add_payment_extension_state_machine.sql was applied.
--
-- This rollback intentionally restores the historical DEV privilege state,
-- including privileges that the forward migration removes for security.
-- ============================================================================

grant update
on table public.payments
to anon, authenticated;

grant insert, update, delete
on table public.payment_receipts
to anon, authenticated;

grant execute
on function public.claim_payment(uuid, uuid)
to public, anon, authenticated, service_role;

grant execute
on function public.reject_payment(uuid)
to public, anon, authenticated, service_role;

grant execute
on function public.refresh_iou_status(uuid)
to public, anon, authenticated, service_role;

drop function if exists public.request_payment_extension(uuid, date, text);

drop function if exists public.decide_payment_extension(uuid, text);

drop trigger if exists payment_extension_events_block_mutation
on public.payment_extension_events;

drop function if exists public.block_payment_extension_event_mutation();

drop table if exists public.payment_extension_events;

alter table public.payments
  drop column if exists extension_request_id;

alter table public.payments
  drop column if exists extension_original_due_date;

commit;
