-- Roll back secure IOU acceptance and restore the prior client privilege surface.
-- Existing acceptance evidence is preserved.

begin;

drop function if exists public.accept_iou_with_legal(
  uuid,
  text,
  text,
  text,
  boolean,
  boolean,
  boolean,
  boolean,
  text,
  text,
  jsonb,
  jsonb
);

grant insert
  on table public.iou_acceptance_audit
  to public, anon, authenticated;

grant insert
  on table public.legal_acceptances
  to public, anon, authenticated;

grant execute
  on function public.accept_iou_request(uuid)
  to public, anon, authenticated, service_role;

grant execute
  on function public.activate_iou(uuid, text)
  to public, anon, authenticated, service_role;

grant execute
  on function public.record_legal_acceptance(
    text,
    text,
    text,
    uuid,
    text,
    text,
    jsonb,
    jsonb,
    text
  )
  to public, anon, authenticated, service_role;

grant execute
  on function public.has_current_legal_acceptance(text, text)
  to public, anon, authenticated, service_role;

commit;
