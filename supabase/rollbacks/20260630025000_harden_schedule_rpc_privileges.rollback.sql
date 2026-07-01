-- Roll back schedule lifecycle RPC privilege hardening.
-- Restores the privilege surface observed before migration 20260630025000.

grant execute on function public.finalize_iou_schedule(uuid,jsonb,text,uuid,uuid,bigint,integer,date,integer,text) to public;
grant execute on function public.finalize_iou_schedule(uuid,jsonb,text,uuid,uuid,bigint,integer,date,integer,text) to anon;
grant execute on function public.finalize_iou_schedule(uuid,jsonb,text,uuid,uuid,bigint,integer,date,integer,text) to authenticated;
grant execute on function public.finalize_iou_schedule(uuid,jsonb,text,uuid,uuid,bigint,integer,date,integer,text) to service_role;

grant execute on function public.propose_schedule_change(uuid,jsonb) to public;
grant execute on function public.propose_schedule_change(uuid,jsonb) to anon;
grant execute on function public.propose_schedule_change(uuid,jsonb) to authenticated;
grant execute on function public.propose_schedule_change(uuid,jsonb) to service_role;

grant execute on function public.reject_schedule_change(uuid) to public;
grant execute on function public.reject_schedule_change(uuid) to anon;
grant execute on function public.reject_schedule_change(uuid) to authenticated;
grant execute on function public.reject_schedule_change(uuid) to service_role;
