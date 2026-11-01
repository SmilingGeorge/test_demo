-- =====================================================================
--  Mellow George — reseller platform (2/4: trigger and API functions), merged into the live mg_inventory
--  schema (project mellow-george-inv).
--
--  mg_inventory already holds the source of truth for stock:
--    team_access (owner/manager/staff/reseller, keyed by email), products,
--    movements (stockroom ledger), reseller_stock, reseller_movements,
--    orders (reseller stock requests), requests, admin_events — all written
--    only through mg_inventory.dispatch().
--
--  This migration adds what that system lacks — businesses, profiles,
--  resellers, customers, sales + sale_items, payments, loyalty, storefront
--  orders + items, activity logs — and wires them into the existing ledgers:
--    * a reseller sale draws down reseller_stock and writes a
--      reseller_movements 'sale' row, under the same advisory lock
--      dispatch() uses, so dispatch snapshots stay correct;
--    * a packed storefront order draws down the stockroom (products.quantity)
--      and writes a movements 'sale' row; cancelling writes a 'reversal'.
--
--  Every table (existing and new) gets: uuid id, created_at, updated_at,
--  deleted_at (soft delete), created_by, updated_by.
--
--  Access (Row Level Security):
--    admin    = team_access role owner|manager (active)  -> everything
--    reseller = team_access role reseller (active)       -> only own
--               customers, sales, payments, stock, loyalty, reports
--  Writes to stock tables still go through dispatch(); resellers get
--  read-only, RLS-scoped access to their own stock and ledger.
--  Also locks down the old June app's public.* tables (allow-all policies).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 6. Trigger functions
-- ---------------------------------------------------------------------

-- 6.1 Audit columns on every table.
create or replace function mg_inventory.tg_audit()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
    new.updated_at := now();
    new.created_by := coalesce(new.created_by, auth.uid());
    new.updated_by := coalesce(new.updated_by, auth.uid());
  else
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := now();
    new.updated_by := coalesce(auth.uid(), old.updated_by);
  end if;
  return new;
end $$;

-- 6.2 One profile per auth user, kept in step with the auth email.
create or replace function mg_inventory.tg_sync_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into mg_inventory.profiles (user_id, email, display_name, created_by, updated_by)
  values (new.id, lower(new.email),
          nullif(left(coalesce(new.raw_user_meta_data->>'full_name', split_part(coalesce(new.email,''), '@', 1)), 80), ''),
          new.id, new.id)
  on conflict (user_id) do update set email = excluded.email;
  return new;
end $$;

-- 6.3 Every reseller in team_access gets a resellers row.
create or replace function mg_inventory.tg_team_access_reseller()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.role = 'reseller' then
    insert into mg_inventory.resellers (email) values (new.email)
    on conflict (email) do update set deleted_at = null
      where mg_inventory.resellers.deleted_at is not null;
  end if;
  return null;
end $$;

