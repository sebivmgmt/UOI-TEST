


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';


SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."ious" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "lender_id" "uuid" NOT NULL,
    "borrower_id" "uuid" NOT NULL,
    "principal_cents" bigint NOT NULL,
    "apr_bps" integer DEFAULT 0,
    "start_date" "date" NOT NULL,
    "term_months" integer NOT NULL,
    "frequency" "text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "title" "text",
    "contract_text" "text",
    "is_archived" boolean DEFAULT false NOT NULL,
    "archived_at" timestamp with time zone,
    "archived_by" "uuid",
    "deleted_at" timestamp with time zone,
    "lender_signature" "text",
    "borrower_signature" "text",
    "lender_signed_at" timestamp with time zone,
    "borrower_signed_at" timestamp with time zone,
    "activated_at" timestamp with time zone,
    "contract_hash" "text",
    "total_installments" integer DEFAULT 0,
    "paid_installments" integer DEFAULT 0,
    "progress_percent" numeric DEFAULT 0,
    "exposure_points" integer DEFAULT 0 NOT NULL,
    "autopay_enabled" boolean DEFAULT true,
    "autopay_day" integer,
    "created_by" "uuid",
    "requested_action_by" "uuid",
    "accepted_at" timestamp with time zone,
    "denied_at" timestamp with time zone,
    "denied_by" "uuid",
    "denial_reason" "text",
    CONSTRAINT "ious_frequency_check" CHECK (("frequency" = ANY (ARRAY['weekly'::"text", 'biweekly'::"text", 'monthly'::"text"]))),
    CONSTRAINT "ious_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'open'::"text", 'late'::"text", 'paid'::"text", 'archived'::"text", 'canceled'::"text", 'denied'::"text", 'pending_acceptance'::"text", 'pending_counterparty'::"text", 'pending_lender_review'::"text"])))
);


ALTER TABLE "public"."ious" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."accept_iou_request"("p_iou_id" "uuid") RETURNS "public"."ious"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_iou            public.ious%ROWTYPE;
  v_payment_count  integer;
  v_payment_total  bigint;
BEGIN
  SELECT * INTO v_iou
  FROM public.ious
  WHERE id = p_iou_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'IOU not found: %', p_iou_id;
  END IF;

  IF v_iou.activated_at IS NOT NULL THEN
    RAISE EXCEPTION 'IOU is already active';
  END IF;

  IF v_iou.status NOT IN ('open', 'pending_acceptance', 'pending_counterparty') THEN
    RAISE EXCEPTION 'IOU is not in a pending state (status: %)', v_iou.status;
  END IF;

  SELECT COUNT(*), COALESCE(SUM(amount_cents), 0)
  INTO v_payment_count, v_payment_total
  FROM public.payments
  WHERE iou_id = p_iou_id
    AND status = 'scheduled';

  IF v_payment_count = 0 THEN
    RAISE EXCEPTION 'IOU has no payment schedule. Edit and save the schedule before accepting.';
  END IF;

  IF v_payment_total < v_iou.principal_cents THEN
    RAISE EXCEPTION 'Payment schedule total (% cents) is less than the principal (% cents). Regenerate the schedule.',
      v_payment_total, v_iou.principal_cents;
  END IF;

  UPDATE public.ious
  SET
    activated_at = NOW(),
    requested_action_by = NULL
  WHERE id = p_iou_id
  RETURNING * INTO v_iou;

  RETURN v_iou;
END;
$$;


ALTER FUNCTION "public"."accept_iou_request"("p_iou_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."activate_iou"("p_iou_id" "uuid", "p_contract_text" "text" DEFAULT NULL::"text") RETURNS "public"."ious"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_actor uuid;
  v_iou public.ious%rowtype;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'Not authenticated.';
  end if;

  select *
    into v_iou
  from public.ious
  where id = p_iou_id
  for update;

  if not found then
    raise exception 'IOU not found.';
  end if;

  if v_iou.lender_id is distinct from v_actor then
    raise exception 'Only the lender can activate this IOU.';
  end if;

  if v_iou.activated_at is not null then
    return v_iou;
  end if;

  if v_iou.status = 'paid' then
    raise exception 'Cannot activate a paid IOU.';
  end if;

  update public.ious
  set
    status = 'open',
    activated_at = now(),
    contract_text = coalesce(p_contract_text, contract_text)
  where id = p_iou_id
  returning *
  into v_iou;

  perform public.recompute_iou_progress(p_iou_id);
  perform public.recompute_iou_exposure(p_iou_id);

  select *
    into v_iou
  from public.ious
  where id = p_iou_id;

  return v_iou;
end;
$$;


ALTER FUNCTION "public"."activate_iou"("p_iou_id" "uuid", "p_contract_text" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_default_strike"("p_user_id" "uuid", "p_iou_id" "uuid" DEFAULT NULL::"uuid", "p_reason" "text" DEFAULT 'defaulted_loan'::"text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_profile public.profiles%rowtype;
  v_new_strike integer;
  v_new_score integer;
  v_event_key text;
begin
  if p_user_id is null then
    raise exception 'Missing user id';
  end if;

  select *
  into v_profile
  from public.profiles
  where id = p_user_id
  for update;

  if not found then
    raise exception 'Profile not found for user %', p_user_id;
  end if;

  v_new_strike := coalesce(v_profile.strike_count, 0) + 1;
  v_event_key := 'strike:' || p_user_id::text || ':' || coalesce(p_iou_id::text, 'none') || ':' || v_new_strike::text;

  if exists (
    select 1
    from public.score_events
    where event_key = v_event_key
  ) then
    return v_profile.strike_count;
  end if;

  if v_new_strike = 1 then
    v_new_score := greatest(0, coalesce(v_profile.iou_score, 700) - 200);

    update public.profiles
    set
      strike_count = v_new_strike,
      iou_score = v_new_score,
      score_last_updated_at = now()
    where id = p_user_id;

    insert into public.score_events (
      user_id, iou_id, event_type, delta, description, event_key
    )
    values (
      p_user_id, p_iou_id, 'strike_1', -200, p_reason, v_event_key
    );

  elsif v_new_strike = 2 then
    v_new_score := greatest(0, coalesce(v_profile.iou_score, 700) - 200);

    update public.profiles
    set
      strike_count = v_new_strike,
      iou_score = v_new_score,
      score_last_updated_at = now()
    where id = p_user_id;

    insert into public.score_events (
      user_id, iou_id, event_type, delta, description, event_key
    )
    values (
      p_user_id, p_iou_id, 'strike_2', -200, p_reason, v_event_key
    );

  else
    update public.profiles
    set
      strike_count = v_new_strike,
      iou_score = 333,
      lifetime_score_cap = 700,
      score_last_updated_at = now()
    where id = p_user_id;

    insert into public.score_events (
      user_id, iou_id, event_type, delta, description, event_key
    )
    values (
      p_user_id, p_iou_id, 'strike_3', 0,
      p_reason || ' | score forced to 333, lifetime cap set to 700',
      v_event_key
    );
  end if;

  return v_new_strike;
end;
$$;


ALTER FUNCTION "public"."apply_default_strike"("p_user_id" "uuid", "p_iou_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_payment_score_event"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_iou public.ious%rowtype;
  v_due_date date;
  v_paid_date date;
  v_reward integer := 0;
  v_event_type text;
  v_desc text;
  v_unpaid_count integer := 0;
  v_default_already_applied boolean := false;
begin
  select *
  into v_iou
  from public.ious
  where id = new.iou_id;

  if not found or v_iou.borrower_id is null then
    return new;
  end if;

  if coalesce(new.failed_attempts, 0) >= 8
     and (
       tg_op = 'INSERT'
       or coalesce(old.failed_attempts, 0) < 8
     ) then

    select exists (
      select 1
      from public.score_events
      where iou_id = new.iou_id
        and event_type in ('strike_1', 'strike_2', 'strike_3')
    )
    into v_default_already_applied;

    if not coalesce(v_default_already_applied, false) then
      perform public.apply_default_strike(
        v_iou.borrower_id,
        v_iou.id,
        'Payment default: failed attempts reached 8'
      );
    end if;

    return new;
  end if;

  if new.paid_at is null then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.paid_at is not null then
    return new;
  end if;

  v_due_date :=
    coalesce(
      new.due_date,
      new.due_at::date,
      new.scheduled_at
    );

  if v_due_date is null then
    return new;
  end if;

  v_paid_date := new.paid_at::date;

  if v_paid_date < v_due_date then
    v_reward := public.iou_score_medium_early_reward();
    v_event_type := 'payment_early';
    v_desc := 'Early payment confirmed';

  elsif v_paid_date = v_due_date then
    v_reward := public.iou_score_small_on_time_reward();
    v_event_type := 'payment_on_time';
    v_desc := 'On-time payment confirmed';

  else
    v_reward := 0;
    v_event_type := 'payment_late';
    v_desc := 'Late payment confirmed';
  end if;

  if v_reward <> 0 then
    perform public.apply_score_event_once(
      v_iou.borrower_id,
      v_event_type,
      v_reward,
      v_desc,
      v_iou.id,
      new.id,
      'payment:' || new.id::text || ':' || v_event_type
    );
  end if;

  select count(*)
  into v_unpaid_count
  from public.payments
  where iou_id = new.iou_id
    and paid_at is null;

  if coalesce(v_unpaid_count, 0) = 0 then
    perform public.apply_score_event_once(
      v_iou.borrower_id,
      'loan_completed',
      public.iou_score_large_completion_reward(),
      'Loan completed',
      v_iou.id,
      new.id,
      'completion:' || v_iou.id::text
    );
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."apply_payment_score_event"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_score_event_once"("p_user_id" "uuid", "p_event_type" "text", "p_delta" integer, "p_description" "text" DEFAULT NULL::"text", "p_iou_id" "uuid" DEFAULT NULL::"uuid", "p_payment_id" "uuid" DEFAULT NULL::"uuid", "p_event_key" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_profile public.profiles%rowtype;
  v_new_score integer;
  v_inserted_id uuid;
begin
  if p_user_id is null then
    return false;
  end if;

  if p_event_key is not null then
    if exists (
      select 1
      from public.score_events
      where event_key = p_event_key
    ) then
      return false;
    end if;
  end if;

  select *
  into v_profile
  from public.profiles
  where id = p_user_id
  for update;

  if not found then
    return false;
  end if;

  v_new_score := coalesce(v_profile.iou_score, 700) + coalesce(p_delta, 0);
  v_new_score := greatest(0, v_new_score);

  if v_profile.lifetime_score_cap is not null then
    v_new_score := least(v_new_score, v_profile.lifetime_score_cap);
  end if;

  update public.profiles
  set
    iou_score = v_new_score,
    score_last_updated_at = now()
  where id = p_user_id;

  insert into public.score_events (
    user_id,
    iou_id,
    payment_id,
    event_type,
    delta,
    description,
    event_key
  )
  values (
    p_user_id,
    p_iou_id,
    p_payment_id,
    p_event_type,
    coalesce(p_delta, 0),
    p_description,
    p_event_key
  )
  returning id into v_inserted_id;

  return v_inserted_id is not null;
end;
$$;


ALTER FUNCTION "public"."apply_score_event_once"("p_user_id" "uuid", "p_event_type" "text", "p_delta" integer, "p_description" "text", "p_iou_id" "uuid", "p_payment_id" "uuid", "p_event_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."archive_iou"("p_iou" "uuid", "p_archived" boolean DEFAULT true) RETURNS "public"."ious"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_row public.ious;
begin
  select * into v_row from public.ious where id = p_iou for update;
  if v_row.id is null then raise exception 'IOU not found'; end if;
  if v_row.lender_id <> auth.uid() then raise exception 'Not allowed'; end if;

  update public.ious
     set archived_at = case when p_archived then now() else null end
   where id = p_iou
  returning * into v_row;

  return v_row;
end;
$$;


ALTER FUNCTION "public"."archive_iou"("p_iou" "uuid", "p_archived" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."build_receipt_canonical"("p_iou_id" "uuid", "p_payment_id" "uuid", "p_actor" "uuid", "p_amount_cents" integer, "p_scheduled_at" timestamp with time zone, "p_paid_at" timestamp with time zone) RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$
  select
    'iou_id='||p_iou_id||E'\n'||
    'payment_id='||p_payment_id||E'\n'||
    'actor='||p_actor||E'\n'||
    'amount_cents='||p_amount_cents||E'\n'||
    'scheduled_at='||to_char(p_scheduled_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')||E'\n'||
    'paid_at='||to_char(p_paid_at    at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
$$;


ALTER FUNCTION "public"."build_receipt_canonical"("p_iou_id" "uuid", "p_payment_id" "uuid", "p_actor" "uuid", "p_amount_cents" integer, "p_scheduled_at" timestamp with time zone, "p_paid_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_iou_exposure"("p_principal_cents" numeric, "p_apr_bps" numeric, "p_borrower_score" integer) RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_size_points integer := 0;
  v_apr_points integer := 0;
  v_score_points integer := 0;
  v_total integer := 0;
begin
  if p_principal_cents < 20000 then
    v_size_points := 5;
  elsif p_principal_cents < 50000 then
    v_size_points := 10;
  elsif p_principal_cents < 100000 then
    v_size_points := 18;
  elsif p_principal_cents < 200000 then
    v_size_points := 28;
  else
    v_size_points := 40;
  end if;

  if p_apr_bps <= 800 then
    v_apr_points := 0;
  elsif p_apr_bps <= 1500 then
    v_apr_points := 2;
  elsif p_apr_bps <= 2500 then
    v_apr_points := 4;
  else
    v_apr_points := 6;
  end if;

  if p_borrower_score >= 900 then
    v_score_points := -2;
  elsif p_borrower_score >= 800 then
    v_score_points := 0;
  elsif p_borrower_score >= 700 then
    v_score_points := 2;
  else
    v_score_points := 4;
  end if;

  v_total := v_size_points + v_apr_points + v_score_points;
  return least(70, greatest(0, v_total));
end;
$$;


ALTER FUNCTION "public"."calculate_iou_exposure"("p_principal_cents" numeric, "p_apr_bps" numeric, "p_borrower_score" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_receipt_split_totals"("p_receipt_split_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_subtotal_cents integer := 0;
  v_tax_cents integer := 0;
  v_tip_cents integer := 0;
  v_total_assigned bigint := 0;
  v_rounding_diff integer := 0;
  v_largest_participant uuid;
begin

  -- Validate ownership / membership
  if not exists (
    select 1
    from receipt_splits rs
    where rs.id = p_receipt_split_id
      and (
        rs.owner_id = auth.uid()
        or exists (
          select 1
          from receipt_split_participants p
          where p.receipt_split_id = rs.id
            and p.user_id = auth.uid()
        )
      )
  ) then
    raise exception 'Access denied';
  end if;

  -- Load receipt values
  select
    subtotal_cents,
    tax_cents,
    tip_cents
  into
    v_subtotal_cents,
    v_tax_cents,
    v_tip_cents
  from receipt_splits
  where id = p_receipt_split_id;

  -- Clear old totals
  delete from receipt_split_totals
  where receipt_split_id = p_receipt_split_id;

  -- =====================================================
  -- STEP 1: ITEM TOTALS
  -- =====================================================

  insert into receipt_split_totals (
    receipt_split_id,
    participant_id,
    items_total_cents,
    tax_share_cents,
    tip_share_cents,
    total_owed_cents
  )
  select
    p_receipt_split_id,
    ria.participant_id,

    round(sum(
      (
        rsi.total_price_cents::numeric
        * (ria.share_percent / 100.0)
      )
    ))::integer as items_total_cents,

    0,
    0,
    0

  from receipt_item_assignments ria
  join receipt_split_items rsi
    on rsi.id = ria.item_id

  where ria.receipt_split_id = p_receipt_split_id

  group by ria.participant_id;

  -- =====================================================
  -- STEP 2: PROPORTIONAL TAX/TIP
  -- =====================================================

  update receipt_split_totals rst
  set
    tax_share_cents =
      case
        when v_subtotal_cents <= 0 then 0
        else round(
          (rst.items_total_cents::numeric / v_subtotal_cents)
          * v_tax_cents
        )::integer
      end,

    tip_share_cents =
      case
        when v_subtotal_cents <= 0 then 0
        else round(
          (rst.items_total_cents::numeric / v_subtotal_cents)
          * v_tip_cents
        )::integer
      end

  where rst.receipt_split_id = p_receipt_split_id;

  -- =====================================================
  -- STEP 3: FINAL TOTALS
  -- =====================================================

  update receipt_split_totals
  set total_owed_cents =
    items_total_cents
    + tax_share_cents
    + tip_share_cents
  where receipt_split_id = p_receipt_split_id;

  -- =====================================================
  -- STEP 4: ROUNDING CORRECTION
  -- =====================================================

  select coalesce(sum(total_owed_cents), 0)
  into v_total_assigned
  from receipt_split_totals
  where receipt_split_id = p_receipt_split_id;

  select
    (
      subtotal_cents
      + tax_cents
      + tip_cents
    ) - v_total_assigned
  into v_rounding_diff
  from receipt_splits
  where id = p_receipt_split_id;

  -- Apply rounding diff to largest participant
  if v_rounding_diff <> 0 then

    select participant_id
    into v_largest_participant
    from receipt_split_totals
    where receipt_split_id = p_receipt_split_id
    order by total_owed_cents desc
    limit 1;

    update receipt_split_totals
    set total_owed_cents =
      total_owed_cents + v_rounding_diff
    where receipt_split_id = p_receipt_split_id
      and participant_id = v_largest_participant;

  end if;

  -- =====================================================
  -- STEP 5: MARK READY
  -- =====================================================

  update receipt_splits
  set
    status = 'ready',
    updated_at = now()
  where id = p_receipt_split_id;

end;
$$;


ALTER FUNCTION "public"."calculate_receipt_split_totals"("p_receipt_split_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "iou_id" "uuid" NOT NULL,
    "due_date" "date" NOT NULL,
    "amount_cents" bigint NOT NULL,
    "status" "text" DEFAULT 'scheduled'::"text" NOT NULL,
    "paid_at" timestamp with time zone,
    "tx_ref" "text",
    "loan_id" "uuid",
    "due_at" timestamp with time zone,
    "scheduled_at" "date" GENERATED ALWAYS AS ("due_date") STORED,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "updated_by" "uuid",
    "claimed_paid_at" timestamp with time zone,
    "claimed_by" "uuid",
    "confirmed_paid_at" timestamp with time zone,
    "confirmed_by" "uuid",
    "late_marked" boolean DEFAULT false,
    "failed_attempts" integer DEFAULT 0,
    "payment_method" "text",
    "initiated_at" timestamp without time zone,
    "extension_requested_at" timestamp with time zone,
    "extension_requested_by" "uuid",
    "extension_requested_until" "date",
    "extension_status" "text" DEFAULT 'none'::"text",
    "extension_reason" "text",
    "extension_decision_at" timestamp with time zone,
    "extension_decided_by" "uuid",
    CONSTRAINT "payments_amount_positive" CHECK (("amount_cents" > 0)),
    CONSTRAINT "payments_extension_status_check" CHECK (("extension_status" = ANY (ARRAY['none'::"text", 'requested'::"text", 'approved'::"text", 'denied'::"text"]))),
    CONSTRAINT "payments_status_check" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'pending_confirmation'::"text", 'paid'::"text", 'late'::"text"]))),
    CONSTRAINT "payments_status_check_v2" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'pending_confirmation'::"text", 'paid'::"text", 'late'::"text"]))),
    CONSTRAINT "payments_status_chk" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'processing'::"text", 'pending_confirmation'::"text", 'paid'::"text", 'late'::"text", 'failed'::"text", 'missed'::"text", 'defaulted'::"text"])))
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_payment"("p_payment_id" "uuid", "p_actor" "uuid") RETURNS "public"."payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_payment public.payments%ROWTYPE;
  v_iou public.ious%ROWTYPE;
BEGIN
  SELECT *
  INTO v_payment
  FROM public.payments
  WHERE id = p_payment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment not found.';
  END IF;

  IF v_payment.paid_at IS NOT NULL THEN
    RAISE EXCEPTION 'Payment already paid.';
  END IF;

  IF v_payment.status = 'pending_confirmation' THEN
    RAISE EXCEPTION 'Payment is already waiting for lender confirmation.';
  END IF;

  SELECT *
  INTO v_iou
  FROM public.ious
  WHERE id = v_payment.iou_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Linked IOU not found.';
  END IF;

  IF auth.uid() IS DISTINCT FROM p_actor THEN
    RAISE EXCEPTION 'Actor does not match authenticated user.';
  END IF;

  IF v_iou.borrower_id IS DISTINCT FROM p_actor THEN
    RAISE EXCEPTION 'Only the borrower can start this payment.';
  END IF;

  IF v_iou.activated_at IS NULL THEN
    RAISE EXCEPTION 'IOU must be active before payments can be submitted.';
  END IF;

  UPDATE public.payments
  SET
    status = 'pending_confirmation',
    payment_method = COALESCE(payment_method, 'manual'),
    initiated_at = COALESCE(initiated_at, NOW()),
    claimed_paid_at = COALESCE(claimed_paid_at, NOW()),
    claimed_by = p_actor,
    updated_at = NOW(),
    updated_by = p_actor
  WHERE id = p_payment_id
  RETURNING * INTO v_payment;

  PERFORM public.refresh_iou_status(v_payment.iou_id);

  RETURN v_payment;
END;
$$;


