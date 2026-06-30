begin;

-- Restore the direct client privileges that existed immediately before
-- 20260630023000_add_atomic_iou_creation_rpc.sql.
--
-- payments UPDATE remains revoked because that restriction belongs to the
-- earlier payment-extension state-machine migration.

grant insert
on table public.ious
to anon, authenticated;

grant insert, delete
on table public.payments
to anon, authenticated;

drop function if exists public.create_iou_with_schedule(
  text,
  uuid,
  uuid,
  bigint,
  integer,
  date,
  integer,
  text,
  text,
  text
);

commit;
