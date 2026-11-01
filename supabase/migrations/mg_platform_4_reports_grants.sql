-- =====================================================================
--  Mellow George — reseller platform (4/4: views, grants, seed, public lockdown), merged into the live mg_inventory
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
-- 10. Report views (security_invoker: each caller sees only what RLS allows)
-- ---------------------------------------------------------------------
create or replace view mg_inventory.admins with (security_invoker = true) as
select t.id, t.email, t.display_name, t.role, t.active, t.created_at, t.updated_at, p.user_id
  from mg_inventory.team_access t
  left join mg_inventory.profiles p on p.email = t.email
 where t.role in ('owner','manager') and t.deleted_at is null;

create or replace view mg_inventory.v_product_catalog with (security_invoker = true) as
select p.id, p.name, p.category, p.unit, p.audience, p.inspiration, p.fragrance_family,
       p.scent_character, p.description, p.retail_cents, p.sort_order
  from mg_inventory.products p
 where p.deleted_at is null and p.is_active;

create or replace view mg_inventory.v_reseller_inventory with (security_invoker = true) as
select r.id as reseller_id, rs.email, rs.product_id, p.name as product_name, p.category, p.unit, p.audience,
       rs.quantity, p.retail_cents,
       (rs.quantity * coalesce(p.retail_cents, 0))::bigint as retail_value_cents,
       rs.quantity <= coalesce((select b.reseller_low_stock from mg_inventory.businesses b
                                where b.deleted_at is null order by b.created_at limit 1), 3) as is_low
  from mg_inventory.reseller_stock rs
  join mg_inventory.resellers r on r.email = rs.email
  join mg_inventory.products p on p.id = rs.product_id
 where rs.deleted_at is null;

create or replace view mg_inventory.v_customer_balances with (security_invoker = true) as
select c.id as customer_id, c.reseller_id, c.full_name, c.phone,
       coalesce(s.total_cents, 0)                         as total_sales_cents,
       coalesce(p.paid_cents, 0)                          as total_paid_cents,
       coalesce(s.total_cents, 0) - coalesce(p.paid_cents, 0) as balance_due_cents,
       c.credit_limit_cents,
       la.points_balance as loyalty_points, la.tier as loyalty_tier
  from mg_inventory.customers c
  left join (select customer_id, sum(total_cents) total_cents from mg_inventory.sales
              where status = 'completed' and deleted_at is null group by customer_id) s on s.customer_id = c.id
  left join (select customer_id, sum(amount_cents) paid_cents from mg_inventory.payments
              where status = 'completed' and deleted_at is null group by customer_id) p on p.customer_id = c.id
  left join mg_inventory.loyalty_accounts la on la.customer_id = c.id
 where c.deleted_at is null;

create or replace view mg_inventory.v_sales_detail with (security_invoker = true) as
select s.id, s.sale_number, s.reseller_id, s.customer_id, c.full_name as customer_name, s.status,
       s.subtotal_cents, s.discount_cents, s.total_cents, s.amount_paid_cents, s.balance_cents,
       s.payment_status, s.sold_at,
       coalesce(jsonb_agg(jsonb_build_object('product_id', i.product_id, 'product_name', p.name,
                                             'quantity', i.quantity, 'unit_price_cents', i.unit_price_cents,
                                             'line_total_cents', i.line_total_cents)
                          order by i.created_at) filter (where i.id is not null), '[]'::jsonb) as items
  from mg_inventory.sales s
  left join mg_inventory.customers c on c.id = s.customer_id
  left join mg_inventory.sale_items i on i.sale_id = s.id and i.deleted_at is null
  left join mg_inventory.products p on p.id = i.product_id
 where s.deleted_at is null
 group by s.id, c.full_name;