ALTER FUNCTION "public"."claim_payment"("p_payment_id" "uuid", "p_actor" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_trust_report_share"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text" DEFAULT 'summary'::"text", "p_expires_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_reason" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_share_id uuid;
  v_latest_snapshot_id uuid;
begin
  if p_owner_user_id is null or p_viewer_user_id is null then
    raise exception 'Missing owner or viewer user id';
  end if;

  if p_owner_user_id = p_viewer_user_id then
    raise exception 'Cannot create Trust Report share with self';
  end if;

  select id
  into v_latest_snapshot_id
  from public.trust_score_snapshots
  where user_id = p_owner_user_id
  order by created_at desc
  limit 1;

  insert into public.trust_report_shares (
    owner_user_id,
    viewer_user_id,
    trust_score_snapshot_id,
    scope,
    expires_at,
    reason,
    metadata
  )
  values (
    p_owner_user_id,
    p_viewer_user_id,
    v_latest_snapshot_id,
    coalesce(p_scope, 'summary'),
    p_expires_at,
    p_reason,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_share_id;

  insert into public.trust_report_access_logs (
    owner_user_id,
    viewer_user_id,
    trust_report_share_id,
    access_type,
    scope,
    metadata
  )
  values (
    p_owner_user_id,
    p_viewer_user_id,
    v_share_id,
    'share_created',
    coalesce(p_scope, 'summary'),
    jsonb_build_object('reason', p_reason)
  );

  return v_share_id;
end;
$$;


ALTER FUNCTION "public"."create_trust_report_share"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text", "p_expires_at" timestamp with time zone, "p_reason" "text", "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_trust_score_snapshot"("p_user_id" "uuid", "p_snapshot_reason" "text" DEFAULT 'manual_snapshot'::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_profile public.profiles%rowtype;
  v_snapshot_id uuid;

  v_score integer;
  v_exposure integer;
  v_freshness integer := 100;
  v_visible_trust integer;
  v_proof_depth integer := 0;
  v_confidence integer := 0;
  v_tier text;

  v_total_agreements integer := 0;
  v_active_agreements integer := 0;
  v_total_ceiling integer := 0;
  v_total_contributed integer := 0;
  v_risk_flags integer := 0;
begin
  if p_user_id is null then
    raise exception 'Missing user id';
  end if;

  select *
  into v_profile
  from public.profiles
  where id = p_user_id;

  if not found then
    raise exception 'Profile not found for user %', p_user_id;
  end if;

  v_score := greatest(300, coalesce(v_profile.iou_score, 700));
  v_exposure := greatest(0, coalesce(v_profile.active_exposure_points, 0));

  select
    count(*),
    count(*) filter (where status in ('active', 'completed')),
    coalesce(sum(score_ceiling), 0),
    coalesce(sum(score_contributed), 0)
  into
    v_total_agreements,
    v_active_agreements,
    v_total_ceiling,
    v_total_contributed
  from public.score_agreements
  where user_id = p_user_id;

  select count(*)
  into v_risk_flags
  from public.score_risk_flags
  where user_id = p_user_id
    and is_active = true;

  -- Early shadow approximation:
  -- Proof depth grows with verified agreements and ceiling diversity.
  v_proof_depth := least(
    100,
    greatest(
      0,
      (v_active_agreements * 10)
      + least(40, floor(v_total_ceiling / 25)::integer)
    )
  );

  -- Confidence uses proof depth and freshness.
  v_confidence := least(
    100,
    greatest(
      0,
      round((v_proof_depth * 0.70) + (v_freshness * 0.30))::integer
    )
  );

  v_visible_trust := public.score_v2_visible_trust(v_score, v_exposure, v_freshness);

  v_tier := public.score_v2_trust_tier(
    v_score,
    greatest(0, floor(extract(epoch from (now() - coalesce(v_profile.created_at, now()))) / 86400)::integer),
    v_proof_depth,
    coalesce(v_profile.strike_count, 0) > 0,
    v_risk_flags > 0
  );

  insert into public.trust_score_snapshots (
    user_id,
    model_key,
    model_version,
    public_score,
    visible_trust,
    active_exposure_points,
    trust_tier,
    proof_depth,
    proof_depth_label,
    confidence_score,
    confidence_label,
    freshness_score,
    trend_30d,
    score_agreement_count,
    active_score_agreement_count,
    score_ceiling_total,
    score_contributed_total,
    risk_flag_count,
    active_strike_count,
    snapshot_reason,
    summary
  )
  values (
    p_user_id,
    'iou_score',
    'v2.0-shadow',
    v_score,
    v_visible_trust,
    v_exposure,
    v_tier,
    v_proof_depth,
    public.score_v2_proof_depth_label(v_proof_depth),
    v_confidence,
    public.score_v2_confidence_label(v_confidence),
    v_freshness,
    'stable',
    v_total_agreements,
    v_active_agreements,
    v_total_ceiling,
    v_total_contributed,
    v_risk_flags,
    coalesce(v_profile.strike_count, 0),
    coalesce(p_snapshot_reason, 'manual_snapshot'),
    jsonb_build_object(
      'shadow_mode', true,
      'raw_score_decay', false,
      'note', 'Snapshot generated for Score v2 trust intelligence learning loop.'
    )
  )
  returning id into v_snapshot_id;

  return v_snapshot_id;
end;
$$;


ALTER FUNCTION "public"."create_trust_score_snapshot"("p_user_id" "uuid", "p_snapshot_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_iou_soft"("p_iou" "uuid") RETURNS "public"."ious"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_row public.ious;
  v_has_paid boolean;
begin
  select * into v_row from public.ious where id = p_iou for update;
  if v_row.id is null then raise exception 'IOU not found'; end if;
  if v_row.lender_id <> auth.uid() then raise exception 'Not allowed'; end if;

  select exists (
    select 1 from public.payments
     where loan_id = p_iou and paid_at is not null
  ) into v_has_paid;

  if v_row.status is distinct from 'draft' and v_has_paid then
    raise exception 'Cannot delete: IOU has recorded payments or is not in draft status';
  end if;

  update public.ious
     set deleted_at = now(), archived_at = null
   where id = p_iou
  returning * into v_row;

  return v_row;
end;
$$;


ALTER FUNCTION "public"."delete_iou_soft"("p_iou" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_loan"("p_loan" "uuid", "p_user" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  delete from public.loans
   where id = p_loan
     and lender_id = p_user
     and status in ('draft','archived');
end $$;


ALTER FUNCTION "public"."delete_loan"("p_loan" "uuid", "p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."deny_iou_request"("p_iou_id" "uuid", "p_reason" "text" DEFAULT NULL::"text") RETURNS "public"."ious"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_iou public.ious;
BEGIN
  SELECT *
  INTO v_iou
  FROM public.ious
  WHERE id = p_iou_id;

  IF v_iou.id IS NULL THEN
    RAISE EXCEPTION 'IOU not found';
  END IF;

  IF v_iou.requested_action_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Not allowed to deny this IOU';
  END IF;

  IF v_iou.status IS DISTINCT FROM 'pending_counterparty' THEN
    RAISE EXCEPTION 'IOU is not pending';
  END IF;

  UPDATE public.ious
  SET
    status = 'denied',
    denied_at = NOW(),
    denied_by = auth.uid(),
    denial_reason = NULLIF(TRIM(p_reason), '')
  WHERE id = p_iou_id
  RETURNING * INTO v_iou;

  RETURN v_iou;
END;
$$;


ALTER FUNCTION "public"."deny_iou_request"("p_iou_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."finalize_iou_schedule"("p_iou_id" "uuid", "p_payments" "jsonb", "p_title" "text" DEFAULT NULL::"text", "p_lender_id" "uuid" DEFAULT NULL::"uuid", "p_borrower_id" "uuid" DEFAULT NULL::"uuid", "p_principal_cents" bigint DEFAULT NULL::bigint, "p_apr_bps" integer DEFAULT NULL::integer, "p_start_date" "date" DEFAULT NULL::"date", "p_term_months" integer DEFAULT NULL::integer, "p_frequency" "text" DEFAULT NULL::"text") RETURNS TABLE("id" "uuid", "status" "text", "total_installments" integer, "scheduled_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_iou public.ious%ROWTYPE;
  v_count bigint := 0;
  v_total bigint := 0;
  v_final_principal bigint := 0;
BEGIN
  SELECT i.*
  INTO v_iou
  FROM public.ious i
  WHERE i.id = p_iou_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'IOU not found: %', p_iou_id;
  END IF;

  IF auth.uid() IS DISTINCT FROM v_iou.lender_id THEN
    RAISE EXCEPTION 'Only the lender may finalize the payment schedule';
  END IF;

  IF v_iou.activated_at IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot edit the schedule of an already-activated IOU';
  END IF;

  IF p_payments IS NULL OR jsonb_typeof(p_payments) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Payment schedule must be a JSON array';
  END IF;

  IF jsonb_array_length(p_payments) = 0 THEN
    RAISE EXCEPTION 'Payment schedule cannot be empty';
  END IF;

  v_final_principal := COALESCE(p_principal_cents, v_iou.principal_cents);

  DELETE FROM public.payments pay
  WHERE pay.iou_id = p_iou_id
    AND COALESCE(pay.status, 'scheduled') = 'scheduled';

  INSERT INTO public.payments (
    iou_id,
    due_date,
    amount_cents,
    status
  )
  SELECT
    p_iou_id,
    (r->>'due_date')::date,
    (r->>'amount_cents')::bigint,
    'scheduled'
  FROM jsonb_array_elements(p_payments) AS r
  WHERE (r ? 'due_date')
    AND (r ? 'amount_cents');

  SELECT
    COUNT(*),
    COALESCE(SUM(pay.amount_cents), 0)
  INTO
    v_count,
    v_total
  FROM public.payments pay
  WHERE pay.iou_id = p_iou_id
    AND pay.status = 'scheduled';

  IF v_count = 0 THEN
    RAISE EXCEPTION 'Payment insert produced 0 rows';
  END IF;

  IF v_total < v_final_principal THEN
    RAISE EXCEPTION 'Payment schedule total (% cents) is less than principal (% cents)',
      v_total, v_final_principal;
  END IF;

  UPDATE public.ious i
  SET
    status = 'open',
    requested_action_by = COALESCE(p_borrower_id, v_iou.borrower_id),
    title = COALESCE(p_title, i.title),
    lender_id = COALESCE(p_lender_id, i.lender_id),
    borrower_id = COALESCE(p_borrower_id, i.borrower_id),
    principal_cents = COALESCE(p_principal_cents, i.principal_cents),
    apr_bps = COALESCE(p_apr_bps, i.apr_bps),
    start_date = COALESCE(p_start_date, i.start_date),
    term_months = COALESCE(p_term_months, i.term_months),
    frequency = COALESCE(p_frequency, i.frequency),
    total_installments = v_count::integer,
    paid_installments = 0
  WHERE i.id = p_iou_id;

  PERFORM public.refresh_iou_status(p_iou_id);

  RETURN QUERY
  SELECT
    i.id,
    i.status,
    i.total_installments,
    v_count
  FROM public.ious i
  WHERE i.id = p_iou_id;
END;
$$;


ALTER FUNCTION "public"."finalize_iou_schedule"("p_iou_id" "uuid", "p_payments" "jsonb", "p_title" "text", "p_lender_id" "uuid", "p_borrower_id" "uuid", "p_principal_cents" bigint, "p_apr_bps" integer, "p_start_date" "date", "p_term_months" integer, "p_frequency" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_iou_hash"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_hash text;
  v_attempts integer := 0;
begin
  loop
    v_attempts := v_attempts + 1;

    v_hash :=
      'IOU-' ||
      upper(substr(encode(gen_random_bytes(4), 'hex'), 1, 4)) ||
      '-' ||
      upper(substr(encode(gen_random_bytes(4), 'hex'), 1, 4));

    if not exists (
      select 1
      from public.profiles p
      where p.iou_hash = v_hash
    ) then
      return v_hash;
    end if;

    if v_attempts >= 25 then
      raise exception 'Could not generate unique IOU hash after % attempts', v_attempts;
    end if;
  end loop;
end;
$$;


ALTER FUNCTION "public"."generate_iou_hash"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_ious_from_receipt_split"("p_receipt_split_id" "uuid", "p_due_date" "date" DEFAULT CURRENT_DATE) RETURNS TABLE("participant_id" "uuid", "borrower_id" "uuid", "generated_iou_id" "uuid", "generated_payment_id" "uuid", "amount_cents" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_owner_id uuid;
  v_restaurant_name text;
  v_receipt_date date;
  v_iou_id uuid;
  v_payment_id uuid;
  v_title text;
  r record;
begin
  -- Only the receipt owner can generate IOUs
  select
    rs.owner_id,
    rs.restaurant_name,
    rs.receipt_date
  into
    v_owner_id,
    v_restaurant_name,
    v_receipt_date
  from public.receipt_splits rs
  where rs.id = p_receipt_split_id;

  if v_owner_id is null then
    raise exception 'Receipt split not found';
  end if;

  if v_owner_id <> auth.uid() then
    raise exception 'Only the receipt owner can generate IOUs';
  end if;

  -- Require calculated totals first
  if not exists (
    select 1
    from public.receipt_split_totals rst
    where rst.receipt_split_id = p_receipt_split_id
  ) then
    raise exception 'Receipt split totals have not been calculated yet';
  end if;

  -- Build title
  v_title :=
    case
      when v_restaurant_name is not null and length(trim(v_restaurant_name)) > 0
        then 'Receipt split - ' || trim(v_restaurant_name)
      else 'Receipt split'
    end;

  -- Create one IOU per linked participant who owes money
  for r in
    select
      rst.id as total_row_id,
      rst.participant_id,
      rsp.user_id as borrower_id,
      rst.total_owed_cents::bigint as amount_cents
    from public.receipt_split_totals rst
    join public.receipt_split_participants rsp
      on rsp.id = rst.participant_id
    where rst.receipt_split_id = p_receipt_split_id
      and rst.total_owed_cents > 0
      and rsp.user_id is not null
      and rsp.user_id <> v_owner_id
      and rst.generated_iou_id is null
  loop
    insert into public.ious (
      lender_id,
      borrower_id,
      principal_cents,
      apr_bps,
      start_date,
      term_months,
      frequency,
      status,
      title,
      created_by,
      requested_action_by,
      autopay_enabled,
      total_installments,
      paid_installments,
      progress_percent
    )
    values (
      v_owner_id,
      r.borrower_id,
      r.amount_cents,
      0,
      current_date,
      1,
      'one_time',
      'draft',
      v_title,
      v_owner_id,
      r.borrower_id,
      true,
      1,
      0,
      0
    )
    returning id into v_iou_id;

    insert into public.payments (
      iou_id,
      loan_id,
      due_date,
      scheduled_at,
      due_at,
      amount_cents,
      status
    )
    values (
      v_iou_id,
      v_iou_id,
      p_due_date,
      p_due_date,
      p_due_date::timestamptz,
      r.amount_cents,
      'scheduled'
    )
    returning id into v_payment_id;

    update public.receipt_split_totals
    set
      generated_iou_id = v_iou_id,
      updated_at = now()
    where id = r.total_row_id;

    participant_id := r.participant_id;
    borrower_id := r.borrower_id;
    generated_iou_id := v_iou_id;
    generated_payment_id := v_payment_id;
    amount_cents := r.amount_cents;

    return next;
  end loop;

  update public.receipt_splits
  set
    status = 'sent',
    updated_at = now()
  where id = p_receipt_split_id;

end;
$$;


ALTER FUNCTION "public"."generate_ious_from_receipt_split"("p_receipt_split_id" "uuid", "p_due_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_score_v2_shadow_risk_flags"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_created integer := 0;
  r record;
  v_flag_id uuid;
begin
  -- 1. Same-pair concentration.
  for r in
    select
      sa.user_id,
      sa.counterparty_id,
      count(*) as active_pair_count,
      sum(sa.score_ceiling) as active_pair_ceiling,
      max(sa.same_pair_index) as max_same_pair_index
    from public.score_agreements sa
    where sa.source_type = 'personal_iou'
      and sa.status in ('active', 'completed')
      and sa.counterparty_id is not null
      and public.score_v2_relationship_affects_score(sa.user_id, sa.counterparty_id)
    group by sa.user_id, sa.counterparty_id
    having count(*) >= 5
  loop
    v_flag_id := public.upsert_score_risk_flag(
      r.user_id,
      'same_pair_concentration',
      case
        when r.active_pair_count >= 10 then 'high'
        when r.active_pair_count >= 7 then 'medium'
        else 'low'
      end,
      'profile_pair',
      null,
      'Multiple score-affecting IOUs with the same counterparty.',
      jsonb_build_object(
        'counterparty_id', r.counterparty_id,
        'active_pair_count', r.active_pair_count,
        'active_pair_ceiling', r.active_pair_ceiling,
        'max_same_pair_index', r.max_same_pair_index,
        'shadow_mode', true
      )
    );

    v_created := v_created + 1;
  end loop;

  -- 2. Many tiny IOUs.
  for r in
    select
      sa.user_id,
      count(*) as tiny_iou_count,
      sum(sa.score_ceiling) as tiny_iou_ceiling
    from public.score_agreements sa
    where sa.source_type = 'personal_iou'
      and sa.amount_cents < 10000
      and sa.status in ('active', 'completed')
      and sa.score_ceiling > 0
    group by sa.user_id
    having count(*) >= 5
  loop
    v_flag_id := public.upsert_score_risk_flag(
      r.user_id,
      'many_tiny_ious',
      case
        when r.tiny_iou_count >= 20 then 'high'
        when r.tiny_iou_count >= 10 then 'medium'
        else 'low'
      end,
      'score_agreements',
      null,
      'User has many small IOUs; these should build history more than score.',
      jsonb_build_object(
        'tiny_iou_count', r.tiny_iou_count,
        'tiny_iou_ceiling', r.tiny_iou_ceiling,
        'threshold_amount_cents', 10000,
        'shadow_mode', true
      )
    );

    v_created := v_created + 1;
  end loop;

  -- 3. Self no-score detected.
  for r in
    select
      sa.user_id,
      count(*) as self_iou_count
    from public.score_agreements sa
    where sa.user_id = sa.counterparty_id
      and sa.source_type = 'personal_iou'
    group by sa.user_id
    having count(*) > 0
  loop
    v_flag_id := public.upsert_score_risk_flag(
      r.user_id,
      'self_no_score_detected',
      'low',
      'score_agreements',
      null,
      'Self IOUs were detected and excluded from score impact.',
      jsonb_build_object(
        'self_iou_count', r.self_iou_count,
        'shadow_mode', true
      )
    );

    v_created := v_created + 1;
  end loop;

  -- 4. High active exposure.
  for r in
    select
      id as user_id,
      active_exposure_points
    from public.profiles
    where coalesce(active_exposure_points, 0) >= 50
  loop
    v_flag_id := public.upsert_score_risk_flag(
      r.user_id,
      'high_active_exposure',
      case
        when r.active_exposure_points >= 100 then 'high'
        when r.active_exposure_points >= 70 then 'medium'
        else 'low'
      end,
      'profiles',
      r.user_id,
      'User has elevated active exposure.',
      jsonb_build_object(
        'active_exposure_points', r.active_exposure_points,
        'shadow_mode', true
      )
    );

    v_created := v_created + 1;
  end loop;

  return v_created;
end;
$$;


ALTER FUNCTION "public"."generate_score_v2_shadow_risk_flags"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_iou_ach_readiness"("p_iou_id" "uuid") RETURNS TABLE("iou_id" "uuid", "self_id" "uuid", "counterparty_id" "uuid", "self_ready" boolean, "counterparty_ready" boolean, "both_ready" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_lender_id uuid;
  v_borrower_id uuid;
  v_counterparty_id uuid;
  v_self_ready boolean;
  v_counterparty_ready boolean;
begin
  if v_uid is null then
    raise exception using
      errcode = '42501',
      message = 'not authenticated';
  end if;

  select
    i.lender_id,
    i.borrower_id
  into
    v_lender_id,
    v_borrower_id
  from public.ious i
  where i.id = p_iou_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'IOU not found';
  end if;

  if v_uid = v_lender_id then
    v_counterparty_id := v_borrower_id;
  elsif v_uid = v_borrower_id then
    v_counterparty_id := v_lender_id;
  else
    raise exception using
      errcode = '42501',
      message = 'not an IOU participant';
  end if;

  select coalesce(p.ach_status = 'ready', false)
  into v_self_ready
  from public.profiles p
  where p.id = v_uid;

  select coalesce(p.ach_status = 'ready', false)
  into v_counterparty_ready
  from public.profiles p
  where p.id = v_counterparty_id;

  v_self_ready := coalesce(v_self_ready, false);
  v_counterparty_ready := coalesce(v_counterparty_ready, false);

  return query
  select
    p_iou_id,
    v_uid,
    v_counterparty_id,
    v_self_ready,
    v_counterparty_ready,
    v_self_ready and v_counterparty_ready;
end;
$$;


ALTER FUNCTION "public"."get_iou_ach_readiness"("p_iou_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_iou_contacts"() RETURNS TABLE("id" "uuid", "iou_hash" "text", "public_name" "text", "avatar_url" "text", "iou_score" integer, "active_exposure_points" integer, "strike_count" integer, "last_interaction_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception using
      errcode = '42501',
      message = 'not authenticated';
  end if;

  return query
  with contact_ids as (
    select
      case
        when i.lender_id = v_uid then i.borrower_id
        else i.lender_id
      end as counterparty_id,
      max(i.created_at) as last_interaction_at
    from public.ious i
    where
      i.lender_id = v_uid
      or i.borrower_id = v_uid
    group by
      case
        when i.lender_id = v_uid then i.borrower_id
        else i.lender_id
      end
  )
  select
    p.id,
    p.iou_hash,
    coalesce(
      nullif(btrim(p.display_name), ''),
      nullif(btrim(p.name), ''),
      nullif(btrim(p.full_name), ''),
      'IOU User'
    ) as public_name,
    coalesce(
      nullif(btrim(p.avatar_url), ''),
      nullif(btrim(p.photo_url), '')
    ) as avatar_url,
    p.iou_score,
    p.active_exposure_points,
    p.strike_count,
    c.last_interaction_at
  from contact_ids c
  join public.profiles p
    on p.id = c.counterparty_id
  where c.counterparty_id is not null
  order by c.last_interaction_at desc;
end;
$$;


ALTER FUNCTION "public"."get_my_iou_contacts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_trust_report_access_logs"() RETURNS TABLE("id" "uuid", "owner_user_id" "uuid", "viewer_user_id" "uuid", "viewer_email" "text", "viewer_full_name" "text", "viewer_iou_hash" "text", "access_type" "text", "scope" "text", "created_at" timestamp with time zone, "metadata" "jsonb")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_auth_user_id uuid := auth.uid();
begin
  if v_auth_user_id is null then
    raise exception 'Not authenticated';
  end if;

  return query
  select
    l.id,
    l.owner_user_id,
    l.viewer_user_id,
    viewer.email as viewer_email,
    viewer.full_name as viewer_full_name,
    viewer.iou_hash as viewer_iou_hash,
    l.access_type,
    l.scope,
    l.created_at,
    l.metadata
  from public.trust_report_access_logs l
  left join public.profiles viewer on viewer.id = l.viewer_user_id
  where l.owner_user_id = v_auth_user_id
  order by l.created_at desc;
end;
$$;


ALTER FUNCTION "public"."get_my_trust_report_access_logs"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_relationship_mode"("p_user_id" "uuid", "p_related_user_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
    AS $$
declare
  v_mode text;
begin
  if p_user_id is null or p_related_user_id is null then
    return 'standard_score_affecting';
  end if;

  if p_user_id = p_related_user_id then
    return 'self_no_score';
  end if;

  select relationship_mode
  into v_mode
  from public.user_relationship_modes
  where user_id = p_user_id
    and related_user_id = p_related_user_id
  limit 1;

  if v_mode is not null then
    return v_mode;
  end if;

  -- Check reverse direction too.
  -- Family / close-circle should work even if one person created the relationship mode.
  select relationship_mode
  into v_mode
  from public.user_relationship_modes
  where user_id = p_related_user_id
    and related_user_id = p_user_id
  limit 1;

  return coalesce(v_mode, 'standard_score_affecting');
end;
$$;


ALTER FUNCTION "public"."get_relationship_mode"("p_user_id" "uuid", "p_related_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_trust_report_for_viewer"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text" DEFAULT 'summary'::"text") RETURNS TABLE("user_id" "uuid", "email" "text", "public_score" integer, "visible_trust" integer, "trust_tier" "text", "proof_depth" integer, "proof_depth_label" "text", "confidence_score" integer, "confidence_label" "text", "active_score_affecting_agreements" bigint, "active_score_affecting_counterparties" bigint, "active_score_ceiling_total" numeric, "active_risk_flag_count" bigint, "private_risk_summary" "text", "sylienn_private_note" "text", "latest_snapshot_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_share_id uuid;
begin
  if p_owner_user_id is null or p_viewer_user_id is null then
    raise exception 'Missing owner or viewer user id';
  end if;

  if not public.has_active_trust_report_share(p_owner_user_id, p_viewer_user_id, p_scope) then
    insert into public.trust_report_access_logs (
      owner_user_id,
      viewer_user_id,
      trust_report_share_id,
      access_type,
      scope,
      metadata
    )
    values (
      p_owner_user_id,
      p_viewer_user_id,
      null,
      'access_denied',
      p_scope,
      jsonb_build_object('reason', 'no_active_share')
    );

    return;
  end if;

  select id
  into v_share_id
  from public.trust_report_shares
  where owner_user_id = p_owner_user_id
    and viewer_user_id = p_viewer_user_id
    and revoked_at is null
    and (expires_at is null or expires_at > now())
  order by created_at desc
  limit 1;

  insert into public.trust_report_access_logs (
    owner_user_id,
    viewer_user_id,
    trust_report_share_id,
    access_type,
    scope,
    metadata
  )
  values (
    p_owner_user_id,
    p_viewer_user_id,
    v_share_id,
    'view',
    p_scope,
    '{}'::jsonb
  );

  return query
  select
    tr.user_id,
    tr.email,
    tr.public_score,
    tr.visible_trust,
    tr.trust_tier,
    tr.proof_depth,
    tr.proof_depth_label,
    tr.confidence_score,
    tr.confidence_label,
    tr.active_score_affecting_agreements,
    tr.active_score_affecting_counterparties,
    tr.active_score_ceiling_total::numeric,
    tr.active_risk_flag_count,
    tr.private_risk_summary,
    tr.sylienn_private_note,
    tr.latest_snapshot_at
  from public.trust_report_shadow_v tr
  where tr.user_id = p_owner_user_id;
end;
$$;


ALTER FUNCTION "public"."get_trust_report_for_viewer"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_trust_reports_shared_with_me"() RETURNS TABLE("share_id" "uuid", "owner_user_id" "uuid", "owner_email" "text", "owner_full_name" "text", "owner_iou_hash" "text", "scope" "text", "reason" "text", "expires_at" timestamp with time zone, "created_at" timestamp with time zone, "metadata" "jsonb")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_auth_user_id uuid := auth.uid();
begin
  if v_auth_user_id is null then
    raise exception 'Not authenticated';
  end if;

  return query
  select
    s.id as share_id,
    s.owner_user_id,
    owner.email as owner_email,
    owner.full_name as owner_full_name,
    owner.iou_hash as owner_iou_hash,
    s.scope,
    s.reason,
    s.expires_at,
    s.created_at,
    s.metadata
  from public.trust_report_shares s
  join public.profiles owner on owner.id = s.owner_user_id
  where s.viewer_user_id = v_auth_user_id
    and s.revoked_at is null
    and (s.expires_at is null or s.expires_at > now())
  order by s.created_at desc;
end;
$$;


ALTER FUNCTION "public"."get_trust_reports_shared_with_me"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_iou_activation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_score integer := 700;
  v_active_exposure integer := 0;
  v_existing_active_loans integer := 0;
  v_new_exposure integer := 0;
  v_is_activating boolean := false;
begin
  v_is_activating :=
    NEW.borrower_id is not null
    and NEW.deleted_at is null
    and NEW.archived_at is null
    and NEW.activated_at is not null
    and NEW.status in ('open', 'late')
    and (
      TG_OP = 'INSERT'
      or OLD.activated_at is null
    );

  if not v_is_activating then
    return NEW;
  end if;

  select
    coalesce(iou_score, 700),
    coalesce(active_exposure_points, 0)
  into
    v_score,
    v_active_exposure
  from public.profiles
  where id = NEW.borrower_id;

  select count(*)
  into v_existing_active_loans
  from public.ious
  where borrower_id = NEW.borrower_id
    and id <> NEW.id
    and activated_at is not null
    and deleted_at is null
    and archived_at is null
    and status in ('open', 'late');

  if v_existing_active_loans >= 10 then
    raise exception 'Borrower already has the maximum number of active loans.';
  end if;

  v_new_exposure := public.calculate_iou_exposure(
    NEW.principal_cents::numeric,
    NEW.apr_bps::numeric,
    v_score
  );

  if v_active_exposure + v_new_exposure > 70 then
    raise exception 'Borrower would exceed the maximum allowed exposure.';
  end if;

  return NEW;
end;
$$;


ALTER FUNCTION "public"."guard_iou_activation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."guard_phone_verification_integrity"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  if current_user in ('anon', 'authenticated') then

    -- Changing the phone invalidates the old verification.
    if new.phone is distinct from old.phone then
      new.phone_verified := false;
      new.phone_verified_at := null;

    -- Verification fields cannot otherwise be set directly by the client.
    elsif
      new.phone_verified is distinct from old.phone_verified
      or new.phone_verified_at is distinct from old.phone_verified_at
    then
      raise exception using
        errcode = '42501',
        message = 'Phone verification status is server-managed';
    end if;

  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."guard_phone_verification_integrity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_exposure_release"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  borrower uuid;
  exposure int;
begin

  select borrower_id, ceil(principal_cents / 10000)
  into borrower, exposure
  from ious
  where id = new.iou_id;

  update profiles
  set active_exposure_points =
    greatest(0, coalesce(active_exposure_points,0) - exposure)
  where id = borrower;

  return new;

end;
$$;


ALTER FUNCTION "public"."handle_exposure_release"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_late_payment"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  borrower uuid;
begin

  -- find borrower
  select borrower_id into borrower
  from ious
  where id = new.iou_id;

  -- apply penalty
  update profiles
  set iou_score = greatest(0, coalesce(iou_score,700) - 10)
  where id = borrower;

  insert into score_history (user_id, delta, reason, iou_id)
  values (borrower, -10, 'late_payment', new.iou_id);

  return new;

end;
$$;


ALTER FUNCTION "public"."handle_late_payment"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_loan_completion"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  unpaid_count int;
  borrower uuid;
begin

  select borrower_id into borrower
  from ious
  where id = new.iou_id;

  select count(*) into unpaid_count
  from payments
  where iou_id = new.iou_id
  and paid_at is null;

  if unpaid_count = 0 then

    update profiles
    set iou_score = coalesce(iou_score,700) + 40
    where id = borrower;

    insert into score_history (user_id, delta, reason, iou_id)
    values (borrower, 40, 'loan_completed', new.iou_id);

  end if;

  return new;

end;
$$;


ALTER FUNCTION "public"."handle_loan_completion"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_loan_exposure"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_score integer := 700;
  v_exposure integer := 0;
BEGIN
  IF OLD.activated_at IS NULL
     AND NEW.activated_at IS NOT NULL
     AND NEW.borrower_id IS NOT NULL
     AND NEW.deleted_at IS NULL
     AND NEW.archived_at IS NULL
     AND NEW.status IN ('open', 'late') THEN

    SELECT COALESCE(iou_score, 700)::integer
    INTO v_score
    FROM public.profiles
    WHERE id = NEW.borrower_id;

    v_exposure := public.calculate_iou_exposure(
      NEW.principal_cents::numeric,
      NEW.apr_bps::numeric,
      COALESCE(v_score, 700)
    );

    UPDATE public.profiles
    SET active_exposure_points = COALESCE(active_exposure_points, 0) + v_exposure
    WHERE id = NEW.borrower_id;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_loan_exposure"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.profiles (
    id,
    email,
    full_name,
    iou_hash
  )
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    public.generate_iou_hash()
  )
  on conflict (id) do nothing;

  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_on_time_payment"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  borrower uuid;
begin

  -- find borrower
  select borrower_id into borrower
  from ious
  where id = new.iou_id;

  -- reward if payment was on time
  if new.paid_at <= new.due_at then

    update profiles
    set iou_score = coalesce(iou_score,700) + 3
    where id = borrower;

    insert into score_history (user_id, delta, reason, iou_id)
    values (borrower, 3, 'payment_on_time', new.iou_id);

  end if;

  return new;

end;
$$;


ALTER FUNCTION "public"."handle_on_time_payment"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_payment_default"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  borrower uuid;
  strikes int;
begin

  -- only trigger when attempts reach 8
  if new.failed_attempts < 8 then
    return new;
  end if;

  select borrower_id into borrower
  from ious
  where id = new.iou_id;

  -- increase strike count and record when it happened
  update profiles
  set strike_count = coalesce(strike_count, 0) + 1,
      last_strike_at = now()
  where id = borrower
  returning strike_count into strikes;

  -- apply score penalty
  update profiles
  set iou_score = greatest(0, coalesce(iou_score, 700) - 200)
  where id = borrower;

  insert into score_history (user_id, delta, reason, iou_id)
  values (borrower, -200, 'loan_default', new.iou_id);

  -- strike 3 rule
  if strikes >= 3 then
    update profiles
    set iou_score = 333,
        score_cap = 700
    where id = borrower;
  end if;

  return new;

end;
$$;


ALTER FUNCTION "public"."handle_payment_default"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_active_trust_report_share"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
    AS $$
begin
  if p_owner_user_id is null or p_viewer_user_id is null then
    return false;
  end if;

  if p_owner_user_id = p_viewer_user_id then
    return true;
  end if;

  return exists (
    select 1
    from public.trust_report_shares s
    where s.owner_user_id = p_owner_user_id
      and s.viewer_user_id = p_viewer_user_id
      and s.revoked_at is null
      and (s.expires_at is null or s.expires_at > now())
      and (
        p_scope is null
        or s.scope = p_scope
        or s.scope = 'full_report'
      )
  );
end;
$$;


ALTER FUNCTION "public"."has_active_trust_report_share"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_current_legal_acceptance"("p_terms_version" "text", "p_privacy_version" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id     uuid;
  v_has_terms   boolean := false;
  v_has_privacy boolean := false;
  v_missing     text[]  := '{}';
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'has_current_legal_acceptance: caller is not authenticated';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.legal_acceptances
    WHERE user_id          = v_user_id
      AND document_type    = 'terms_of_service'
      AND document_version = p_terms_version
  ) INTO v_has_terms;

  SELECT EXISTS (
    SELECT 1 FROM public.legal_acceptances
    WHERE user_id          = v_user_id
      AND document_type    = 'privacy_policy'
      AND document_version = p_privacy_version
  ) INTO v_has_privacy;

  IF NOT v_has_terms   THEN v_missing := array_append(v_missing, 'terms_of_service'); END IF;
  IF NOT v_has_privacy THEN v_missing := array_append(v_missing, 'privacy_policy');   END IF;

  RETURN jsonb_build_object(
    'all_current', v_has_terms AND v_has_privacy,
    'has_terms',   v_has_terms,
    'has_privacy', v_has_privacy,
    'missing',     to_jsonb(v_missing)
  );
END;
$$;


ALTER FUNCTION "public"."has_current_legal_acceptance"("p_terms_version" "text", "p_privacy_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_trust_education_acceptance"("p_user_id" "uuid", "p_education_key" "text" DEFAULT 'iou_trust_intro'::"text", "p_education_version" "text" DEFAULT '2026-05-30'::"text", "p_context" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if p_user_id is null then
    return false;
  end if;

  return exists (
    select 1
    from public.trust_education_acceptances tea
    where tea.user_id = p_user_id
      and tea.education_key = coalesce(p_education_key, 'iou_trust_intro')
      and tea.education_version = coalesce(p_education_version, '2026-05-30')
      and (
        p_context is null
        or tea.context = p_context
      )
  );
end;
$$;


ALTER FUNCTION "public"."has_trust_education_acceptance"("p_user_id" "uuid", "p_education_key" "text", "p_education_version" "text", "p_context" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."iou_score_large_completion_reward"() RETURNS integer
    LANGUAGE "sql" STABLE
    AS $$
  select 77;
$$;


ALTER FUNCTION "public"."iou_score_large_completion_reward"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."iou_score_medium_early_reward"() RETURNS integer
    LANGUAGE "sql" STABLE
    AS $$
  select 27;
$$;


ALTER FUNCTION "public"."iou_score_medium_early_reward"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."iou_score_small_on_time_reward"() RETURNS integer
    LANGUAGE "sql" STABLE
    AS $$
  select 7;
$$;


ALTER FUNCTION "public"."iou_score_small_on_time_reward"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false);
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_receipt_split_member"("p_receipt_split_id" "uuid") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1
    from public.receipt_splits rs
    where rs.id = p_receipt_split_id
      and rs.owner_id = auth.uid()
  )
  or exists (
    select 1
    from public.receipt_split_participants rsp
    where rsp.receipt_split_id = p_receipt_split_id
      and rsp.user_id = auth.uid()
  );
$$;


ALTER FUNCTION "public"."is_receipt_split_member"("p_receipt_split_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."legal_acceptances_block_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  RAISE EXCEPTION
    'legal_acceptances is an append-only consent ledger. '
    'UPDATE and DELETE are not permitted on this table. '
    'Consent records must not be mutated after creation. '
    'If a correction or anonymization is required, contact the database '
    'administrator and follow the documented administrative procedure.';
  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."legal_acceptances_block_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_agreement_event"("p_user_id" "uuid", "p_actor_id" "uuid", "p_counterparty_id" "uuid", "p_score_agreement_id" "uuid", "p_source_type" "text", "p_source_id" "uuid", "p_event_type" "text", "p_amount_cents" bigint DEFAULT NULL::bigint, "p_previous_amount_cents" bigint DEFAULT NULL::bigint, "p_apr_bps" integer DEFAULT NULL::integer, "p_previous_apr_bps" integer DEFAULT NULL::integer, "p_due_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_previous_due_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_days_early" integer DEFAULT NULL::integer, "p_days_late" integer DEFAULT NULL::integer, "p_proof_tier" integer DEFAULT NULL::integer, "p_verification_tier" integer DEFAULT NULL::integer, "p_relationship_mode" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid;
begin
  insert into public.agreement_events (
    user_id,
    actor_id,
    counterparty_id,
    score_agreement_id,
    source_type,
    source_id,
    event_type,
    amount_cents,
    previous_amount_cents,
    apr_bps,
    previous_apr_bps,
    due_at,
    previous_due_at,
    days_early,
    days_late,
    proof_tier,
    verification_tier,
    relationship_mode,
    score_model_version,
    risk_model_version,
    metadata
  )
  values (
    p_user_id,
    p_actor_id,
    p_counterparty_id,
    p_score_agreement_id,
    p_source_type,
    p_source_id,
    p_event_type,
    p_amount_cents,
    p_previous_amount_cents,
    p_apr_bps,
    p_previous_apr_bps,
    p_due_at,
    p_previous_due_at,
    p_days_early,
    p_days_late,
    p_proof_tier,
    p_verification_tier,
    p_relationship_mode,
    'v2.0-shadow',
    'v0.1-shadow',
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_event_id;

  return v_event_id;
end;
$$;


ALTER FUNCTION "public"."log_agreement_event"("p_user_id" "uuid", "p_actor_id" "uuid", "p_counterparty_id" "uuid", "p_score_agreement_id" "uuid", "p_source_type" "text", "p_source_id" "uuid", "p_event_type" "text", "p_amount_cents" bigint, "p_previous_amount_cents" bigint, "p_apr_bps" integer, "p_previous_apr_bps" integer, "p_due_at" timestamp with time zone, "p_previous_due_at" timestamp with time zone, "p_days_early" integer, "p_days_late" integer, "p_proof_tier" integer, "p_verification_tier" integer, "p_relationship_mode" "text", "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_payment_score_outcome_shadow"("p_payment_id" "uuid", "p_actor_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_payment public.payments%rowtype;
  v_iou public.ious%rowtype;
  v_score_agreement_id uuid;
  v_due_date date;
  v_paid_date date;
  v_days_early integer := null;
  v_days_late integer := null;
  v_outcome_type text;
  v_payment_outcome jsonb := null;
  v_completion_outcome jsonb := null;
  v_unpaid_count integer := 0;
begin
  if p_payment_id is null then
    return jsonb_build_object(
      'recorded', false,
      'reason', 'missing_payment_id'
    );
  end if;

  select *
  into v_payment
  from public.payments
  where id = p_payment_id;

  if not found then
    return jsonb_build_object(
      'recorded', false,
      'reason', 'payment_not_found',
      'payment_id', p_payment_id
    );
  end if;

  if v_payment.paid_at is null or v_payment.status is distinct from 'paid' then
    return jsonb_build_object(
      'recorded', false,
      'reason', 'payment_not_paid',
      'payment_id', v_payment.id,
      'status', v_payment.status
    );
  end if;

  select *
  into v_iou
  from public.ious
  where id = v_payment.iou_id;

  if not found then
    return jsonb_build_object(
      'recorded', false,
      'reason', 'iou_not_found',
      'payment_id', v_payment.id,
      'iou_id', v_payment.iou_id
    );
  end if;

  select sa.id
  into v_score_agreement_id
  from public.score_agreements sa
  where sa.source_type = 'personal_iou'
    and sa.source_id = v_iou.id
  order by sa.created_at desc nulls last, sa.id
  limit 1;

  if v_score_agreement_id is null then
    return jsonb_build_object(
      'recorded', false,
      'reason', 'score_agreement_not_found',
      'payment_id', v_payment.id,
      'iou_id', v_iou.id
    );
  end if;

  -- Idempotency: one payment outcome per payment id.
  if exists (
    select 1
    from public.trust_outcome_events toe
    where toe.score_agreement_id = v_score_agreement_id
      and toe.outcome_type in (
        'payment_paid_early',
        'payment_paid_on_time',
        'payment_paid_late'
      )
      and toe.metadata->>'payment_id' = v_payment.id::text
  ) then
    return jsonb_build_object(
      'recorded', false,
      'reason', 'payment_outcome_already_logged',
      'payment_id', v_payment.id,
      'score_agreement_id', v_score_agreement_id
    );
  end if;

  v_due_date := v_payment.due_date;
  v_paid_date := (v_payment.paid_at at time zone 'UTC')::date;

  if v_paid_date < v_due_date then
    v_outcome_type := 'payment_paid_early';
    v_days_early := v_due_date - v_paid_date;
    v_days_late := null;
  elsif v_paid_date = v_due_date then
    v_outcome_type := 'payment_paid_on_time';
    v_days_early := 0;
    v_days_late := 0;
  else
    v_outcome_type := 'payment_paid_late';
    v_days_early := null;
    v_days_late := v_paid_date - v_due_date;
  end if;

  v_payment_outcome := public.log_score_agreement_outcome(
    v_score_agreement_id,
    v_outcome_type,
    p_actor_id,
    v_payment.amount_cents,
    v_days_early,
    v_days_late,
    jsonb_build_object(
      'payment_id', v_payment.id,
      'iou_id', v_iou.id,
      'due_date', v_payment.due_date,
      'paid_at', v_payment.paid_at,
      'payment_status', v_payment.status,
      'payment_method', coalesce(v_payment.payment_method, 'manual'),
      'trigger', 'pay_and_receipt',
      'shadow_mode', true
    )
  );

  select count(*)
  into v_unpaid_count
  from public.payments p
  where p.iou_id = v_iou.id
    and (
      p.status is distinct from 'paid'
      or p.paid_at is null
    );

  if v_unpaid_count = 0
    and not exists (
      select 1
      from public.trust_outcome_events toe
      where toe.score_agreement_id = v_score_agreement_id
        and toe.outcome_type = 'agreement_completed'
    )
  then
    v_completion_outcome := public.log_score_agreement_outcome(
      v_score_agreement_id,
      'agreement_completed',
      p_actor_id,
      v_iou.principal_cents,
      null,
      null,
      jsonb_build_object(
        'iou_id', v_iou.id,
        'completed_by_payment_id', v_payment.id,
        'trigger', 'pay_and_receipt',
        'shadow_mode', true
      )
    );
  end if;

  return jsonb_build_object(
    'recorded', true,
    'payment_outcome', v_payment_outcome,
    'completion_outcome', v_completion_outcome,
    'payment_id', v_payment.id,
    'iou_id', v_iou.id,
    'score_agreement_id', v_score_agreement_id,
    'outcome_type', v_outcome_type
  );
end;
$$;


ALTER FUNCTION "public"."log_payment_score_outcome_shadow"("p_payment_id" "uuid", "p_actor_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_score_agreement_outcome"("p_score_agreement_id" "uuid", "p_outcome_type" "text", "p_actor_id" "uuid" DEFAULT NULL::"uuid", "p_amount_cents" bigint DEFAULT NULL::bigint, "p_days_early" integer DEFAULT NULL::integer, "p_days_late" integer DEFAULT NULL::integer, "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_agreement public.score_agreements%rowtype;
  v_outcome_id uuid;
  v_agreement_event_id uuid;
  v_relationship_mode text;
begin
  if p_score_agreement_id is null then
    raise exception 'Missing score agreement id';
  end if;

  if p_outcome_type is null then
    raise exception 'Missing outcome type';
  end if;

  select *
  into v_agreement
  from public.score_agreements
  where id = p_score_agreement_id;

  if not found then
    raise exception 'Score agreement not found: %', p_score_agreement_id;
  end if;

  v_relationship_mode := public.get_relationship_mode(
    v_agreement.user_id,
    v_agreement.counterparty_id
  );

  v_outcome_id := public.log_trust_outcome_event(
    v_agreement.user_id,
    v_agreement.id,
    v_agreement.source_type,
    v_agreement.source_id,
    p_outcome_type,
    coalesce(p_amount_cents, v_agreement.amount_cents),
    p_days_early,
    p_days_late,
    v_agreement.proof_tier,
    v_agreement.verification_tier,
    null,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
      'score_ceiling_at_outcome', v_agreement.score_ceiling,
      'score_contributed_at_outcome', v_agreement.score_contributed,
      'same_pair_index', v_agreement.same_pair_index,
      'same_pair_multiplier', v_agreement.same_pair_multiplier,
      'relationship_mode', v_relationship_mode,
      'shadow_mode', true
    )
  );

  v_agreement_event_id := public.log_agreement_event(
    v_agreement.user_id,
    coalesce(p_actor_id, v_agreement.user_id),
    v_agreement.counterparty_id,
    v_agreement.id,
    v_agreement.source_type,
    v_agreement.source_id,
    p_outcome_type,
    coalesce(p_amount_cents, v_agreement.amount_cents),
    null,
    null,
    null,
    null,
    null,
    p_days_early,
    p_days_late,
    v_agreement.proof_tier,
    v_agreement.verification_tier,
    v_relationship_mode,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object(
      'trust_outcome_event_id', v_outcome_id,
      'score_ceiling_at_outcome', v_agreement.score_ceiling,
      'shadow_mode', true
    )
  );

  return jsonb_build_object(
    'trust_outcome_event_id', v_outcome_id,
    'agreement_event_id', v_agreement_event_id,
    'score_agreement_id', v_agreement.id,
    'outcome_type', p_outcome_type,
    'relationship_mode', v_relationship_mode
  );
end;
$$;


ALTER FUNCTION "public"."log_score_agreement_outcome"("p_score_agreement_id" "uuid", "p_outcome_type" "text", "p_actor_id" "uuid", "p_amount_cents" bigint, "p_days_early" integer, "p_days_late" integer, "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."log_trust_outcome_event"("p_user_id" "uuid", "p_score_agreement_id" "uuid" DEFAULT NULL::"uuid", "p_source_type" "text" DEFAULT NULL::"text", "p_source_id" "uuid" DEFAULT NULL::"uuid", "p_outcome_type" "text" DEFAULT NULL::"text", "p_amount_cents" bigint DEFAULT NULL::bigint, "p_days_early" integer DEFAULT NULL::integer, "p_days_late" integer DEFAULT NULL::integer, "p_proof_tier" integer DEFAULT NULL::integer, "p_verification_tier" integer DEFAULT NULL::integer, "p_related_snapshot_id" "uuid" DEFAULT NULL::"uuid", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid;
begin
  if p_user_id is null then
    raise exception 'Missing user id';
  end if;

  if p_outcome_type is null then
    raise exception 'Missing outcome type';
  end if;

  insert into public.trust_outcome_events (
    user_id,
    score_agreement_id,
    source_type,
    source_id,
    outcome_type,
    amount_cents,
    days_early,
    days_late,
    proof_tier,
    verification_tier,
    related_snapshot_id,
    metadata
  )
  values (
    p_user_id,
    p_score_agreement_id,
    p_source_type,
    p_source_id,
    p_outcome_type,
    p_amount_cents,
    p_days_early,
    p_days_late,
    p_proof_tier,
    p_verification_tier,
    p_related_snapshot_id,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_event_id;

  return v_event_id;
end;
$$;


ALTER FUNCTION "public"."log_trust_outcome_event"("p_user_id" "uuid", "p_score_agreement_id" "uuid", "p_source_type" "text", "p_source_id" "uuid", "p_outcome_type" "text", "p_amount_cents" bigint, "p_days_early" integer, "p_days_late" integer, "p_proof_tier" integer, "p_verification_tier" integer, "p_related_snapshot_id" "uuid", "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pay_and_receipt"("p_payment_id" "uuid") RETURNS "public"."payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_payment public.payments%rowtype;
  v_iou public.ious%rowtype;
  v_payload jsonb;
  v_hash text;
begin
  select pay.*
  into v_payment
  from public.payments pay
  where pay.id = p_payment_id
  for update;

  if not found then
    raise exception 'Payment not found: %', p_payment_id;
  end if;

  select i.*
  into v_iou
  from public.ious i
  where i.id = v_payment.iou_id
  for update;

  if not found then
    raise exception 'Linked IOU not found';
  end if;

  if auth.uid() is distinct from v_iou.lender_id then
    raise exception 'Only the lender may confirm this payment';
  end if;

  if v_payment.status is distinct from 'pending_confirmation' then
    raise exception 'Only pending confirmation payments can be confirmed';
  end if;

  update public.payments pay
  set
    status = 'paid',
    paid_at = now(),
    updated_at = now(),
    updated_by = auth.uid()
  where pay.id = p_payment_id
  returning pay.* into v_payment;

  v_payload := jsonb_build_object(
    'iou_id', v_payment.iou_id,
    'payment_id', v_payment.id,
    'amount_cents', v_payment.amount_cents,
    'payer_id', v_iou.borrower_id,
    'payee_id', v_iou.lender_id,
    'timestamp', v_payment.paid_at,
    'nonce', gen_random_uuid()
  );

  v_hash := encode(
    extensions.digest(convert_to(v_payload::text, 'UTF8'), 'sha256'),
    'hex'
  );

  insert into public.payment_receipts (
    payment_id,
    iou_id,
    amount_cents,
    currency,
    method,
    paid_at,
    payload_json,
    receipt_hash
  )
  values (
    v_payment.id,
    v_payment.iou_id,
    v_payment.amount_cents,
    'USD',
    coalesce(v_payment.payment_method, 'manual'),
    v_payment.paid_at,
    v_payload,
    v_hash
  )
  on conflict (payment_id) do nothing;

  perform public.refresh_iou_status(v_payment.iou_id);

  -- Shadow outcome logging must never block payment confirmation.
  begin
    perform public.log_payment_score_outcome_shadow(v_payment.id, auth.uid());
  exception when others then
    raise notice 'Shadow payment outcome logging failed for payment %: %', v_payment.id, sqlerrm;
  end;

  return v_payment;
end;
$$;


ALTER FUNCTION "public"."pay_and_receipt"("p_payment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."payments_due_sync"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.due_date is not null then
    new.due_at := (new.due_date::timestamptz);
  end if;
  return new;
end$$;


ALTER FUNCTION "public"."payments_due_sync"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."payments_status_auto"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Do not override terminal/manual workflow statuses.
  IF NEW.status IN ('pending_confirmation', 'paid') THEN
    RETURN NEW;
  END IF;

  -- If this payment has been marked paid, keep it paid.
  IF NEW.paid_at IS NOT NULL THEN
    NEW.status := 'paid';
    RETURN NEW;
  END IF;

  -- Default unpaid payment status.
  IF NEW.due_date IS NOT NULL
     AND NEW.due_date < CURRENT_DATE THEN
    NEW.status := 'late';
  ELSE
    NEW.status := 'scheduled';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."payments_status_auto"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."payments_status_autoupdate"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Do not override terminal/manual workflow statuses.
  IF NEW.status IN ('pending_confirmation', 'paid') THEN
    RETURN NEW;
  END IF;

  -- If this payment has been marked paid, keep it paid.
  IF NEW.paid_at IS NOT NULL THEN
    NEW.status := 'paid';
    RETURN NEW;
  END IF;

  -- Default unpaid payment status.
  IF NEW.due_date IS NOT NULL
     AND NEW.due_date < CURRENT_DATE THEN
    NEW.status := 'late';
  ELSE
    NEW.status := 'scheduled';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."payments_status_autoupdate"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."profiles_phone_digits_sync"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.phone_digits := regexp_replace(coalesce(new.phone,''), '\D', '', 'g');
  return new;
end $$;


ALTER FUNCTION "public"."profiles_phone_digits_sync"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."propose_schedule_change"("p_iou_id" "uuid", "p_payments" "jsonb") RETURNS TABLE("id" "uuid", "status" "text", "requested_action_by" "uuid")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_iou public.ious%ROWTYPE;
  v_count bigint := 0;
  v_total bigint := 0;
BEGIN
  SELECT *
  INTO v_iou
  FROM public.ious
  WHERE public.ious.id = p_iou_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'IOU not found: %', p_iou_id;
  END IF;

  IF auth.uid() IS DISTINCT FROM v_iou.borrower_id THEN
    RAISE EXCEPTION 'Only the borrower may propose schedule changes';
  END IF;

  IF v_iou.activated_at IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot change the schedule of an activated IOU';
  END IF;

  IF p_payments IS NULL OR jsonb_typeof(p_payments) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Payment schedule must be a JSON array';
  END IF;

  IF jsonb_array_length(p_payments) = 0 THEN
    RAISE EXCEPTION 'Payment schedule cannot be empty';
  END IF;

  DELETE FROM public.payments pay
  WHERE pay.iou_id = p_iou_id
    AND COALESCE(pay.status, 'scheduled') = 'scheduled';

  INSERT INTO public.payments (
    iou_id,
    due_date,
    amount_cents,
    status
  )
  SELECT
    p_iou_id,
    (r->>'due_date')::date,
    (r->>'amount_cents')::bigint,
    'scheduled'
  FROM jsonb_array_elements(p_payments) AS r
  WHERE (r ? 'due_date')
    AND (r ? 'amount_cents');

  SELECT
    COUNT(*),
    COALESCE(SUM(pay.amount_cents), 0)
  INTO
    v_count,
    v_total
  FROM public.payments pay
  WHERE pay.iou_id = p_iou_id
    AND pay.status = 'scheduled';

  IF v_count = 0 THEN
    RAISE EXCEPTION 'Payment insert produced 0 rows';
  END IF;

  IF v_total < v_iou.principal_cents THEN
    RAISE EXCEPTION 'Payment schedule total (% cents) is less than principal (% cents)',
      v_total, v_iou.principal_cents;
  END IF;

  -- Borrower proposed schedule. Now lender must review.
  UPDATE public.ious i
  SET
    status = 'draft',
    requested_action_by = v_iou.lender_id,
    total_installments = v_count::integer,
    paid_installments = 0
  WHERE i.id = p_iou_id;

  RETURN QUERY
  SELECT
    i.id,
    i.status,
    i.requested_action_by
  FROM public.ious i
  WHERE i.id = p_iou_id;
END;
$$;


ALTER FUNCTION "public"."propose_schedule_change"("p_iou_id" "uuid", "p_payments" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recalculate_profile_exposure"("p_profile_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_total integer := 0;
begin
  select coalesce(sum(coalesce(exposure_points, 0)), 0)::integer
    into v_total
  from public.ious
  where borrower_id = p_profile_id
    and activated_at is not null
    and deleted_at is null
    and archived_at is null
    and status in ('open', 'late');

  update public.profiles
  set
    active_exposure_points = least(70, greatest(0, coalesce(v_total, 0))),
    score_last_updated_at = now()
  where id = p_profile_id;
end;
$$;


ALTER FUNCTION "public"."recalculate_profile_exposure"("p_profile_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recalculate_score_v2_personal_iou_pair"("p_user_id" "uuid", "p_counterparty_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_updated integer := 0;
begin
  if p_user_id is null or p_counterparty_id is null then
    return 0;
  end if;

  with ranked as (
    select
      sa.id,
      row_number() over (
        partition by sa.user_id, sa.counterparty_id
        order by
          case
            when sa.status in ('active', 'completed') then 0
            else 1
          end,
          sa.activated_at nulls last,
          sa.created_at,
          sa.id
      )::integer as rn
    from public.score_agreements sa
    where sa.source_type = 'personal_iou'
      and sa.user_id = p_user_id
      and sa.counterparty_id = p_counterparty_id
  ),
  updated as (
    update public.score_agreements sa
    set
      same_pair_index = r.rn,
      same_pair_multiplier =
        public.score_v2_same_pair_multiplier(r.rn),
      obligation_weight =
        public.score_v2_obligation_weight(
          sa.source_type,
          sa.amount_cents,
          sa.term_months,
          sa.frequency,
          sa.proof_tier,
          sa.verification_tier,
          r.rn,
          coalesce(sa.metadata, '{}'::jsonb)
        ),
      score_ceiling =
        case
          when sa.status = 'cancelled' then 0
          else public.score_v2_score_ceiling(
            sa.source_type,
            sa.amount_cents,
            sa.term_months,
            sa.frequency,
            sa.proof_tier,
            sa.verification_tier,
            r.rn,
            coalesce(sa.metadata, '{}'::jsonb)
          )
        end,
      metadata =
        coalesce(sa.metadata, '{}'::jsonb)
        || jsonb_build_object(
          'same_pair_index',
          r.rn,
          'same_pair_multiplier',
          public.score_v2_same_pair_multiplier(r.rn),
          'pair_recalculated_at',
          now(),
          'pair_recalculation_source',
          'recalculate_score_v2_personal_iou_pair'
        )
    from ranked r
    where sa.id = r.id
    returning 1
  )
  select count(*)::integer
  into v_updated
  from updated;

  return coalesce(v_updated, 0);
end;
$$;


ALTER FUNCTION "public"."recalculate_score_v2_personal_iou_pair"("p_user_id" "uuid", "p_counterparty_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recompute_iou_exposure"("p_iou_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_iou public.ious%rowtype;
  v_borrower_score integer := 700;
  v_base_exposure integer := 0;
  v_scheduled_total numeric := 0;
  v_remaining_total numeric := 0;
  v_live_exposure integer := 0;
begin
  select *
    into v_iou
  from public.ious
  where id = p_iou_id
  for update;

  if not found then
    raise exception 'IOU not found.';
  end if;

  if v_iou.borrower_id is null
     or v_iou.activated_at is null
     or v_iou.deleted_at is not null
     or v_iou.archived_at is not null
     or v_iou.status = 'paid' then
    update public.ious
    set exposure_points = 0
    where id = p_iou_id;

    if v_iou.borrower_id is not null then
      perform public.recalculate_profile_exposure(v_iou.borrower_id);
    end if;

    return;
  end if;

  select coalesce(iou_score, 700)
    into v_borrower_score
  from public.profiles
  where id = v_iou.borrower_id;

  v_base_exposure := public.calculate_iou_exposure(
    v_iou.principal_cents::numeric,
    v_iou.apr_bps::numeric,
    coalesce(v_borrower_score, 700)
  );

  select coalesce(sum(amount_cents), 0)::numeric
    into v_scheduled_total
  from public.payments
  where iou_id = p_iou_id;

  select coalesce(sum(amount_cents), 0)::numeric
    into v_remaining_total
  from public.payments
  where iou_id = p_iou_id
    and paid_at is null;

  if coalesce(v_scheduled_total, 0) <= 0 or coalesce(v_remaining_total, 0) <= 0 then
    v_live_exposure := 0;
  else
    v_live_exposure := ceil(
      (v_base_exposure::numeric * v_remaining_total) / v_scheduled_total
    )::integer;
  end if;

  update public.ious
  set exposure_points = least(70, greatest(0, coalesce(v_live_exposure, 0)))
  where id = p_iou_id;

  perform public.recalculate_profile_exposure(v_iou.borrower_id);
end;
$$;


ALTER FUNCTION "public"."recompute_iou_exposure"("p_iou_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recompute_iou_progress"("p_iou_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_total_installments integer := 0;
  v_paid_installments integer := 0;
  v_progress numeric := 0;
begin
  select count(*)
    into v_total_installments
  from public.payments
  where iou_id = p_iou_id;

  select count(*)
    into v_paid_installments
  from public.payments
  where iou_id = p_iou_id
    and paid_at is not null;

  if coalesce(v_total_installments, 0) > 0 then
    v_progress := round((v_paid_installments::numeric / v_total_installments::numeric) * 100, 2);
  else
    v_progress := 0;
  end if;

  update public.ious
  set
    total_installments = v_total_installments,
    paid_installments = v_paid_installments,
    progress_percent = v_progress,
    status = case
      when deleted_at is not null then status
      when archived_at is not null then status
      when v_total_installments > 0 and v_paid_installments >= v_total_installments then 'paid'
      when activated_at is not null then 'open'
      else status
    end
  where id = p_iou_id;
end;
$$;


ALTER FUNCTION "public"."recompute_iou_progress"("p_iou_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recompute_iou_status"("p_iou" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  v_status text;
  v_current_status text;
  v_total_payments integer := 0;
  v_unpaid_count integer := 0;
  v_late_count integer := 0;
begin
  select status
  into v_current_status
  from public.ious
  where id = p_iou;

  if v_current_status is null then
    return null;
  end if;

  -- keep archived as archived
  if v_current_status = 'archived' then
    return v_current_status;
  end if;

  select count(*)
  into v_total_payments
  from public.payments
  where iou_id = p_iou;

  select count(*)
  into v_unpaid_count
  from public.payments
  where iou_id = p_iou
    and paid_at is null;

  select count(*)
  into v_late_count
  from public.payments
  where iou_id = p_iou
    and paid_at is null
    and coalesce(due_date, due_at::date) < now()::date;

  if v_total_payments = 0 then
    v_status := 'draft';
  elsif v_unpaid_count = 0 then
    v_status := 'paid';
  elsif v_late_count > 0 then
    v_status := 'late';
  else
    v_status := 'open';
  end if;

  update public.ious
  set status = v_status
  where id = p_iou;

  return v_status;
end;
$$;


ALTER FUNCTION "public"."recompute_iou_status"("p_iou" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_legal_acceptance"("p_document_type" "text", "p_document_version" "text", "p_context" "text", "p_related_iou_id" "uuid" DEFAULT NULL::"uuid", "p_platform" "text" DEFAULT NULL::"text", "p_app_version" "text" DEFAULT NULL::"text", "p_device_metadata" "jsonb" DEFAULT NULL::"jsonb", "p_metadata" "jsonb" DEFAULT NULL::"jsonb", "p_document_hash" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_user_id   uuid;
  v_id        uuid;
  v_inserted  boolean;
  v_clean_ver text;
BEGIN
  -- auth.uid() reads from the session JWT claim.
  -- In a service_role context (no JWT), this returns NULL — the function
  -- raises and cannot be used. Service-role writes use direct table access.
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'record_legal_acceptance: caller is not authenticated';
  END IF;

  -- Input validation. These mirror the table CHECK constraints and provide
  -- clear error messages before the INSERT is attempted.
  IF p_document_type NOT IN ('terms_of_service', 'privacy_policy') THEN
    RAISE EXCEPTION 'record_legal_acceptance: invalid document_type "%"', p_document_type;
  END IF;

  IF p_context NOT IN ('new_iou_flow', 'signup', 're_acceptance', 'settings') THEN
    RAISE EXCEPTION 'record_legal_acceptance: invalid context "%"', p_context;
  END IF;

  IF p_document_version IS NULL OR trim(p_document_version) = '' THEN
    RAISE EXCEPTION 'record_legal_acceptance: document_version must not be empty';
  END IF;

  v_clean_ver := trim(p_document_version);

  -- Atomic insert. ON CONFLICT DO NOTHING handles concurrent duplicate calls
  -- without a race window. The unique constraint
  -- legal_acceptances_unique_acceptance is the enforcement point.
  -- If the conflict fires, RETURNING returns nothing (v_id stays NULL).
  INSERT INTO public.legal_acceptances (
    user_id,          document_type,     document_version,  document_hash,
    accepted_at,      context,           related_iou_id,    platform,
    app_version,      device_metadata,   metadata
  ) VALUES (
    v_user_id,        p_document_type,   v_clean_ver,       p_document_hash,
    now(),            p_context,         p_related_iou_id,  p_platform,
    p_app_version,    p_device_metadata, p_metadata
  )
  ON CONFLICT (user_id, document_type, document_version, context) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NOT NULL THEN
    -- New row inserted.
    v_inserted := true;
  ELSE
    -- Conflict: row already exists. Fetch its id.
    -- This SELECT runs after the INSERT is known to have been skipped,
    -- so the row is guaranteed to exist at this point.
    SELECT id INTO v_id
    FROM public.legal_acceptances
    WHERE user_id          = v_user_id
      AND document_type    = p_document_type
      AND document_version = v_clean_ver
      AND context          = p_context;
    v_inserted := false;
  END IF;

  RETURN jsonb_build_object(
    'id',               v_id,
    'inserted',         v_inserted,
    'document_type',    p_document_type,
    'document_version', v_clean_ver,
    'context',          p_context
  );
END;
$$;


ALTER FUNCTION "public"."record_legal_acceptance"("p_document_type" "text", "p_document_version" "text", "p_context" "text", "p_related_iou_id" "uuid", "p_platform" "text", "p_app_version" "text", "p_device_metadata" "jsonb", "p_metadata" "jsonb", "p_document_hash" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_trust_education_acceptance"("p_user_id" "uuid", "p_education_key" "text" DEFAULT 'iou_trust_intro'::"text", "p_education_version" "text" DEFAULT '2026-05-30'::"text", "p_context" "text" DEFAULT 'manual_review'::"text", "p_platform" "text" DEFAULT NULL::"text", "p_accepted_statements" "jsonb" DEFAULT '[]'::"jsonb", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_acceptance_id uuid;
  v_inserted boolean := false;
begin
  if p_user_id is null then
    raise exception 'Missing user id';
  end if;

  if auth.uid() is not null and auth.uid() <> p_user_id then
    raise exception 'Cannot record trust education acceptance for another user';
  end if;

  insert into public.trust_education_acceptances (
    user_id,
    education_key,
    education_version,
    context,
    platform,
    accepted_statements,
    metadata
  )
  values (
    p_user_id,
    coalesce(p_education_key, 'iou_trust_intro'),
    coalesce(p_education_version, '2026-05-30'),
    coalesce(p_context, 'manual_review'),
    p_platform,
    coalesce(p_accepted_statements, '[]'::jsonb),
    coalesce(p_metadata, '{}'::jsonb)
  )
  on conflict (user_id, education_key, education_version, context)
  do update set
    platform = excluded.platform,
    accepted_statements = excluded.accepted_statements,
    metadata = public.trust_education_acceptances.metadata || excluded.metadata
  returning id into v_acceptance_id;

  return jsonb_build_object(
    'acceptance_id', v_acceptance_id,
    'education_key', coalesce(p_education_key, 'iou_trust_intro'),
    'education_version', coalesce(p_education_version, '2026-05-30'),
    'context', coalesce(p_context, 'manual_review'),
    'recorded', true
  );
end;
$$;


ALTER FUNCTION "public"."record_trust_education_acceptance"("p_user_id" "uuid", "p_education_key" "text", "p_education_version" "text", "p_context" "text", "p_platform" "text", "p_accepted_statements" "jsonb", "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recover_strikes"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin

  update profiles
  set strike_count = strike_count - 1,
      last_strike_at = now()
  where strike_count > 0
    and last_strike_at < now() - interval '24 months';

end;
$$;


ALTER FUNCTION "public"."recover_strikes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recover_user_strike"("user_uuid" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin

update profiles
set strike_count = strike_count - 1,
    last_strike_at = now()
where id = user_uuid
and strike_count > 0
and last_strike_at < now() - interval '24 months';

end;
$$;


ALTER FUNCTION "public"."recover_user_strike"("user_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_iou_status"("target_iou" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  total_payments int := 0;
  paid_payments int := 0;
  past_due int := 0;
  v_activated_at timestamptz;
  v_deleted_at timestamptz;
  v_archived_at timestamptz;
  new_status text;
BEGIN
  SELECT activated_at, deleted_at, archived_at
  INTO v_activated_at, v_deleted_at, v_archived_at
  FROM public.ious
  WHERE id = target_iou;

  -- Do not recompute status for deleted/archived IOUs.
  IF v_deleted_at IS NOT NULL OR v_archived_at IS NOT NULL THEN
    RETURN;
  END IF;

  SELECT
    COUNT(*) AS total_payments,
    COUNT(*) FILTER (WHERE status = 'paid') AS paid_payments,
    COUNT(*) FILTER (
      WHERE status <> 'paid'
        AND due_date < now() - interval '24 hours'
    ) AS past_due
  INTO total_payments, paid_payments, past_due
  FROM public.payments
  WHERE iou_id = target_iou;

  IF total_payments = 0 THEN
    new_status := 'draft';

  ELSIF paid_payments = total_payments THEN
    new_status := 'paid';

  ELSIF v_activated_at IS NULL THEN
    -- Pending accept-ready IOU. It has a schedule, but borrower has not accepted yet.
    -- Do not mark it late before activation.
    new_status := 'open';

  ELSIF past_due > 0 THEN
    new_status := 'late';

  ELSE
    new_status := 'open';
  END IF;

  UPDATE public.ious i
  SET status = new_status
  WHERE i.id = target_iou
    AND i.status IS DISTINCT FROM new_status;
END;
$$;


ALTER FUNCTION "public"."refresh_iou_status"("target_iou" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refresh_iou_status_from_payments"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.refresh_iou_status(coalesce(NEW.iou_id, OLD.iou_id));
  return null;
end;
$$;


ALTER FUNCTION "public"."refresh_iou_status_from_payments"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_payment"("p_payment_id" "uuid") RETURNS "public"."payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_payment public.payments%ROWTYPE;
  v_iou public.ious%ROWTYPE;
BEGIN
  SELECT *
  INTO v_payment
  FROM public.payments
  WHERE id = p_payment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment not found: %', p_payment_id;
  END IF;

  SELECT *
  INTO v_iou
  FROM public.ious
  WHERE id = v_payment.iou_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Linked IOU not found';
  END IF;

  IF auth.uid() IS DISTINCT FROM v_iou.lender_id THEN
    RAISE EXCEPTION 'Only the lender may reject this payment';
  END IF;

  IF v_payment.status IS DISTINCT FROM 'pending_confirmation' THEN
    RAISE EXCEPTION 'Only pending confirmation payments can be rejected';
  END IF;

  UPDATE public.payments
  SET
    status = 'scheduled',
    payment_method = NULL,
    initiated_at = NULL,
    paid_at = NULL
  WHERE id = p_payment_id
  RETURNING * INTO v_payment;

  PERFORM public.refresh_iou_status(v_payment.iou_id);

  RETURN v_payment;
END;
$$;


ALTER FUNCTION "public"."reject_payment"("p_payment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_schedule_change"("p_iou_id" "uuid") RETURNS TABLE("id" "uuid", "status" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_iou public.ious%ROWTYPE;
BEGIN
  SELECT *
  INTO v_iou
  FROM public.ious
  WHERE public.ious.id = p_iou_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'IOU not found: %', p_iou_id;
  END IF;

  IF auth.uid() IS DISTINCT FROM v_iou.lender_id THEN
    RAISE EXCEPTION 'Only the lender may reject schedule changes';
  END IF;

  IF v_iou.activated_at IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot reject schedule changes on an activated IOU';
  END IF;

  DELETE FROM public.payments pay
  WHERE pay.iou_id = p_iou_id
    AND COALESCE(pay.status, 'scheduled') = 'scheduled';

  -- Send it back to borrower to set another schedule.
  UPDATE public.ious i
  SET
    status = 'draft',
    requested_action_by = v_iou.borrower_id,
    total_installments = 0,
    paid_installments = 0
  WHERE i.id = p_iou_id;

  RETURN QUERY
  SELECT
    i.id,
    i.status
  FROM public.ious i
  WHERE i.id = p_iou_id;
END;
$$;


ALTER FUNCTION "public"."reject_schedule_change"("p_iou_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."restore_iou"("p_iou" "uuid") RETURNS "public"."ious"
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  update public.ious
     set archived_at = null,
         deleted_at  = null
   where id = p_iou
     and lender_id = auth.uid()
  returning *;
$$;


ALTER FUNCTION "public"."restore_iou"("p_iou" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."restore_loan"("p_loan" "uuid", "p_user" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  update public.loans
    set archived_at = null
  where id = p_loan
    and (lender_id = p_user or borrower_id = p_user);
end $$;


ALTER FUNCTION "public"."restore_loan"("p_loan" "uuid", "p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revoke_trust_report_share"("p_share_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_share public.trust_report_shares%rowtype;
begin
  if p_share_id is null then
    raise exception 'Missing share id';
  end if;

  select *
  into v_share
  from public.trust_report_shares
  where id = p_share_id;

  if not found then
    return false;
  end if;

  update public.trust_report_shares
  set
    revoked_at = now(),
    updated_at = now()
  where id = p_share_id
    and revoked_at is null;

  insert into public.trust_report_access_logs (
    owner_user_id,
    viewer_user_id,
    trust_report_share_id,
    access_type,
    scope,
    metadata
  )
  values (
    v_share.owner_user_id,
    v_share.viewer_user_id,
    v_share.id,
    'share_revoked',
    v_share.scope,
    '{}'::jsonb
  );

  return true;
end;
$$;


ALTER FUNCTION "public"."revoke_trust_report_share"("p_share_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_amount_weight"("p_amount_cents" bigint) RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $_$
declare
  v_amount_dollars numeric := greatest(1, coalesce(p_amount_cents, 0)::numeric / 100.0);
begin
  -- Logarithmic so $10,000 matters more than $100,
  -- but does not overpower consistency/time/proof.
  return round((ln(v_amount_dollars + 10) / ln(10))::numeric, 4);
end;
$_$;


ALTER FUNCTION "public"."score_v2_amount_weight"("p_amount_cents" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_confidence_label"("p_confidence" integer) RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_conf integer := greatest(0, least(100, coalesce(p_confidence, 0)));
begin
  if v_conf >= 90 then
    return 'very_high';
  elsif v_conf >= 75 then
    return 'high';
  elsif v_conf >= 55 then
    return 'medium';
  elsif v_conf >= 35 then
    return 'low';
  else
    return 'thin';
  end if;
end;
$$;


ALTER FUNCTION "public"."score_v2_confidence_label"("p_confidence" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_contract_ceiling"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer) RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_amount numeric := greatest(0, coalesce(p_amount_cents, 0)::numeric);
  v_proof numeric := public.score_v2_proof_multiplier(p_proof_tier, p_verification_tier);
  v_term numeric := public.score_v2_term_weight(p_term_months);
  v_raw numeric := 0;
  v_cap integer := 180;
begin
  v_raw := public.score_v2_personal_iou_ceiling(v_amount::bigint) * 1.2 * v_term * v_proof;

  if p_source_type = 'business_obligation' then
    v_cap := 300;
    v_raw := v_raw * 1.25;
  elsif p_source_type = 'service_contract' then
    v_cap := 180;
  else
    v_cap := 160;
  end if;

  return least(v_cap, greatest(5, round(v_raw)::integer));
end;
$$;


ALTER FUNCTION "public"."score_v2_contract_ceiling"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_domain_freshness_days"("p_domain" "text") RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
begin
  return case coalesce(p_domain, '')
    when 'housing_reliability' then 60
    when 'recurring_obligation_reliability' then 60
    when 'payment_reliability' then 180
    when 'obligation_strength' then 365
    when 'proof_depth' then 180
    when 'counterparty_diversity' then 365
    when 'recovery_behavior' then 180
    when 'lender_fairness' then 365
    when 'time_with_iou' then 99999
    when 'risk_stability' then 90
    else 180
  end;
end;
$$;


ALTER FUNCTION "public"."score_v2_domain_freshness_days"("p_domain" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_freshness_adjustment"("p_score" integer, "p_freshness_score" integer) RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_score integer := greatest(300, coalesce(p_score, 700));
  v_fresh integer := greatest(0, least(100, coalesce(p_freshness_score, 100)));
  v_adjustment integer := 0;
begin
  -- No raw score decay. This only affects Visible Trust.
  -- Higher scores rely more on fresh proof.

  if v_fresh >= 85 then
    return 0;
  end if;

  if v_fresh >= 70 then
    v_adjustment := case
      when v_score >= 1200 then 35
      when v_score >= 1000 then 25
      when v_score >= 850 then 12
      else 5
    end;
  elsif v_fresh >= 55 then
    v_adjustment := case
      when v_score >= 1200 then 70
      when v_score >= 1000 then 50
      when v_score >= 850 then 28
      else 12
    end;
  elsif v_fresh >= 40 then
    v_adjustment := case
      when v_score >= 1200 then 105
      when v_score >= 1000 then 80
      when v_score >= 850 then 45
      else 20
    end;
  else
    v_adjustment := case
      when v_score >= 1200 then 150
      when v_score >= 1000 then 115
      when v_score >= 850 then 70
      else 35
    end;
  end if;

  return v_adjustment;
end;
$$;


ALTER FUNCTION "public"."score_v2_freshness_adjustment"("p_score" integer, "p_freshness_score" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_freshness_multiplier"("p_last_verified_at" timestamp with time zone, "p_domain" "text" DEFAULT 'payment_reliability'::"text", "p_as_of" timestamp with time zone DEFAULT "now"()) RETURNS numeric
    LANGUAGE "plpgsql" STABLE
    AS $$
declare
  v_days_since integer;
  v_fresh_days integer;
begin
  if p_last_verified_at is null then
    return 0.40;
  end if;

  v_days_since := greatest(0, floor(extract(epoch from (p_as_of - p_last_verified_at)) / 86400)::integer);
  v_fresh_days := public.score_v2_domain_freshness_days(p_domain);

  if v_days_since <= v_fresh_days then
    return 1.00;
  end if;

  if v_days_since <= v_fresh_days * 2 then
    return 0.85;
  end if;

  if v_days_since <= v_fresh_days * 3 then
    return 0.70;
  end if;

  if v_days_since <= v_fresh_days * 5 then
    return 0.55;
  end if;

  return 0.40;
end;
$$;


ALTER FUNCTION "public"."score_v2_freshness_multiplier"("p_last_verified_at" timestamp with time zone, "p_domain" "text", "p_as_of" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_freshness_score"("p_last_verified_at" timestamp with time zone, "p_domain" "text" DEFAULT 'payment_reliability'::"text", "p_as_of" timestamp with time zone DEFAULT "now"()) RETURNS integer
    LANGUAGE "plpgsql" STABLE
    AS $$
begin
  return round(public.score_v2_freshness_multiplier(p_last_verified_at, p_domain, p_as_of) * 100)::integer;
end;
$$;


ALTER FUNCTION "public"."score_v2_freshness_score"("p_last_verified_at" timestamp with time zone, "p_domain" "text", "p_as_of" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_obligation_weight"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_frequency" "text", "p_proof_tier" integer, "p_verification_tier" integer, "p_same_pair_index" integer, "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_source numeric;
  v_amount numeric;
  v_term numeric;
  v_proof numeric;
  v_pair numeric;
  v_rent_meta numeric := 1.00;
  v_frequency numeric := 1.00;
  v_weight numeric;
begin
  v_source := public.score_v2_source_multiplier(p_source_type);
  v_amount := public.score_v2_amount_weight(p_amount_cents);
  v_term := public.score_v2_term_weight(p_term_months);
  v_proof := public.score_v2_proof_multiplier(p_proof_tier, p_verification_tier);
  v_pair := public.score_v2_same_pair_multiplier(p_same_pair_index);

  v_frequency :=
    case coalesce(p_frequency, '')
      when 'weekly' then 1.05
      when 'biweekly' then 1.03
      when 'monthly' then 1.00
      when 'one_time' then 0.85
      else 1.00
    end;

  if p_source_type = 'rent' then
    v_rent_meta := public.score_v2_rent_metadata_multiplier(coalesce(p_metadata, '{}'::jsonb));
  end if;

  v_weight := v_source * v_amount * v_term * v_proof * v_pair * v_frequency * v_rent_meta;

  return round(greatest(0, v_weight)::numeric, 4);
end;
$$;


ALTER FUNCTION "public"."score_v2_obligation_weight"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_frequency" "text", "p_proof_tier" integer, "p_verification_tier" integer, "p_same_pair_index" integer, "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_personal_iou_ceiling"("p_amount_cents" bigint) RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $_$
declare
  v_amount numeric := greatest(0, coalesce(p_amount_cents, 0)::numeric);
begin
  return case
    when v_amount < 5000 then
      greatest(1, round(v_amount / 2000.0)::integer) -- $20≈1, $40≈2

    when v_amount < 10000 then
      round(3 + ((v_amount - 5000) / 5000.0) * 3)::integer -- $50-$99≈3-6

    when v_amount < 25000 then
      round(7 + ((v_amount - 10000) / 15000.0) * 8)::integer -- $100-$249≈7-15

    when v_amount < 50000 then
      round(16 + ((v_amount - 25000) / 25000.0) * 14)::integer -- $250-$499≈16-30

    when v_amount < 100000 then
      round(35 + ((v_amount - 50000) / 50000.0) * 20)::integer -- $500-$999≈35-55

    when v_amount < 200000 then
      round(56 + ((v_amount - 100000) / 100000.0) * 24)::integer -- $1k-$2k≈56-80

    else
      least(140, round(68 + ln((v_amount / 100.0) / 2000.0 + 1) * 36)::integer)
  end;
end;
$_$;


ALTER FUNCTION "public"."score_v2_personal_iou_ceiling"("p_amount_cents" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_phone_bill_ceiling"("p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer) RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_amount numeric := greatest(0, coalesce(p_amount_cents, 0)::numeric / 100.0);
  v_months integer := greatest(1, coalesce(p_term_months, 1));
  v_base numeric := 0;
  v_time_bonus numeric := 1;
  v_proof numeric := public.score_v2_proof_multiplier(p_proof_tier, p_verification_tier);
begin
  v_base := case
    when v_amount < 30 then 2
    when v_amount < 50 then 4
    when v_amount < 80 then 7
    when v_amount < 120 then 10
    when v_amount < 200 then 14
    else 18
  end;

  v_time_bonus := case
    when v_months >= 24 then 2.2
    when v_months >= 12 then 1.7
    when v_months >= 6 then 1.3
    else 1.0
  end;

  return least(60, greatest(1, round(v_base * v_time_bonus * v_proof)::integer));
end;
$$;


ALTER FUNCTION "public"."score_v2_phone_bill_ceiling"("p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_proof_depth_label"("p_proof_depth" integer) RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_depth integer := greatest(0, least(100, coalesce(p_proof_depth, 0)));
begin
  if v_depth >= 90 then
    return 'institutional_grade';
  elsif v_depth >= 75 then
    return 'strong';
  elsif v_depth >= 55 then
    return 'developing';
  elsif v_depth >= 35 then
    return 'thin';
  else
    return 'very_thin';
  end if;
end;
$$;


ALTER FUNCTION "public"."score_v2_proof_depth_label"("p_proof_depth" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_proof_multiplier"("p_proof_tier" integer, "p_verification_tier" integer) RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_proof numeric := 0.25;
  v_verification numeric := 1.00;
begin
  v_proof :=
    case greatest(0, least(coalesce(p_proof_tier, 0), 4))
      when 0 then 0.25  -- self-entered / unverified
      when 1 then 0.60  -- manual proof / counterparty confirmed
      when 2 then 0.90  -- bank detected
      when 3 then 1.10  -- verified counterparty / landlord / business
      when 4 then 1.25  -- IOU processed payment rail
      else 0.25
    end;

  v_verification :=
    case greatest(0, least(coalesce(p_verification_tier, 0), 4))
      when 0 then 0.85
      when 1 then 0.95
      when 2 then 1.00
      when 3 then 1.10
      when 4 then 1.20
      else 1.00
    end;

  return round((v_proof * v_verification)::numeric, 4);
end;
$$;


ALTER FUNCTION "public"."score_v2_proof_multiplier"("p_proof_tier" integer, "p_verification_tier" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_public_trend_label"("p_delta_30d" integer) RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_delta integer := coalesce(p_delta_30d, 0);
begin
  if v_delta >= 15 then
    return 'improving';
  elsif v_delta <= -15 then
    return 'declining';
  elsif abs(v_delta) >= 8 then
    return 'volatile';
  else
    return 'stable';
  end if;
end;
$$;


ALTER FUNCTION "public"."score_v2_public_trend_label"("p_delta_30d" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_relationship_affects_score"("p_user_id" "uuid", "p_related_user_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public'
    AS $$
declare
  v_mode text;
begin
  v_mode := public.get_relationship_mode(p_user_id, p_related_user_id);

  return v_mode in (
    'standard_score_affecting',
    'business_score_affecting',
    'landlord_tenant_score_affecting'
  );
end;
$$;


ALTER FUNCTION "public"."score_v2_relationship_affects_score"("p_user_id" "uuid", "p_related_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_rent_ceiling"("p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer, "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_amount numeric := greatest(0, coalesce(p_amount_cents, 0)::numeric / 100.0);
  v_months integer := greatest(1, coalesce(p_term_months, 1));
  v_bedrooms integer := greatest(0, coalesce((p_metadata->>'bedroom_count')::integer, 0));
  v_same_amount numeric := greatest(0, least(1, coalesce((p_metadata->>'same_amount_consistency')::numeric, 0)));
  v_landlord_verified boolean := coalesce((p_metadata->>'landlord_verified')::boolean, false);

  v_base numeric := 0;
  v_term numeric := 1;
  v_bedroom_bonus numeric := 1;
  v_proof numeric := 1;
  v_consistency numeric := 1;
  v_market numeric := 1;
begin
  -- Raw rent amount still matters, but no longer dominates.
  v_base := case
    when v_amount < 500 then 25
    when v_amount < 900 then 45
    when v_amount < 1500 then 70
    when v_amount < 2400 then 100
    when v_amount < 3500 then 130
    else 160
  end;

  -- Time is a major trust factor.
  v_term := case
    when v_months >= 36 then 1.45
    when v_months >= 24 then 1.30
    when v_months >= 18 then 1.18
    when v_months >= 12 then 1.05
    when v_months >= 6 then 0.90
    else 0.70
  end;

  -- Bedrooms increase responsibility, but only moderately.
  v_bedroom_bonus := case
    when v_bedrooms <= 0 then 1.00
    when v_bedrooms = 1 then 1.03
    when v_bedrooms = 2 then 1.07
    when v_bedrooms = 3 then 1.12
    else 1.16
  end;

  -- Tier 4 IOU rail is the biggest proof boost.
  v_proof := case greatest(0, least(coalesce(p_proof_tier, 0), 4))
    when 0 then 0.25
    when 1 then 0.45
    when 2 then 0.75
    when 3 then 0.95
    when 4 then 1.35
    else 0.25
  end;

  v_proof := v_proof * case greatest(0, least(coalesce(p_verification_tier, 0), 4))
    when 0 then 0.80
    when 1 then 0.90
    when 2 then 1.00
    when 3 then 1.05
    when 4 then 1.30
    else 1.00
  end;

  -- Consistency and verified landlord are confidence boosters.
  v_consistency := 1.00 + (v_same_amount * 0.05);

  if v_landlord_verified then
    v_consistency := v_consistency + 0.05;
  end if;

  -- Local market adjustment.
  v_market := public.score_v2_rent_market_multiplier(coalesce(p_metadata, '{}'::jsonb));

  return least(
    350,
    greatest(
      20,
      round(v_base * v_term * v_bedroom_bonus * v_proof * v_consistency * v_market)::integer
    )
  );
end;
$$;


ALTER FUNCTION "public"."score_v2_rent_ceiling"("p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer, "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_rent_market_multiplier"("p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_ratio numeric := coalesce((p_metadata->>'rent_to_market_ratio')::numeric, null);
  v_market_median_cents numeric := coalesce((p_metadata->>'market_median_rent_cents')::numeric, null);
  v_monthly_rent_cents numeric := coalesce((p_metadata->>'monthly_rent_cents')::numeric, null);
begin
  -- If ratio was not precomputed, calculate it from monthly rent and local median.
  if v_ratio is null
     and v_market_median_cents is not null
     and v_market_median_cents > 0
     and v_monthly_rent_cents is not null then
    v_ratio := v_monthly_rent_cents / v_market_median_cents;
  end if;

  -- No local market data = conservative neutral-low multiplier.
  -- We do not reward raw high rent without area context.
  if v_ratio is null then
    return 0.85;
  end if;

  -- Market-adjusted obligation seriousness:
  -- Too low relative to market = valid but lighter signal.
  -- Around local median = strong normal signal.
  -- Moderately above median = serious obligation.
  -- Extreme above median = possible overextension/fake/inflated rent, cap benefit.
  return case
    when v_ratio < 0.50 then 0.65
    when v_ratio < 0.75 then 0.80
    when v_ratio <= 1.15 then 1.00
    when v_ratio <= 1.35 then 1.08
    when v_ratio <= 1.60 then 1.12
    when v_ratio <= 1.90 then 1.05
    else 0.90
  end;
end;
$$;


ALTER FUNCTION "public"."score_v2_rent_market_multiplier"("p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_rent_metadata_multiplier"("p_metadata" "jsonb") RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_bedrooms integer := greatest(0, coalesce((p_metadata->>'bedroom_count')::integer, 0));
  v_stream_months integer := greatest(0, coalesce((p_metadata->>'rent_stream_months')::integer, 0));
  v_same_amount numeric := greatest(0, least(1, coalesce((p_metadata->>'same_amount_consistency')::numeric, 0)));
  v_landlord_verified boolean := coalesce((p_metadata->>'landlord_verified')::boolean, false);
  v_multiplier numeric := 1.00;
begin
  -- Bedrooms boost ceiling, not instant score.
  v_multiplier := v_multiplier +
    case
      when v_bedrooms <= 0 then 0
      when v_bedrooms = 1 then 0.05
      when v_bedrooms = 2 then 0.12
      when v_bedrooms = 3 then 0.20
      else 0.25
    end;

  -- Long stable rent stream matters.
  v_multiplier := v_multiplier +
    case
      when v_stream_months >= 24 then 0.25
      when v_stream_months >= 12 then 0.18
      when v_stream_months >= 6 then 0.10
      when v_stream_months >= 3 then 0.04
      else 0
    end;

  -- Same amount consistency suggests stability.
  v_multiplier := v_multiplier + (v_same_amount * 0.10);

  if v_landlord_verified then
    v_multiplier := v_multiplier + 0.15;
  end if;

  return round(least(v_multiplier, 1.75)::numeric, 4);
end;
$$;


ALTER FUNCTION "public"."score_v2_rent_metadata_multiplier"("p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_same_pair_multiplier"("p_same_pair_index" integer) RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_index integer := greatest(1, coalesce(p_same_pair_index, 1));
begin
  if v_index = 1 then return 1.00; end if;
  if v_index = 2 then return 0.80; end if;
  if v_index = 3 then return 0.64; end if;
  if v_index = 4 then return 0.50; end if;
  if v_index = 5 then return 0.35; end if;

  return 0.20;
end;
$$;


ALTER FUNCTION "public"."score_v2_same_pair_multiplier"("p_same_pair_index" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_score_ceiling"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_frequency" "text", "p_proof_tier" integer, "p_verification_tier" integer, "p_same_pair_index" integer, "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_base integer := 0;
  v_pair numeric := public.score_v2_same_pair_multiplier(p_same_pair_index);
begin
  v_base := case p_source_type
    when 'personal_iou' then public.score_v2_personal_iou_ceiling(p_amount_cents)
    when 'family_obligation' then public.score_v2_personal_iou_ceiling(p_amount_cents)
    when 'phone_bill' then public.score_v2_phone_bill_ceiling(p_amount_cents, p_term_months, p_proof_tier, p_verification_tier)
    when 'utility_bill' then public.score_v2_phone_bill_ceiling(p_amount_cents, p_term_months, p_proof_tier, p_verification_tier)
    when 'rent' then public.score_v2_rent_ceiling(p_amount_cents, p_term_months, p_proof_tier, p_verification_tier, coalesce(p_metadata, '{}'::jsonb))
    when 'service_contract' then public.score_v2_contract_ceiling(p_source_type, p_amount_cents, p_term_months, p_proof_tier, p_verification_tier)
    when 'business_obligation' then public.score_v2_contract_ceiling(p_source_type, p_amount_cents, p_term_months, p_proof_tier, p_verification_tier)
    when 'receipt_split' then least(15, greatest(0, round(public.score_v2_personal_iou_ceiling(p_amount_cents) * 0.20)::integer))
    when 'lender_activity' then least(120, greatest(3, round(public.score_v2_personal_iou_ceiling(p_amount_cents) * 0.85)::integer))
    when 'landlord_activity' then least(180, greatest(5, round(public.score_v2_personal_iou_ceiling(p_amount_cents) * 1.15)::integer))
    else least(50, greatest(1, round(public.score_v2_personal_iou_ceiling(p_amount_cents) * 0.5)::integer))
  end;

  return greatest(0, round(v_base * v_pair)::integer);
end;
$$;


ALTER FUNCTION "public"."score_v2_score_ceiling"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_frequency" "text", "p_proof_tier" integer, "p_verification_tier" integer, "p_same_pair_index" integer, "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_source_multiplier"("p_source_type" "text") RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
begin
  return case coalesce(p_source_type, '')
    when 'receipt_split' then 0.20
    when 'phone_bill' then 0.45
    when 'utility_bill' then 0.45
    when 'personal_iou' then 1.00
    when 'family_obligation' then 1.00
    when 'service_contract' then 1.15
    when 'business_obligation' then 1.25
    when 'rent' then 1.75
    when 'lender_activity' then 1.10
    when 'landlord_activity' then 1.35
    else 0.50
  end;
end;
$$;


ALTER FUNCTION "public"."score_v2_source_multiplier"("p_source_type" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_term_weight"("p_term_months" integer) RETURNS numeric
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_months integer := greatest(1, coalesce(p_term_months, 1));
begin
  -- Longer obligations matter more, but with diminishing returns.
  return round((1 + (ln(v_months::numeric + 1) / ln(10)) / 2)::numeric, 4);
end;
$$;


ALTER FUNCTION "public"."score_v2_term_weight"("p_term_months" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_tier_freshness_eligible"("p_tier" "text", "p_freshness_score" integer, "p_proof_depth" integer DEFAULT 0, "p_time_with_iou_days" integer DEFAULT 0) RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_tier text := coalesce(p_tier, '');
  v_fresh integer := greatest(0, least(100, coalesce(p_freshness_score, 0)));
  v_depth integer := greatest(0, least(100, coalesce(p_proof_depth, 0)));
  v_days integer := greatest(0, coalesce(p_time_with_iou_days, 0));
begin
  -- Lower/middle tiers should not punish inactivity harshly.
  if v_tier in ('rebuilding_user', 'verified_user', 'developing_trust', 'reliable') then
    return true;
  end if;

  if v_tier = 'strong' then
    return v_fresh >= 45;
  end if;

  if v_tier = 'excellent' then
    return v_fresh >= 55 and v_depth >= 45;
  end if;

  -- Elite trust requires recent proof.
  -- A stale high score can keep the raw score, but cannot keep elite eligibility.
  if v_tier = 'elite_trust' then
    return v_fresh >= 80 and v_depth >= 75 and v_days >= 365;
  end if;

  -- IOU Pillar is extremely rare and requires very fresh proof + 5 years.
  if v_tier = 'iou_pillar' then
    return v_fresh >= 90 and v_depth >= 90 and v_days >= 1825;
  end if;

  return false;
end;
$$;


ALTER FUNCTION "public"."score_v2_tier_freshness_eligible"("p_tier" "text", "p_freshness_score" integer, "p_proof_depth" integer, "p_time_with_iou_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_trust_tier"("p_score" integer, "p_time_with_iou_days" integer DEFAULT 0, "p_proof_depth" integer DEFAULT 0, "p_has_active_strike" boolean DEFAULT false, "p_has_high_risk_flag" boolean DEFAULT false) RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_score integer := coalesce(p_score, 700);
  v_days integer := greatest(0, coalesce(p_time_with_iou_days, 0));
  v_proof integer := greatest(0, least(100, coalesce(p_proof_depth, 0)));
begin
  if p_has_active_strike then
    return 'rebuilding_user';
  end if;

  if v_score < 650 then
    return 'rebuilding_user';
  end if;

  if v_score < 725 then
    return 'verified_user';
  end if;

  if v_score < 800 then
    return 'developing_trust';
  end if;

  if v_score < 875 then
    return 'reliable';
  end if;

  if v_score < 950 then
    return 'strong';
  end if;

  if v_score < 1050 then
    return 'excellent';
  end if;

  -- Elite requires score plus proof/time.
  if v_score < 1250 then
    if v_days >= 365 and v_proof >= 70 and not p_has_high_risk_flag then
      return 'elite_trust';
    end if;
    return 'excellent';
  end if;

  -- IOU Pillar should be extremely rare.
  -- Requires 5+ years and very high proof depth.
  if v_score >= 1300 and v_days >= 1825 and v_proof >= 90 and not p_has_high_risk_flag then
    return 'iou_pillar';
  end if;

  return 'elite_trust';
end;
$$;


ALTER FUNCTION "public"."score_v2_trust_tier"("p_score" integer, "p_time_with_iou_days" integer, "p_proof_depth" integer, "p_has_active_strike" boolean, "p_has_high_risk_flag" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."score_v2_visible_trust"("p_score" integer, "p_active_exposure_points" integer DEFAULT 0, "p_freshness_score" integer DEFAULT 100) RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_score integer := greatest(300, coalesce(p_score, 700));
  v_exposure integer := greatest(0, coalesce(p_active_exposure_points, 0));
  v_freshness_adjustment integer := public.score_v2_freshness_adjustment(v_score, p_freshness_score);
begin
  return greatest(300, v_score - v_exposure - v_freshness_adjustment);
end;
$$;


ALTER FUNCTION "public"."score_v2_visible_trust"("p_score" integer, "p_active_exposure_points" integer, "p_freshness_score" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_score_agreement_for_iou"("p_iou_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_iou public.ious%rowtype;
  v_status text;
  v_agreement_id uuid;

  v_existing_id uuid;
  v_old_user_id uuid;
  v_old_counterparty_id uuid;

  v_proof_tier integer := 1;
  v_verification_tier integer := 1;

  v_existing_metadata jsonb := '{}'::jsonb;
  v_sync_metadata jsonb := '{}'::jsonb;
begin
  if p_iou_id is null then
    return null;
  end if;

  select *
  into v_iou
  from public.ious
  where id = p_iou_id
  for update;

  if not found then
    return null;
  end if;

  select
    sa.id,
    sa.user_id,
    sa.counterparty_id,
    coalesce(sa.proof_tier, 1),
    coalesce(sa.verification_tier, 1),
    coalesce(sa.metadata, '{}'::jsonb)
  into
    v_existing_id,
    v_old_user_id,
    v_old_counterparty_id,
    v_proof_tier,
    v_verification_tier,
    v_existing_metadata
  from public.score_agreements sa
  where sa.source_type = 'personal_iou'
    and sa.source_id = p_iou_id
  for update;

  if not found then
    v_existing_id := null;
    v_old_user_id := null;
    v_old_counterparty_id := null;
    v_proof_tier := 1;
    v_verification_tier := 1;
    v_existing_metadata := '{}'::jsonb;
  end if;

  if v_iou.borrower_id is null
     or v_iou.lender_id is null then

    if v_existing_id is not null then
      update public.score_agreements
      set
        status = 'cancelled',
        score_ceiling = 0,
        metadata =
          (coalesce(metadata, '{}'::jsonb) - 'archived_at')
          || jsonb_build_object(
            'legacy_status',
            v_iou.status,
            'derived_score_status',
            'cancelled',
            'source_eligible',
            false,
            'deleted_at',
            v_iou.deleted_at,
            'inactive_shadow_ceiling_zeroed',
            true,
            'synced_at',
            now(),
            'sync_source',
            'sync_score_agreement_for_iou'
          )
      where id = v_existing_id;

      perform public.recalculate_score_v2_personal_iou_pair(
        v_old_user_id,
        v_old_counterparty_id
      );
    end if;

    return v_existing_id;
  end if;

  v_status :=
    case
      when v_iou.deleted_at is not null
        or v_iou.status in ('canceled', 'cancelled')
        then 'cancelled'

      when v_iou.status = 'paid'
        then 'completed'

      when v_iou.activated_at is not null
        and v_iou.status in ('open', 'late')
        then 'active'

      else 'draft'
    end;

  v_sync_metadata :=
    (coalesce(v_existing_metadata, '{}'::jsonb) - 'archived_at')
    || jsonb_build_object(
      'source_table',
      'ious',
      'legacy_status',
      v_iou.status,
      'derived_score_status',
      v_status,
      'source_eligible',
      true,
      'title',
      v_iou.title,
      'apr_bps',
      v_iou.apr_bps,
      'source_created_at',
      v_iou.created_at,
      'deleted_at',
      v_iou.deleted_at,
      'inactive_shadow_ceiling_zeroed',
      (v_status = 'cancelled'),
      'synced_at',
      now(),
      'sync_source',
      'sync_score_agreement_for_iou'
    );

  if v_existing_id is null then
    v_sync_metadata :=
      v_sync_metadata
      || jsonb_build_object(
        'shadow_backfill',
        false
      );
  end if;

  insert into public.score_agreements (
    user_id,
    source_type,
    source_id,
    counterparty_id,
    amount_cents,
    term_months,
    frequency,
    status,
    proof_tier,
    verification_tier,
    obligation_weight,
    score_ceiling,
    score_contributed,
    same_pair_index,
    same_pair_multiplier,
    activated_at,
    completed_at,
    metadata
  )
  values (
    v_iou.borrower_id,
    'personal_iou',
    v_iou.id,
    v_iou.lender_id,
    v_iou.principal_cents,
    v_iou.term_months,
    v_iou.frequency,
    v_status,
    v_proof_tier,
    v_verification_tier,
    public.score_v2_obligation_weight(
      'personal_iou',
      v_iou.principal_cents,
      v_iou.term_months,
      v_iou.frequency,
      v_proof_tier,
      v_verification_tier,
      1,
      v_sync_metadata
    ),
    case
      when v_status = 'cancelled'
        then 0
      else public.score_v2_score_ceiling(
        'personal_iou',
        v_iou.principal_cents,
        v_iou.term_months,
        v_iou.frequency,
        v_proof_tier,
        v_verification_tier,
        1,
        v_sync_metadata
      )
    end,
    0,
    1,
    public.score_v2_same_pair_multiplier(1),
    v_iou.activated_at,
    case
      when v_status = 'completed'
        then now()
      else null
    end,
    v_sync_metadata
  )
  on conflict (source_id)
    where source_type = 'personal_iou'
      and source_id is not null
  do update set
    user_id = excluded.user_id,
    counterparty_id = excluded.counterparty_id,
    amount_cents = excluded.amount_cents,
    term_months = excluded.term_months,
    frequency = excluded.frequency,
    status = excluded.status,
    activated_at = excluded.activated_at,
    completed_at =
      case
        when excluded.status = 'completed'
          then coalesce(
            public.score_agreements.completed_at,
            excluded.completed_at
          )
        else null
      end,
    metadata = excluded.metadata
  returning id
  into v_agreement_id;

  if v_old_user_id is not null
     and v_old_counterparty_id is not null
     and (
       v_old_user_id is distinct from v_iou.borrower_id
       or v_old_counterparty_id
         is distinct from v_iou.lender_id
     ) then

    perform public.recalculate_score_v2_personal_iou_pair(
      v_old_user_id,
      v_old_counterparty_id
    );
  end if;

  perform public.recalculate_score_v2_personal_iou_pair(
    v_iou.borrower_id,
    v_iou.lender_id
  );

  return v_agreement_id;
end;
$$;


ALTER FUNCTION "public"."sync_score_agreement_for_iou"("p_iou_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_create_receipt_on_paid"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_actor uuid;
  v_payload jsonb;
  v_hash text;
begin
  -- only do work when a payment becomes paid
  if new.paid_at is null then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.paid_at is not null then
    return new;
  end if;

  v_actor := coalesce(new.updated_by, auth.uid());

  v_payload := jsonb_build_object(
    'v', 1,
    'payment_id', new.id,
    'iou_id', new.iou_id,
    'actor_id', v_actor,
    'amount_cents', new.amount_cents,
    'paid_at', new.paid_at,
    'due_at', new.due_at
  );

  v_hash := encode(digest(v_payload::text, 'sha256'), 'hex');

  insert into public.receipts (
    iou_id,
    event_type,
    payload_json,
    hash_sha256,
    created_by
  )
  values (
    new.iou_id,
    'payment_paid',
    v_payload,
    v_hash,
    v_actor
  );

  return new;
end
$$;


ALTER FUNCTION "public"."tg_create_receipt_on_paid"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_recompute_iou_status"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  perform public.recompute_iou_status(coalesce(NEW.iou_id, OLD.iou_id));
  return null;
end;
$$;


ALTER FUNCTION "public"."tg_recompute_iou_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_sync_score_agreement_for_iou"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.sync_score_agreement_for_iou(new.id);
  return new;
end;
$$;


ALTER FUNCTION "public"."trg_sync_score_agreement_for_iou"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_iou_progress"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin

update ious
set
  paid_installments = (
    select count(*)
    from payments
    where payments.iou_id = ious.id
    and payments.paid_at is not null
  ),
  progress_percent = (
    select
      case
        when count(*) = 0 then 0
        else
          (
            count(*) filter (where paid_at is not null)::numeric /
            count(*)::numeric
          ) * 100
      end
    from payments
    where payments.iou_id = ious.id
  )
where id = new.iou_id;

return new;

end;
$$;


ALTER FUNCTION "public"."update_iou_progress"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_score_risk_flag"("p_user_id" "uuid", "p_flag_type" "text", "p_severity" "text" DEFAULT 'low'::"text", "p_source_type" "text" DEFAULT NULL::"text", "p_source_id" "uuid" DEFAULT NULL::"uuid", "p_description" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_flag_id uuid;
begin
  if p_user_id is null then
    raise exception 'Missing user id';
  end if;

  if p_flag_type is null then
    raise exception 'Missing flag type';
  end if;

  select id
  into v_flag_id
  from public.score_risk_flags
  where user_id = p_user_id
    and flag_type = p_flag_type
    and coalesce(source_type, '') = coalesce(p_source_type, '')
    and source_id is not distinct from p_source_id
    and is_active = true
  limit 1;

  if v_flag_id is not null then
    update public.score_risk_flags
    set
      severity = p_severity,
      description = p_description,
      metadata = coalesce(metadata, '{}'::jsonb) || coalesce(p_metadata, '{}'::jsonb)
    where id = v_flag_id;

    return v_flag_id;
  end if;

  insert into public.score_risk_flags (
    user_id,
    flag_type,
    severity,
    source_type,
    source_id,
    description,
    metadata
  )
  values (
    p_user_id,
    p_flag_type,
    p_severity,
    p_source_type,
    p_source_id,
    p_description,
    coalesce(p_metadata, '{}'::jsonb)
  )
  returning id into v_flag_id;

  return v_flag_id;
end;
$$;


ALTER FUNCTION "public"."upsert_score_risk_flag"("p_user_id" "uuid", "p_flag_type" "text", "p_severity" "text", "p_source_type" "text", "p_source_id" "uuid", "p_description" "text", "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_receipt_item_assignment"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_item_receipt_split_id uuid;
  v_participant_receipt_split_id uuid;
  v_total_share numeric;
begin
  select receipt_split_id
  into v_item_receipt_split_id
  from public.receipt_split_items
  where id = new.item_id;

  if v_item_receipt_split_id is null then
    raise exception using message = 'Invalid receipt item';
  end if;

  select receipt_split_id
  into v_participant_receipt_split_id
  from public.receipt_split_participants
  where id = new.participant_id;

  if v_participant_receipt_split_id is null then
    raise exception using message = 'Invalid receipt participant';
  end if;

  if new.receipt_split_id <> v_item_receipt_split_id then
    raise exception using message = 'Assignment receipt_split_id does not match item receipt_split_id';
  end if;

  if v_participant_receipt_split_id <> v_item_receipt_split_id then
    raise exception using message = 'Participant does not belong to this receipt split';
  end if;

  select coalesce(sum(share_percent), 0)
  into v_total_share
  from public.receipt_item_assignments
  where item_id = new.item_id
    and id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

  v_total_share := v_total_share + new.share_percent;

  if v_total_share > 100 then
    raise exception using message =
      'Item assignment exceeds 100 percent. Current attempted total: ' || v_total_share::text;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."validate_receipt_item_assignment"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."verify_phone_code"("in_code" "text", "in_phone" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_verification_id uuid;
  v_verified_phone text;
  v_target_phone text := nullif(btrim(coalesce(in_phone, '')), '');
begin
  if v_uid is null then
    raise exception using
      errcode = '42501',
      message = 'not authenticated';
  end if;

  if nullif(btrim(coalesce(in_code, '')), '') is null then
    return false;
  end if;

  select
    pv.id,
    pv.phone
  into
    v_verification_id,
    v_verified_phone
  from public.phone_verifications pv
  where pv.user_id = v_uid
    and pv.used_at is null
    and pv.expires_at > now()
    and pv.code = btrim(in_code)
    and (
      v_target_phone is null
      or pv.phone = v_target_phone
    )
  order by pv.created_at desc
  limit 1
  for update;

  if not found then
    return false;
  end if;

  update public.phone_verifications
  set used_at = now()
  where id = v_verification_id
    and used_at is null;

  if not found then
    return false;
  end if;

  update public.profiles
  set
    phone = v_verified_phone,
    phone_verified = true,
    phone_verified_at = now()
  where id = v_uid;

  if not found then
    raise exception 'Profile not found for authenticated user';
  end if;

  return true;
end;
$$;


ALTER FUNCTION "public"."verify_phone_code"("in_code" "text", "in_phone" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."agreement_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "actor_id" "uuid",
    "counterparty_id" "uuid",
    "score_agreement_id" "uuid",
    "source_type" "text",
    "source_id" "uuid",
    "event_type" "text" NOT NULL,
    "event_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "amount_cents" bigint,
    "previous_amount_cents" bigint,
    "apr_bps" integer,
    "previous_apr_bps" integer,
    "due_at" timestamp with time zone,
    "previous_due_at" timestamp with time zone,
    "days_early" integer,
    "days_late" integer,
    "proof_tier" integer,
    "verification_tier" integer,
    "relationship_mode" "text",
    "score_model_version" "text",
    "risk_model_version" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "agreement_events_event_type_check" CHECK (("event_type" = ANY (ARRAY['agreement_created'::"text", 'agreement_invited'::"text", 'agreement_viewed'::"text", 'agreement_accepted'::"text", 'agreement_declined'::"text", 'agreement_cancelled'::"text", 'agreement_archived'::"text", 'agreement_restored'::"text", 'agreement_completed'::"text", 'agreement_defaulted'::"text", 'terms_proposed'::"text", 'terms_changed'::"text", 'amount_changed'::"text", 'apr_changed'::"text", 'schedule_changed'::"text", 'due_date_changed'::"text", 'payment_due'::"text", 'payment_attempt_started'::"text", 'payment_attempt_failed'::"text", 'payment_paid_early'::"text", 'payment_paid_on_time'::"text", 'payment_paid_late'::"text", 'payment_partial'::"text", 'payment_confirmed'::"text", 'payment_rejected'::"text", 'payment_reversed'::"text", 'extension_requested'::"text", 'extension_approved'::"text", 'extension_denied'::"text", 'extension_counteroffered'::"text", 'dispute_opened'::"text", 'dispute_updated'::"text", 'dispute_resolved'::"text", 'strike_applied'::"text", 'strike_expired'::"text", 'recovery_progress'::"text", 'rent_month_verified'::"text", 'rent_month_missed'::"text", 'phone_bill_verified'::"text", 'phone_bill_missed'::"text", 'relationship_mode_applied'::"text", 'risk_flag_created'::"text", 'risk_flag_resolved'::"text"]))),
    CONSTRAINT "agreement_events_proof_tier_check" CHECK ((("proof_tier" IS NULL) OR (("proof_tier" >= 0) AND ("proof_tier" <= 4)))),
    CONSTRAINT "agreement_events_verification_tier_check" CHECK ((("verification_tier" IS NULL) OR (("verification_tier" >= 0) AND ("verification_tier" <= 4))))
);


ALTER TABLE "public"."agreement_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."amend_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "iou_id" "uuid" NOT NULL,
    "requester_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "resolved_by" "uuid"
);


ALTER TABLE "public"."amend_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "accessed_by" "text" NOT NULL,
    "action" "text" NOT NULL,
    "target_table" "text" NOT NULL,
    "target_id" "text" NOT NULL,
    "reason" "text",
    "ip_address" "inet",
    "accessed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "audit_log_action_check" CHECK (("action" = ANY (ARRAY['READ'::"text", 'WRITE'::"text", 'DELETE'::"text"])))
);


ALTER TABLE "public"."audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bank_accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "plaid_item_id" "text" NOT NULL,
    "plaid_account_id" "text" NOT NULL,
    "institution_name" "text",
    "account_name" "text",
    "official_name" "text",
    "mask" "text",
    "type" "text",
    "subtype" "text",
    "verification_status" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "is_default_payment" boolean DEFAULT false NOT NULL,
    "is_default_payout" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "dwolla_funding_source_url" "text",
    "dwolla_funding_source_id" "text",
    "dwolla_funding_source_status" "text"
);


ALTER TABLE "public"."bank_accounts" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."borrower_due_next_14" AS
 SELECT "i"."borrower_id",
    ("now"())::"date" AS "from_day",
    ((("now"())::"date" + '14 days'::interval))::"date" AS "to_day",
    "sum"("p"."amount_cents") FILTER (WHERE (("p"."status" <> 'paid'::"text") AND ("p"."due_date" >= ("now"())::"date") AND ("p"."due_date" < ((("now"())::"date" + '14 days'::interval))::"date"))) AS "total_due_cents",
    "count"(*) FILTER (WHERE (("p"."status" <> 'paid'::"text") AND ("p"."due_date" >= ("now"())::"date") AND ("p"."due_date" < ((("now"())::"date" + '14 days'::interval))::"date"))) AS "payment_count",
    "count"(DISTINCT "p"."iou_id") FILTER (WHERE (("p"."status" <> 'paid'::"text") AND ("p"."due_date" >= ("now"())::"date") AND ("p"."due_date" < ((("now"())::"date" + '14 days'::interval))::"date"))) AS "iou_count"
   FROM ("public"."payments" "p"
     JOIN "public"."ious" "i" ON (("i"."id" = "p"."iou_id")))
  GROUP BY "i"."borrower_id";


ALTER VIEW "public"."borrower_due_next_14" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "iou_id" "uuid",
    "kind" "text" NOT NULL,
    "meta" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."identity_vault" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "full_name" "text",
    "dob" "text",
    "ssn_last_4" "text",
    "ssn_full_encrypted" "text",
    "email" "text",
    "phone" "text",
    "phone_digits" "text",
    "address_1" "text",
    "address_2" "text",
    "city" "text",
    "state" "text",
    "postal_code" "text",
    "dwolla_customer_id" "text",
    "dwolla_customer_status" "text",
    "plaid_account_id" "text",
    "plaid_institution_name" "text",
    "account_mask" "text",
    "bank_name" "text",
    "identity_status" "text",
    "identity_verified_at" timestamp with time zone,
    "phone_verified" boolean DEFAULT false,
    "phone_verified_at" timestamp with time zone,
    "bank_linked" boolean DEFAULT false,
    "plaid_linked" boolean DEFAULT false,
    "ach_status" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "retention_until" timestamp with time zone
);


ALTER TABLE "public"."identity_vault" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invitations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "iou_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "token" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."invitations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(6), 'hex'::"text") NOT NULL,
    "inviter_id" "uuid" NOT NULL,
    "target_email" "text",
    "target_phone" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "accepted_by" "uuid",
    "accepted_at" timestamp with time zone
);


ALTER TABLE "public"."invites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."iou_acceptance_audit" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "iou_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "typed_signature" "text" NOT NULL,
    "terms_version" "text" NOT NULL,
    "privacy_version" "text" NOT NULL,
    "platform_fee_bps" integer DEFAULT 70 NOT NULL,
    "accepted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "repayment_total_cents" bigint DEFAULT 0 NOT NULL,
    "platform_fee_cents" bigint DEFAULT 0 NOT NULL,
    "total_borrower_cost_cents" bigint DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "public"."iou_acceptance_audit" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."iou_acceptance_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "iou_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "typed_signature" "text",
    "terms_version" "text",
    "privacy_version" "text",
    "platform_fee_bps" integer,
    "ip_address" "text",
    "user_agent" "text",
    "accepted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb"
);


ALTER TABLE "public"."iou_acceptance_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."iou_invites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "iou_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "token" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."iou_invites" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."iou_progress" AS
 SELECT "id" AS "iou_id",
    "title",
    "total_installments",
    "paid_installments",
    "progress_percent"
   FROM "public"."ious" "i";


ALTER VIEW "public"."iou_progress" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."legal_acceptances" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "document_type" "text" NOT NULL,
    "document_version" "text" NOT NULL,
    "document_hash" "text",
    "accepted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "context" "text" NOT NULL,
    "related_iou_id" "uuid",
    "platform" "text",
    "app_version" "text",
    "device_metadata" "jsonb",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "legal_acceptances_context_check" CHECK (("context" = ANY (ARRAY['new_iou_flow'::"text", 'signup'::"text", 're_acceptance'::"text", 'settings'::"text"]))),
    CONSTRAINT "legal_acceptances_document_type_check" CHECK (("document_type" = ANY (ARRAY['terms_of_service'::"text", 'privacy_policy'::"text"]))),
    CONSTRAINT "legal_acceptances_document_version_nonempty" CHECK ((TRIM(BOTH FROM "document_version") <> ''::"text"))
);


ALTER TABLE "public"."legal_acceptances" OWNER TO "postgres";


COMMENT ON TABLE "public"."legal_acceptances" IS 'Append-only consent ledger for platform Terms of Service and Privacy Policy. Separate from iou_acceptance_audit (signed IOU agreements). Do not UPDATE or DELETE rows. See trigger: legal_acceptances_block_mutation_trg.';



CREATE OR REPLACE VIEW "public"."lender_due_next_14" AS
 SELECT "i"."lender_id",
    ("now"())::"date" AS "from_day",
    ((("now"())::"date" + '14 days'::interval))::"date" AS "to_day",
    "sum"("p"."amount_cents") FILTER (WHERE (("p"."status" <> 'paid'::"text") AND ("p"."due_date" >= ("now"())::"date") AND ("p"."due_date" < ((("now"())::"date" + '14 days'::interval))::"date"))) AS "total_due_cents",
    "count"(*) FILTER (WHERE (("p"."status" <> 'paid'::"text") AND ("p"."due_date" >= ("now"())::"date") AND ("p"."due_date" < ((("now"())::"date" + '14 days'::interval))::"date"))) AS "payment_count",
    "count"(DISTINCT "p"."iou_id") FILTER (WHERE (("p"."status" <> 'paid'::"text") AND ("p"."due_date" >= ("now"())::"date") AND ("p"."due_date" < ((("now"())::"date" + '14 days'::interval))::"date"))) AS "iou_count"
   FROM ("public"."payments" "p"
     JOIN "public"."ious" "i" ON (("i"."id" = "p"."iou_id")))
  GROUP BY "i"."lender_id";


ALTER VIEW "public"."lender_due_next_14" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."loan_amendments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "iou_id" "uuid" NOT NULL,
    "proposer_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'proposed'::"text" NOT NULL,
    "note" "text",
    "proposed" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "decided_at" timestamp with time zone,
    "decided_by" "uuid"
);


ALTER TABLE "public"."loan_amendments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."loan_invites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "iou_id" "uuid" NOT NULL,
    "lender_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "accepted_at" timestamp with time zone,
    "accepted_by" "uuid"
);


ALTER TABLE "public"."loan_invites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_receipts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_id" "uuid" NOT NULL,
    "iou_id" "uuid" NOT NULL,
    "payer_user_id" "uuid",
    "payee_user_id" "uuid",
    "amount_cents" integer NOT NULL,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "method" "text" DEFAULT 'manual'::"text" NOT NULL,
    "paid_at" timestamp with time zone NOT NULL,
    "payload_json" "jsonb" NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "payment_receipts_amount_cents_check" CHECK (("amount_cents" >= 0))
);


ALTER TABLE "public"."payment_receipts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."phone_lookup" (
    "phone_hash" "text" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "verified" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."phone_lookup" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."phone_verifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "phone" "text" NOT NULL,
    "code" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '00:05:00'::interval) NOT NULL,
    "used_at" timestamp with time zone
);


ALTER TABLE "public"."phone_verifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plaid_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "item_id" "text" NOT NULL,
    "access_token" "text" NOT NULL,
    "institution_name" "text",
    "account_mask" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."plaid_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "display_name" "text",
    "photo_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "email" "text",
    "name" "text",
    "phone" "text",
    "phone_digits" "text",
    "phone_verified" boolean DEFAULT false,
    "full_name" "text",
    "phone_verified_at" timestamp with time zone,
    "public_key" "text",
    "iou_score" integer DEFAULT 700,
    "score_last_updated_at" timestamp with time zone DEFAULT "now"(),
    "active_exposure_points" integer DEFAULT 0 NOT NULL,
    "strike_count" integer DEFAULT 0,
    "score_cap" integer,
    "lifetime_score_cap" integer,
    "bank_linked" boolean DEFAULT false,
    "account_mask" "text",
    "bank_name" "text",
    "plaid_institution_name" "text",
    "plaid_account_id" "text",
    "plaid_linked" boolean DEFAULT false,
    "ach_status" "text" DEFAULT 'not_ready'::"text",
    "dwolla_customer_id" "text",
    "dwolla_customer_status" "text",
    "dob" "text",
    "address_1" "text",
    "address_2" "text",
    "city" "text",
    "state" "text",
    "postal_code" "text",
    "ssn_last_4" "text",
    "identity_status" "text",
    "identity_verified_at" timestamp with time zone,
    "iou_hash" "text" NOT NULL,
    "avatar_url" "text"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."profile_directory" WITH ("security_barrier"='true') AS
 SELECT "id",
    "iou_hash",
    COALESCE(NULLIF("btrim"("display_name"), ''::"text"), NULLIF("btrim"("name"), ''::"text"), NULLIF("btrim"("full_name"), ''::"text"), 'IOU User'::"text") AS "public_name",
    COALESCE(NULLIF("btrim"("avatar_url"), ''::"text"), NULLIF("btrim"("photo_url"), ''::"text")) AS "avatar_url",
    "iou_score",
    "active_exposure_points",
    "strike_count"
   FROM "public"."profiles" "p";


ALTER VIEW "public"."profile_directory" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profile_visibility_settings" (
    "user_id" "uuid" NOT NULL,
    "allow_phone_discovery" boolean DEFAULT true NOT NULL,
    "allow_email_discovery" boolean DEFAULT true NOT NULL,
    "trust_report_default_visibility" "text" DEFAULT 'private'::"text" NOT NULL,
    "show_basic_verified_badge" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "profile_visibility_settings_trust_report_default_visibili_check" CHECK (("trust_report_default_visibility" = ANY (ARRAY['private'::"text", 'connections_only'::"text", 'share_only'::"text"])))
);


ALTER TABLE "public"."profile_visibility_settings" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."public_profile" AS
 SELECT "id",
    "iou_hash",
    "display_name",
    "name",
    "photo_url",
    "iou_score",
    "score_cap",
    "lifetime_score_cap",
    "strike_count",
    "active_exposure_points",
    "created_at"
   FROM "public"."profiles";


ALTER VIEW "public"."public_profile" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."receipt_split_participants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "receipt_split_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "display_name" "text",
    "phone" "text",
    "email" "text",
    "is_owner" boolean DEFAULT false NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "receipt_split_participants_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'declined'::"text"])))
);


ALTER TABLE "public"."receipt_split_participants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."receipt_split_totals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "receipt_split_id" "uuid" NOT NULL,
    "participant_id" "uuid" NOT NULL,
    "items_total_cents" integer DEFAULT 0 NOT NULL,
    "tax_share_cents" integer DEFAULT 0 NOT NULL,
    "tip_share_cents" integer DEFAULT 0 NOT NULL,
    "total_owed_cents" integer DEFAULT 0 NOT NULL,
    "generated_iou_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."receipt_split_totals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."receipt_splits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "restaurant_name" "text",
    "receipt_date" "date",
    "subtotal_cents" integer DEFAULT 0 NOT NULL,
    "tax_cents" integer DEFAULT 0 NOT NULL,
    "tip_cents" integer DEFAULT 0 NOT NULL,
    "total_cents" integer DEFAULT 0 NOT NULL,
    "image_url" "text",
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "image_uri" "text",
    CONSTRAINT "receipt_splits_nonnegative_amounts" CHECK ((("subtotal_cents" >= 0) AND ("tax_cents" >= 0) AND ("tip_cents" >= 0) AND ("total_cents" >= 0))),
    CONSTRAINT "receipt_splits_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'assigning'::"text", 'ready'::"text", 'sent'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."receipt_splits" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."receipt_generated_ious_view" AS
 SELECT "rs"."id" AS "receipt_split_id",
    "rs"."owner_id",
    "rs"."restaurant_name",
    "rs"."status" AS "receipt_status",
    "rst"."participant_id",
    "rsp"."user_id" AS "borrower_id",
    "rsp"."display_name" AS "borrower_display_name",
    "rst"."items_total_cents",
    "rst"."tax_share_cents",
    "rst"."tip_share_cents",
    "rst"."total_owed_cents",
    "rst"."generated_iou_id",
    "rst"."created_at",
    "rst"."updated_at"
   FROM (("public"."receipt_split_totals" "rst"
     JOIN "public"."receipt_splits" "rs" ON (("rs"."id" = "rst"."receipt_split_id")))
     JOIN "public"."receipt_split_participants" "rsp" ON (("rsp"."id" = "rst"."participant_id")));


ALTER VIEW "public"."receipt_generated_ious_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."receipt_item_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "receipt_split_id" "uuid" NOT NULL,
    "item_id" "uuid" NOT NULL,
    "participant_id" "uuid" NOT NULL,
    "share_percent" numeric DEFAULT 100 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "receipt_item_assignments_share_percent_check" CHECK ((("share_percent" > (0)::numeric) AND ("share_percent" <= (100)::numeric)))
);


ALTER TABLE "public"."receipt_item_assignments" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."receipt_split_detail_view" AS
SELECT
    NULL::"uuid" AS "receipt_split_id",
    NULL::"uuid" AS "owner_id",
    NULL::"text" AS "restaurant_name",
    NULL::"date" AS "receipt_date",
    NULL::integer AS "subtotal_cents",
    NULL::integer AS "tax_cents",
    NULL::integer AS "tip_cents",
    NULL::integer AS "total_cents",
    NULL::"text" AS "status",
    NULL::"text" AS "image_url",
    NULL::timestamp with time zone AS "created_at",
    NULL::timestamp with time zone AS "updated_at",
    NULL::"jsonb" AS "participants",
    NULL::"jsonb" AS "items";


ALTER VIEW "public"."receipt_split_detail_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."receipt_split_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "receipt_split_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "quantity" numeric DEFAULT 1 NOT NULL,
    "unit_price_cents" integer DEFAULT 0 NOT NULL,
    "total_price_cents" integer DEFAULT 0 NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "local_item_id" "text",
    CONSTRAINT "receipt_split_items_nonnegative_amounts" CHECK ((("quantity" > (0)::numeric) AND ("unit_price_cents" >= 0) AND ("total_price_cents" >= 0)))
);


ALTER TABLE "public"."receipt_split_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."receipts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "iou_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "payload_json" "jsonb" NOT NULL,
    "hash_sha256" "text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "payment_id" "uuid",
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."receipts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."score_agreements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "source_type" "text" NOT NULL,
    "source_id" "uuid",
    "counterparty_id" "uuid",
    "amount_cents" bigint DEFAULT 0 NOT NULL,
    "term_months" integer,
    "frequency" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "proof_tier" integer DEFAULT 0 NOT NULL,
    "verification_tier" integer DEFAULT 0 NOT NULL,
    "obligation_weight" numeric DEFAULT 0 NOT NULL,
    "score_ceiling" integer DEFAULT 0 NOT NULL,
    "score_contributed" integer DEFAULT 0 NOT NULL,
    "same_pair_index" integer DEFAULT 1 NOT NULL,
    "same_pair_multiplier" numeric DEFAULT 1 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "activated_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "score_agreements_proof_tier_check" CHECK ((("proof_tier" >= 0) AND ("proof_tier" <= 4))),
    CONSTRAINT "score_agreements_source_type_check" CHECK (("source_type" = ANY (ARRAY['personal_iou'::"text", 'rent'::"text", 'phone_bill'::"text", 'utility_bill'::"text", 'receipt_split'::"text", 'service_contract'::"text", 'business_obligation'::"text", 'family_obligation'::"text", 'lender_activity'::"text", 'landlord_activity'::"text"]))),
    CONSTRAINT "score_agreements_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'active'::"text", 'completed'::"text", 'defaulted'::"text", 'cancelled'::"text", 'archived'::"text"]))),
    CONSTRAINT "score_agreements_verification_tier_check" CHECK ((("verification_tier" >= 0) AND ("verification_tier" <= 4)))
);


ALTER TABLE "public"."score_agreements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."score_badges" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "badge_key" "text" NOT NULL,
    "label" "text" NOT NULL,
    "visibility" "text" DEFAULT 'private'::"text" NOT NULL,
    "awarded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone,
    "source_type" "text",
    "source_id" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "score_badges_visibility_check" CHECK (("visibility" = ANY (ARRAY['public'::"text", 'private'::"text", 'internal'::"text"])))
);


ALTER TABLE "public"."score_badges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."score_domains" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "domain" "text" NOT NULL,
    "score" integer DEFAULT 0 NOT NULL,
    "confidence" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "score_domains_confidence_check" CHECK ((("confidence" >= 0) AND ("confidence" <= 100))),
    CONSTRAINT "score_domains_domain_check" CHECK (("domain" = ANY (ARRAY['payment_reliability'::"text", 'housing_reliability'::"text", 'recurring_obligation_reliability'::"text", 'obligation_strength'::"text", 'proof_depth'::"text", 'counterparty_diversity'::"text", 'recovery_behavior'::"text", 'lender_fairness'::"text", 'time_with_iou'::"text", 'risk_stability'::"text"])))
);


ALTER TABLE "public"."score_domains" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."score_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "iou_id" "uuid",
    "payment_id" "uuid",
    "event_type" "text" NOT NULL,
    "delta" integer DEFAULT 0 NOT NULL,
    "description" "text",
    "event_key" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "score_agreement_id" "uuid",
    "domain" "text",
    "visibility" "text" DEFAULT 'public'::"text" NOT NULL,
    "proof_tier" integer DEFAULT 0 NOT NULL,
    "obligation_weight" numeric,
    "reversal_of" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "score_events_proof_tier_check" CHECK ((("proof_tier" >= 0) AND ("proof_tier" <= 4))),
    CONSTRAINT "score_events_visibility_check" CHECK (("visibility" = ANY (ARRAY['public'::"text", 'private'::"text", 'internal'::"text"])))
);


ALTER TABLE "public"."score_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."score_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "delta" integer NOT NULL,
    "reason" "text" NOT NULL,
    "iou_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."score_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."score_risk_flags" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "flag_type" "text" NOT NULL,
    "severity" "text" DEFAULT 'low'::"text" NOT NULL,
    "source_type" "text",
    "source_id" "uuid",
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "score_risk_flags_severity_check" CHECK (("severity" = ANY (ARRAY['low'::"text", 'medium'::"text", 'high'::"text", 'critical'::"text"])))
);


ALTER TABLE "public"."score_risk_flags" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."signatures" (
    "iou_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "signed_at" timestamp with time zone DEFAULT "now"(),
    "signature_url" "text"
);


ALTER TABLE "public"."signatures" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trust_education_acceptances" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "education_key" "text" DEFAULT 'iou_trust_intro'::"text" NOT NULL,
    "education_version" "text" NOT NULL,
    "context" "text" DEFAULT 'manual_review'::"text" NOT NULL,
    "platform" "text",
    "accepted_statements" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "completed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."trust_education_acceptances" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trust_model_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "model_key" "text" NOT NULL,
    "version" "text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "description" "text",
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "activated_at" timestamp with time zone,
    "retired_at" timestamp with time zone,
    CONSTRAINT "trust_model_versions_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'shadow'::"text", 'active'::"text", 'deprecated'::"text", 'retired'::"text"])))
);


ALTER TABLE "public"."trust_model_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trust_outcome_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "score_agreement_id" "uuid",
    "source_type" "text",
    "source_id" "uuid",
    "outcome_type" "text" NOT NULL,
    "outcome_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "amount_cents" bigint,
    "days_early" integer,
    "days_late" integer,
    "proof_tier" integer,
    "verification_tier" integer,
    "related_snapshot_id" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "trust_outcome_events_outcome_type_check" CHECK (("outcome_type" = ANY (ARRAY['payment_paid_early'::"text", 'payment_paid_on_time'::"text", 'payment_paid_late'::"text", 'payment_reversed'::"text", 'payment_disputed'::"text", 'agreement_completed'::"text", 'agreement_defaulted'::"text", 'extension_requested'::"text", 'extension_approved'::"text", 'extension_denied'::"text", 'rent_month_verified'::"text", 'rent_month_missed'::"text", 'phone_bill_verified'::"text", 'phone_bill_missed'::"text", 'strike_applied'::"text", 'strike_expired'::"text", 'recovery_progress'::"text", 'lender_confirmed_fast'::"text", 'lender_confirmed_slow'::"text", 'lender_false_rejection'::"text", 'risk_flag_created'::"text", 'risk_flag_resolved'::"text"]))),
    CONSTRAINT "trust_outcome_events_proof_tier_check" CHECK ((("proof_tier" IS NULL) OR (("proof_tier" >= 0) AND ("proof_tier" <= 4)))),
    CONSTRAINT "trust_outcome_events_verification_tier_check" CHECK ((("verification_tier" IS NULL) OR (("verification_tier" >= 0) AND ("verification_tier" <= 4))))
);


ALTER TABLE "public"."trust_outcome_events" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."trust_prediction_accuracy_v" AS
 SELECT "toe"."id" AS "outcome_event_id",
    "toe"."created_at" AS "outcome_logged_at",
    "toe"."outcome_at",
    "toe"."user_id",
    "borrower"."email" AS "user_email",
    "toe"."score_agreement_id",
    "sa"."source_type",
    "sa"."source_id",
    "sa"."status" AS "agreement_status",
    "sa"."amount_cents",
    "round"((("sa"."amount_cents")::numeric / 100.0), 2) AS "amount_dollars",
    "sa"."term_months",
    "sa"."frequency",
    "sa"."proof_tier",
    "sa"."verification_tier",
    COALESCE(("toe"."metadata" ->> 'relationship_mode'::"text"), "public"."get_relationship_mode"("sa"."user_id", "sa"."counterparty_id")) AS "relationship_mode",
    "sa"."same_pair_index",
    "sa"."same_pair_multiplier",
    "sa"."obligation_weight",
    "sa"."score_ceiling",
    "sa"."score_contributed",
    "sa"."counterparty_id",
    "counterparty"."email" AS "counterparty_email",
    "toe"."outcome_type",
    "toe"."amount_cents" AS "outcome_amount_cents",
    "round"((("toe"."amount_cents")::numeric / 100.0), 2) AS "outcome_amount_dollars",
    "toe"."days_early",
    "toe"."days_late",
        CASE
            WHEN ("toe"."outcome_type" = ANY (ARRAY['payment_paid_early'::"text", 'payment_paid_on_time'::"text", 'agreement_completed'::"text", 'rent_month_verified'::"text", 'phone_bill_verified'::"text", 'recovery_progress'::"text", 'lender_confirmed_fast'::"text"])) THEN true
            ELSE false
        END AS "is_positive_outcome",
        CASE
            WHEN ("toe"."outcome_type" = ANY (ARRAY['payment_paid_late'::"text", 'payment_reversed'::"text", 'payment_disputed'::"text", 'agreement_defaulted'::"text", 'rent_month_missed'::"text", 'phone_bill_missed'::"text", 'strike_applied'::"text", 'lender_false_rejection'::"text"])) THEN true
            ELSE false
        END AS "is_negative_outcome",
        CASE
            WHEN ("toe"."outcome_type" = 'payment_paid_early'::"text") THEN 'better_than_expected'::"text"
            WHEN ("toe"."outcome_type" = 'payment_paid_on_time'::"text") THEN 'as_expected_good'::"text"
            WHEN ("toe"."outcome_type" = 'agreement_completed'::"text") THEN 'as_expected_good'::"text"
            WHEN ("toe"."outcome_type" = 'payment_paid_late'::"text") THEN 'weaker_than_expected'::"text"
            WHEN ("toe"."outcome_type" = 'agreement_defaulted'::"text") THEN 'failed'::"text"
            WHEN ("toe"."outcome_type" = 'payment_reversed'::"text") THEN 'failed_or_uncertain'::"text"
            WHEN ("toe"."outcome_type" = 'payment_disputed'::"text") THEN 'uncertain'::"text"
            ELSE 'informational'::"text"
        END AS "outcome_quality_label",
        CASE
            WHEN ("sa"."score_ceiling" >= 100) THEN 'high_predicted_value'::"text"
            WHEN ("sa"."score_ceiling" >= 40) THEN 'medium_predicted_value'::"text"
            WHEN ("sa"."score_ceiling" >= 10) THEN 'low_predicted_value'::"text"
            ELSE 'tiny_predicted_value'::"text"
        END AS "prediction_value_band",
        CASE
            WHEN ("sa"."same_pair_index" >= 6) THEN 'high_same_pair_repetition'::"text"
            WHEN ("sa"."same_pair_index" >= 3) THEN 'medium_same_pair_repetition'::"text"
            ELSE 'low_same_pair_repetition'::"text"
        END AS "same_pair_repetition_band",
    "toe"."metadata" AS "outcome_metadata",
    "sa"."metadata" AS "agreement_metadata"
   FROM ((("public"."trust_outcome_events" "toe"
     LEFT JOIN "public"."score_agreements" "sa" ON (("sa"."id" = "toe"."score_agreement_id")))
     LEFT JOIN "public"."profiles" "borrower" ON (("borrower"."id" = "toe"."user_id")))
     LEFT JOIN "public"."profiles" "counterparty" ON (("counterparty"."id" = "sa"."counterparty_id")));


ALTER VIEW "public"."trust_prediction_accuracy_v" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."trust_prediction_by_proof_tier_v" AS
 SELECT "proof_tier",
    "verification_tier",
    "count"(*) AS "total_outcomes",
    "count"(*) FILTER (WHERE "is_positive_outcome") AS "positive_outcomes",
    "count"(*) FILTER (WHERE "is_negative_outcome") AS "negative_outcomes",
    "round"("avg"("score_ceiling"), 2) AS "avg_score_ceiling",
    "round"("avg"("amount_dollars"), 2) AS "avg_amount_dollars",
    "round"(((100.0 * ("count"(*) FILTER (WHERE "is_positive_outcome"))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "positive_rate_pct",
    "round"(((100.0 * ("count"(*) FILTER (WHERE "is_negative_outcome"))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "negative_rate_pct"
   FROM "public"."trust_prediction_accuracy_v"
  GROUP BY "proof_tier", "verification_tier";


ALTER VIEW "public"."trust_prediction_by_proof_tier_v" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."trust_prediction_by_relationship_mode_v" AS
 SELECT "relationship_mode",
    "count"(*) AS "total_outcomes",
    "count"(*) FILTER (WHERE "is_positive_outcome") AS "positive_outcomes",
    "count"(*) FILTER (WHERE "is_negative_outcome") AS "negative_outcomes",
    "round"("avg"("score_ceiling"), 2) AS "avg_score_ceiling",
    "round"("avg"("amount_dollars"), 2) AS "avg_amount_dollars",
    "round"(((100.0 * ("count"(*) FILTER (WHERE "is_positive_outcome"))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "positive_rate_pct",
    "round"(((100.0 * ("count"(*) FILTER (WHERE "is_negative_outcome"))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "negative_rate_pct"
   FROM "public"."trust_prediction_accuracy_v"
  GROUP BY "relationship_mode";


ALTER VIEW "public"."trust_prediction_by_relationship_mode_v" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."trust_prediction_by_same_pair_band_v" AS
 SELECT "same_pair_repetition_band",
    "count"(*) AS "total_outcomes",
    "count"(*) FILTER (WHERE "is_positive_outcome") AS "positive_outcomes",
    "count"(*) FILTER (WHERE "is_negative_outcome") AS "negative_outcomes",
    "round"("avg"("same_pair_index"), 2) AS "avg_same_pair_index",
    "round"("avg"("same_pair_multiplier"), 4) AS "avg_same_pair_multiplier",
    "round"("avg"("score_ceiling"), 2) AS "avg_score_ceiling",
    "round"(((100.0 * ("count"(*) FILTER (WHERE "is_positive_outcome"))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "positive_rate_pct",
    "round"(((100.0 * ("count"(*) FILTER (WHERE "is_negative_outcome"))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "negative_rate_pct"
   FROM "public"."trust_prediction_accuracy_v"
  GROUP BY "same_pair_repetition_band";


ALTER VIEW "public"."trust_prediction_by_same_pair_band_v" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."trust_prediction_by_source_type_v" AS
 SELECT "source_type",
    "count"(*) AS "total_outcomes",
    "count"(*) FILTER (WHERE "is_positive_outcome") AS "positive_outcomes",
    "count"(*) FILTER (WHERE "is_negative_outcome") AS "negative_outcomes",
    "round"("avg"("score_ceiling"), 2) AS "avg_score_ceiling",
    "round"("avg"("amount_dollars"), 2) AS "avg_amount_dollars",
    "round"(((100.0 * ("count"(*) FILTER (WHERE "is_positive_outcome"))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "positive_rate_pct",
    "round"(((100.0 * ("count"(*) FILTER (WHERE "is_negative_outcome"))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "negative_rate_pct"
   FROM "public"."trust_prediction_accuracy_v"
  GROUP BY "source_type";


ALTER VIEW "public"."trust_prediction_by_source_type_v" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."trust_prediction_by_value_band_v" AS
 SELECT "prediction_value_band",
    "count"(*) AS "total_outcomes",
    "count"(*) FILTER (WHERE "is_positive_outcome") AS "positive_outcomes",
    "count"(*) FILTER (WHERE "is_negative_outcome") AS "negative_outcomes",
    "round"("avg"("score_ceiling"), 2) AS "avg_score_ceiling",
    "round"("avg"("amount_dollars"), 2) AS "avg_amount_dollars",
    "round"(((100.0 * ("count"(*) FILTER (WHERE "is_positive_outcome"))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "positive_rate_pct",
    "round"(((100.0 * ("count"(*) FILTER (WHERE "is_negative_outcome"))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "negative_rate_pct"
   FROM "public"."trust_prediction_accuracy_v"
  GROUP BY "prediction_value_band";


ALTER VIEW "public"."trust_prediction_by_value_band_v" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."trust_prediction_outcome_summary_v" AS
 SELECT "count"(*) AS "total_outcomes",
    "count"(*) FILTER (WHERE "is_positive_outcome") AS "positive_outcomes",
    "count"(*) FILTER (WHERE "is_negative_outcome") AS "negative_outcomes",
    "round"(((100.0 * ("count"(*) FILTER (WHERE "is_positive_outcome"))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "positive_rate_pct",
    "round"(((100.0 * ("count"(*) FILTER (WHERE "is_negative_outcome"))::numeric) / (NULLIF("count"(*), 0))::numeric), 2) AS "negative_rate_pct",
    "count"(*) FILTER (WHERE ("outcome_quality_label" = 'better_than_expected'::"text")) AS "better_than_expected_count",
    "count"(*) FILTER (WHERE ("outcome_quality_label" = 'as_expected_good'::"text")) AS "as_expected_good_count",
    "count"(*) FILTER (WHERE ("outcome_quality_label" = 'weaker_than_expected'::"text")) AS "weaker_than_expected_count",
    "count"(*) FILTER (WHERE ("outcome_quality_label" = ANY (ARRAY['failed'::"text", 'failed_or_uncertain'::"text"]))) AS "failed_or_uncertain_count"
   FROM "public"."trust_prediction_accuracy_v";


ALTER VIEW "public"."trust_prediction_outcome_summary_v" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."trust_prediction_learning_dashboard_v" AS
 SELECT 'overall'::"text" AS "section",
    'all_outcomes'::"text" AS "label",
    "trust_prediction_outcome_summary_v"."total_outcomes",
    "trust_prediction_outcome_summary_v"."positive_outcomes",
    "trust_prediction_outcome_summary_v"."negative_outcomes",
    "trust_prediction_outcome_summary_v"."positive_rate_pct",
    "trust_prediction_outcome_summary_v"."negative_rate_pct",
    NULL::numeric AS "avg_score_ceiling",
    NULL::numeric AS "avg_amount_dollars"
   FROM "public"."trust_prediction_outcome_summary_v"
UNION ALL
 SELECT 'prediction_value_band'::"text" AS "section",
    "trust_prediction_by_value_band_v"."prediction_value_band" AS "label",
    "trust_prediction_by_value_band_v"."total_outcomes",
    "trust_prediction_by_value_band_v"."positive_outcomes",
    "trust_prediction_by_value_band_v"."negative_outcomes",
    "trust_prediction_by_value_band_v"."positive_rate_pct",
    "trust_prediction_by_value_band_v"."negative_rate_pct",
    "trust_prediction_by_value_band_v"."avg_score_ceiling",
    "trust_prediction_by_value_band_v"."avg_amount_dollars"
   FROM "public"."trust_prediction_by_value_band_v"
UNION ALL
 SELECT 'same_pair_repetition_band'::"text" AS "section",
    "trust_prediction_by_same_pair_band_v"."same_pair_repetition_band" AS "label",
    "trust_prediction_by_same_pair_band_v"."total_outcomes",
    "trust_prediction_by_same_pair_band_v"."positive_outcomes",
    "trust_prediction_by_same_pair_band_v"."negative_outcomes",
    "trust_prediction_by_same_pair_band_v"."positive_rate_pct",
    "trust_prediction_by_same_pair_band_v"."negative_rate_pct",
    "trust_prediction_by_same_pair_band_v"."avg_score_ceiling",
    NULL::numeric AS "avg_amount_dollars"
   FROM "public"."trust_prediction_by_same_pair_band_v"
UNION ALL
 SELECT 'relationship_mode'::"text" AS "section",
    "trust_prediction_by_relationship_mode_v"."relationship_mode" AS "label",
    "trust_prediction_by_relationship_mode_v"."total_outcomes",
    "trust_prediction_by_relationship_mode_v"."positive_outcomes",
    "trust_prediction_by_relationship_mode_v"."negative_outcomes",
    "trust_prediction_by_relationship_mode_v"."positive_rate_pct",
    "trust_prediction_by_relationship_mode_v"."negative_rate_pct",
    "trust_prediction_by_relationship_mode_v"."avg_score_ceiling",
    "trust_prediction_by_relationship_mode_v"."avg_amount_dollars"
   FROM "public"."trust_prediction_by_relationship_mode_v"
UNION ALL
 SELECT 'source_type'::"text" AS "section",
    "trust_prediction_by_source_type_v"."source_type" AS "label",
    "trust_prediction_by_source_type_v"."total_outcomes",
    "trust_prediction_by_source_type_v"."positive_outcomes",
    "trust_prediction_by_source_type_v"."negative_outcomes",
    "trust_prediction_by_source_type_v"."positive_rate_pct",
    "trust_prediction_by_source_type_v"."negative_rate_pct",
    "trust_prediction_by_source_type_v"."avg_score_ceiling",
    "trust_prediction_by_source_type_v"."avg_amount_dollars"
   FROM "public"."trust_prediction_by_source_type_v";


ALTER VIEW "public"."trust_prediction_learning_dashboard_v" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trust_report_access_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_user_id" "uuid" NOT NULL,
    "viewer_user_id" "uuid" NOT NULL,
    "trust_report_share_id" "uuid",
    "access_type" "text" DEFAULT 'view'::"text" NOT NULL,
    "scope" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "trust_report_access_logs_access_type_check" CHECK (("access_type" = ANY (ARRAY['view'::"text", 'share_created'::"text", 'share_revoked'::"text", 'share_expired_denied'::"text", 'access_denied'::"text"])))
);


ALTER TABLE "public"."trust_report_access_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trust_score_snapshots" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "model_key" "text" DEFAULT 'iou_score'::"text" NOT NULL,
    "model_version" "text" DEFAULT 'v2.0-shadow'::"text" NOT NULL,
    "public_score" integer NOT NULL,
    "visible_trust" integer NOT NULL,
    "active_exposure_points" integer DEFAULT 0 NOT NULL,
    "trust_tier" "text" NOT NULL,
    "proof_depth" integer DEFAULT 0 NOT NULL,
    "proof_depth_label" "text" DEFAULT 'very_thin'::"text" NOT NULL,
    "confidence_score" integer DEFAULT 0 NOT NULL,
    "confidence_label" "text" DEFAULT 'thin'::"text" NOT NULL,
    "freshness_score" integer DEFAULT 100 NOT NULL,
    "trend_30d" "text" DEFAULT 'stable'::"text" NOT NULL,
    "score_agreement_count" integer DEFAULT 0 NOT NULL,
    "active_score_agreement_count" integer DEFAULT 0 NOT NULL,
    "score_ceiling_total" integer DEFAULT 0 NOT NULL,
    "score_contributed_total" integer DEFAULT 0 NOT NULL,
    "risk_flag_count" integer DEFAULT 0 NOT NULL,
    "active_strike_count" integer DEFAULT 0 NOT NULL,
    "snapshot_reason" "text" DEFAULT 'manual_snapshot'::"text" NOT NULL,
    "summary" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "trust_score_snapshots_confidence_score_check" CHECK ((("confidence_score" >= 0) AND ("confidence_score" <= 100))),
    CONSTRAINT "trust_score_snapshots_freshness_score_check" CHECK ((("freshness_score" >= 0) AND ("freshness_score" <= 100))),
    CONSTRAINT "trust_score_snapshots_proof_depth_check" CHECK ((("proof_depth" >= 0) AND ("proof_depth" <= 100)))
);


ALTER TABLE "public"."trust_score_snapshots" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."trust_report_shadow_v" AS
 WITH "latest_snapshot" AS (
         SELECT DISTINCT ON ("s_1"."user_id") "s_1"."id",
            "s_1"."user_id",
            "s_1"."model_key",
            "s_1"."model_version",
            "s_1"."public_score",
            "s_1"."visible_trust",
            "s_1"."active_exposure_points",
            "s_1"."trust_tier",
            "s_1"."proof_depth",
            "s_1"."proof_depth_label",
            "s_1"."confidence_score",
            "s_1"."confidence_label",
            "s_1"."freshness_score",
            "s_1"."trend_30d",
            "s_1"."score_agreement_count",
            "s_1"."active_score_agreement_count",
            "s_1"."score_ceiling_total",
            "s_1"."score_contributed_total",
            "s_1"."risk_flag_count",
            "s_1"."active_strike_count",
            "s_1"."snapshot_reason",
            "s_1"."summary",
            "s_1"."created_at"
           FROM "public"."trust_score_snapshots" "s_1"
          ORDER BY "s_1"."user_id", "s_1"."created_at" DESC
        ), "risk_summary" AS (
         SELECT "rf"."user_id",
            "count"(*) FILTER (WHERE ("rf"."is_active" = true)) AS "active_risk_flag_count",
            "count"(*) FILTER (WHERE (("rf"."is_active" = true) AND ("rf"."severity" = 'low'::"text"))) AS "low_risk_flag_count",
            "count"(*) FILTER (WHERE (("rf"."is_active" = true) AND ("rf"."severity" = 'medium'::"text"))) AS "medium_risk_flag_count",
            "count"(*) FILTER (WHERE (("rf"."is_active" = true) AND ("rf"."severity" = 'high'::"text"))) AS "high_risk_flag_count",
            "count"(*) FILTER (WHERE (("rf"."is_active" = true) AND ("rf"."severity" = 'critical'::"text"))) AS "critical_risk_flag_count",
            "jsonb_agg"("jsonb_build_object"('flag_type', "rf"."flag_type", 'severity', "rf"."severity", 'description', "rf"."description", 'metadata', "rf"."metadata", 'created_at', "rf"."created_at") ORDER BY "rf"."created_at" DESC) FILTER (WHERE ("rf"."is_active" = true)) AS "active_risk_flags"
           FROM "public"."score_risk_flags" "rf"
          GROUP BY "rf"."user_id"
        ), "agreement_summary" AS (
         SELECT "sa"."user_id",
            "count"(*) AS "total_score_agreements",
            "count"(*) FILTER (WHERE (("sa"."status" = ANY (ARRAY['active'::"text", 'completed'::"text"])) AND "public"."score_v2_relationship_affects_score"("sa"."user_id", "sa"."counterparty_id"))) AS "active_score_affecting_agreements",
            "count"(*) FILTER (WHERE (("sa"."status" = ANY (ARRAY['active'::"text", 'completed'::"text"])) AND (NOT "public"."score_v2_relationship_affects_score"("sa"."user_id", "sa"."counterparty_id")))) AS "active_no_score_agreements",
            COALESCE("sum"("sa"."score_ceiling") FILTER (WHERE (("sa"."status" = ANY (ARRAY['active'::"text", 'completed'::"text"])) AND "public"."score_v2_relationship_affects_score"("sa"."user_id", "sa"."counterparty_id"))), (0)::bigint) AS "active_score_ceiling_total",
            COALESCE("sum"("sa"."score_contributed") FILTER (WHERE (("sa"."status" = ANY (ARRAY['active'::"text", 'completed'::"text"])) AND "public"."score_v2_relationship_affects_score"("sa"."user_id", "sa"."counterparty_id"))), (0)::bigint) AS "active_score_contributed_total",
            "count"(DISTINCT "sa"."counterparty_id") FILTER (WHERE (("sa"."status" = ANY (ARRAY['active'::"text", 'completed'::"text"])) AND ("sa"."counterparty_id" IS NOT NULL) AND "public"."score_v2_relationship_affects_score"("sa"."user_id", "sa"."counterparty_id"))) AS "active_score_affecting_counterparties",
            "max"("sa"."same_pair_index") FILTER (WHERE ("sa"."status" = ANY (ARRAY['active'::"text", 'completed'::"text"]))) AS "max_same_pair_index"
           FROM "public"."score_agreements" "sa"
          GROUP BY "sa"."user_id"
        ), "outcome_summary" AS (
         SELECT "toe"."user_id",
            "count"(*) AS "total_outcomes",
            "count"(*) FILTER (WHERE ("toe"."outcome_type" = ANY (ARRAY['payment_paid_early'::"text", 'payment_paid_on_time'::"text", 'agreement_completed'::"text", 'rent_month_verified'::"text", 'phone_bill_verified'::"text", 'recovery_progress'::"text", 'lender_confirmed_fast'::"text"]))) AS "positive_outcomes",
            "count"(*) FILTER (WHERE ("toe"."outcome_type" = ANY (ARRAY['payment_paid_late'::"text", 'payment_reversed'::"text", 'payment_disputed'::"text", 'agreement_defaulted'::"text", 'rent_month_missed'::"text", 'phone_bill_missed'::"text", 'strike_applied'::"text", 'lender_false_rejection'::"text"]))) AS "negative_outcomes"
           FROM "public"."trust_outcome_events" "toe"
          GROUP BY "toe"."user_id"
        )
 SELECT "p"."id" AS "user_id",
    "p"."email",
    COALESCE("s"."public_score", COALESCE("p"."iou_score", 700)) AS "public_score",
    COALESCE("s"."visible_trust", "public"."score_v2_visible_trust"(COALESCE("p"."iou_score", 700), COALESCE("p"."active_exposure_points", 0), 100)) AS "visible_trust",
    COALESCE("s"."active_exposure_points", COALESCE("p"."active_exposure_points", 0)) AS "active_exposure_points",
    COALESCE("s"."trust_tier", "public"."score_v2_trust_tier"(COALESCE("p"."iou_score", 700), GREATEST(0, ("floor"((EXTRACT(epoch FROM ("now"() - COALESCE("p"."created_at", "now"()))) / (86400)::numeric)))::integer), 0, (COALESCE("p"."strike_count", 0) > 0), false)) AS "trust_tier",
    COALESCE("s"."proof_depth", 0) AS "proof_depth",
    COALESCE("s"."proof_depth_label", "public"."score_v2_proof_depth_label"(0)) AS "proof_depth_label",
    COALESCE("s"."confidence_score", 0) AS "confidence_score",
    COALESCE("s"."confidence_label", "public"."score_v2_confidence_label"(0)) AS "confidence_label",
    COALESCE("s"."freshness_score", 100) AS "freshness_score",
    COALESCE("s"."trend_30d", 'stable'::"text") AS "public_trend_30d",
    COALESCE("a"."total_score_agreements", (0)::bigint) AS "total_score_agreements",
    COALESCE("a"."active_score_affecting_agreements", (0)::bigint) AS "active_score_affecting_agreements",
    COALESCE("a"."active_no_score_agreements", (0)::bigint) AS "active_no_score_agreements",
    COALESCE("a"."active_score_ceiling_total", (0)::bigint) AS "active_score_ceiling_total",
    COALESCE("a"."active_score_contributed_total", (0)::bigint) AS "active_score_contributed_total",
    COALESCE("a"."active_score_affecting_counterparties", (0)::bigint) AS "active_score_affecting_counterparties",
    COALESCE("a"."max_same_pair_index", 0) AS "max_same_pair_index",
    COALESCE("r"."active_risk_flag_count", (0)::bigint) AS "active_risk_flag_count",
    COALESCE("r"."low_risk_flag_count", (0)::bigint) AS "low_risk_flag_count",
    COALESCE("r"."medium_risk_flag_count", (0)::bigint) AS "medium_risk_flag_count",
    COALESCE("r"."high_risk_flag_count", (0)::bigint) AS "high_risk_flag_count",
    COALESCE("r"."critical_risk_flag_count", (0)::bigint) AS "critical_risk_flag_count",
    COALESCE("r"."active_risk_flags", '[]'::"jsonb") AS "active_risk_flags",
    COALESCE("o"."total_outcomes", (0)::bigint) AS "total_outcomes",
    COALESCE("o"."positive_outcomes", (0)::bigint) AS "positive_outcomes",
    COALESCE("o"."negative_outcomes", (0)::bigint) AS "negative_outcomes",
        CASE
            WHEN (COALESCE("r"."active_risk_flag_count", (0)::bigint) = 0) THEN 'No active private risk flags.'::"text"
            WHEN ((COALESCE("r"."high_risk_flag_count", (0)::bigint) > 0) OR (COALESCE("r"."critical_risk_flag_count", (0)::bigint) > 0)) THEN 'Private review recommended before expanding trust.'::"text"
            WHEN (COALESCE("r"."medium_risk_flag_count", (0)::bigint) > 0) THEN 'Trust activity has concentration or pattern warnings.'::"text"
            ELSE 'Minor private trust notes available.'::"text"
        END AS "private_risk_summary",
        CASE
            WHEN (COALESCE("s"."proof_depth", 0) < 35) THEN 'Build proof depth by completing verified obligations or adding rent/phone bill verification.'::"text"
            WHEN ((COALESCE("a"."active_score_affecting_counterparties", (0)::bigint) <= 1) AND (COALESCE("a"."active_score_affecting_agreements", (0)::bigint) >= 3)) THEN 'Most trust activity is concentrated with one counterparty. More verified counterparties would improve trust depth.'::"text"
            WHEN (COALESCE("s"."freshness_score", 100) < 70) THEN 'Proof is getting stale. Refresh trust with recent verified activity.'::"text"
            ELSE 'Trust profile is developing cleanly.'::"text"
        END AS "sylienn_private_note",
    "s"."created_at" AS "latest_snapshot_at"
   FROM (((("public"."profiles" "p"
     LEFT JOIN "latest_snapshot" "s" ON (("s"."user_id" = "p"."id")))
     LEFT JOIN "risk_summary" "r" ON (("r"."user_id" = "p"."id")))
     LEFT JOIN "agreement_summary" "a" ON (("a"."user_id" = "p"."id")))
     LEFT JOIN "outcome_summary" "o" ON (("o"."user_id" = "p"."id")));


ALTER VIEW "public"."trust_report_shadow_v" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trust_report_shares" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_user_id" "uuid" NOT NULL,
    "viewer_user_id" "uuid" NOT NULL,
    "trust_score_snapshot_id" "uuid",
    "scope" "text" DEFAULT 'summary'::"text" NOT NULL,
    "reason" "text",
    "expires_at" timestamp with time zone,
    "revoked_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "trust_report_shares_no_self_share" CHECK (("owner_user_id" <> "viewer_user_id")),
    CONSTRAINT "trust_report_shares_scope_check" CHECK (("scope" = ANY (ARRAY['summary'::"text", 'full_report'::"text", 'agreement_only'::"text"])))
);


ALTER TABLE "public"."trust_report_shares" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trust_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "public_score" integer NOT NULL,
    "visible_trust" integer NOT NULL,
    "trust_tier" "text" NOT NULL,
    "confidence_label" "text" NOT NULL,
    "proof_depth_label" "text" NOT NULL,
    "payment_reliability" integer DEFAULT 0 NOT NULL,
    "housing_reliability" integer DEFAULT 0 NOT NULL,
    "recurring_obligation_reliability" integer DEFAULT 0 NOT NULL,
    "obligation_strength" integer DEFAULT 0 NOT NULL,
    "proof_depth" integer DEFAULT 0 NOT NULL,
    "counterparty_diversity" integer DEFAULT 0 NOT NULL,
    "recovery_behavior" integer DEFAULT 0 NOT NULL,
    "lender_fairness" integer DEFAULT 0 NOT NULL,
    "time_with_iou" integer DEFAULT 0 NOT NULL,
    "risk_stability" integer DEFAULT 0 NOT NULL,
    "trend_30d" "text" DEFAULT 'stable'::"text" NOT NULL,
    "time_with_iou_days" integer DEFAULT 0 NOT NULL,
    "summary" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."trust_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_relationship_modes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "related_user_id" "uuid" NOT NULL,
    "relationship_mode" "text" DEFAULT 'standard_score_affecting'::"text" NOT NULL,
    "label" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "user_relationship_modes_no_null_pair" CHECK ((("user_id" IS NOT NULL) AND ("related_user_id" IS NOT NULL))),
    CONSTRAINT "user_relationship_modes_relationship_mode_check" CHECK (("relationship_mode" = ANY (ARRAY['standard_score_affecting'::"text", 'family_no_score'::"text", 'close_circle_no_score'::"text", 'private_record_only'::"text", 'self_no_score'::"text", 'business_score_affecting'::"text", 'landlord_tenant_score_affecting'::"text"])))
);


ALTER TABLE "public"."user_relationship_modes" OWNER TO "postgres";


ALTER TABLE ONLY "public"."agreement_events"
    ADD CONSTRAINT "agreement_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."amend_requests"
    ADD CONSTRAINT "amend_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."audit_log"
    ADD CONSTRAINT "audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bank_accounts"
    ADD CONSTRAINT "bank_accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bank_accounts"
    ADD CONSTRAINT "bank_accounts_plaid_account_id_key" UNIQUE ("plaid_account_id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."identity_vault"
    ADD CONSTRAINT "identity_vault_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."identity_vault"
    ADD CONSTRAINT "identity_vault_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invites"
    ADD CONSTRAINT "invites_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."invites"
    ADD CONSTRAINT "invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."iou_acceptance_audit"
    ADD CONSTRAINT "iou_acceptance_audit_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."iou_acceptance_events"
    ADD CONSTRAINT "iou_acceptance_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."iou_invites"
    ADD CONSTRAINT "iou_invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."iou_invites"
    ADD CONSTRAINT "iou_invites_token_key" UNIQUE ("token");



ALTER TABLE "public"."ious"
    ADD CONSTRAINT "ious_apr_bps_standard_cap_check" CHECK ((("apr_bps" IS NULL) OR (("apr_bps" >= 0) AND ("apr_bps" <= 1600)))) NOT VALID;



COMMENT ON CONSTRAINT "ious_apr_bps_standard_cap_check" ON "public"."ious" IS 'Conservative platform APR cap for standard IOUs: apr_bps must be between 0 and 1600 when present. Added NOT VALID because one existing row exceeded the cap; enforced for new/updated rows going forward. This is not a jurisdiction-specific legal guarantee.';



ALTER TABLE ONLY "public"."ious"
    ADD CONSTRAINT "ious_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."legal_acceptances"
    ADD CONSTRAINT "legal_acceptances_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."legal_acceptances"
    ADD CONSTRAINT "legal_acceptances_unique_acceptance" UNIQUE ("user_id", "document_type", "document_version", "context");



ALTER TABLE ONLY "public"."loan_amendments"
    ADD CONSTRAINT "loan_amendments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."loan_invites"
    ADD CONSTRAINT "loan_invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_receipts"
    ADD CONSTRAINT "payment_receipts_payment_id_key" UNIQUE ("payment_id");



ALTER TABLE ONLY "public"."payment_receipts"
    ADD CONSTRAINT "payment_receipts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."phone_lookup"
    ADD CONSTRAINT "phone_lookup_pkey" PRIMARY KEY ("phone_hash");



ALTER TABLE ONLY "public"."phone_lookup"
    ADD CONSTRAINT "phone_lookup_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."phone_verifications"
    ADD CONSTRAINT "phone_verifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plaid_items"
    ADD CONSTRAINT "plaid_items_item_id_key" UNIQUE ("item_id");



ALTER TABLE ONLY "public"."plaid_items"
    ADD CONSTRAINT "plaid_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profile_visibility_settings"
    ADD CONSTRAINT "profile_visibility_settings_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_iou_hash_key" UNIQUE ("iou_hash");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."receipt_item_assignments"
    ADD CONSTRAINT "receipt_item_assignments_item_id_participant_id_key" UNIQUE ("item_id", "participant_id");



ALTER TABLE ONLY "public"."receipt_item_assignments"
    ADD CONSTRAINT "receipt_item_assignments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."receipt_split_items"
    ADD CONSTRAINT "receipt_split_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."receipt_split_participants"
    ADD CONSTRAINT "receipt_split_participants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."receipt_split_participants"
    ADD CONSTRAINT "receipt_split_participants_receipt_split_id_user_id_key" UNIQUE ("receipt_split_id", "user_id");



ALTER TABLE ONLY "public"."receipt_split_totals"
    ADD CONSTRAINT "receipt_split_totals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."receipt_split_totals"
    ADD CONSTRAINT "receipt_split_totals_receipt_split_id_participant_id_key" UNIQUE ("receipt_split_id", "participant_id");



ALTER TABLE ONLY "public"."receipt_splits"
    ADD CONSTRAINT "receipt_splits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."receipts"
    ADD CONSTRAINT "receipts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."score_agreements"
    ADD CONSTRAINT "score_agreements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."score_badges"
    ADD CONSTRAINT "score_badges_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."score_badges"
    ADD CONSTRAINT "score_badges_user_id_badge_key_source_id_key" UNIQUE ("user_id", "badge_key", "source_id");



ALTER TABLE ONLY "public"."score_domains"
    ADD CONSTRAINT "score_domains_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."score_domains"
    ADD CONSTRAINT "score_domains_user_id_domain_key" UNIQUE ("user_id", "domain");



ALTER TABLE ONLY "public"."score_events"
    ADD CONSTRAINT "score_events_event_key_key" UNIQUE ("event_key");



ALTER TABLE ONLY "public"."score_events"
    ADD CONSTRAINT "score_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."score_history"
    ADD CONSTRAINT "score_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."score_risk_flags"
    ADD CONSTRAINT "score_risk_flags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."signatures"
    ADD CONSTRAINT "signatures_pkey" PRIMARY KEY ("iou_id", "user_id");



ALTER TABLE ONLY "public"."trust_education_acceptances"
    ADD CONSTRAINT "trust_education_acceptances_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trust_education_acceptances"
    ADD CONSTRAINT "trust_education_acceptances_user_id_education_key_education_key" UNIQUE ("user_id", "education_key", "education_version", "context");



ALTER TABLE ONLY "public"."trust_model_versions"
    ADD CONSTRAINT "trust_model_versions_model_key_version_key" UNIQUE ("model_key", "version");



ALTER TABLE ONLY "public"."trust_model_versions"
    ADD CONSTRAINT "trust_model_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trust_outcome_events"
    ADD CONSTRAINT "trust_outcome_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trust_report_access_logs"
    ADD CONSTRAINT "trust_report_access_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trust_report_shares"
    ADD CONSTRAINT "trust_report_shares_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trust_reports"
    ADD CONSTRAINT "trust_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trust_score_snapshots"
    ADD CONSTRAINT "trust_score_snapshots_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_relationship_modes"
    ADD CONSTRAINT "user_relationship_modes_no_duplicate" UNIQUE ("user_id", "related_user_id");



ALTER TABLE ONLY "public"."user_relationship_modes"
    ADD CONSTRAINT "user_relationship_modes_pkey" PRIMARY KEY ("id");



CREATE INDEX "agreement_events_actor_created_idx" ON "public"."agreement_events" USING "btree" ("actor_id", "created_at" DESC);



CREATE INDEX "agreement_events_counterparty_created_idx" ON "public"."agreement_events" USING "btree" ("counterparty_id", "created_at" DESC);



CREATE INDEX "agreement_events_event_at_idx" ON "public"."agreement_events" USING "btree" ("event_at" DESC);



CREATE INDEX "agreement_events_score_agreement_idx" ON "public"."agreement_events" USING "btree" ("score_agreement_id");



CREATE INDEX "agreement_events_source_idx" ON "public"."agreement_events" USING "btree" ("source_type", "source_id");



CREATE INDEX "agreement_events_type_idx" ON "public"."agreement_events" USING "btree" ("event_type");



CREATE INDEX "agreement_events_user_created_idx" ON "public"."agreement_events" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "amend_requests_iou_created_idx" ON "public"."amend_requests" USING "btree" ("iou_id", "created_at" DESC);



CREATE INDEX "bank_accounts_default_payment_idx" ON "public"."bank_accounts" USING "btree" ("user_id", "is_default_payment");



CREATE INDEX "bank_accounts_default_payout_idx" ON "public"."bank_accounts" USING "btree" ("user_id", "is_default_payout");



CREATE INDEX "bank_accounts_plaid_item_id_idx" ON "public"."bank_accounts" USING "btree" ("plaid_item_id");



CREATE INDEX "bank_accounts_user_id_idx" ON "public"."bank_accounts" USING "btree" ("user_id");



CREATE INDEX "idx_identity_vault_retention" ON "public"."identity_vault" USING "btree" ("retention_until") WHERE ("retention_until" IS NOT NULL);



CREATE INDEX "idx_iou_acceptance_audit_accepted_at" ON "public"."iou_acceptance_audit" USING "btree" ("accepted_at");



CREATE INDEX "idx_iou_acceptance_audit_iou_id" ON "public"."iou_acceptance_audit" USING "btree" ("iou_id");



CREATE INDEX "idx_iou_acceptance_audit_user_id" ON "public"."iou_acceptance_audit" USING "btree" ("user_id");



CREATE INDEX "idx_ious_active" ON "public"."ious" USING "btree" ("created_at") WHERE (("archived_at" IS NULL) AND ("deleted_at" IS NULL));



CREATE INDEX "idx_ious_archived_at" ON "public"."ious" USING "btree" ("archived_at") WHERE ("archived_at" IS NOT NULL);



CREATE INDEX "idx_ious_created_by" ON "public"."ious" USING "btree" ("created_by");



CREATE INDEX "idx_ious_inbox" ON "public"."ious" USING "btree" ("requested_action_by", "status", "created_at" DESC);



CREATE INDEX "idx_ious_is_archived_true" ON "public"."ious" USING "btree" ("is_archived") WHERE ("is_archived" = true);



CREATE INDEX "idx_ious_requested_action_by" ON "public"."ious" USING "btree" ("requested_action_by");



CREATE INDEX "idx_ious_status" ON "public"."ious" USING "btree" ("status");



CREATE INDEX "idx_payment_receipts_iou_id" ON "public"."payment_receipts" USING "btree" ("iou_id");



CREATE INDEX "idx_payment_receipts_payment_id" ON "public"."payment_receipts" USING "btree" ("payment_id");



CREATE INDEX "idx_payment_receipts_receipt_hash" ON "public"."payment_receipts" USING "btree" ("receipt_hash");



CREATE INDEX "idx_payments_loan_due_unpaid" ON "public"."payments" USING "btree" ("iou_id", "due_date") WHERE ("paid_at" IS NULL);



CREATE INDEX "idx_payments_unpaid_due" ON "public"."payments" USING "btree" ("due_date") WHERE ("paid_at" IS NULL);



CREATE INDEX "idx_receipt_item_assignments_item_id" ON "public"."receipt_item_assignments" USING "btree" ("item_id");



CREATE INDEX "idx_receipt_item_assignments_receipt_split_id" ON "public"."receipt_item_assignments" USING "btree" ("receipt_split_id");



CREATE INDEX "idx_receipt_split_items_local_item_id" ON "public"."receipt_split_items" USING "btree" ("receipt_split_id", "local_item_id");



CREATE INDEX "idx_receipt_split_items_receipt_split_id" ON "public"."receipt_split_items" USING "btree" ("receipt_split_id");



CREATE UNIQUE INDEX "idx_receipt_split_one_owner_participant" ON "public"."receipt_split_participants" USING "btree" ("receipt_split_id") WHERE ("is_owner" = true);



CREATE INDEX "idx_receipt_split_participants_receipt_split_id" ON "public"."receipt_split_participants" USING "btree" ("receipt_split_id");



CREATE INDEX "idx_receipt_split_participants_user_id" ON "public"."receipt_split_participants" USING "btree" ("user_id");



CREATE INDEX "idx_receipt_split_totals_receipt_split_id" ON "public"."receipt_split_totals" USING "btree" ("receipt_split_id");



CREATE INDEX "idx_receipt_splits_owner_id" ON "public"."receipt_splits" USING "btree" ("owner_id");



CREATE INDEX "idx_receipts_iou" ON "public"."receipts" USING "btree" ("iou_id");



CREATE INDEX "idx_receipts_payment" ON "public"."receipts" USING "btree" ("payment_id");



CREATE INDEX "invites_inviter_idx" ON "public"."invites" USING "btree" ("inviter_id");



CREATE INDEX "ious_arch_created_idx" ON "public"."ious" USING "btree" ("is_archived", "created_at" DESC);



CREATE INDEX "loan_amendments_iou_idx" ON "public"."loan_amendments" USING "btree" ("iou_id");



CREATE INDEX "loan_amendments_status_idx" ON "public"."loan_amendments" USING "btree" ("status");



CREATE INDEX "loan_invites_email_idx" ON "public"."loan_invites" USING "btree" ("lower"("email"));



CREATE INDEX "loan_invites_iou_idx" ON "public"."loan_invites" USING "btree" ("iou_id");



CREATE INDEX "payments_iou_due_idx" ON "public"."payments" USING "btree" ("iou_id", "due_date");



CREATE INDEX "payments_unpaid_idx" ON "public"."payments" USING "btree" ("iou_id") WHERE ("paid_at" IS NULL);



CREATE INDEX "plaid_items_user_id_idx" ON "public"."plaid_items" USING "btree" ("user_id");



CREATE INDEX "profiles_email_ci_idx" ON "public"."profiles" USING "btree" ("lower"("email"));



CREATE INDEX "profiles_email_idx" ON "public"."profiles" USING "btree" ("email");



CREATE INDEX "profiles_full_name_trgm" ON "public"."profiles" USING "gin" ("full_name" "public"."gin_trgm_ops");



CREATE INDEX "profiles_phone_digits_idx" ON "public"."profiles" USING "btree" ("phone_digits");



CREATE UNIQUE INDEX "profiles_phone_digits_uq" ON "public"."profiles" USING "btree" ("phone_digits") WHERE (("phone_digits" IS NOT NULL) AND ("length"("phone_digits") > 0));



CREATE UNIQUE INDEX "receipts_hash_idx" ON "public"."receipts" USING "btree" ("hash_sha256");



CREATE INDEX "receipts_iou_idx" ON "public"."receipts" USING "btree" ("iou_id");



CREATE UNIQUE INDEX "score_agreements_personal_iou_source_unique" ON "public"."score_agreements" USING "btree" ("source_id") WHERE (("source_type" = 'personal_iou'::"text") AND ("source_id" IS NOT NULL));



CREATE UNIQUE INDEX "score_agreements_unique_source_user" ON "public"."score_agreements" USING "btree" ("source_type", "source_id", "user_id") WHERE ("source_id" IS NOT NULL);



CREATE INDEX "score_events_iou_id_idx" ON "public"."score_events" USING "btree" ("iou_id");



CREATE INDEX "score_events_payment_id_idx" ON "public"."score_events" USING "btree" ("payment_id");



CREATE INDEX "score_events_user_id_created_at_idx" ON "public"."score_events" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "trust_education_acceptances_key_version_idx" ON "public"."trust_education_acceptances" USING "btree" ("education_key", "education_version");



CREATE INDEX "trust_education_acceptances_user_idx" ON "public"."trust_education_acceptances" USING "btree" ("user_id", "completed_at" DESC);



CREATE INDEX "trust_model_versions_key_status_idx" ON "public"."trust_model_versions" USING "btree" ("model_key", "status");



CREATE INDEX "trust_outcome_events_agreement_idx" ON "public"."trust_outcome_events" USING "btree" ("score_agreement_id");



CREATE INDEX "trust_outcome_events_type_idx" ON "public"."trust_outcome_events" USING "btree" ("outcome_type");



CREATE INDEX "trust_outcome_events_user_created_idx" ON "public"."trust_outcome_events" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "trust_report_access_logs_owner_idx" ON "public"."trust_report_access_logs" USING "btree" ("owner_user_id", "created_at" DESC);



CREATE INDEX "trust_report_access_logs_viewer_idx" ON "public"."trust_report_access_logs" USING "btree" ("viewer_user_id", "created_at" DESC);



CREATE INDEX "trust_report_shares_active_lookup_idx" ON "public"."trust_report_shares" USING "btree" ("owner_user_id", "viewer_user_id", "revoked_at", "expires_at");



CREATE INDEX "trust_report_shares_owner_idx" ON "public"."trust_report_shares" USING "btree" ("owner_user_id");



CREATE INDEX "trust_report_shares_viewer_idx" ON "public"."trust_report_shares" USING "btree" ("viewer_user_id");



CREATE INDEX "trust_score_snapshots_model_idx" ON "public"."trust_score_snapshots" USING "btree" ("model_key", "model_version");



CREATE INDEX "trust_score_snapshots_user_created_idx" ON "public"."trust_score_snapshots" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "user_relationship_modes_mode_idx" ON "public"."user_relationship_modes" USING "btree" ("relationship_mode");



CREATE INDEX "user_relationship_modes_related_user_idx" ON "public"."user_relationship_modes" USING "btree" ("related_user_id");



CREATE INDEX "user_relationship_modes_user_idx" ON "public"."user_relationship_modes" USING "btree" ("user_id");



CREATE UNIQUE INDEX "ux_receipts_payment" ON "public"."receipts" USING "btree" ("payment_id");



CREATE OR REPLACE VIEW "public"."receipt_split_detail_view" AS
 SELECT "rs"."id" AS "receipt_split_id",
    "rs"."owner_id",
    "rs"."restaurant_name",
    "rs"."receipt_date",
    "rs"."subtotal_cents",
    "rs"."tax_cents",
    "rs"."tip_cents",
    "rs"."total_cents",
    "rs"."status",
    "rs"."image_url",
    "rs"."created_at",
    "rs"."updated_at",
    COALESCE("jsonb_agg"(DISTINCT "jsonb_build_object"('id', "rsp"."id", 'user_id', "rsp"."user_id", 'display_name', "rsp"."display_name", 'phone', "rsp"."phone", 'email', "rsp"."email", 'is_owner', "rsp"."is_owner", 'status', "rsp"."status")) FILTER (WHERE ("rsp"."id" IS NOT NULL)), '[]'::"jsonb") AS "participants",
    COALESCE("jsonb_agg"(DISTINCT "jsonb_build_object"('id', "rsi"."id", 'name', "rsi"."name", 'quantity', "rsi"."quantity", 'unit_price_cents', "rsi"."unit_price_cents", 'total_price_cents', "rsi"."total_price_cents", 'sort_order', "rsi"."sort_order")) FILTER (WHERE ("rsi"."id" IS NOT NULL)), '[]'::"jsonb") AS "items"
   FROM (("public"."receipt_splits" "rs"
     LEFT JOIN "public"."receipt_split_participants" "rsp" ON (("rsp"."receipt_split_id" = "rs"."id")))
     LEFT JOIN "public"."receipt_split_items" "rsi" ON (("rsi"."receipt_split_id" = "rs"."id")))
  GROUP BY "rs"."id";



CREATE OR REPLACE TRIGGER "guard_iou_activation_trigger" BEFORE INSERT OR UPDATE OF "activated_at", "status" ON "public"."ious" FOR EACH ROW EXECUTE FUNCTION "public"."guard_iou_activation"();



CREATE OR REPLACE TRIGGER "guard_phone_verification_integrity_tg" BEFORE UPDATE OF "phone", "phone_verified", "phone_verified_at" ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."guard_phone_verification_integrity"();



CREATE OR REPLACE TRIGGER "ious_score_agreement_sync_insert_trg" AFTER INSERT ON "public"."ious" FOR EACH ROW EXECUTE FUNCTION "public"."trg_sync_score_agreement_for_iou"();



CREATE OR REPLACE TRIGGER "ious_score_agreement_sync_update_trg" AFTER UPDATE OF "status", "deleted_at", "activated_at", "borrower_id", "lender_id", "principal_cents", "term_months", "frequency", "apr_bps", "title" ON "public"."ious" FOR EACH ROW WHEN ((("new"."status" IS DISTINCT FROM "old"."status") OR ("new"."deleted_at" IS DISTINCT FROM "old"."deleted_at") OR ("new"."activated_at" IS DISTINCT FROM "old"."activated_at") OR ("new"."borrower_id" IS DISTINCT FROM "old"."borrower_id") OR ("new"."lender_id" IS DISTINCT FROM "old"."lender_id") OR ("new"."principal_cents" IS DISTINCT FROM "old"."principal_cents") OR ("new"."term_months" IS DISTINCT FROM "old"."term_months") OR ("new"."frequency" IS DISTINCT FROM "old"."frequency") OR ("new"."apr_bps" IS DISTINCT FROM "old"."apr_bps") OR ("new"."title" IS DISTINCT FROM "old"."title"))) EXECUTE FUNCTION "public"."trg_sync_score_agreement_for_iou"();



CREATE OR REPLACE TRIGGER "legal_acceptances_block_mutation_trg" BEFORE DELETE OR UPDATE ON "public"."legal_acceptances" FOR EACH ROW EXECUTE FUNCTION "public"."legal_acceptances_block_mutation"();



CREATE OR REPLACE TRIGGER "loan_exposure_create_trigger" AFTER UPDATE OF "activated_at" ON "public"."ious" FOR EACH ROW WHEN ((("old"."activated_at" IS NULL) AND ("new"."activated_at" IS NOT NULL))) EXECUTE FUNCTION "public"."handle_new_loan_exposure"();



CREATE OR REPLACE TRIGGER "loan_exposure_release_trigger" AFTER UPDATE OF "paid_at" ON "public"."payments" FOR EACH ROW WHEN (("new"."paid_at" IS NOT NULL)) EXECUTE FUNCTION "public"."handle_exposure_release"();

ALTER TABLE "public"."payments" DISABLE TRIGGER "loan_exposure_release_trigger";



CREATE OR REPLACE TRIGGER "payments_refresh_iou_status" AFTER INSERT OR DELETE OR UPDATE ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."refresh_iou_status_from_payments"();

ALTER TABLE "public"."payments" DISABLE TRIGGER "payments_refresh_iou_status";



CREATE OR REPLACE TRIGGER "payments_status_auto_updater" BEFORE INSERT OR UPDATE ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."payments_status_auto"();



CREATE OR REPLACE TRIGGER "payments_status_tg" BEFORE INSERT OR UPDATE OF "due_date", "paid_at" ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."payments_status_autoupdate"();



CREATE OR REPLACE TRIGGER "profiles_phone_digits_tg" BEFORE INSERT OR UPDATE OF "phone" ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."profiles_phone_digits_sync"();



CREATE OR REPLACE TRIGGER "set_receipt_split_totals_updated_at" BEFORE UPDATE ON "public"."receipt_split_totals" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_receipt_splits_updated_at" BEFORE UPDATE ON "public"."receipt_splits" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_apply_payment_score_event" AFTER INSERT OR UPDATE OF "paid_at" ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."apply_payment_score_event"();



CREATE OR REPLACE TRIGGER "trg_create_receipt_on_paid" AFTER UPDATE OF "paid_at" ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."tg_create_receipt_on_paid"();



CREATE OR REPLACE TRIGGER "trg_payments_due_sync" BEFORE INSERT OR UPDATE ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."payments_due_sync"();



CREATE OR REPLACE TRIGGER "trg_recompute_iou_status" AFTER INSERT OR DELETE OR UPDATE ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."tg_recompute_iou_status"();



CREATE OR REPLACE TRIGGER "trigger_update_iou_progress" AFTER UPDATE OF "paid_at" ON "public"."payments" FOR EACH ROW WHEN (("new"."paid_at" IS NOT NULL)) EXECUTE FUNCTION "public"."update_iou_progress"();



CREATE OR REPLACE TRIGGER "validate_receipt_item_assignment_trigger" BEFORE INSERT OR UPDATE ON "public"."receipt_item_assignments" FOR EACH ROW EXECUTE FUNCTION "public"."validate_receipt_item_assignment"();



ALTER TABLE ONLY "public"."agreement_events"
    ADD CONSTRAINT "agreement_events_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."agreement_events"
    ADD CONSTRAINT "agreement_events_counterparty_id_fkey" FOREIGN KEY ("counterparty_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."agreement_events"
    ADD CONSTRAINT "agreement_events_score_agreement_id_fkey" FOREIGN KEY ("score_agreement_id") REFERENCES "public"."score_agreements"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."agreement_events"
    ADD CONSTRAINT "agreement_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."amend_requests"
    ADD CONSTRAINT "amend_requests_iou_id_fkey" FOREIGN KEY ("iou_id") REFERENCES "public"."ious"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_iou_id_fkey" FOREIGN KEY ("iou_id") REFERENCES "public"."ious"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."identity_vault"
    ADD CONSTRAINT "identity_vault_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_iou_id_fkey" FOREIGN KEY ("iou_id") REFERENCES "public"."ious"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invites"
    ADD CONSTRAINT "invites_accepted_by_fkey" FOREIGN KEY ("accepted_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."invites"
    ADD CONSTRAINT "invites_inviter_id_fkey" FOREIGN KEY ("inviter_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."iou_acceptance_audit"
    ADD CONSTRAINT "iou_acceptance_audit_iou_id_fkey" FOREIGN KEY ("iou_id") REFERENCES "public"."ious"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."iou_acceptance_audit"
    ADD CONSTRAINT "iou_acceptance_audit_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."iou_acceptance_events"
    ADD CONSTRAINT "iou_acceptance_events_iou_id_fkey" FOREIGN KEY ("iou_id") REFERENCES "public"."ious"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."iou_acceptance_events"
    ADD CONSTRAINT "iou_acceptance_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."iou_invites"
    ADD CONSTRAINT "iou_invites_iou_id_fkey" FOREIGN KEY ("iou_id") REFERENCES "public"."ious"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ious"
    ADD CONSTRAINT "ious_borrower_id_fkey" FOREIGN KEY ("borrower_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."ious"
    ADD CONSTRAINT "ious_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."ious"
    ADD CONSTRAINT "ious_denied_by_fkey" FOREIGN KEY ("denied_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."ious"
    ADD CONSTRAINT "ious_lender_id_fkey" FOREIGN KEY ("lender_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."ious"
    ADD CONSTRAINT "ious_requested_action_by_fkey" FOREIGN KEY ("requested_action_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."legal_acceptances"
    ADD CONSTRAINT "legal_acceptances_related_iou_id_fkey" FOREIGN KEY ("related_iou_id") REFERENCES "public"."ious"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."legal_acceptances"
    ADD CONSTRAINT "legal_acceptances_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."loan_amendments"
    ADD CONSTRAINT "loan_amendments_decided_by_fkey" FOREIGN KEY ("decided_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."loan_amendments"
    ADD CONSTRAINT "loan_amendments_iou_id_fkey" FOREIGN KEY ("iou_id") REFERENCES "public"."ious"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loan_amendments"
    ADD CONSTRAINT "loan_amendments_proposer_id_fkey" FOREIGN KEY ("proposer_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."loan_invites"
    ADD CONSTRAINT "loan_invites_iou_id_fkey" FOREIGN KEY ("iou_id") REFERENCES "public"."ious"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_receipts"
    ADD CONSTRAINT "payment_receipts_iou_id_fkey" FOREIGN KEY ("iou_id") REFERENCES "public"."ious"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_receipts"
    ADD CONSTRAINT "payment_receipts_payee_user_id_fkey" FOREIGN KEY ("payee_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."payment_receipts"
    ADD CONSTRAINT "payment_receipts_payer_user_id_fkey" FOREIGN KEY ("payer_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."payment_receipts"
    ADD CONSTRAINT "payment_receipts_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_receipts"
    ADD CONSTRAINT "payment_receipts_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_extension_decided_by_fkey" FOREIGN KEY ("extension_decided_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_extension_requested_by_fkey" FOREIGN KEY ("extension_requested_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_iou_id_fkey" FOREIGN KEY ("iou_id") REFERENCES "public"."ious"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_loan_id_fkey" FOREIGN KEY ("loan_id") REFERENCES "public"."ious"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."phone_lookup"
    ADD CONSTRAINT "phone_lookup_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."phone_verifications"
    ADD CONSTRAINT "phone_verifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plaid_items"
    ADD CONSTRAINT "plaid_items_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profile_visibility_settings"
    ADD CONSTRAINT "profile_visibility_settings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."receipt_item_assignments"
    ADD CONSTRAINT "receipt_item_assignments_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."receipt_split_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."receipt_item_assignments"
    ADD CONSTRAINT "receipt_item_assignments_participant_id_fkey" FOREIGN KEY ("participant_id") REFERENCES "public"."receipt_split_participants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."receipt_item_assignments"
    ADD CONSTRAINT "receipt_item_assignments_receipt_split_id_fkey" FOREIGN KEY ("receipt_split_id") REFERENCES "public"."receipt_splits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."receipt_split_items"
    ADD CONSTRAINT "receipt_split_items_receipt_split_id_fkey" FOREIGN KEY ("receipt_split_id") REFERENCES "public"."receipt_splits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."receipt_split_participants"
    ADD CONSTRAINT "receipt_split_participants_receipt_split_id_fkey" FOREIGN KEY ("receipt_split_id") REFERENCES "public"."receipt_splits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."receipt_split_participants"
    ADD CONSTRAINT "receipt_split_participants_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."receipt_split_totals"
    ADD CONSTRAINT "receipt_split_totals_participant_id_fkey" FOREIGN KEY ("participant_id") REFERENCES "public"."receipt_split_participants"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."receipt_split_totals"
    ADD CONSTRAINT "receipt_split_totals_receipt_split_id_fkey" FOREIGN KEY ("receipt_split_id") REFERENCES "public"."receipt_splits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."receipt_splits"
    ADD CONSTRAINT "receipt_splits_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."receipts"
    ADD CONSTRAINT "receipts_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."receipts"
    ADD CONSTRAINT "receipts_iou_id_fkey" FOREIGN KEY ("iou_id") REFERENCES "public"."ious"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."receipts"
    ADD CONSTRAINT "receipts_payment_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."receipts"
    ADD CONSTRAINT "receipts_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."score_agreements"
    ADD CONSTRAINT "score_agreements_counterparty_id_fkey" FOREIGN KEY ("counterparty_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."score_agreements"
    ADD CONSTRAINT "score_agreements_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."score_badges"
    ADD CONSTRAINT "score_badges_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."score_domains"
    ADD CONSTRAINT "score_domains_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."score_events"
    ADD CONSTRAINT "score_events_iou_id_fkey" FOREIGN KEY ("iou_id") REFERENCES "public"."ious"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."score_events"
    ADD CONSTRAINT "score_events_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."score_events"
    ADD CONSTRAINT "score_events_reversal_of_fkey" FOREIGN KEY ("reversal_of") REFERENCES "public"."score_events"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."score_events"
    ADD CONSTRAINT "score_events_score_agreement_id_fkey" FOREIGN KEY ("score_agreement_id") REFERENCES "public"."score_agreements"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."score_events"
    ADD CONSTRAINT "score_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."score_risk_flags"
    ADD CONSTRAINT "score_risk_flags_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."signatures"
    ADD CONSTRAINT "signatures_iou_id_fkey" FOREIGN KEY ("iou_id") REFERENCES "public"."ious"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."signatures"
    ADD CONSTRAINT "signatures_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trust_education_acceptances"
    ADD CONSTRAINT "trust_education_acceptances_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trust_outcome_events"
    ADD CONSTRAINT "trust_outcome_events_related_snapshot_id_fkey" FOREIGN KEY ("related_snapshot_id") REFERENCES "public"."trust_score_snapshots"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trust_outcome_events"
    ADD CONSTRAINT "trust_outcome_events_score_agreement_id_fkey" FOREIGN KEY ("score_agreement_id") REFERENCES "public"."score_agreements"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trust_outcome_events"
    ADD CONSTRAINT "trust_outcome_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trust_report_access_logs"
    ADD CONSTRAINT "trust_report_access_logs_owner_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trust_report_access_logs"
    ADD CONSTRAINT "trust_report_access_logs_trust_report_share_id_fkey" FOREIGN KEY ("trust_report_share_id") REFERENCES "public"."trust_report_shares"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trust_report_access_logs"
    ADD CONSTRAINT "trust_report_access_logs_viewer_user_id_fkey" FOREIGN KEY ("viewer_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trust_report_shares"
    ADD CONSTRAINT "trust_report_shares_owner_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trust_report_shares"
    ADD CONSTRAINT "trust_report_shares_trust_score_snapshot_id_fkey" FOREIGN KEY ("trust_score_snapshot_id") REFERENCES "public"."trust_score_snapshots"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trust_report_shares"
    ADD CONSTRAINT "trust_report_shares_viewer_user_id_fkey" FOREIGN KEY ("viewer_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trust_reports"
    ADD CONSTRAINT "trust_reports_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trust_score_snapshots"
    ADD CONSTRAINT "trust_score_snapshots_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_relationship_modes"
    ADD CONSTRAINT "user_relationship_modes_related_user_id_fkey" FOREIGN KEY ("related_user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_relationship_modes"
    ADD CONSTRAINT "user_relationship_modes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;



CREATE POLICY "Allow service role full access" ON "public"."bank_accounts" USING (true) WITH CHECK (true);



CREATE POLICY "Owner can manage receipt totals" ON "public"."receipt_split_totals" USING ((EXISTS ( SELECT 1
   FROM "public"."receipt_splits" "rs"
  WHERE (("rs"."id" = "receipt_split_totals"."receipt_split_id") AND ("rs"."owner_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."receipt_splits" "rs"
  WHERE (("rs"."id" = "receipt_split_totals"."receipt_split_id") AND ("rs"."owner_id" = "auth"."uid"())))));



CREATE POLICY "Receipt totals visible to split members" ON "public"."receipt_split_totals" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."receipt_splits" "rs"
  WHERE (("rs"."id" = "receipt_split_totals"."receipt_split_id") AND (("rs"."owner_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
           FROM "public"."receipt_split_participants" "p"
          WHERE (("p"."receipt_split_id" = "rs"."id") AND ("p"."user_id" = "auth"."uid"())))))))));



CREATE POLICY "Users can insert payment receipts for own ious" ON "public"."payment_receipts" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payment_receipts"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"()))))));



CREATE POLICY "Users can update payment receipts for own ious" ON "public"."payment_receipts" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payment_receipts"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"())))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payment_receipts"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"()))))));



CREATE POLICY "Users can view payment receipts for own ious" ON "public"."payment_receipts" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payment_receipts"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"()))))));



CREATE POLICY "Users can view their own bank accounts" ON "public"."bank_accounts" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "amend-insert" ON "public"."amend_requests" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "amend_requests"."iou_id") AND (("auth"."uid"() = "i"."lender_id") OR ("auth"."uid"() = "i"."borrower_id"))))));



CREATE POLICY "amend-select" ON "public"."amend_requests" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "amend_requests"."iou_id") AND (("auth"."uid"() = "i"."lender_id") OR ("auth"."uid"() = "i"."borrower_id"))))));



CREATE POLICY "amend-update" ON "public"."amend_requests" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "amend_requests"."iou_id") AND ("auth"."uid"() = "i"."lender_id"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "amend_requests"."iou_id") AND ("auth"."uid"() = "i"."lender_id")))));



ALTER TABLE "public"."amend_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "amendments-insert" ON "public"."loan_amendments" FOR INSERT WITH CHECK ((("proposer_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "loan_amendments"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"())))))));



CREATE POLICY "amendments-select" ON "public"."loan_amendments" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "loan_amendments"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"()))))));



CREATE POLICY "amendments-update" ON "public"."loan_amendments" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "loan_amendments"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"()))))));



ALTER TABLE "public"."audit_log" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "audit_log_insert_service_only" ON "public"."audit_log" FOR INSERT WITH CHECK (("auth"."role"() = 'service_role'::"text"));



CREATE POLICY "audit_log_no_delete" ON "public"."audit_log" FOR DELETE USING (false);



CREATE POLICY "audit_log_no_update" ON "public"."audit_log" FOR UPDATE USING (false);



CREATE POLICY "audit_log_select_service_only" ON "public"."audit_log" FOR SELECT USING (("auth"."role"() = 'service_role'::"text"));



ALTER TABLE "public"."bank_accounts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "delete_ious_lender_only" ON "public"."ious" FOR DELETE USING ((("auth"."uid"() = "lender_id") AND ("status" = ANY (ARRAY['draft'::"text", 'archived'::"text"]))));



ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."identity_vault" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "identity_vault_service_only" ON "public"."identity_vault" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));



CREATE POLICY "insert as lender" ON "public"."ious" FOR INSERT WITH CHECK (("auth"."uid"() = "lender_id"));



CREATE POLICY "insert payments for own iou" ON "public"."payments" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."ious"
  WHERE (("ious"."id" = "payments"."iou_id") AND ("auth"."uid"() = "ious"."lender_id")))));



CREATE POLICY "inv_by_party" ON "public"."invitations" USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "invitations"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"()))))));



ALTER TABLE "public"."invitations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inviter-insert" ON "public"."invites" FOR INSERT WITH CHECK (("inviter_id" = "auth"."uid"()));



CREATE POLICY "inviter-select" ON "public"."invites" FOR SELECT USING ((("inviter_id" = "auth"."uid"()) OR ("accepted_by" = "auth"."uid"())));



ALTER TABLE "public"."invites" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "invites-insert" ON "public"."loan_invites" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "loan_invites"."iou_id") AND ("i"."lender_id" = "auth"."uid"())))));



CREATE POLICY "invites-select" ON "public"."loan_invites" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "loan_invites"."iou_id") AND ("i"."lender_id" = "auth"."uid"())))));



CREATE POLICY "invites_owner_read" ON "public"."iou_invites" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ious"
  WHERE (("iou_invites"."iou_id" = "ious"."id") AND ("auth"."uid"() = "ious"."lender_id")))));



CREATE POLICY "invites_owner_update" ON "public"."iou_invites" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."ious"
  WHERE (("iou_invites"."iou_id" = "ious"."id") AND ("auth"."uid"() = "ious"."lender_id")))));



CREATE POLICY "invites_owner_write" ON "public"."iou_invites" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."ious"
  WHERE (("iou_invites"."iou_id" = "ious"."id") AND ("auth"."uid"() = "ious"."lender_id")))));



ALTER TABLE "public"."iou_acceptance_audit" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."iou_acceptance_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "iou_borrower_sign" ON "public"."ious" FOR UPDATE USING (("auth"."uid"() = "borrower_id")) WITH CHECK (("auth"."uid"() = "borrower_id"));



ALTER TABLE "public"."iou_invites" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "iou_lender_sign" ON "public"."ious" FOR UPDATE USING (("auth"."uid"() = "lender_id")) WITH CHECK ((("auth"."uid"() = "lender_id") AND true));



ALTER TABLE "public"."ious" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ious-insert" ON "public"."ious" FOR INSERT WITH CHECK (("auth"."uid"() = "lender_id"));



CREATE POLICY "ious-select" ON "public"."ious" FOR SELECT USING ((("auth"."uid"() = "lender_id") OR ("auth"."uid"() = "borrower_id")));



CREATE POLICY "ious-update" ON "public"."ious" FOR UPDATE USING ((("auth"."uid"() = "lender_id") OR ("auth"."uid"() = "borrower_id"))) WITH CHECK ((("auth"."uid"() = "lender_id") OR ("auth"."uid"() = "borrower_id")));



CREATE POLICY "ious_borrower_sign" ON "public"."ious" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "borrower_id")) WITH CHECK (("auth"."uid"() = "borrower_id"));



CREATE POLICY "ious_lender_delete" ON "public"."ious" FOR DELETE USING (("auth"."uid"() = "lender_id"));



CREATE POLICY "ious_lender_sign" ON "public"."ious" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "lender_id")) WITH CHECK (("auth"."uid"() = "lender_id"));



CREATE POLICY "ious_owner_delete" ON "public"."ious" FOR DELETE USING ("public"."is_admin"());



CREATE POLICY "ious_owner_update" ON "public"."ious" FOR UPDATE USING ((("lender_id" = "auth"."uid"()) OR ("borrower_id" = "auth"."uid"()))) WITH CHECK (true);



CREATE POLICY "ious_party_delete" ON "public"."ious" FOR DELETE USING ((("auth"."uid"() = "lender_id") OR ("auth"."uid"() = "borrower_id")));



CREATE POLICY "ious_party_read" ON "public"."ious" FOR SELECT USING ((((("lender_id" = "auth"."uid"()) OR ("borrower_id" = "auth"."uid"())) AND (NOT "is_archived")) OR "public"."is_admin"()));



CREATE POLICY "ious_party_write" ON "public"."ious" FOR INSERT WITH CHECK ((("lender_id" = "auth"."uid"()) OR ("borrower_id" = "auth"."uid"())));



CREATE POLICY "ious_read" ON "public"."ious" FOR SELECT USING ((("auth"."uid"() = "lender_id") OR ("auth"."uid"() = "borrower_id")));



CREATE POLICY "ious_update" ON "public"."ious" FOR UPDATE USING ((("auth"."uid"() = "lender_id") OR ("auth"."uid"() = "borrower_id")));



CREATE POLICY "ious_update_archive" ON "public"."ious" FOR UPDATE USING (("auth"."uid"() = "lender_id")) WITH CHECK (("auth"."uid"() = "lender_id"));



CREATE POLICY "ious_write" ON "public"."ious" FOR INSERT WITH CHECK (("auth"."uid"() = "lender_id"));



ALTER TABLE "public"."legal_acceptances" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "legal_acceptances_own_select" ON "public"."legal_acceptances" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "lender_can_delete_scheduled_payments" ON "public"."payments" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."ious"
  WHERE (("ious"."id" = "payments"."iou_id") AND ("ious"."lender_id" = "auth"."uid"())))));



ALTER TABLE "public"."loan_amendments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."loan_invites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payment_receipts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "payments-select" ON "public"."payments" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payments"."iou_id") AND (("auth"."uid"() = "i"."lender_id") OR ("auth"."uid"() = "i"."borrower_id"))))));



CREATE POLICY "payments-update" ON "public"."payments" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payments"."iou_id") AND (("auth"."uid"() = "i"."lender_id") OR ("auth"."uid"() = "i"."borrower_id")))))) WITH CHECK (true);



CREATE POLICY "payments_insert" ON "public"."payments" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payments"."iou_id") AND ("auth"."uid"() = "i"."lender_id")))));



CREATE POLICY "payments_lender_delete" ON "public"."payments" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payments"."iou_id") AND ("i"."lender_id" = "auth"."uid"())))));



CREATE POLICY "payments_party_delete" ON "public"."payments" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payments"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"()))))));



CREATE POLICY "payments_party_read" ON "public"."payments" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payments"."iou_id") AND (((("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"())) AND (NOT "i"."is_archived")) OR "public"."is_admin"())))));



CREATE POLICY "payments_party_update" ON "public"."payments" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payments"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"()))))));



CREATE POLICY "payments_party_write" ON "public"."payments" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payments"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"()))))));



CREATE POLICY "payments_read" ON "public"."payments" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payments"."iou_id") AND (("auth"."uid"() = "i"."lender_id") OR ("auth"."uid"() = "i"."borrower_id"))))));



CREATE POLICY "payments_update" ON "public"."payments" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payments"."iou_id") AND (("auth"."uid"() = "i"."lender_id") OR ("auth"."uid"() = "i"."borrower_id")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "payments"."iou_id") AND (("auth"."uid"() = "i"."lender_id") OR ("auth"."uid"() = "i"."borrower_id"))))));



ALTER TABLE "public"."phone_lookup" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "phone_lookup_select_authenticated" ON "public"."phone_lookup" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "phone_lookup_write_service_only" ON "public"."phone_lookup" USING (("auth"."role"() = 'service_role'::"text")) WITH CHECK (("auth"."role"() = 'service_role'::"text"));



ALTER TABLE "public"."phone_verifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plaid_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_owner_select" ON "public"."profiles" FOR SELECT TO "authenticated" USING (("id" = "auth"."uid"()));



CREATE POLICY "profiles_owner_update" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("id" = "auth"."uid"())) WITH CHECK (("id" = "auth"."uid"()));



CREATE POLICY "read own ious" ON "public"."ious" FOR SELECT USING ((("auth"."uid"() = "lender_id") OR ("auth"."uid"() = "borrower_id")));



CREATE POLICY "read payments for own ious" ON "public"."payments" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ious"
  WHERE (("ious"."id" = "payments"."iou_id") AND (("auth"."uid"() = "ious"."lender_id") OR ("auth"."uid"() = "ious"."borrower_id"))))));