-- 6.4 Fill the owning reseller from the caller, and keep ownership consistent
--     across references (foreign keys alone ignore RLS, so a reseller could
--     otherwise attach a payment to another reseller's sale).
create or replace function mg_inventory.tg_enforce_ownership()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_owner uuid; v_sale_customer uuid;
begin
  if tg_table_name in ('customers','sales','payments') and new.reseller_id is null then
    new.reseller_id := mg_inventory.current_reseller_id();
  end if;

  if tg_table_name = 'sales' then
    if new.customer_id is not null then
      select reseller_id into v_owner from mg_inventory.customers where id = new.customer_id;
      if v_owner is distinct from new.reseller_id then
        raise exception 'Customer belongs to a different reseller.' using errcode = '42501';
      end if;
    end if;
  elsif tg_table_name = 'payments' then
    if new.customer_id is not null then
      select reseller_id into v_owner from mg_inventory.customers where id = new.customer_id;
      if v_owner is distinct from new.reseller_id then
        raise exception 'Customer belongs to a different reseller.' using errcode = '42501';
      end if;
    end if;
    if new.sale_id is not null then
      select reseller_id, customer_id into v_owner, v_sale_customer from mg_inventory.sales where id = new.sale_id;
      if v_owner is distinct from new.reseller_id then
        raise exception 'Sale belongs to a different reseller.' using errcode = '42501';
      end if;
      if new.customer_id is null then
        new.customer_id := v_sale_customer;
      elsif v_sale_customer is not null and v_sale_customer <> new.customer_id then
        raise exception 'Payment customer does not match the sale.' using errcode = '22023';
      end if;
    end if;
  end if;
  return new;
end $$;

-- 6.5 Non-admins may not change ownership, money totals or pricing fields
--     directly. Allowed through: admins, nested trigger writes
--     (pg_trigger_depth() > 1 = system recalculations), and trusted server
--     roles (SQL editor / service role) — only end-user API roles are checked.
create or replace function mg_inventory.tg_guard_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- Applies to everyone: soft-deleting a completed sale cancels it,
  -- which returns its stock (see mg_sale_status).
  if tg_table_name = 'sales' then
    if old.deleted_at is null and new.deleted_at is not null and new.status = 'completed' then
      new.status := 'cancelled';
    end if;
  end if;

  if current_user not in ('authenticated','anon')
     or mg_inventory.is_admin() or pg_trigger_depth() > 1 then
    return new;
  end if;

  if tg_table_name = 'customers' then
    if new.reseller_id is distinct from old.reseller_id then
      raise exception 'A customer cannot be moved to another reseller.' using errcode = '42501';
    end if;
  elsif tg_table_name = 'sales' then
    if new.reseller_id is distinct from old.reseller_id
       or new.subtotal_cents <> old.subtotal_cents or new.total_cents <> old.total_cents
       or new.amount_paid_cents <> old.amount_paid_cents
       or new.payment_status <> old.payment_status then
      raise exception 'Sale totals and payment status are calculated automatically.' using errcode = '42501';
    end if;
    if old.status <> 'completed' and new.status <> old.status then
      raise exception 'A cancelled or refunded sale cannot be reopened.' using errcode = '22023';
    end if;
    if new.discount_cents <> old.discount_cents then
      raise exception 'Change the discount by cancelling and re-recording the sale.' using errcode = '22023';
    end if;
  elsif tg_table_name = 'payments' then
    if new.reseller_id is distinct from old.reseller_id or new.customer_id is distinct from old.customer_id
       or new.sale_id is distinct from old.sale_id or new.amount_cents <> old.amount_cents then
      raise exception 'Void this payment and record a new one instead of editing it.' using errcode = '22023';
    end if;
  elsif tg_table_name = 'resellers' then
    if new.email is distinct from old.email or new.reseller_code is distinct from old.reseller_code
       or new.team_leader_id is distinct from old.team_leader_id or new.tier is distinct from old.tier
       or new.starter_kit is distinct from old.starter_kit or new.override_rate <> old.override_rate
       or new.joined_at <> old.joined_at then
      raise exception 'Only an owner or manager can change reseller programme details.' using errcode = '42501';
    end if;
  elsif tg_table_name = 'profiles' then
    if new.user_id is distinct from old.user_id or new.email is distinct from old.email then
      raise exception 'Profile identity is managed by sign-in.' using errcode = '42501';
    end if;
  end if;

  return new;
end $$;

-- 6.6 Recording a sale line takes the bottles out of the reseller's
--     allocated stock and writes the matching reseller_movements row.
create or replace function mg_inventory.tg_sale_item_stock()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_sale    mg_inventory.sales%rowtype;
  v_product mg_inventory.products%rowtype;
  v_email   text;
  v_name    text;
  v_old     numeric;
  v_mov     uuid;
begin
  select * into v_sale from mg_inventory.sales where id = new.sale_id;
  if v_sale.status <> 'completed' or v_sale.deleted_at is not null then
    raise exception 'Items can only be added to an active sale.' using errcode = '22023';
  end if;

  select * into v_product from mg_inventory.products where id = new.product_id;
  if v_product.category <> 'perfume' then
    raise exception 'Sales recording is available for finished perfumes only.' using errcode = '22023';
  end if;
  new.unit_price_cents := coalesce(new.unit_price_cents, v_product.retail_cents);
  if new.discount_cents > new.quantity * new.unit_price_cents then
    raise exception 'Discount is larger than the line value.' using errcode = '22023';
  end if;

  select r.email, t.display_name into v_email, v_name
    from mg_inventory.resellers r join mg_inventory.team_access t on t.email = r.email
   where r.id = v_sale.reseller_id;

  perform mg_inventory.lock_inventory();
  select quantity into v_old from mg_inventory.reseller_stock
   where email = v_email and product_id = new.product_id for update;
  if coalesce(v_old, 0) < new.quantity then
    raise exception 'Not enough allocated stock of %. Request more stock first.', v_product.name
      using errcode = '23514';
  end if;

  update mg_inventory.reseller_stock
     set quantity = quantity - new.quantity, version = version + 1
   where email = v_email and product_id = new.product_id;

  insert into mg_inventory.reseller_movements
    (request_id, email, product_id, kind, delta, balance, revenue_cents, actor_name, actor_id, note)
  values
    (gen_random_uuid(), v_email, new.product_id, 'sale', -new.quantity, v_old - new.quantity,
     new.quantity * new.unit_price_cents - new.discount_cents, v_name,
     coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
     left('Sale ' || v_sale.sale_number, 500))
  returning id into v_mov;

  new.stock_movement_id := v_mov;
  return new;
end $$;

-- 6.7 Put the bottles of a sale back into the reseller's stock. The ledger
--     row uses kind 'sale' with a positive delta and negative revenue, so
--     dispatch() unit and revenue totals net out correctly.
create or replace function mg_inventory.reverse_sale_stock(p_sale uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_sale mg_inventory.sales%rowtype;
  v_email text; v_name text; v_old numeric;
  it record;
begin
  select * into v_sale from mg_inventory.sales where id = p_sale;
  select r.email, t.display_name into v_email, v_name
    from mg_inventory.resellers r join mg_inventory.team_access t on t.email = r.email
   where r.id = v_sale.reseller_id;

  perform mg_inventory.lock_inventory();
  for it in select * from mg_inventory.sale_items where sale_id = p_sale and stock_movement_id is not null loop
    select quantity into v_old from mg_inventory.reseller_stock
     where email = v_email and product_id = it.product_id for update;
    insert into mg_inventory.reseller_stock (email, product_id, quantity, version)
    values (v_email, it.product_id, coalesce(v_old, 0) + it.quantity, 1)
    on conflict (email, product_id) do update
      set quantity = excluded.quantity, version = mg_inventory.reseller_stock.version + 1;
    insert into mg_inventory.reseller_movements
      (request_id, email, product_id, kind, delta, balance, revenue_cents, actor_name, actor_id, note)
    values
      (gen_random_uuid(), v_email, it.product_id, 'sale', it.quantity, coalesce(v_old, 0) + it.quantity,
       -it.line_total_cents, v_name, coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
       left('Reversal of ' || v_sale.sale_number, 500));
  end loop;
end $$;

create or replace function mg_inventory.tg_sale_status()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'completed' and new.status <> 'completed' then
    perform mg_inventory.reverse_sale_stock(new.id);
  end if;
  return null;
end $$;

create or replace function mg_inventory.tg_sale_before_delete()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'completed' and old.deleted_at is null then
    perform mg_inventory.reverse_sale_stock(old.id);
  end if;
  return old;
end $$;

-- Sale lines are a stock ledger: immutable once recorded. To correct one,
-- cancel the sale (stock returns) and record it again.
create or replace function mg_inventory.tg_sale_item_immutable()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    if (new.sale_id, new.product_id, new.quantity, new.unit_price_cents, new.discount_cents, new.stock_movement_id)
       is distinct from
       (old.sale_id, old.product_id, old.quantity, old.unit_price_cents, old.discount_cents, old.stock_movement_id) then
      raise exception 'Sale lines cannot be edited. Cancel the sale and record it again.' using errcode = '22023';
    end if;
    return new;
  end if;
  -- DELETE: allowed only when the parent sale is already gone (cascade) or no longer completed.
  if exists (select 1 from mg_inventory.sales s
             where s.id = old.sale_id and s.status = 'completed' and s.deleted_at is null) then
    raise exception 'Sale lines cannot be removed. Cancel the sale instead.' using errcode = '22023';
  end if;
  return old;
end $$;

-- 6.8 Keep sale header totals equal to the sum of its lines.
create or replace function mg_inventory.tg_recalc_sale()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_sale uuid := coalesce(new.sale_id, old.sale_id); v_sub bigint;
begin
  select coalesce(sum(line_total_cents), 0) into v_sub
    from mg_inventory.sale_items where sale_id = v_sale and deleted_at is null;
  update mg_inventory.sales
     set subtotal_cents = v_sub,
         total_cents    = greatest(v_sub - discount_cents, 0)
   where id = v_sale;
  perform mg_inventory.refresh_sale_payment(v_sale);
  return null;
end $$;

-- 6.9 Roll completed, non-deleted payments up onto the sale.
create or replace function mg_inventory.refresh_sale_payment(p_sale uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_paid bigint; v_total bigint;
begin
  if p_sale is null then return; end if;
  select coalesce(sum(amount_cents), 0) into v_paid from mg_inventory.payments
   where sale_id = p_sale and status = 'completed' and deleted_at is null;
  select total_cents into v_total from mg_inventory.sales where id = p_sale;
  update mg_inventory.sales
     set amount_paid_cents = v_paid,
         payment_status = case when v_paid <= 0 then 'unpaid'
                               when v_paid >= v_total then 'paid'
                               else 'partial' end
   where id = p_sale;
end $$;

create or replace function mg_inventory.tg_payment_rollup()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op in ('INSERT','UPDATE') then perform mg_inventory.refresh_sale_payment(new.sale_id); end if;
  if tg_op in ('UPDATE','DELETE') and old.sale_id is distinct from new.sale_id then
    perform mg_inventory.refresh_sale_payment(old.sale_id);
  end if;
  if tg_op = 'DELETE' then perform mg_inventory.refresh_sale_payment(old.sale_id); end if;
  return null;
end $$;

-- 6.10 Loyalty: 1 point per R1 of each completed, non-deleted payment.
--      Idempotent — tops up or claws back the difference for that payment.
create or replace function mg_inventory.tg_payment_loyalty()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_due integer; v_have integer; v_delta integer; v_acct uuid; v_bal integer; v_life integer;
begin
  if new.customer_id is null then return null; end if;
  v_due := case when new.status = 'completed' and new.deleted_at is null then (new.amount_cents / 100)::int else 0 end;

  insert into mg_inventory.loyalty_accounts (customer_id) values (new.customer_id)
  on conflict (customer_id) do nothing;
  select id into v_acct from mg_inventory.loyalty_accounts where customer_id = new.customer_id for update;

  select coalesce(sum(points), 0) into v_have from mg_inventory.loyalty_transactions
   where payment_id = new.id and kind in ('earn','adjust');
  v_delta := v_due - v_have;
  if v_delta = 0 then return null; end if;

  update mg_inventory.loyalty_accounts
     set points_balance  = points_balance + v_delta,
         lifetime_points = lifetime_points + v_delta,
         tier = case when lifetime_points + v_delta >= 5000 then 'platinum'
                     when lifetime_points + v_delta >= 2000 then 'gold'
                     when lifetime_points + v_delta >= 500  then 'silver'
                     else 'bronze' end
   where id = v_acct
   returning points_balance, lifetime_points into v_bal, v_life;

  insert into mg_inventory.loyalty_transactions (account_id, kind, points, balance_after, payment_id, sale_id, note)
  values (v_acct, case when v_have = 0 and v_delta > 0 then 'earn' else 'adjust' end, v_delta, v_bal,
          new.id, new.sale_id,
          case when v_delta > 0 then 'Points for payment ' else 'Points reversed for payment ' end || new.payment_number);
  return null;
end $$;

-- 6.11 Storefront orders: totals, free delivery, and stockroom deduction.
create or replace function mg_inventory.tg_recalc_customer_order()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_order uuid := coalesce(new.order_id, old.order_id);
  v_sub bigint; v_threshold bigint; v_fee bigint;
begin
  select coalesce(sum(line_total_cents), 0) into v_sub
    from mg_inventory.customer_order_items where order_id = v_order and deleted_at is null;
  select free_delivery_threshold_cents, delivery_fee_cents into v_threshold, v_fee
    from mg_inventory.businesses where deleted_at is null order by created_at limit 1;
  v_fee := case when v_sub >= coalesce(v_threshold, 25000) then 0 else coalesce(v_fee, 0) end;
  update mg_inventory.customer_orders
     set subtotal_cents = v_sub,
         delivery_fee_cents = v_fee,
         total_cents = greatest(v_sub - discount_cents, 0) + v_fee
   where id = v_order;
  return null;
end $$;

create or replace function mg_inventory.tg_customer_order_item_guard()
returns trigger language plpgsql set search_path = '' as $$
declare v_locked boolean;
begin
  select stock_deducted into v_locked from mg_inventory.customer_orders
   where id = coalesce(new.order_id, old.order_id);
  if coalesce(v_locked, false) and pg_trigger_depth() = 1 then
    raise exception 'This order has been packed; its items can no longer change.' using errcode = '22023';
  end if;
  if tg_op = 'INSERT' and new.unit_price_cents is null then
    select retail_cents into new.unit_price_cents from mg_inventory.products where id = new.product_id;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create or replace function mg_inventory.tg_customer_order_stock()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  it record; v_qty numeric; v_mov uuid; v_store_email text;
begin
  select coalesce(email, 'hello@mellowgeorge.shop') into v_store_email
    from mg_inventory.businesses where deleted_at is null order by created_at limit 1;
  v_store_email := coalesce(v_store_email, 'hello@mellowgeorge.shop');

  -- Packing (or later) for the first time: take bottles out of the stockroom.
  if new.status in ('packed','shipped','delivered') and not new.stock_deducted then
    perform mg_inventory.lock_inventory();
    for it in select * from mg_inventory.customer_order_items where order_id = new.id and deleted_at is null loop
      select quantity into v_qty from mg_inventory.products where id = it.product_id for update;
      if v_qty is null then
        raise exception 'Set the stockroom opening count for this product before packing orders.' using errcode = '22023';
      end if;
      if v_qty < it.quantity then
        raise exception 'Not enough stock in the stockroom to pack order %.', new.order_number using errcode = '23514';
      end if;
      update mg_inventory.products set quantity = quantity - it.quantity, version = version + 1 where id = it.product_id;
      insert into mg_inventory.movements
        (request_id, product_id, kind, delta, balance, revenue_cents, note, actor_id, actor_name, actor_email)
      values
        (gen_random_uuid(), it.product_id, 'sale', -it.quantity, v_qty - it.quantity, it.line_total_cents,
         left('Online order ' || new.order_number, 500),
         coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid), 'Online store', v_store_email)
      returning id into v_mov;
      update mg_inventory.customer_order_items set stock_movement_id = v_mov where id = it.id;
    end loop;
    update mg_inventory.customer_orders set stock_deducted = true where id = new.id;

  -- Cancelled or refunded after packing: return the bottles via reversal rows.
  elsif new.status in ('cancelled','refunded') and new.stock_deducted then
    perform mg_inventory.lock_inventory();
    for it in select * from mg_inventory.customer_order_items where order_id = new.id and stock_movement_id is not null loop
      select quantity into v_qty from mg_inventory.products where id = it.product_id for update;
      update mg_inventory.products set quantity = coalesce(quantity, 0) + it.quantity, version = version + 1 where id = it.product_id;
      insert into mg_inventory.movements
        (request_id, product_id, kind, delta, balance, revenue_cents, note, actor_id, actor_name, actor_email, reverses)
      values
        (gen_random_uuid(), it.product_id, 'reversal', it.quantity, coalesce(v_qty, 0) + it.quantity, -it.line_total_cents,
         left('Cancelled online order ' || new.order_number, 500),
         coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid), 'Online store', v_store_email,
         it.stock_movement_id);
    end loop;
    update mg_inventory.customer_orders set stock_deducted = false where id = new.id;
  end if;
  return null;
end $$;

-- 6.12 Activity log for the business tables.
create or replace function mg_inventory.tg_activity_log()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_action text := lower(tg_op);
  v_changes jsonb := '{}'::jsonb;
  k text;
begin
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(v_new) loop
      if k not in ('updated_at','updated_by') and (v_new->k) is distinct from (v_old->k) then
        v_changes := v_changes || jsonb_build_object(k, jsonb_build_object('from', v_old->k, 'to', v_new->k));
      end if;
    end loop;
    if v_changes = '{}'::jsonb then return null; end if;
    if (v_old->>'deleted_at') is null and (v_new->>'deleted_at') is not null then v_action := 'soft_delete';
    elsif (v_old->>'deleted_at') is not null and (v_new->>'deleted_at') is null then v_action := 'restore';
    end if;
  end if;

  insert into mg_inventory.activity_logs (actor_id, actor_email, reseller_id, action, entity_type, entity_id, details)
  values (auth.uid(), mg_inventory.current_email(),
          case when tg_table_name = 'resellers' then (v_row->>'id')::uuid
               else nullif(v_row->>'reseller_id','')::uuid end,
          v_action, tg_table_name, (v_row->>'id')::uuid,
          case when tg_op = 'UPDATE' then jsonb_build_object('changes', v_changes)
               else jsonb_build_object('row', v_row - 'created_by' - 'updated_by') end);
  return null;
end $$;

-- ---------------------------------------------------------------------
-- 8. Functions callers use directly
-- ---------------------------------------------------------------------

-- Soft delete for the business tables. RLS hides soft-deleted rows from
-- non-admins, and Postgres checks an UPDATE's new row against SELECT
-- policies, so a direct "set deleted_at" by a reseller is rejected. This
-- function checks ownership itself (admin, or the row belongs to the
-- caller) and then performs the update.
create or replace function mg_inventory.soft_delete(p_table text, p_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_allowed boolean; n integer;
begin
  if p_table in ('customers','sales','payments') then
    execute format('select mg_inventory.is_admin() or reseller_id = mg_inventory.current_reseller_id()
                    from mg_inventory.%I where id = $1 and deleted_at is null', p_table)
      into v_allowed using p_id;
  elsif p_table = 'profiles' then
    select mg_inventory.is_admin() or user_id = auth.uid() into v_allowed
      from mg_inventory.profiles where id = p_id and deleted_at is null;
  elsif p_table in ('customer_orders','resellers') then
    v_allowed := mg_inventory.is_admin();
  else
    raise exception 'Soft delete is not available for %.', p_table using errcode = '22023';
  end if;
  if not coalesce(v_allowed, false) then
    raise exception 'Record not found.' using errcode = '42501';
  end if;
  execute format('update mg_inventory.%I set deleted_at = now() where id = $1 and deleted_at is null', p_table) using p_id;
  get diagnostics n = row_count;
  return n = 1;
end $$;

create or replace function mg_inventory.restore_record(p_table text, p_id uuid)
returns boolean language plpgsql security invoker set search_path = '' as $$
declare n integer;
begin
  if not mg_inventory.is_admin() then
    raise exception 'Only an owner or manager can restore records.' using errcode = '42501';
  end if;
  if p_table not in ('customers','sales','payments','customer_orders','profiles','resellers') then
    raise exception 'Restore is not available for %.', p_table using errcode = '22023';
  end if;
  execute format('update mg_inventory.%I set deleted_at = null where id = $1 and deleted_at is not null', p_table) using p_id;
  get diagnostics n = row_count;
  return n = 1;
end $$;

-- Redeem loyalty points for one of the caller's customers.
create or replace function mg_inventory.redeem_loyalty_points(p_customer uuid, p_points integer, p_note text default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_owner uuid; v_acct uuid; v_bal integer;
begin
  if p_points is null or p_points <= 0 then
    raise exception 'Points to redeem must be positive.' using errcode = '22023';
  end if;
  select reseller_id into v_owner from mg_inventory.customers where id = p_customer and deleted_at is null;
  if not found or not (mg_inventory.is_admin() or v_owner = mg_inventory.current_reseller_id()) then
    raise exception 'Customer not found.' using errcode = '42501';
  end if;
  select id, points_balance into v_acct, v_bal from mg_inventory.loyalty_accounts
   where customer_id = p_customer for update;
  if v_acct is null or v_bal < p_points then
    raise exception 'Not enough loyalty points.' using errcode = '23514';
  end if;
  update mg_inventory.loyalty_accounts set points_balance = points_balance - p_points
   where id = v_acct returning points_balance into v_bal;
  insert into mg_inventory.loyalty_transactions (account_id, kind, points, balance_after, note)
  values (v_acct, 'redeem', -p_points, v_bal, left(coalesce(p_note, 'Points redeemed'), 500));
  return v_bal;
end $$;

-- Stockroom report (exact main-stock counts). dispatch() hides these from
-- resellers, so they are not column-granted; admins read them here.
create or replace function mg_inventory.stockroom_report()
returns table (product_id uuid, name text, category text, unit text, audience text,
               quantity numeric, low_threshold numeric, is_low boolean,
               allocated_to_resellers numeric, retail_cents integer)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not mg_inventory.is_admin() then
    raise exception 'An owner or manager account is required.' using errcode = '42501';
  end if;
  return query
  select p.id, p.name, p.category, p.unit, p.audience, p.quantity, p.low_threshold,
         coalesce(p.quantity <= p.low_threshold, false),
         coalesce((select sum(s.quantity) from mg_inventory.reseller_stock s where s.product_id = p.id), 0),
         p.retail_cents
    from mg_inventory.products p
   where p.deleted_at is null
   order by p.category, lower(p.name);
end $$;


-- New functions default to EXECUTE for PUBLIC; keep them closed until the
-- access migration grants exactly what each role needs.
revoke all on all functions in schema mg_inventory from public, anon;
grant execute on function mg_inventory.dispatch(text, jsonb) to authenticated;
