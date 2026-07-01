-- Harden schedule lifecycle RPC execution privileges.
-- DEV follow-up to secure IOU acceptance hardening.
-- This migration intentionally changes privileges only.

revoke all on function public.finalize_iou_schedule(uuid,jsonb,text,uuid,uuid,bigint,integer,date,integer,text) from public;
revoke all on function public.finalize_iou_schedule(uuid,jsonb,text,uuid,uuid,bigint,integer,date,integer,text) from anon;
grant execute on function public.finalize_iou_schedule(uuid,jsonb,text,uuid,uuid,bigint,integer,date,integer,text) to authenticated;
grant execute on function public.finalize_iou_schedule(uuid,jsonb,text,uuid,uuid,bigint,integer,date,integer,text) to service_role;

revoke all on function public.propose_schedule_change(uuid,jsonb) from public;
revoke all on function public.propose_schedule_change(uuid,jsonb) from anon;
grant execute on function public.propose_schedule_change(uuid,jsonb) to authenticated;
grant execute on function public.propose_schedule_change(uuid,jsonb) to service_role;

revoke all on function public.reject_schedule_change(uuid) from public;
revoke all on function public.reject_schedule_change(uuid) from anon;
grant execute on function public.reject_schedule_change(uuid) to authenticated;
grant execute on function public.reject_schedule_change(uuid) to service_role;