ALTER TABLE "public"."receipt_item_assignments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "receipt_item_assignments_owner_all" ON "public"."receipt_item_assignments" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."receipt_splits" "rs"
  WHERE (("rs"."id" = "receipt_item_assignments"."receipt_split_id") AND ("rs"."owner_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."receipt_splits" "rs"
  WHERE (("rs"."id" = "receipt_item_assignments"."receipt_split_id") AND ("rs"."owner_id" = "auth"."uid"())))));



ALTER TABLE "public"."receipt_split_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "receipt_split_items_owner_all" ON "public"."receipt_split_items" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."receipt_splits" "rs"
  WHERE (("rs"."id" = "receipt_split_items"."receipt_split_id") AND ("rs"."owner_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."receipt_splits" "rs"
  WHERE (("rs"."id" = "receipt_split_items"."receipt_split_id") AND ("rs"."owner_id" = "auth"."uid"())))));



ALTER TABLE "public"."receipt_split_participants" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "receipt_split_participants_owner_all" ON "public"."receipt_split_participants" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."receipt_splits" "rs"
  WHERE (("rs"."id" = "receipt_split_participants"."receipt_split_id") AND ("rs"."owner_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."receipt_splits" "rs"
  WHERE (("rs"."id" = "receipt_split_participants"."receipt_split_id") AND ("rs"."owner_id" = "auth"."uid"())))));



