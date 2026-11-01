-- =====================================================================
--  Mellow George — reseller platform (3/4: triggers and RLS policies), merged into the live mg_inventory
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
-- 7. Attach triggers
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['team_access','products','movements','requests','admin_events','reseller_stock',
                           'reseller_movements','orders','businesses','profiles','resellers','customers','sales',
                           'sale_items','payments','loyalty_accounts','loyalty_transactions','customer_orders',
                           'customer_order_items','activity_logs'] loop
    execute format('create or replace trigger mg_audit before insert or update on mg_inventory.%I
                    for each row execute function mg_inventory.tg_audit()', t);
  end loop;

  foreach t in array array['customers','sales','payments','resellers','profiles'] loop
    execute format('create or replace trigger mg_guard_update before update on mg_inventory.%I
                    for each row execute function mg_inventory.tg_guard_update()', t);
  end loop;

  foreach t in array array['customers','sales','payments'] loop
    execute format('create or replace trigger mg_enforce_ownership before insert or update on mg_inventory.%I
                    for each row execute function mg_inventory.tg_enforce_ownership()', t);
  end loop;

  foreach t in array array['customers','sales','payments','resellers','customer_orders','businesses'] loop
    execute format('create or replace trigger mg_activity after insert or update or delete on mg_inventory.%I
                    for each row execute function mg_inventory.tg_activity_log()', t);
  end loop;
end $$;

create or replace trigger mg_sync_profile after insert or update of email on auth.users
  for each row execute function mg_inventory.tg_sync_profile();

create or replace trigger mg_team_access_reseller after insert or update of role on mg_inventory.team_access
  for each row execute function mg_inventory.tg_team_access_reseller();

create or replace trigger mg_sale_item_stock before insert on mg_inventory.sale_items
  for each row execute function mg_inventory.tg_sale_item_stock();

create or replace trigger mg_sale_item_immutable before update or delete on mg_inventory.sale_items
  for each row execute function mg_inventory.tg_sale_item_immutable();

create or replace trigger mg_recalc_sale after insert or update or delete on mg_inventory.sale_items
  for each row execute function mg_inventory.tg_recalc_sale();

create or replace trigger mg_sale_status after update on mg_inventory.sales
  for each row when (old.status is distinct from new.status)
  execute function mg_inventory.tg_sale_status();

create or replace trigger mg_sale_before_delete before delete on mg_inventory.sales
  for each row execute function mg_inventory.tg_sale_before_delete();

create or replace trigger mg_payment_rollup after insert or update or delete on mg_inventory.payments
  for each row execute function mg_inventory.tg_payment_rollup();

create or replace trigger mg_payment_loyalty after insert or update on mg_inventory.payments
  for each row execute function mg_inventory.tg_payment_loyalty();

create or replace trigger mg_customer_order_item_guard before insert or update or delete on mg_inventory.customer_order_items
  for each row execute function mg_inventory.tg_customer_order_item_guard();

create or replace trigger mg_recalc_customer_order after insert or update or delete on mg_inventory.customer_order_items
  for each row execute function mg_inventory.tg_recalc_customer_order();

create or replace trigger mg_customer_order_stock after update on mg_inventory.customer_orders
  for each row when (old.status is distinct from new.status)
  execute function mg_inventory.tg_customer_order_stock();

-- Create a policy, or update it in place if it already exists, so the
-- migration can be re-run without removing anything first.
create or replace function mg_inventory._ensure_policy(p_table regclass, p_name text, p_cmd text,
                                                       p_using text, p_check text default null)
returns void language plpgsql set search_path = '' as $$
declare v_sql text;
begin
  if exists (select 1 from pg_catalog.pg_policy where polrelid = p_table and polname = p_name) then
    v_sql := format('alter policy %I on %s to authenticated', p_name, p_table);
  else
    v_sql := format('create policy %I on %s for %s to authenticated', p_name, p_table, p_cmd);
  end if;
  if p_using is not null then v_sql := v_sql || format(' using (%s)', p_using); end if;
  if p_check is not null then v_sql := v_sql || format(' with check (%s)', p_check); end if;
  execute v_sql;
end $$;
revoke all on function mg_inventory._ensure_policy(regclass, text, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 9. Row Level Security
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['businesses','profiles','resellers','customers','sales','sale_items','payments',
                           'loyalty_accounts','loyalty_transactions','customer_orders','customer_order_items',
                           'activity_logs'] loop
    execute format('alter table mg_inventory.%I enable row level security', t);
  end loop;
end $$;

-- Existing stock tables: read-only, scoped. Writes stay with dispatch().
select mg_inventory._ensure_policy('mg_inventory.team_access', 'mg_team_access_read', 'select', $p$mg_inventory.is_admin() or email = mg_inventory.current_email()
         or exists (select 1 from mg_inventory.resellers d
                    where d.email = team_access.email and d.deleted_at is null
                      and d.team_leader_id = mg_inventory.current_reseller_id())$p$);

select mg_inventory._ensure_policy('mg_inventory.products', 'mg_products_read', 'select', $p$mg_inventory.is_admin()
         or (mg_inventory.is_team_member() and deleted_at is null and is_active
             and (mg_inventory.member_role() <> 'reseller'
                  or category = any (coalesce((select t.allowed_categories from mg_inventory.team_access t
                                               where t.email = mg_inventory.current_email()), '{}'::text[]))))$p$);

select mg_inventory._ensure_policy('mg_inventory.reseller_stock', 'mg_reseller_stock_read', 'select', $p$mg_inventory.is_admin()
         or (email = mg_inventory.current_email() and mg_inventory.current_reseller_id() is not null)$p$);

select mg_inventory._ensure_policy('mg_inventory.reseller_movements', 'mg_reseller_movements_read', 'select', $p$mg_inventory.is_admin()
         or (email = mg_inventory.current_email() and mg_inventory.current_reseller_id() is not null)$p$);

select mg_inventory._ensure_policy('mg_inventory.orders', 'mg_orders_read', 'select', $p$mg_inventory.is_admin()
         or (email = mg_inventory.current_email() and mg_inventory.current_reseller_id() is not null)
         or exists (select 1 from mg_inventory.resellers d
                    where d.email = orders.email and d.deleted_at is null
                      and d.team_leader_id = mg_inventory.current_reseller_id())$p$);

select mg_inventory._ensure_policy('mg_inventory.movements', 'mg_movements_read', 'select', $p$mg_inventory.is_admin()$p$);

select mg_inventory._ensure_policy('mg_inventory.admin_events', 'mg_admin_events_read', 'select', $p$mg_inventory.is_admin()$p$);

-- businesses
select mg_inventory._ensure_policy('mg_inventory.businesses', 'mg_businesses_read', 'select', $p$mg_inventory.is_team_member() and deleted_at is null or mg_inventory.is_admin()$p$);
select mg_inventory._ensure_policy('mg_inventory.businesses', 'mg_businesses_admin', 'all', $p$mg_inventory.is_admin()$p$, $p$mg_inventory.is_admin()$p$);

-- profiles
select mg_inventory._ensure_policy('mg_inventory.profiles', 'mg_profiles_read', 'select', $p$mg_inventory.is_admin() or user_id = auth.uid()$p$);
select mg_inventory._ensure_policy('mg_inventory.profiles', 'mg_profiles_update_self', 'update', $p$user_id = auth.uid()$p$, $p$user_id = auth.uid()$p$);
select mg_inventory._ensure_policy('mg_inventory.profiles', 'mg_profiles_admin', 'all', $p$mg_inventory.is_admin()$p$, $p$mg_inventory.is_admin()$p$);

-- resellers: self, own downline (team leaders), admins
select mg_inventory._ensure_policy('mg_inventory.resellers', 'mg_resellers_read', 'select', $p$mg_inventory.is_admin()
         or (deleted_at is null and (id = mg_inventory.current_reseller_id()
                                     or team_leader_id = mg_inventory.current_reseller_id()))$p$);
select mg_inventory._ensure_policy('mg_inventory.resellers', 'mg_resellers_update_self', 'update', $p$id = mg_inventory.current_reseller_id()$p$, $p$id = mg_inventory.current_reseller_id()$p$);
select mg_inventory._ensure_policy('mg_inventory.resellers', 'mg_resellers_admin', 'all', $p$mg_inventory.is_admin()$p$, $p$mg_inventory.is_admin()$p$);

-- Reseller-owned tables: customers, sales, payments.
-- Resellers read their own live rows and create/update their own rows;
-- they soft delete through mg_inventory.soft_delete(); hard delete is admin-only.
do $$
declare t text;
begin
  foreach t in array array['customers','sales','payments'] loop
    perform mg_inventory._ensure_policy(('mg_inventory.'||t)::regclass, 'mg_'||t||'_admin', 'all',
      'mg_inventory.is_admin()', 'mg_inventory.is_admin()');
    perform mg_inventory._ensure_policy(('mg_inventory.'||t)::regclass, 'mg_'||t||'_reseller_read', 'select',
      'reseller_id = mg_inventory.current_reseller_id() and deleted_at is null');
    perform mg_inventory._ensure_policy(('mg_inventory.'||t)::regclass, 'mg_'||t||'_reseller_insert', 'insert',
      null, 'reseller_id = mg_inventory.current_reseller_id()');
    perform mg_inventory._ensure_policy(('mg_inventory.'||t)::regclass, 'mg_'||t||'_reseller_update', 'update',
      'reseller_id = mg_inventory.current_reseller_id() and deleted_at is null',
      'reseller_id = mg_inventory.current_reseller_id()');
  end loop;
end $$;

-- sale_items: through the parent sale; insert only (lines are immutable).
select mg_inventory._ensure_policy('mg_inventory.sale_items', 'mg_sale_items_admin', 'all', $p$mg_inventory.is_admin()$p$, $p$mg_inventory.is_admin()$p$);
select mg_inventory._ensure_policy('mg_inventory.sale_items', 'mg_sale_items_reseller_read', 'select', $p$exists (select 1 from mg_inventory.sales s where s.id = sale_id
                 and s.reseller_id = mg_inventory.current_reseller_id() and s.deleted_at is null)$p$);
select mg_inventory._ensure_policy('mg_inventory.sale_items', 'mg_sale_items_reseller_insert', 'insert', null, $p$exists (select 1 from mg_inventory.sales s where s.id = sale_id
                      and s.reseller_id = mg_inventory.current_reseller_id() and s.deleted_at is null)$p$);

-- loyalty: read through the customer's reseller; writes via triggers/functions.
select mg_inventory._ensure_policy('mg_inventory.loyalty_accounts', 'mg_loyalty_accounts_admin', 'all', $p$mg_inventory.is_admin()$p$, $p$mg_inventory.is_admin()$p$);
select mg_inventory._ensure_policy('mg_inventory.loyalty_accounts', 'mg_loyalty_accounts_reseller_read', 'select', $p$exists (select 1 from mg_inventory.customers c where c.id = customer_id
                 and c.reseller_id = mg_inventory.current_reseller_id() and c.deleted_at is null)$p$);
select mg_inventory._ensure_policy('mg_inventory.loyalty_transactions', 'mg_loyalty_tx_admin', 'all', $p$mg_inventory.is_admin()$p$, $p$mg_inventory.is_admin()$p$);
select mg_inventory._ensure_policy('mg_inventory.loyalty_transactions', 'mg_loyalty_tx_reseller_read', 'select', $p$exists (select 1 from mg_inventory.loyalty_accounts a
                 join mg_inventory.customers c on c.id = a.customer_id
                 where a.id = account_id and c.reseller_id = mg_inventory.current_reseller_id()
                   and c.deleted_at is null)$p$);

-- storefront orders: admins manage; referring reseller and the signed-in
-- customer can read. The checkout backend writes with the service role.
select mg_inventory._ensure_policy('mg_inventory.customer_orders', 'mg_corders_admin', 'all', $p$mg_inventory.is_admin()$p$, $p$mg_inventory.is_admin()$p$);
select mg_inventory._ensure_policy('mg_inventory.customer_orders', 'mg_corders_read_own', 'select', $p$deleted_at is null and (reseller_id = mg_inventory.current_reseller_id()
                                 or profile_id = mg_inventory.current_profile_id())$p$);
select mg_inventory._ensure_policy('mg_inventory.customer_order_items', 'mg_corder_items_admin', 'all', $p$mg_inventory.is_admin()$p$, $p$mg_inventory.is_admin()$p$);
select mg_inventory._ensure_policy('mg_inventory.customer_order_items', 'mg_corder_items_read_own', 'select', $p$exists (select 1 from mg_inventory.customer_orders o where o.id = order_id and o.deleted_at is null
                 and (o.reseller_id = mg_inventory.current_reseller_id()
                      or o.profile_id = mg_inventory.current_profile_id()))$p$);

-- activity logs: admins see all; resellers see entries about their own records.
select mg_inventory._ensure_policy('mg_inventory.activity_logs', 'mg_activity_admin', 'select', $p$mg_inventory.is_admin()$p$);
select mg_inventory._ensure_policy('mg_inventory.activity_logs', 'mg_activity_reseller_read', 'select', $p$reseller_id is not null and reseller_id = mg_inventory.current_reseller_id()$p$);


-- The policies above call these helpers, so callers need EXECUTE on them now
-- (part 4 repeats the full grant list; grants are idempotent).
grant execute on function
  mg_inventory.current_email(), mg_inventory.member_role(), mg_inventory.is_admin(),
  mg_inventory.is_team_member(), mg_inventory.current_reseller_id(), mg_inventory.current_profile_id(),
  mg_inventory.is_team_leader_of(uuid)
to authenticated, service_role;