create or replace view mg_inventory.v_reseller_sales_summary with (security_invoker = true) as
select r.id as reseller_id, r.reseller_code, t.display_name,
       count(s.id) filter (where s.status = 'completed')                                   as sales_count,
       coalesce(sum(s.total_cents) filter (where s.status = 'completed'), 0)               as gross_sales_cents,
       coalesce(sum(s.amount_paid_cents) filter (where s.status = 'completed'), 0)         as collected_cents,
       coalesce(sum(s.balance_cents) filter (where s.status = 'completed'), 0)             as outstanding_cents,
       coalesce(sum(s.total_cents) filter (where s.status = 'completed'
                                           and s.sold_at >= date_trunc('month', now())), 0) as month_sales_cents,
       coalesce(sum(i.units), 0)                                                            as units_sold
  from mg_inventory.resellers r
  join mg_inventory.team_access t on t.email = r.email
  left join mg_inventory.sales s on s.reseller_id = r.id and s.deleted_at is null
  left join (select sale_id, sum(quantity) units from mg_inventory.sale_items group by sale_id) i
         on i.sale_id = s.id and s.status = 'completed'
 where r.deleted_at is null
 group by r.id, r.reseller_code, t.display_name;

create or replace view mg_inventory.v_reseller_dashboard with (security_invoker = true) as
select ss.reseller_id, ss.reseller_code, ss.display_name, ss.sales_count, ss.gross_sales_cents,
       ss.collected_cents, ss.outstanding_cents, ss.month_sales_cents, ss.units_sold,
       (select count(*) from mg_inventory.customers c where c.reseller_id = ss.reseller_id and c.deleted_at is null) as customer_count,
       (select coalesce(sum(ri.quantity), 0) from mg_inventory.v_reseller_inventory ri where ri.reseller_id = ss.reseller_id) as units_in_stock,
       (select count(*) from mg_inventory.v_reseller_inventory ri where ri.reseller_id = ss.reseller_id and ri.is_low) as low_stock_items
  from mg_inventory.v_reseller_sales_summary ss;

-- Team-leader override on downline stock requests that were fulfilled,
-- priced at the volume-discount wholesale rate.
create or replace view mg_inventory.v_team_downline with (security_invoker = true) as
select lead.id as team_leader_id, lead.reseller_code as leader_code,
       d.id as downline_id, d.reseller_code as downline_code, td.display_name as downline_name,
       lead.override_rate,
       coalesce(sum(o.quantity) filter (where o.status = 'fulfilled'), 0) as fulfilled_units,
       coalesce(sum(o.quantity * mg_inventory.wholesale_unit_price_cents(o.quantity::integer))
                filter (where o.status = 'fulfilled'), 0)::bigint as wholesale_value_cents,
       round(coalesce(sum(o.quantity * mg_inventory.wholesale_unit_price_cents(o.quantity::integer))
                      filter (where o.status = 'fulfilled'), 0) * lead.override_rate / 100)::bigint as override_cents
  from mg_inventory.resellers lead
  join mg_inventory.resellers d on d.team_leader_id = lead.id and d.deleted_at is null
  join mg_inventory.team_access td on td.email = d.email
  left join mg_inventory.orders o on o.email = d.email and o.deleted_at is null
 where lead.deleted_at is null
 group by lead.id, lead.reseller_code, d.id, d.reseller_code, td.display_name, lead.override_rate;

-- ---------------------------------------------------------------------
-- 11. Privileges
-- ---------------------------------------------------------------------
-- Existing stock tables: read-only (RLS-scoped). products omits the exact
-- stockroom count columns that dispatch() hides from resellers.
grant select on mg_inventory.team_access, mg_inventory.reseller_stock, mg_inventory.reseller_movements,
                mg_inventory.orders, mg_inventory.movements, mg_inventory.admin_events to authenticated;
grant select (id, name, audience, inspiration, retail_cents, created_at, category, unit, updated_at,
              deleted_at, fragrance_family, scent_character, description, is_active, sort_order)
  on mg_inventory.products to authenticated;

grant select on mg_inventory.businesses, mg_inventory.loyalty_accounts, mg_inventory.loyalty_transactions,
                mg_inventory.activity_logs, mg_inventory.customer_orders, mg_inventory.customer_order_items
  to authenticated;
grant select, update on mg_inventory.profiles, mg_inventory.resellers to authenticated;
grant insert, update, delete on mg_inventory.businesses, mg_inventory.customer_orders,
                                mg_inventory.customer_order_items to authenticated;
grant insert, delete on mg_inventory.resellers, mg_inventory.profiles to authenticated;
grant select, insert, update, delete on mg_inventory.customers, mg_inventory.sales,
                                        mg_inventory.sale_items, mg_inventory.payments to authenticated;