ALTER TABLE "public"."receipt_split_totals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."receipt_splits" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "receipt_splits_owner_all" ON "public"."receipt_splits" TO "authenticated" USING (("owner_id" = "auth"."uid"())) WITH CHECK (("owner_id" = "auth"."uid"()));



ALTER TABLE "public"."receipts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "receipts-insert" ON "public"."receipts" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "receipts"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"()))))));



CREATE POLICY "receipts-read" ON "public"."receipts" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "receipts"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"()))))));



CREATE POLICY "receipts_read" ON "public"."receipts" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "receipts"."iou_id") AND (("auth"."uid"() = "i"."lender_id") OR ("auth"."uid"() = "i"."borrower_id"))))));



CREATE POLICY "receipts_select" ON "public"."receipts" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "receipts"."iou_id") AND (("i"."lender_id" = "auth"."uid"()) OR ("i"."borrower_id" = "auth"."uid"()))))));



ALTER TABLE "public"."score_agreements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."score_badges" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."score_domains" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."score_risk_flags" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "select_ious_for_parties" ON "public"."ious" FOR SELECT USING ((("auth"."uid"() = "lender_id") OR ("auth"."uid"() = "borrower_id")));



ALTER TABLE "public"."signatures" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "signatures_rw" ON "public"."signatures" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."trust_education_acceptances" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trust_education_acceptances_own_select" ON "public"."trust_education_acceptances" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."trust_reports" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "update_ious_by_parties" ON "public"."ious" FOR UPDATE USING ((("auth"."uid"() = "lender_id") OR ("auth"."uid"() = "borrower_id"))) WITH CHECK ((("auth"."uid"() = "lender_id") OR ("auth"."uid"() = "borrower_id")));



