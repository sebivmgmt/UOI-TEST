-- One-time cleanup after disabling legacy scoring/exposure drift.
-- Skips legacy signed IOUs above the current standard APR cap because
-- updating those rows violates ious_apr_bps_standard_cap_check.

select public.recompute_iou_exposure(id)
from public.ious
where activated_at is not null
  and deleted_at is null
  and archived_at is null
  and status in ('open', 'late')
  and (apr_bps is null or apr_bps <= 1600);

select public.recalculate_profile_exposure(id)
from public.profiles;
