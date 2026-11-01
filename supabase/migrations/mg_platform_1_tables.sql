-- =====================================================================
--  Mellow George — reseller platform (1/4: columns, tables, indexes, helpers), merged into the live mg_inventory
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
-- 1. Audit columns on the existing mg_inventory tables
-- ---------------------------------------------------------------------
-- team_access and reseller_stock have natural keys (email / email+product)
-- that existing foreign keys and dispatch() rely on, so they keep those
-- primary keys and gain a unique uuid id alongside.
alter table mg_inventory.team_access    add column if not exists id uuid not null default gen_random_uuid();
alter table mg_inventory.reseller_stock add column if not exists id uuid not null default gen_random_uuid();
alter table mg_inventory.reseller_stock add column if not exists created_at timestamptz not null default now();
do $$ begin
  alter table mg_inventory.team_access    add constraint team_access_id_key    unique (id);
exception when duplicate_table or duplicate_object then null; end $$;
do $$ begin
  alter table mg_inventory.reseller_stock add constraint reseller_stock_id_key unique (id);
exception when duplicate_table or duplicate_object then null; end $$;

do $$
declare t text;
begin
  foreach t in array array['team_access','products','movements','requests','admin_events',
                           'reseller_stock','reseller_movements','orders'] loop
    execute format('alter table mg_inventory.%I
      add column if not exists updated_at timestamptz not null default now(),
      add column if not exists deleted_at timestamptz,
      add column if not exists created_by uuid references auth.users(id) on delete set null,
      add column if not exists updated_by uuid references auth.users(id) on delete set null', t);
  end loop;
end $$;

-- Catalogue details used by the storefront (quick view, filters).
alter table mg_inventory.products
  add column if not exists fragrance_family text check (length(fragrance_family) <= 80),
  add column if not exists scent_character  text check (length(scent_character)  <= 300),
  add column if not exists description      text check (length(description)      <= 2000),
  add column if not exists is_active        boolean not null default true,
  add column if not exists sort_order       integer not null default 0;

-- ---------------------------------------------------------------------
-- 2. New tables
-- ---------------------------------------------------------------------
create table if not exists mg_inventory.businesses (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null check (length(trim(name)) between 1 and 120),
  slug               text not null unique,
  tagline            text,
  website            text,
  email              text,
  reseller_email     text,
  currency           text not null default 'ZAR',
  country            text not null default 'South Africa',
  city               text,
  free_delivery_threshold_cents bigint not null default 25000 check (free_delivery_threshold_cents >= 0),
  delivery_fee_cents bigint not null default 0 check (delivery_fee_cents >= 0),
  reseller_low_stock integer not null default 3 check (reseller_low_stock >= 0),
  settings           jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null
);

create table if not exists mg_inventory.profiles (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null unique references auth.users(id) on delete cascade,
  email        text,
  display_name text check (length(display_name) <= 80),
  phone        text check (length(phone) <= 30),
  avatar_url   text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null
);

create table if not exists mg_inventory.resellers (
  id             uuid primary key default gen_random_uuid(),
  email          text not null unique references mg_inventory.team_access(email),
  reseller_code  text not null unique,
  team_leader_id uuid references mg_inventory.resellers(id) on delete set null,
  tier           text not null default 'basic' check (tier in ('basic','full','party_host')),
  starter_kit    text check (starter_kit in ('basic','full','party_host')),
  override_rate  numeric(5,2) not null default 0 check (override_rate between 0 and 100),
  phone          text check (length(phone) <= 30),
  whatsapp       text check (length(whatsapp) <= 30),
  city           text check (length(city) <= 80),
  province       text check (length(province) <= 80),
  joined_at      timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  constraint resellers_not_own_leader check (team_leader_id is distinct from id)
);

create table if not exists mg_inventory.customers (
  id            uuid primary key default gen_random_uuid(),
  reseller_id   uuid references mg_inventory.resellers(id) on delete restrict,  -- null = Mellow George direct customer
  profile_id    uuid references mg_inventory.profiles(id) on delete set null,
  full_name     text not null check (length(trim(full_name)) between 1 and 120),
  phone         text check (length(phone) <= 30),
  whatsapp      text check (length(whatsapp) <= 30),
  email         text check (length(email) <= 254),
  address       text check (length(address) <= 500),
  city          text check (length(city) <= 80),
  province      text check (length(province) <= 80),
  preferred_audience text check (preferred_audience in ('him','her','unisex')),
  credit_limit_cents bigint not null default 0 check (credit_limit_cents >= 0),
  notes         text check (length(notes) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null
);

create table if not exists mg_inventory.sales (
  id                uuid primary key default gen_random_uuid(),
  reseller_id       uuid not null references mg_inventory.resellers(id) on delete restrict,
  customer_id       uuid references mg_inventory.customers(id) on delete restrict,
  sale_number       text not null unique,
  status            text not null default 'completed' check (status in ('completed','cancelled','refunded')),
  subtotal_cents    bigint not null default 0,
  discount_cents    bigint not null default 0 check (discount_cents >= 0),
  total_cents       bigint not null default 0,
  amount_paid_cents bigint not null default 0,
  balance_cents     bigint generated always as (total_cents - amount_paid_cents) stored,
  payment_status    text not null default 'unpaid' check (payment_status in ('unpaid','partial','paid')),
  sold_at           timestamptz not null default now(),
  notes             text check (length(notes) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null
);

create table if not exists mg_inventory.sale_items (
  id               uuid primary key default gen_random_uuid(),
  sale_id          uuid not null references mg_inventory.sales(id) on delete cascade,
  product_id       uuid not null references mg_inventory.products(id) on delete restrict,
  quantity         integer not null check (quantity between 1 and 10000),
  unit_price_cents bigint not null check (unit_price_cents >= 0),   -- filled from product.retail_cents when omitted
  discount_cents   bigint not null default 0 check (discount_cents >= 0),
  line_total_cents bigint generated always as (quantity * unit_price_cents - discount_cents) stored,
  stock_movement_id uuid unique references mg_inventory.reseller_movements(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null
);

create table if not exists mg_inventory.payments (
  id             uuid primary key default gen_random_uuid(),
  reseller_id    uuid not null references mg_inventory.resellers(id) on delete restrict,
  customer_id    uuid references mg_inventory.customers(id) on delete restrict,
  sale_id        uuid references mg_inventory.sales(id) on delete restrict,   -- null = payment on account
  payment_number text not null unique,
  amount_cents   bigint not null check (amount_cents > 0),
  method         text not null default 'cash' check (method in ('cash','snapscan','zapper','capitec_pay','eft','card')),
  status         text not null default 'completed' check (status in ('completed','pending','failed','refunded')),
  reference      text check (length(reference) <= 120),
  paid_at        timestamptz not null default now(),
  notes          text check (length(notes) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  constraint payments_has_target check (customer_id is not null or sale_id is not null)
);

create table if not exists mg_inventory.loyalty_accounts (
  id              uuid primary key default gen_random_uuid(),
  customer_id     uuid not null unique references mg_inventory.customers(id) on delete cascade,
  points_balance  integer not null default 0,
  lifetime_points integer not null default 0,
  tier            text not null default 'bronze' check (tier in ('bronze','silver','gold','platinum')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null
);

create table if not exists mg_inventory.loyalty_transactions (
  id             uuid primary key default gen_random_uuid(),
  account_id     uuid not null references mg_inventory.loyalty_accounts(id) on delete cascade,
  kind           text not null check (kind in ('earn','redeem','adjust')),
  points         integer not null check (points <> 0),
  balance_after  integer not null,
  payment_id     uuid references mg_inventory.payments(id) on delete set null,
  sale_id        uuid references mg_inventory.sales(id) on delete set null,
  note           text check (length(note) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null
);

-- Storefront (website) orders, e.g. POST /api/checkout -> MGP-XXXXXXXX.
-- (mg_inventory.orders already exists and holds reseller stock requests.)
create table if not exists mg_inventory.customer_orders (
  id               uuid primary key default gen_random_uuid(),
  order_number     text not null unique,
  customer_id      uuid references mg_inventory.customers(id) on delete set null,
  profile_id       uuid references mg_inventory.profiles(id) on delete set null,
  reseller_id      uuid references mg_inventory.resellers(id) on delete set null,  -- referral attribution
  email            text not null check (length(email) between 3 and 254),
  phone            text check (length(phone) <= 30),
  status           text not null default 'pending'
                   check (status in ('pending','paid','packed','shipped','delivered','cancelled','refunded')),
  payment_status   text not null default 'unpaid' check (payment_status in ('unpaid','paid','refunded')),
  payment_method   text check (payment_method in ('snapscan','zapper','capitec_pay','eft','card','cash')),
  subtotal_cents   bigint not null default 0,
  discount_cents   bigint not null default 0 check (discount_cents >= 0),
  delivery_fee_cents bigint not null default 0 check (delivery_fee_cents >= 0),
  total_cents      bigint not null default 0,
  stock_deducted   boolean not null default false,
  shipping_address jsonb,
  delivery_city    text,
  delivery_province text,
  notes            text check (length(notes) <= 2000),
  placed_at        timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null
);

create table if not exists mg_inventory.customer_order_items (
  id               uuid primary key default gen_random_uuid(),
  order_id         uuid not null references mg_inventory.customer_orders(id) on delete cascade,
  product_id       uuid not null references mg_inventory.products(id) on delete restrict,
  quantity         integer not null check (quantity between 1 and 10000),
  unit_price_cents bigint not null check (unit_price_cents >= 0),
  line_total_cents bigint generated always as (quantity * unit_price_cents) stored,
  stock_movement_id uuid unique references mg_inventory.movements(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null
);

create table if not exists mg_inventory.activity_logs (
  id          uuid primary key default gen_random_uuid(),
  actor_id    uuid references auth.users(id) on delete set null,
  actor_email text,
  reseller_id uuid references mg_inventory.resellers(id) on delete set null,
  action      text not null,          -- insert | update | delete | soft_delete | restore
  entity_type text not null,
  entity_id   uuid,
  details     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null
);

-- ---------------------------------------------------------------------
-- 3. Indexes
-- ---------------------------------------------------------------------
create index if not exists mg_resellers_leader      on mg_inventory.resellers(team_leader_id);
create index if not exists mg_customers_reseller    on mg_inventory.customers(reseller_id) where deleted_at is null;
create index if not exists mg_customers_profile     on mg_inventory.customers(profile_id);
create index if not exists mg_customers_phone       on mg_inventory.customers(phone);
create index if not exists mg_sales_reseller_date   on mg_inventory.sales(reseller_id, sold_at desc);
create index if not exists mg_sales_customer        on mg_inventory.sales(customer_id);
create index if not exists mg_sales_unpaid          on mg_inventory.sales(reseller_id) where payment_status <> 'paid' and status = 'completed' and deleted_at is null;
create index if not exists mg_sale_items_sale       on mg_inventory.sale_items(sale_id);
create index if not exists mg_sale_items_product    on mg_inventory.sale_items(product_id);
create index if not exists mg_payments_reseller_date on mg_inventory.payments(reseller_id, paid_at desc);
create index if not exists mg_payments_customer     on mg_inventory.payments(customer_id);
create index if not exists mg_payments_sale         on mg_inventory.payments(sale_id);
create index if not exists mg_loyalty_tx_account    on mg_inventory.loyalty_transactions(account_id, created_at desc);
create index if not exists mg_loyalty_tx_payment    on mg_inventory.loyalty_transactions(payment_id);
create index if not exists mg_corders_customer      on mg_inventory.customer_orders(customer_id);
create index if not exists mg_corders_profile       on mg_inventory.customer_orders(profile_id);
create index if not exists mg_corders_reseller      on mg_inventory.customer_orders(reseller_id);
create index if not exists mg_corders_status        on mg_inventory.customer_orders(status, placed_at desc);
create index if not exists mg_corders_email         on mg_inventory.customer_orders(lower(email));
create index if not exists mg_corder_items_order    on mg_inventory.customer_order_items(order_id);
create index if not exists mg_corder_items_product  on mg_inventory.customer_order_items(product_id);
create index if not exists mg_activity_entity       on mg_inventory.activity_logs(entity_type, entity_id);
create index if not exists mg_activity_reseller     on mg_inventory.activity_logs(reseller_id, created_at desc);
create index if not exists mg_activity_recent       on mg_inventory.activity_logs(created_at desc);
create index if not exists mg_reseller_stock_product on mg_inventory.reseller_stock(product_id);
create index if not exists mg_reseller_mov_product  on mg_inventory.reseller_movements(product_id);
create index if not exists mg_orders_product        on mg_inventory.orders(product_id);
-- Foreign keys to auth.users (created_by / updated_by) on every table.
do $$
declare t text;
begin
  foreach t in array array['team_access','products','movements','requests','admin_events','reseller_stock',
                           'reseller_movements','orders','businesses','profiles','resellers','customers','sales',
                           'sale_items','payments','loyalty_accounts','loyalty_transactions','customer_orders',
                           'customer_order_items','activity_logs'] loop
    execute format('create index if not exists %I on mg_inventory.%I(created_by)', 'mg_'||t||'_created_by', t);
    execute format('create index if not exists %I on mg_inventory.%I(updated_by)', 'mg_'||t||'_updated_by', t);
  end loop;
end $$;
create index if not exists mg_activity_actor on mg_inventory.activity_logs(actor_id);

-- ---------------------------------------------------------------------
-- 4. Helper functions (identity + roles). SECURITY DEFINER so RLS
--    policies can call them without recursing through RLS themselves.
-- ---------------------------------------------------------------------
create or replace function mg_inventory.current_email()
returns text language sql stable security definer set search_path = '' as $$
  select lower(u.email) from auth.users u
  where u.id = auth.uid() and u.email_confirmed_at is not null;
$$;

create or replace function mg_inventory.member_role()
returns text language sql stable security definer set search_path = '' as $$
  select t.role from mg_inventory.team_access t
  where t.email = mg_inventory.current_email() and t.active and t.deleted_at is null;
$$;

create or replace function mg_inventory.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(mg_inventory.member_role() in ('owner','manager'), false);
$$;

create or replace function mg_inventory.is_team_member()
returns boolean language sql stable security definer set search_path = '' as $$
  select mg_inventory.member_role() is not null;
$$;

create or replace function mg_inventory.current_reseller_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select r.id from mg_inventory.resellers r
  join mg_inventory.team_access t on t.email = r.email
  where r.email = mg_inventory.current_email()
    and t.role = 'reseller' and t.active and t.deleted_at is null
    and r.deleted_at is null;
$$;

create or replace function mg_inventory.current_profile_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select p.id from mg_inventory.profiles p where p.user_id = auth.uid() and p.deleted_at is null;
$$;

create or replace function mg_inventory.is_team_leader_of(p_reseller uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from mg_inventory.resellers r
                 where r.id = p_reseller and r.deleted_at is null
                   and r.team_leader_id = mg_inventory.current_reseller_id());
$$;

-- Volume-discount wholesale price per bottle, in cents.
create or replace function mg_inventory.wholesale_unit_price_cents(p_qty integer)
returns bigint language sql immutable set search_path = '' as $$
  select case when p_qty >= 100 then 5800
              when p_qty >= 48  then 6500
              when p_qty >= 24  then 7200
              when p_qty >= 12  then 7800
              else 8400 end::bigint;
$$;

create or replace function mg_inventory.gen_doc_number(p_prefix text)
returns text language sql volatile set search_path = '' as $$
  select p_prefix || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
$$;

-- Same lock dispatch() takes, so trigger-driven stock changes serialize with it.
create or replace function mg_inventory.lock_inventory()
returns void language sql volatile set search_path = '' as $$
  select pg_advisory_xact_lock(hashtextextended('mellow-george-inventory-v2', 0));
$$;

-- ---------------------------------------------------------------------
-- 5. Defaults for document numbers
-- ---------------------------------------------------------------------
alter table mg_inventory.resellers       alter column reseller_code  set default mg_inventory.gen_doc_number('MGR');
alter table mg_inventory.sales           alter column sale_number    set default mg_inventory.gen_doc_number('SALE');
alter table mg_inventory.payments        alter column payment_number set default mg_inventory.gen_doc_number('PAY');
alter table mg_inventory.customer_orders alter column order_number   set default mg_inventory.gen_doc_number('MGP');


-- Enable RLS on the new tables now (policies arrive in the access migration).
do $$
declare t text;
begin
  foreach t in array array['businesses','profiles','resellers','customers','sales','sale_items','payments',
                           'loyalty_accounts','loyalty_transactions','customer_orders','customer_order_items',
                           'activity_logs'] loop
    execute format('alter table mg_inventory.%I enable row level security', t);
  end loop;
end $$;


-- New functions default to EXECUTE for PUBLIC; keep them closed until the
-- access migration grants exactly what each role needs.
revoke all on all functions in schema mg_inventory from public, anon;
grant execute on function mg_inventory.dispatch(text, jsonb) to authenticated;