CREATE POLICY "users can view own plaid items" ON "public"."plaid_items" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "users_can_insert_own_iou_acceptance_audit" ON "public"."iou_acceptance_audit" FOR INSERT WITH CHECK ((("user_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "iou_acceptance_audit"."iou_id") AND ("i"."borrower_id" = "auth"."uid"()) AND ("i"."activated_at" IS NULL))))));



CREATE POLICY "users_can_read_own_iou_acceptance_audit" ON "public"."iou_acceptance_audit" FOR SELECT USING ((("user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."ious" "i"
  WHERE (("i"."id" = "iou_acceptance_audit"."iou_id") AND (("auth"."uid"() = "i"."lender_id") OR ("auth"."uid"() = "i"."borrower_id")))))));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON TABLE "public"."ious" TO "anon";
GRANT ALL ON TABLE "public"."ious" TO "authenticated";
GRANT ALL ON TABLE "public"."ious" TO "service_role";



GRANT ALL ON FUNCTION "public"."accept_iou_request"("p_iou_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."accept_iou_request"("p_iou_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."accept_iou_request"("p_iou_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."activate_iou"("p_iou_id" "uuid", "p_contract_text" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."activate_iou"("p_iou_id" "uuid", "p_contract_text" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."activate_iou"("p_iou_id" "uuid", "p_contract_text" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_default_strike"("p_user_id" "uuid", "p_iou_id" "uuid", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."apply_default_strike"("p_user_id" "uuid", "p_iou_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_default_strike"("p_user_id" "uuid", "p_iou_id" "uuid", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_payment_score_event"() TO "anon";
GRANT ALL ON FUNCTION "public"."apply_payment_score_event"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_payment_score_event"() TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_score_event_once"("p_user_id" "uuid", "p_event_type" "text", "p_delta" integer, "p_description" "text", "p_iou_id" "uuid", "p_payment_id" "uuid", "p_event_key" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."apply_score_event_once"("p_user_id" "uuid", "p_event_type" "text", "p_delta" integer, "p_description" "text", "p_iou_id" "uuid", "p_payment_id" "uuid", "p_event_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_score_event_once"("p_user_id" "uuid", "p_event_type" "text", "p_delta" integer, "p_description" "text", "p_iou_id" "uuid", "p_payment_id" "uuid", "p_event_key" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."archive_iou"("p_iou" "uuid", "p_archived" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."archive_iou"("p_iou" "uuid", "p_archived" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."archive_iou"("p_iou" "uuid", "p_archived" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."archive_iou"("p_iou" "uuid", "p_archived" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."build_receipt_canonical"("p_iou_id" "uuid", "p_payment_id" "uuid", "p_actor" "uuid", "p_amount_cents" integer, "p_scheduled_at" timestamp with time zone, "p_paid_at" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."build_receipt_canonical"("p_iou_id" "uuid", "p_payment_id" "uuid", "p_actor" "uuid", "p_amount_cents" integer, "p_scheduled_at" timestamp with time zone, "p_paid_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."build_receipt_canonical"("p_iou_id" "uuid", "p_payment_id" "uuid", "p_actor" "uuid", "p_amount_cents" integer, "p_scheduled_at" timestamp with time zone, "p_paid_at" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_iou_exposure"("p_principal_cents" numeric, "p_apr_bps" numeric, "p_borrower_score" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_iou_exposure"("p_principal_cents" numeric, "p_apr_bps" numeric, "p_borrower_score" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_iou_exposure"("p_principal_cents" numeric, "p_apr_bps" numeric, "p_borrower_score" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_receipt_split_totals"("p_receipt_split_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_receipt_split_totals"("p_receipt_split_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_receipt_split_totals"("p_receipt_split_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT ALL ON FUNCTION "public"."claim_payment"("p_payment_id" "uuid", "p_actor" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."claim_payment"("p_payment_id" "uuid", "p_actor" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."claim_payment"("p_payment_id" "uuid", "p_actor" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_trust_report_share"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text", "p_expires_at" timestamp with time zone, "p_reason" "text", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."create_trust_report_share"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text", "p_expires_at" timestamp with time zone, "p_reason" "text", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_trust_report_share"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text", "p_expires_at" timestamp with time zone, "p_reason" "text", "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_trust_score_snapshot"("p_user_id" "uuid", "p_snapshot_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_trust_score_snapshot"("p_user_id" "uuid", "p_snapshot_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_trust_score_snapshot"("p_user_id" "uuid", "p_snapshot_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_iou_soft"("p_iou" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_iou_soft"("p_iou" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_iou_soft"("p_iou" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_iou_soft"("p_iou" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_loan"("p_loan" "uuid", "p_user" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_loan"("p_loan" "uuid", "p_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_loan"("p_loan" "uuid", "p_user" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."deny_iou_request"("p_iou_id" "uuid", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."deny_iou_request"("p_iou_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."deny_iou_request"("p_iou_id" "uuid", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."finalize_iou_schedule"("p_iou_id" "uuid", "p_payments" "jsonb", "p_title" "text", "p_lender_id" "uuid", "p_borrower_id" "uuid", "p_principal_cents" bigint, "p_apr_bps" integer, "p_start_date" "date", "p_term_months" integer, "p_frequency" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."finalize_iou_schedule"("p_iou_id" "uuid", "p_payments" "jsonb", "p_title" "text", "p_lender_id" "uuid", "p_borrower_id" "uuid", "p_principal_cents" bigint, "p_apr_bps" integer, "p_start_date" "date", "p_term_months" integer, "p_frequency" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."finalize_iou_schedule"("p_iou_id" "uuid", "p_payments" "jsonb", "p_title" "text", "p_lender_id" "uuid", "p_borrower_id" "uuid", "p_principal_cents" bigint, "p_apr_bps" integer, "p_start_date" "date", "p_term_months" integer, "p_frequency" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_iou_hash"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_iou_hash"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_iou_hash"() TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_ious_from_receipt_split"("p_receipt_split_id" "uuid", "p_due_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_ious_from_receipt_split"("p_receipt_split_id" "uuid", "p_due_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_ious_from_receipt_split"("p_receipt_split_id" "uuid", "p_due_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_score_v2_shadow_risk_flags"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_score_v2_shadow_risk_flags"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_score_v2_shadow_risk_flags"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_iou_ach_readiness"("p_iou_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_iou_ach_readiness"("p_iou_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_iou_ach_readiness"("p_iou_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_my_iou_contacts"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_iou_contacts"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_iou_contacts"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_trust_report_access_logs"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_my_trust_report_access_logs"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_trust_report_access_logs"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_relationship_mode"("p_user_id" "uuid", "p_related_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_relationship_mode"("p_user_id" "uuid", "p_related_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_relationship_mode"("p_user_id" "uuid", "p_related_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_trust_report_for_viewer"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_trust_report_for_viewer"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_trust_report_for_viewer"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_trust_reports_shared_with_me"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_trust_reports_shared_with_me"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_trust_reports_shared_with_me"() TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_iou_activation"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_iou_activation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_iou_activation"() TO "service_role";



GRANT ALL ON FUNCTION "public"."guard_phone_verification_integrity"() TO "anon";
GRANT ALL ON FUNCTION "public"."guard_phone_verification_integrity"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."guard_phone_verification_integrity"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_exposure_release"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_exposure_release"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_exposure_release"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_late_payment"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_late_payment"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_late_payment"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_loan_completion"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_loan_completion"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_loan_completion"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_loan_exposure"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_loan_exposure"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_loan_exposure"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_on_time_payment"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_on_time_payment"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_on_time_payment"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_payment_default"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_payment_default"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_payment_default"() TO "service_role";



GRANT ALL ON FUNCTION "public"."has_active_trust_report_share"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."has_active_trust_report_share"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_active_trust_report_share"("p_owner_user_id" "uuid", "p_viewer_user_id" "uuid", "p_scope" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."has_current_legal_acceptance"("p_terms_version" "text", "p_privacy_version" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."has_current_legal_acceptance"("p_terms_version" "text", "p_privacy_version" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."has_current_legal_acceptance"("p_terms_version" "text", "p_privacy_version" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_current_legal_acceptance"("p_terms_version" "text", "p_privacy_version" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."has_trust_education_acceptance"("p_user_id" "uuid", "p_education_key" "text", "p_education_version" "text", "p_context" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."has_trust_education_acceptance"("p_user_id" "uuid", "p_education_key" "text", "p_education_version" "text", "p_context" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_trust_education_acceptance"("p_user_id" "uuid", "p_education_key" "text", "p_education_version" "text", "p_context" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."iou_score_large_completion_reward"() TO "anon";
GRANT ALL ON FUNCTION "public"."iou_score_large_completion_reward"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."iou_score_large_completion_reward"() TO "service_role";



GRANT ALL ON FUNCTION "public"."iou_score_medium_early_reward"() TO "anon";
GRANT ALL ON FUNCTION "public"."iou_score_medium_early_reward"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."iou_score_medium_early_reward"() TO "service_role";



GRANT ALL ON FUNCTION "public"."iou_score_small_on_time_reward"() TO "anon";
GRANT ALL ON FUNCTION "public"."iou_score_small_on_time_reward"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."iou_score_small_on_time_reward"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_receipt_split_member"("p_receipt_split_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_receipt_split_member"("p_receipt_split_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_receipt_split_member"("p_receipt_split_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."legal_acceptances_block_mutation"() TO "anon";
GRANT ALL ON FUNCTION "public"."legal_acceptances_block_mutation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."legal_acceptances_block_mutation"() TO "service_role";



GRANT ALL ON FUNCTION "public"."log_agreement_event"("p_user_id" "uuid", "p_actor_id" "uuid", "p_counterparty_id" "uuid", "p_score_agreement_id" "uuid", "p_source_type" "text", "p_source_id" "uuid", "p_event_type" "text", "p_amount_cents" bigint, "p_previous_amount_cents" bigint, "p_apr_bps" integer, "p_previous_apr_bps" integer, "p_due_at" timestamp with time zone, "p_previous_due_at" timestamp with time zone, "p_days_early" integer, "p_days_late" integer, "p_proof_tier" integer, "p_verification_tier" integer, "p_relationship_mode" "text", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."log_agreement_event"("p_user_id" "uuid", "p_actor_id" "uuid", "p_counterparty_id" "uuid", "p_score_agreement_id" "uuid", "p_source_type" "text", "p_source_id" "uuid", "p_event_type" "text", "p_amount_cents" bigint, "p_previous_amount_cents" bigint, "p_apr_bps" integer, "p_previous_apr_bps" integer, "p_due_at" timestamp with time zone, "p_previous_due_at" timestamp with time zone, "p_days_early" integer, "p_days_late" integer, "p_proof_tier" integer, "p_verification_tier" integer, "p_relationship_mode" "text", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_agreement_event"("p_user_id" "uuid", "p_actor_id" "uuid", "p_counterparty_id" "uuid", "p_score_agreement_id" "uuid", "p_source_type" "text", "p_source_id" "uuid", "p_event_type" "text", "p_amount_cents" bigint, "p_previous_amount_cents" bigint, "p_apr_bps" integer, "p_previous_apr_bps" integer, "p_due_at" timestamp with time zone, "p_previous_due_at" timestamp with time zone, "p_days_early" integer, "p_days_late" integer, "p_proof_tier" integer, "p_verification_tier" integer, "p_relationship_mode" "text", "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."log_payment_score_outcome_shadow"("p_payment_id" "uuid", "p_actor_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."log_payment_score_outcome_shadow"("p_payment_id" "uuid", "p_actor_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_payment_score_outcome_shadow"("p_payment_id" "uuid", "p_actor_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."log_score_agreement_outcome"("p_score_agreement_id" "uuid", "p_outcome_type" "text", "p_actor_id" "uuid", "p_amount_cents" bigint, "p_days_early" integer, "p_days_late" integer, "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."log_score_agreement_outcome"("p_score_agreement_id" "uuid", "p_outcome_type" "text", "p_actor_id" "uuid", "p_amount_cents" bigint, "p_days_early" integer, "p_days_late" integer, "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_score_agreement_outcome"("p_score_agreement_id" "uuid", "p_outcome_type" "text", "p_actor_id" "uuid", "p_amount_cents" bigint, "p_days_early" integer, "p_days_late" integer, "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."log_trust_outcome_event"("p_user_id" "uuid", "p_score_agreement_id" "uuid", "p_source_type" "text", "p_source_id" "uuid", "p_outcome_type" "text", "p_amount_cents" bigint, "p_days_early" integer, "p_days_late" integer, "p_proof_tier" integer, "p_verification_tier" integer, "p_related_snapshot_id" "uuid", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."log_trust_outcome_event"("p_user_id" "uuid", "p_score_agreement_id" "uuid", "p_source_type" "text", "p_source_id" "uuid", "p_outcome_type" "text", "p_amount_cents" bigint, "p_days_early" integer, "p_days_late" integer, "p_proof_tier" integer, "p_verification_tier" integer, "p_related_snapshot_id" "uuid", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_trust_outcome_event"("p_user_id" "uuid", "p_score_agreement_id" "uuid", "p_source_type" "text", "p_source_id" "uuid", "p_outcome_type" "text", "p_amount_cents" bigint, "p_days_early" integer, "p_days_late" integer, "p_proof_tier" integer, "p_verification_tier" integer, "p_related_snapshot_id" "uuid", "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."pay_and_receipt"("p_payment_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."pay_and_receipt"("p_payment_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."pay_and_receipt"("p_payment_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."payments_due_sync"() TO "anon";
GRANT ALL ON FUNCTION "public"."payments_due_sync"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."payments_due_sync"() TO "service_role";



GRANT ALL ON FUNCTION "public"."payments_status_auto"() TO "anon";
GRANT ALL ON FUNCTION "public"."payments_status_auto"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."payments_status_auto"() TO "service_role";



GRANT ALL ON FUNCTION "public"."payments_status_autoupdate"() TO "anon";
GRANT ALL ON FUNCTION "public"."payments_status_autoupdate"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."payments_status_autoupdate"() TO "service_role";



GRANT ALL ON FUNCTION "public"."profiles_phone_digits_sync"() TO "anon";
GRANT ALL ON FUNCTION "public"."profiles_phone_digits_sync"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."profiles_phone_digits_sync"() TO "service_role";



GRANT ALL ON FUNCTION "public"."propose_schedule_change"("p_iou_id" "uuid", "p_payments" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."propose_schedule_change"("p_iou_id" "uuid", "p_payments" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."propose_schedule_change"("p_iou_id" "uuid", "p_payments" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."recalculate_profile_exposure"("p_profile_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recalculate_profile_exposure"("p_profile_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalculate_profile_exposure"("p_profile_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."recalculate_score_v2_personal_iou_pair"("p_user_id" "uuid", "p_counterparty_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recalculate_score_v2_personal_iou_pair"("p_user_id" "uuid", "p_counterparty_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."recompute_iou_exposure"("p_iou_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recompute_iou_exposure"("p_iou_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recompute_iou_exposure"("p_iou_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."recompute_iou_progress"("p_iou_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recompute_iou_progress"("p_iou_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recompute_iou_progress"("p_iou_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."recompute_iou_status"("p_iou" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recompute_iou_status"("p_iou" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recompute_iou_status"("p_iou" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recompute_iou_status"("p_iou" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_legal_acceptance"("p_document_type" "text", "p_document_version" "text", "p_context" "text", "p_related_iou_id" "uuid", "p_platform" "text", "p_app_version" "text", "p_device_metadata" "jsonb", "p_metadata" "jsonb", "p_document_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_legal_acceptance"("p_document_type" "text", "p_document_version" "text", "p_context" "text", "p_related_iou_id" "uuid", "p_platform" "text", "p_app_version" "text", "p_device_metadata" "jsonb", "p_metadata" "jsonb", "p_document_hash" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."record_legal_acceptance"("p_document_type" "text", "p_document_version" "text", "p_context" "text", "p_related_iou_id" "uuid", "p_platform" "text", "p_app_version" "text", "p_device_metadata" "jsonb", "p_metadata" "jsonb", "p_document_hash" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_legal_acceptance"("p_document_type" "text", "p_document_version" "text", "p_context" "text", "p_related_iou_id" "uuid", "p_platform" "text", "p_app_version" "text", "p_device_metadata" "jsonb", "p_metadata" "jsonb", "p_document_hash" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."record_trust_education_acceptance"("p_user_id" "uuid", "p_education_key" "text", "p_education_version" "text", "p_context" "text", "p_platform" "text", "p_accepted_statements" "jsonb", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."record_trust_education_acceptance"("p_user_id" "uuid", "p_education_key" "text", "p_education_version" "text", "p_context" "text", "p_platform" "text", "p_accepted_statements" "jsonb", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_trust_education_acceptance"("p_user_id" "uuid", "p_education_key" "text", "p_education_version" "text", "p_context" "text", "p_platform" "text", "p_accepted_statements" "jsonb", "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."recover_strikes"() TO "anon";
GRANT ALL ON FUNCTION "public"."recover_strikes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."recover_strikes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."recover_user_strike"("user_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recover_user_strike"("user_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recover_user_strike"("user_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_iou_status"("target_iou" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_iou_status"("target_iou" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_iou_status"("target_iou" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."refresh_iou_status_from_payments"() TO "anon";
GRANT ALL ON FUNCTION "public"."refresh_iou_status_from_payments"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."refresh_iou_status_from_payments"() TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_payment"("p_payment_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_payment"("p_payment_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_payment"("p_payment_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_schedule_change"("p_iou_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_schedule_change"("p_iou_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_schedule_change"("p_iou_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."restore_iou"("p_iou" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."restore_iou"("p_iou" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."restore_iou"("p_iou" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."restore_iou"("p_iou" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."restore_loan"("p_loan" "uuid", "p_user" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."restore_loan"("p_loan" "uuid", "p_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."restore_loan"("p_loan" "uuid", "p_user" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."revoke_trust_report_share"("p_share_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."revoke_trust_report_share"("p_share_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."revoke_trust_report_share"("p_share_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_amount_weight"("p_amount_cents" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_amount_weight"("p_amount_cents" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_amount_weight"("p_amount_cents" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_confidence_label"("p_confidence" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_confidence_label"("p_confidence" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_confidence_label"("p_confidence" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_contract_ceiling"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_contract_ceiling"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_contract_ceiling"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_domain_freshness_days"("p_domain" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_domain_freshness_days"("p_domain" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_domain_freshness_days"("p_domain" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_freshness_adjustment"("p_score" integer, "p_freshness_score" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_freshness_adjustment"("p_score" integer, "p_freshness_score" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_freshness_adjustment"("p_score" integer, "p_freshness_score" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_freshness_multiplier"("p_last_verified_at" timestamp with time zone, "p_domain" "text", "p_as_of" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_freshness_multiplier"("p_last_verified_at" timestamp with time zone, "p_domain" "text", "p_as_of" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_freshness_multiplier"("p_last_verified_at" timestamp with time zone, "p_domain" "text", "p_as_of" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_freshness_score"("p_last_verified_at" timestamp with time zone, "p_domain" "text", "p_as_of" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_freshness_score"("p_last_verified_at" timestamp with time zone, "p_domain" "text", "p_as_of" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_freshness_score"("p_last_verified_at" timestamp with time zone, "p_domain" "text", "p_as_of" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_obligation_weight"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_frequency" "text", "p_proof_tier" integer, "p_verification_tier" integer, "p_same_pair_index" integer, "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_obligation_weight"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_frequency" "text", "p_proof_tier" integer, "p_verification_tier" integer, "p_same_pair_index" integer, "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_obligation_weight"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_frequency" "text", "p_proof_tier" integer, "p_verification_tier" integer, "p_same_pair_index" integer, "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_personal_iou_ceiling"("p_amount_cents" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_personal_iou_ceiling"("p_amount_cents" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_personal_iou_ceiling"("p_amount_cents" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_phone_bill_ceiling"("p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_phone_bill_ceiling"("p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_phone_bill_ceiling"("p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_proof_depth_label"("p_proof_depth" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_proof_depth_label"("p_proof_depth" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_proof_depth_label"("p_proof_depth" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_proof_multiplier"("p_proof_tier" integer, "p_verification_tier" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_proof_multiplier"("p_proof_tier" integer, "p_verification_tier" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_proof_multiplier"("p_proof_tier" integer, "p_verification_tier" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_public_trend_label"("p_delta_30d" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_public_trend_label"("p_delta_30d" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_public_trend_label"("p_delta_30d" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_relationship_affects_score"("p_user_id" "uuid", "p_related_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_relationship_affects_score"("p_user_id" "uuid", "p_related_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_relationship_affects_score"("p_user_id" "uuid", "p_related_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_rent_ceiling"("p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer, "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_rent_ceiling"("p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer, "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_rent_ceiling"("p_amount_cents" bigint, "p_term_months" integer, "p_proof_tier" integer, "p_verification_tier" integer, "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_rent_market_multiplier"("p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_rent_market_multiplier"("p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_rent_market_multiplier"("p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_rent_metadata_multiplier"("p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_rent_metadata_multiplier"("p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_rent_metadata_multiplier"("p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_same_pair_multiplier"("p_same_pair_index" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_same_pair_multiplier"("p_same_pair_index" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_same_pair_multiplier"("p_same_pair_index" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_score_ceiling"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_frequency" "text", "p_proof_tier" integer, "p_verification_tier" integer, "p_same_pair_index" integer, "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_score_ceiling"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_frequency" "text", "p_proof_tier" integer, "p_verification_tier" integer, "p_same_pair_index" integer, "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_score_ceiling"("p_source_type" "text", "p_amount_cents" bigint, "p_term_months" integer, "p_frequency" "text", "p_proof_tier" integer, "p_verification_tier" integer, "p_same_pair_index" integer, "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_source_multiplier"("p_source_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_source_multiplier"("p_source_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_source_multiplier"("p_source_type" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_term_weight"("p_term_months" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_term_weight"("p_term_months" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_term_weight"("p_term_months" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_tier_freshness_eligible"("p_tier" "text", "p_freshness_score" integer, "p_proof_depth" integer, "p_time_with_iou_days" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_tier_freshness_eligible"("p_tier" "text", "p_freshness_score" integer, "p_proof_depth" integer, "p_time_with_iou_days" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_tier_freshness_eligible"("p_tier" "text", "p_freshness_score" integer, "p_proof_depth" integer, "p_time_with_iou_days" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_trust_tier"("p_score" integer, "p_time_with_iou_days" integer, "p_proof_depth" integer, "p_has_active_strike" boolean, "p_has_high_risk_flag" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_trust_tier"("p_score" integer, "p_time_with_iou_days" integer, "p_proof_depth" integer, "p_has_active_strike" boolean, "p_has_high_risk_flag" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_trust_tier"("p_score" integer, "p_time_with_iou_days" integer, "p_proof_depth" integer, "p_has_active_strike" boolean, "p_has_high_risk_flag" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."score_v2_visible_trust"("p_score" integer, "p_active_exposure_points" integer, "p_freshness_score" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."score_v2_visible_trust"("p_score" integer, "p_active_exposure_points" integer, "p_freshness_score" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."score_v2_visible_trust"("p_score" integer, "p_active_exposure_points" integer, "p_freshness_score" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."sync_score_agreement_for_iou"("p_iou_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_score_agreement_for_iou"("p_iou_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_create_receipt_on_paid"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_create_receipt_on_paid"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_create_receipt_on_paid"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_recompute_iou_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_recompute_iou_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_recompute_iou_status"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."trg_sync_score_agreement_for_iou"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."trg_sync_score_agreement_for_iou"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_iou_progress"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_iou_progress"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_iou_progress"() TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_score_risk_flag"("p_user_id" "uuid", "p_flag_type" "text", "p_severity" "text", "p_source_type" "text", "p_source_id" "uuid", "p_description" "text", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_score_risk_flag"("p_user_id" "uuid", "p_flag_type" "text", "p_severity" "text", "p_source_type" "text", "p_source_id" "uuid", "p_description" "text", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_score_risk_flag"("p_user_id" "uuid", "p_flag_type" "text", "p_severity" "text", "p_source_type" "text", "p_source_id" "uuid", "p_description" "text", "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_receipt_item_assignment"() TO "anon";
GRANT ALL ON FUNCTION "public"."validate_receipt_item_assignment"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_receipt_item_assignment"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."verify_phone_code"("in_code" "text", "in_phone" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."verify_phone_code"("in_code" "text", "in_phone" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."verify_phone_code"("in_code" "text", "in_phone" "text") TO "service_role";



GRANT ALL ON TABLE "public"."agreement_events" TO "anon";
GRANT ALL ON TABLE "public"."agreement_events" TO "authenticated";
GRANT ALL ON TABLE "public"."agreement_events" TO "service_role";



GRANT ALL ON TABLE "public"."amend_requests" TO "anon";
GRANT ALL ON TABLE "public"."amend_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."amend_requests" TO "service_role";



GRANT ALL ON TABLE "public"."audit_log" TO "anon";
GRANT ALL ON TABLE "public"."audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."bank_accounts" TO "anon";
GRANT ALL ON TABLE "public"."bank_accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."bank_accounts" TO "service_role";



GRANT ALL ON TABLE "public"."borrower_due_next_14" TO "anon";
GRANT ALL ON TABLE "public"."borrower_due_next_14" TO "authenticated";
GRANT ALL ON TABLE "public"."borrower_due_next_14" TO "service_role";



GRANT ALL ON TABLE "public"."events" TO "anon";
GRANT ALL ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";



GRANT ALL ON TABLE "public"."identity_vault" TO "anon";
GRANT ALL ON TABLE "public"."identity_vault" TO "authenticated";
GRANT ALL ON TABLE "public"."identity_vault" TO "service_role";



GRANT ALL ON TABLE "public"."invitations" TO "anon";
GRANT ALL ON TABLE "public"."invitations" TO "authenticated";
GRANT ALL ON TABLE "public"."invitations" TO "service_role";



GRANT ALL ON TABLE "public"."invites" TO "anon";
GRANT ALL ON TABLE "public"."invites" TO "authenticated";
GRANT ALL ON TABLE "public"."invites" TO "service_role";



GRANT ALL ON TABLE "public"."iou_acceptance_audit" TO "anon";
GRANT ALL ON TABLE "public"."iou_acceptance_audit" TO "authenticated";
GRANT ALL ON TABLE "public"."iou_acceptance_audit" TO "service_role";



GRANT ALL ON TABLE "public"."iou_acceptance_events" TO "anon";
GRANT ALL ON TABLE "public"."iou_acceptance_events" TO "authenticated";
GRANT ALL ON TABLE "public"."iou_acceptance_events" TO "service_role";



GRANT ALL ON TABLE "public"."iou_invites" TO "anon";
GRANT ALL ON TABLE "public"."iou_invites" TO "authenticated";
GRANT ALL ON TABLE "public"."iou_invites" TO "service_role";



GRANT ALL ON TABLE "public"."iou_progress" TO "anon";
GRANT ALL ON TABLE "public"."iou_progress" TO "authenticated";
GRANT ALL ON TABLE "public"."iou_progress" TO "service_role";



GRANT ALL ON TABLE "public"."legal_acceptances" TO "anon";
GRANT ALL ON TABLE "public"."legal_acceptances" TO "authenticated";
GRANT ALL ON TABLE "public"."legal_acceptances" TO "service_role";



GRANT ALL ON TABLE "public"."lender_due_next_14" TO "anon";
GRANT ALL ON TABLE "public"."lender_due_next_14" TO "authenticated";
GRANT ALL ON TABLE "public"."lender_due_next_14" TO "service_role";



GRANT ALL ON TABLE "public"."loan_amendments" TO "anon";
GRANT ALL ON TABLE "public"."loan_amendments" TO "authenticated";
GRANT ALL ON TABLE "public"."loan_amendments" TO "service_role";



GRANT ALL ON TABLE "public"."loan_invites" TO "anon";
GRANT ALL ON TABLE "public"."loan_invites" TO "authenticated";
GRANT ALL ON TABLE "public"."loan_invites" TO "service_role";



GRANT ALL ON TABLE "public"."payment_receipts" TO "anon";
GRANT ALL ON TABLE "public"."payment_receipts" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_receipts" TO "service_role";



GRANT ALL ON TABLE "public"."phone_lookup" TO "anon";
GRANT ALL ON TABLE "public"."phone_lookup" TO "authenticated";
GRANT ALL ON TABLE "public"."phone_lookup" TO "service_role";



GRANT ALL ON TABLE "public"."phone_verifications" TO "service_role";



GRANT ALL ON TABLE "public"."plaid_items" TO "anon";
GRANT ALL ON TABLE "public"."plaid_items" TO "authenticated";
GRANT ALL ON TABLE "public"."plaid_items" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT UPDATE("display_name") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("name") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("full_name") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("dob") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("address_1") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("address_2") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("city") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("state") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("postal_code") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("ssn_last_4") ON TABLE "public"."profiles" TO "authenticated";



GRANT SELECT ON TABLE "public"."profile_directory" TO "authenticated";
GRANT SELECT ON TABLE "public"."profile_directory" TO "service_role";



GRANT ALL ON TABLE "public"."profile_visibility_settings" TO "anon";
GRANT ALL ON TABLE "public"."profile_visibility_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."profile_visibility_settings" TO "service_role";



GRANT SELECT ON TABLE "public"."public_profile" TO "service_role";



GRANT ALL ON TABLE "public"."receipt_split_participants" TO "anon";
GRANT ALL ON TABLE "public"."receipt_split_participants" TO "authenticated";
GRANT ALL ON TABLE "public"."receipt_split_participants" TO "service_role";



GRANT ALL ON TABLE "public"."receipt_split_totals" TO "anon";
GRANT ALL ON TABLE "public"."receipt_split_totals" TO "authenticated";
GRANT ALL ON TABLE "public"."receipt_split_totals" TO "service_role";



GRANT ALL ON TABLE "public"."receipt_splits" TO "anon";
GRANT ALL ON TABLE "public"."receipt_splits" TO "authenticated";
GRANT ALL ON TABLE "public"."receipt_splits" TO "service_role";



GRANT ALL ON TABLE "public"."receipt_generated_ious_view" TO "anon";
GRANT ALL ON TABLE "public"."receipt_generated_ious_view" TO "authenticated";
GRANT ALL ON TABLE "public"."receipt_generated_ious_view" TO "service_role";



GRANT ALL ON TABLE "public"."receipt_item_assignments" TO "anon";
GRANT ALL ON TABLE "public"."receipt_item_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."receipt_item_assignments" TO "service_role";



GRANT ALL ON TABLE "public"."receipt_split_detail_view" TO "anon";
GRANT ALL ON TABLE "public"."receipt_split_detail_view" TO "authenticated";
GRANT ALL ON TABLE "public"."receipt_split_detail_view" TO "service_role";



GRANT ALL ON TABLE "public"."receipt_split_items" TO "anon";
GRANT ALL ON TABLE "public"."receipt_split_items" TO "authenticated";
GRANT ALL ON TABLE "public"."receipt_split_items" TO "service_role";



GRANT ALL ON TABLE "public"."receipts" TO "anon";
GRANT ALL ON TABLE "public"."receipts" TO "authenticated";
GRANT ALL ON TABLE "public"."receipts" TO "service_role";



GRANT ALL ON TABLE "public"."score_agreements" TO "anon";
GRANT ALL ON TABLE "public"."score_agreements" TO "authenticated";
GRANT ALL ON TABLE "public"."score_agreements" TO "service_role";



GRANT ALL ON TABLE "public"."score_badges" TO "anon";
GRANT ALL ON TABLE "public"."score_badges" TO "authenticated";
GRANT ALL ON TABLE "public"."score_badges" TO "service_role";



GRANT ALL ON TABLE "public"."score_domains" TO "anon";
GRANT ALL ON TABLE "public"."score_domains" TO "authenticated";
GRANT ALL ON TABLE "public"."score_domains" TO "service_role";



GRANT ALL ON TABLE "public"."score_events" TO "anon";
GRANT ALL ON TABLE "public"."score_events" TO "authenticated";
GRANT ALL ON TABLE "public"."score_events" TO "service_role";



GRANT ALL ON TABLE "public"."score_history" TO "anon";
GRANT ALL ON TABLE "public"."score_history" TO "authenticated";
GRANT ALL ON TABLE "public"."score_history" TO "service_role";



GRANT ALL ON TABLE "public"."score_risk_flags" TO "anon";
GRANT ALL ON TABLE "public"."score_risk_flags" TO "authenticated";
GRANT ALL ON TABLE "public"."score_risk_flags" TO "service_role";



GRANT ALL ON TABLE "public"."signatures" TO "anon";
GRANT ALL ON TABLE "public"."signatures" TO "authenticated";
GRANT ALL ON TABLE "public"."signatures" TO "service_role";



GRANT ALL ON TABLE "public"."trust_education_acceptances" TO "anon";
GRANT ALL ON TABLE "public"."trust_education_acceptances" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_education_acceptances" TO "service_role";



GRANT ALL ON TABLE "public"."trust_model_versions" TO "anon";
GRANT ALL ON TABLE "public"."trust_model_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_model_versions" TO "service_role";



GRANT ALL ON TABLE "public"."trust_outcome_events" TO "anon";
GRANT ALL ON TABLE "public"."trust_outcome_events" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_outcome_events" TO "service_role";



GRANT ALL ON TABLE "public"."trust_prediction_accuracy_v" TO "anon";
GRANT ALL ON TABLE "public"."trust_prediction_accuracy_v" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_prediction_accuracy_v" TO "service_role";



GRANT ALL ON TABLE "public"."trust_prediction_by_proof_tier_v" TO "anon";
GRANT ALL ON TABLE "public"."trust_prediction_by_proof_tier_v" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_prediction_by_proof_tier_v" TO "service_role";



GRANT ALL ON TABLE "public"."trust_prediction_by_relationship_mode_v" TO "anon";
GRANT ALL ON TABLE "public"."trust_prediction_by_relationship_mode_v" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_prediction_by_relationship_mode_v" TO "service_role";



GRANT ALL ON TABLE "public"."trust_prediction_by_same_pair_band_v" TO "anon";
GRANT ALL ON TABLE "public"."trust_prediction_by_same_pair_band_v" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_prediction_by_same_pair_band_v" TO "service_role";



GRANT ALL ON TABLE "public"."trust_prediction_by_source_type_v" TO "anon";
GRANT ALL ON TABLE "public"."trust_prediction_by_source_type_v" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_prediction_by_source_type_v" TO "service_role";



GRANT ALL ON TABLE "public"."trust_prediction_by_value_band_v" TO "anon";
GRANT ALL ON TABLE "public"."trust_prediction_by_value_band_v" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_prediction_by_value_band_v" TO "service_role";



GRANT ALL ON TABLE "public"."trust_prediction_outcome_summary_v" TO "anon";
GRANT ALL ON TABLE "public"."trust_prediction_outcome_summary_v" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_prediction_outcome_summary_v" TO "service_role";



GRANT ALL ON TABLE "public"."trust_prediction_learning_dashboard_v" TO "anon";
GRANT ALL ON TABLE "public"."trust_prediction_learning_dashboard_v" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_prediction_learning_dashboard_v" TO "service_role";



GRANT ALL ON TABLE "public"."trust_report_access_logs" TO "anon";
GRANT ALL ON TABLE "public"."trust_report_access_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_report_access_logs" TO "service_role";



GRANT ALL ON TABLE "public"."trust_score_snapshots" TO "anon";
GRANT ALL ON TABLE "public"."trust_score_snapshots" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_score_snapshots" TO "service_role";



GRANT ALL ON TABLE "public"."trust_report_shadow_v" TO "anon";
GRANT ALL ON TABLE "public"."trust_report_shadow_v" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_report_shadow_v" TO "service_role";



GRANT ALL ON TABLE "public"."trust_report_shares" TO "anon";
GRANT ALL ON TABLE "public"."trust_report_shares" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_report_shares" TO "service_role";



GRANT ALL ON TABLE "public"."trust_reports" TO "anon";
GRANT ALL ON TABLE "public"."trust_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."trust_reports" TO "service_role";



GRANT ALL ON TABLE "public"."user_relationship_modes" TO "anon";
GRANT ALL ON TABLE "public"."user_relationship_modes" TO "authenticated";
GRANT ALL ON TABLE "public"."user_relationship_modes" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