grant select on mg_inventory.admins, mg_inventory.v_product_catalog, mg_inventory.v_reseller_inventory,
                mg_inventory.v_customer_balances, mg_inventory.v_sales_detail, mg_inventory.v_reseller_sales_summary,
                mg_inventory.v_reseller_dashboard, mg_inventory.v_team_downline to authenticated;

-- The checkout backend (service role) needs the storefront tables.
grant usage on schema mg_inventory to service_role;
grant select, insert, update, delete on mg_inventory.customer_orders, mg_inventory.customer_order_items,
                                        mg_inventory.customers to service_role;
grant select on mg_inventory.businesses, mg_inventory.v_product_catalog to service_role;
grant select (id, name, audience, inspiration, retail_cents, category, unit, fragrance_family,
              scent_character, description, is_active, sort_order, deleted_at)
  on mg_inventory.products to service_role;

-- Functions: nothing for anon/public; callers get what they need.
revoke all on all functions in schema mg_inventory from public, anon;
grant execute on function
  mg_inventory.current_email(), mg_inventory.member_role(), mg_inventory.is_admin(),
  mg_inventory.is_team_member(), mg_inventory.current_reseller_id(), mg_inventory.current_profile_id(),
  mg_inventory.is_team_leader_of(uuid), mg_inventory.wholesale_unit_price_cents(integer),
  mg_inventory.gen_doc_number(text), mg_inventory.soft_delete(text, uuid),
  mg_inventory.restore_record(text, uuid), mg_inventory.redeem_loyalty_points(uuid, integer, text),
  mg_inventory.stockroom_report(), mg_inventory.dispatch(text, jsonb)
to authenticated;
grant execute on function mg_inventory.gen_doc_number(text), mg_inventory.wholesale_unit_price_cents(integer),
  mg_inventory.current_email(), mg_inventory.member_role(), mg_inventory.is_admin(),
  mg_inventory.current_reseller_id(), mg_inventory.current_profile_id()
  to service_role;
-- The live inventory app calls public.mg_inventory_api -> mg_inventory.dispatch.
grant execute on function public.mg_inventory_api(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 12. Backfill + seed
-- ---------------------------------------------------------------------
insert into mg_inventory.profiles (user_id, email, display_name)
select u.id, lower(u.email), nullif(left(split_part(coalesce(u.email,''), '@', 1), 80), '')
  from auth.users u
on conflict (user_id) do nothing;

insert into mg_inventory.resellers (email)
select t.email from mg_inventory.team_access t where t.role = 'reseller'
on conflict (email) do nothing;

insert into mg_inventory.businesses (name, slug, tagline, website, email, reseller_email, city)
values ('Mellow George Perfumes', 'mellow-george', 'Smell like a million. Pay like a person.',
        'https://www.mellowgeorge.shop', 'hello@mellowgeorge.shop', 'resellers@mellowgeorge.shop', 'Johannesburg')
on conflict (slug) do nothing;

update mg_inventory.products p set fragrance_family = v.family, scent_character = v.character_text
  from (values ('grootman', 'Aromatic Fougère', 'Bold, South African swagger. The one men reach for without thinking.'),
               ('bonolo',   'Fruity Floral',    'Light, playful, everyday wear.'),
               ('velvet rose', 'Oriental Floral', 'Coffee and rose wrapped in velvet. Addictive.')) as v(name, family, character_text)
 where p.category = 'perfume' and lower(trim(p.name)) = v.name and p.fragrance_family is null;

-- ---------------------------------------------------------------------
-- 13. Lock down the old June app's public tables (were allow-all, which
--     exposed users.pin_hash to anyone holding the anon key).
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['users','products','inventory','inventory_movements','sales','sale_items'] loop
    if exists (select 1 from pg_catalog.pg_policy
               where polrelid = ('public.'||t)::regclass and polname = 'allow_all_'||t) then
      -- turn the old allow-all policy into the admin-only one, in place
      execute format('alter policy %I on public.%I rename to %I', 'allow_all_'||t, t, 'mg_admin_only_'||t);
    end if;
    perform mg_inventory._ensure_policy(('public.'||t)::regclass, 'mg_admin_only_'||t, 'all',
      'mg_inventory.is_admin()', 'mg_inventory.is_admin()');
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;
