-- =====================================================================
--  Mellow George Perfumes — Complete Supabase / PostgreSQL schema
--  Multi-tenant reseller platform: business + admins + resellers +
--  customers + products + inventory + sales + payments + orders +
--  stock movements + loyalty + activity logs + profiles.
--
--  Conventions (every business table):
--    id          uuid primary key default gen_random_uuid()
--    created_at  timestamptz not null default now()
--    updated_at  timestamptz not null default now()   (maintained by trigger)
--    deleted_at  timestamptz                          (soft delete)
--    created_by  uuid references auth.users(id)       (set by trigger)
--    updated_by  uuid references auth.users(id)       (set by trigger)
--
--  Access model (Row Level Security):
--    * Admins  -> full access to everything (is_admin()).
--    * Resellers -> only THEIR OWN customers / sales / inventory /
--      payments / reports (scoped by current_reseller_id()).
--    * Anonymous storefront -> read active products only.
--    * The Tornado backend uses the service_role key, which bypasses RLS.
-- =====================================================================

-- Helper functions below forward-reference tables created further down;
-- defer SQL body validation until the whole migration has run.
set check_function_bodies = false;

-- ---------------------------------------------------------------------
-- 0. Extensions
-- ---------------------------------------------------------------------
create extension if not exists "pgcrypto";     -- gen_random_uuid()
create extension if not exists "pg_trgm";       -- fuzzy product search
create extension if not exists "citext";        -- case-insensitive email

-- ---------------------------------------------------------------------
-- 1. Enumerated types
-- ---------------------------------------------------------------------
do $$ begin
  create type public.user_role        as enum ('admin','reseller','staff','customer');
  create type public.admin_level       as enum ('super','standard','support');
  create type public.product_line       as enum ('her','him','bundle');
  create type public.reseller_tier      as enum ('basic','full','party_host');
  create type public.reseller_status    as enum ('pending','active','inactive','suspended');
  create type public.sale_status        as enum ('draft','completed','cancelled','refunded');
  create type public.payment_method     as enum ('snapscan','zapper','capitec_pay','eft','cash','card','payfast');
  create type public.payment_status     as enum ('pending','partial','completed','failed','refunded');
  create type public.order_type         as enum ('retail','wholesale');
  create type public.order_status       as enum ('pending','paid','packed','shipped','delivered','cancelled','refunded');
  create type public.movement_type      as enum ('initial','purchase','sale','adjustment','return','transfer_in','transfer_out');
  create type public.loyalty_tier       as enum ('bronze','silver','gold','platinum');
  create type public.loyalty_txn_type   as enum ('earn','redeem','adjust','expire');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- 2. Utility / security-helper functions
--    (SECURITY DEFINER so RLS-helper reads don't recurse on profiles)
-- ---------------------------------------------------------------------

-- Maintain audit columns on every insert / update.
create or replace function public.tg_set_audit()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
    new.updated_at := now();
    new.created_by := coalesce(new.created_by, auth.uid());
    new.updated_by := coalesce(new.updated_by, auth.uid());
  elsif tg_op = 'UPDATE' then
    new.created_at := old.created_at;        -- immutable
    new.created_by := old.created_by;        -- immutable
    new.updated_at := now();
    new.updated_by := coalesce(auth.uid(), old.updated_by);
  end if;
  return new;
end $$;

-- Current auth user's profile id.
create or replace function public.current_profile_id()
returns uuid language sql stable security definer set search_path = public, auth as $$
  select p.id from public.profiles p
  where p.user_id = auth.uid() and p.deleted_at is null
  limit 1;
$$;

-- Is the current user an admin?
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from public.profiles p
    where p.user_id = auth.uid()
      and p.role = 'admin'
      and p.deleted_at is null
  );
$$;

-- Current user's reseller id (null if they are not a reseller).
create or replace function public.current_reseller_id()
returns uuid language sql stable security definer set search_path = public, auth as $$
  select r.id
  from public.resellers r
  join public.profiles p on p.id = r.profile_id
  where p.user_id = auth.uid()
    and r.deleted_at is null
  limit 1;
$$;

-- Is :reseller in the current user's downline (they are the team leader)?
create or replace function public.is_team_leader_of(p_reseller uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.resellers r
    where r.id = p_reseller
      and r.team_leader_id = public.current_reseller_id()
      and r.deleted_at is null
  );
$$;

-- Tiered wholesale unit price from the volume-discount table.
create or replace function public.wholesale_unit_price(p_qty integer)
returns numeric language sql immutable as $$
  select case
    when p_qty >= 100 then 58
    when p_qty >= 48  then 65
    when p_qty >= 24  then 72
    when p_qty >= 12  then 78
    else                   84
  end::numeric;
$$;

-- Human-friendly document number generator, e.g. MGP-9F3A2B7C.
create or replace function public.gen_doc_number(p_prefix text)
returns text language sql volatile as $$
  select p_prefix || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
$$;

-- Soft delete / restore helpers (kept generic; admins may still hard-delete).
create or replace function public.soft_delete(p_table regclass, p_id uuid)
returns void language plpgsql as $$
begin
  execute format('update %s set deleted_at = now(), updated_at = now(), updated_by = auth.uid() where id = $1 and deleted_at is null', p_table) using p_id;
end $$;

create or replace function public.restore_record(p_table regclass, p_id uuid)
returns void language plpgsql as $$
begin
  execute format('update %s set deleted_at = null, updated_at = now(), updated_by = auth.uid() where id = $1', p_table) using p_id;
end $$;

-- =====================================================================
-- 3. Tables
-- =====================================================================

-- 3.1 businesses ------------------------------------------------------
create table if not exists public.businesses (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  slug          text unique,
  tagline       text,
  website       text,
  email         citext,
  support_email citext,
  reseller_email citext,
  currency      text not null default 'ZAR',
  country       text not null default 'South Africa',
  city          text,
  phone         text,
  free_delivery_threshold numeric not null default 250,
  settings      jsonb not null default '{}'::jsonb,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  created_by    uuid references auth.users(id),
  updated_by    uuid references auth.users(id)
);

-- 3.2 profiles (1:1 with auth.users) ----------------------------------
create table if not exists public.profiles (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid unique not null references auth.users(id) on delete cascade,
  business_id uuid references public.businesses(id) on delete set null,
  role        public.user_role not null default 'customer',
  full_name   text,
  email       citext,
  phone       text,
  avatar_url  text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  created_by  uuid references auth.users(id),
  updated_by  uuid references auth.users(id)
);

-- 3.3 admins ----------------------------------------------------------
create table if not exists public.admins (
  id           uuid primary key default gen_random_uuid(),
  profile_id   uuid unique not null references public.profiles(id) on delete cascade,
  business_id  uuid references public.businesses(id) on delete set null,
  access_level public.admin_level not null default 'standard',
  permissions  jsonb not null default '{}'::jsonb,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  created_by   uuid references auth.users(id),
  updated_by   uuid references auth.users(id)
);

-- 3.4 resellers -------------------------------------------------------
create table if not exists public.resellers (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid unique not null references public.profiles(id) on delete cascade,
  business_id    uuid references public.businesses(id) on delete set null,
  reseller_code  text unique not null default public.gen_doc_number('MGR'),
  display_name   text,
  team_leader_id uuid references public.resellers(id) on delete set null,
  tier           public.reseller_tier not null default 'basic',
  status         public.reseller_status not null default 'pending',
  commission_rate numeric not null default 0,     -- % on own sales (if used)
  override_rate   numeric not null default 0,     -- % earned on downline purchases
  phone          text,
  whatsapp       text,
  city           text,
  province       text,
  starter_kit    public.reseller_tier,
  joined_at      timestamptz not null default now(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  created_by     uuid references auth.users(id),
  updated_by     uuid references auth.users(id),
  constraint resellers_no_self_lead check (team_leader_id is null or team_leader_id <> id)
);

-- 3.5 customers (owned by a reseller) --------------------------------
create table if not exists public.customers (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid references public.businesses(id) on delete set null,
  reseller_id  uuid references public.resellers(id) on delete set null,
  profile_id   uuid references public.profiles(id) on delete set null,
  full_name    text not null,
  email        citext,
  phone        text,
  whatsapp     text,
  address      text,
  city         text,
  province     text,
  postal_code  text,
  preferred_line public.product_line,
  credit_limit numeric not null default 0,
  notes        text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz,
  created_by   uuid references auth.users(id),
  updated_by   uuid references auth.users(id)
);

-- 3.6 products (catalog) ---------------------------------------------
create table if not exists public.products (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid references public.businesses(id) on delete set null,
  sku           text unique,
  name          text not null,
  slug          text unique,
  line          public.product_line not null,
  inspired_by   text,
  fragrance_family text,
  character     text,
  description   text,
  notes_top     text,
  notes_heart   text,
  notes_base    text,
  size_ml       numeric not null default 50,
  concentration text not null default 'Eau de Parfum',
  retail_price  numeric not null default 120,
  wholesale_price numeric not null default 84,
  recommended_sell_price numeric not null default 150,
  cost_price    numeric,
  emoji         text default '🧴',
  image_url     text,
  accent_color  text,
  is_bundle     boolean not null default false,
  bundle_size   integer,
  is_active     boolean not null default true,
  is_featured   boolean not null default false,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  created_by    uuid references auth.users(id),
  updated_by    uuid references auth.users(id),
  constraint products_price_nonneg check (retail_price >= 0 and wholesale_price >= 0)
);

-- 3.7 inventory (per reseller; null reseller = central Mellow George stock)
create table if not exists public.inventory (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid references public.businesses(id) on delete set null,
  reseller_id       uuid references public.resellers(id) on delete cascade,
  product_id        uuid not null references public.products(id) on delete cascade,
  quantity          integer not null default 0,
  reserved_quantity integer not null default 0,
  reorder_level     integer not null default 6,
  reorder_quantity  integer not null default 12,
  location          text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  created_by        uuid references auth.users(id),
  updated_by        uuid references auth.users(id),
  constraint inventory_qty_nonneg check (quantity >= 0 and reserved_quantity >= 0)
);

-- 3.8 sales (reseller -> customer) -----------------------------------
create table if not exists public.sales (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid references public.businesses(id) on delete set null,
  reseller_id    uuid not null references public.resellers(id) on delete cascade,
  customer_id    uuid references public.customers(id) on delete set null,
  sale_number    text unique not null default public.gen_doc_number('SALE'),
  status         public.sale_status not null default 'completed',
  subtotal       numeric not null default 0,
  discount       numeric not null default 0,
  total          numeric not null default 0,
  amount_paid    numeric not null default 0,
  balance        numeric generated always as (total - amount_paid) stored,
  payment_status public.payment_status not null default 'pending',
  sold_at        timestamptz not null default now(),
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  created_by     uuid references auth.users(id),
  updated_by     uuid references auth.users(id)
);

-- 3.9 sale_items -----------------------------------------------------
create table if not exists public.sale_items (
  id          uuid primary key default gen_random_uuid(),
  sale_id     uuid not null references public.sales(id) on delete cascade,
  product_id  uuid references public.products(id) on delete set null,
  description text,
  quantity    integer not null default 1,
  unit_price  numeric not null,
  discount    numeric not null default 0,
  line_total  numeric generated always as ((unit_price * quantity) - discount) stored,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  created_by  uuid references auth.users(id),
  updated_by  uuid references auth.users(id),
  constraint sale_items_qty_pos check (quantity > 0)
);

-- 3.10 payments (against sales / credit) -----------------------------
create table if not exists public.payments (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid references public.businesses(id) on delete set null,
  reseller_id    uuid not null references public.resellers(id) on delete cascade,
  customer_id    uuid references public.customers(id) on delete set null,
  sale_id        uuid references public.sales(id) on delete set null,
  payment_number text unique not null default public.gen_doc_number('PAY'),
  amount         numeric not null,
  method         public.payment_method not null default 'cash',
  status         public.payment_status not null default 'completed',
  reference      text,
  paid_at        timestamptz not null default now(),
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  created_by     uuid references auth.users(id),
  updated_by     uuid references auth.users(id),
  constraint payments_amount_pos check (amount >= 0)
);

-- 3.11 orders (storefront retail + reseller wholesale) ---------------
create table if not exists public.orders (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid references public.businesses(id) on delete set null,
  order_number   text unique not null default public.gen_doc_number('MGP'),
  order_type     public.order_type not null default 'retail',
  reseller_id    uuid references public.resellers(id) on delete set null,
  customer_id    uuid references public.customers(id) on delete set null,
  profile_id     uuid references public.profiles(id) on delete set null,
  email          citext not null,
  phone          text,
  status         public.order_status not null default 'pending',
  payment_status public.payment_status not null default 'pending',
  payment_method public.payment_method,
  subtotal       numeric not null default 0,
  discount       numeric not null default 0,
  delivery_fee   numeric not null default 0,
  total          numeric not null default 0,
  shipping_address jsonb,
  delivery_city  text,
  delivery_province text,
  delivery_eta   text,
  notes          text,
  placed_at      timestamptz not null default now(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  created_by     uuid references auth.users(id),
  updated_by     uuid references auth.users(id)
);

-- 3.12 order_items ---------------------------------------------------
create table if not exists public.order_items (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id) on delete cascade,
  product_id  uuid references public.products(id) on delete set null,
  description text,
  quantity    integer not null default 1,
  unit_price  numeric not null,
  line_total  numeric generated always as (unit_price * quantity) stored,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  created_by  uuid references auth.users(id),
  updated_by  uuid references auth.users(id),
  constraint order_items_qty_pos check (quantity > 0)
);

-- 3.13 stock_movements (immutable audit of every inventory change) ----
create table if not exists public.stock_movements (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid references public.businesses(id) on delete set null,
  reseller_id    uuid references public.resellers(id) on delete cascade,
  product_id     uuid not null references public.products(id) on delete cascade,
  movement_type  public.movement_type not null,
  quantity       integer not null,               -- signed: +in / -out
  balance_after  integer,
  reference_type text,
  reference_id   uuid,
  reason         text,
  occurred_at    timestamptz not null default now(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  created_by     uuid references auth.users(id),
  updated_by     uuid references auth.users(id)
);

-- 3.14 loyalty_accounts ----------------------------------------------
create table if not exists public.loyalty_accounts (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid references public.businesses(id) on delete set null,
  customer_id    uuid unique not null references public.customers(id) on delete cascade,
  points_balance integer not null default 0,
  lifetime_points integer not null default 0,
  tier           public.loyalty_tier not null default 'bronze',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  created_by     uuid references auth.users(id),
  updated_by     uuid references auth.users(id)
);

-- 3.15 loyalty_transactions ------------------------------------------
create table if not exists public.loyalty_transactions (
  id             uuid primary key default gen_random_uuid(),
  account_id     uuid not null references public.loyalty_accounts(id) on delete cascade,
  customer_id    uuid references public.customers(id) on delete set null,
  txn_type       public.loyalty_txn_type not null,
  points         integer not null,               -- signed
  balance_after  integer,
  reference_type text,
  reference_id   uuid,
  description    text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz,
  created_by     uuid references auth.users(id),
  updated_by     uuid references auth.users(id)
);

-- 3.16 activity_logs -------------------------------------------------
create table if not exists public.activity_logs (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid references public.businesses(id) on delete set null,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  actor_reseller_id uuid references public.resellers(id) on delete set null,
  action           text not null,
  entity_type      text,
  entity_id        uuid,
  description      text,
  metadata         jsonb not null default '{}'::jsonb,
  ip_address       inet,
  user_agent       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz,
  created_by       uuid references auth.users(id),
  updated_by       uuid references auth.users(id)
);

-- =====================================================================
-- 4. Indexes
-- =====================================================================
-- Foreign-key & lookup indexes
create index if not exists idx_profiles_user          on public.profiles(user_id);
create index if not exists idx_profiles_business       on public.profiles(business_id);
create index if not exists idx_profiles_role           on public.profiles(role);
create index if not exists idx_admins_profile          on public.admins(profile_id);
create index if not exists idx_resellers_profile       on public.resellers(profile_id);
create index if not exists idx_resellers_leader        on public.resellers(team_leader_id);
create index if not exists idx_resellers_business       on public.resellers(business_id);
create index if not exists idx_resellers_status        on public.resellers(status);
create index if not exists idx_customers_reseller      on public.customers(reseller_id);
create index if not exists idx_customers_profile       on public.customers(profile_id);
create index if not exists idx_customers_email         on public.customers(email);
create index if not exists idx_products_line           on public.products(line);
create index if not exists idx_products_active         on public.products(is_active) where deleted_at is null;
create index if not exists idx_products_name_trgm      on public.products using gin (name gin_trgm_ops);
create index if not exists idx_inventory_reseller      on public.inventory(reseller_id);
create index if not exists idx_inventory_product       on public.inventory(product_id);
create index if not exists idx_sales_reseller_date     on public.sales(reseller_id, sold_at desc);
create index if not exists idx_sales_customer          on public.sales(customer_id);
create index if not exists idx_sales_payment_status    on public.sales(payment_status);
create index if not exists idx_sale_items_sale         on public.sale_items(sale_id);
create index if not exists idx_sale_items_product      on public.sale_items(product_id);
create index if not exists idx_payments_reseller_date  on public.payments(reseller_id, paid_at desc);
create index if not exists idx_payments_customer       on public.payments(customer_id);
create index if not exists idx_payments_sale           on public.payments(sale_id);
create index if not exists idx_orders_reseller         on public.orders(reseller_id);
create index if not exists idx_orders_customer         on public.orders(customer_id);
create index if not exists idx_orders_email            on public.orders(email);
create index if not exists idx_orders_status           on public.orders(status);
create index if not exists idx_order_items_order       on public.order_items(order_id);
create index if not exists idx_stock_mov_product       on public.stock_movements(product_id);
create index if not exists idx_stock_mov_reseller      on public.stock_movements(reseller_id);
create index if not exists idx_stock_mov_ref           on public.stock_movements(reference_type, reference_id);
create index if not exists idx_loyalty_acct_customer   on public.loyalty_accounts(customer_id);
create index if not exists idx_loyalty_txn_account     on public.loyalty_transactions(account_id);
create index if not exists idx_activity_actor          on public.activity_logs(actor_profile_id);
create index if not exists idx_activity_entity         on public.activity_logs(entity_type, entity_id);
create index if not exists idx_activity_created        on public.activity_logs(created_at desc);

-- One inventory row per (product, owner). NULL reseller collapses to the
-- all-zero uuid so central stock is also unique.
create unique index if not exists uq_inventory_owner_product
  on public.inventory (product_id, coalesce(reseller_id,'00000000-0000-0000-0000-000000000000'::uuid))
  where deleted_at is null;

-- =====================================================================
-- 5. Attach audit trigger + enable RLS + soft-delete index on all tables
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array[
    'businesses','profiles','admins','resellers','customers','products',
    'inventory','sales','sale_items','payments','orders','order_items',
    'stock_movements','loyalty_accounts','loyalty_transactions','activity_logs'
  ] loop
    execute format('alter table public.%I enable row level security;', t);
    execute format('drop trigger if exists trg_audit on public.%I;', t);
    execute format('create trigger trg_audit before insert or update on public.%I
                    for each row execute function public.tg_set_audit();', t);
    execute format('create index if not exists idx_%s_deleted_at on public.%I (deleted_at) where deleted_at is null;', t, t);
  end loop;
end $$;

-- =====================================================================
-- 6. Business-logic triggers & functions
-- =====================================================================

-- 6.1 Auto-create a profile when a Supabase auth user is created.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
begin
  insert into public.profiles (user_id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
    coalesce((new.raw_user_meta_data->>'role')::public.user_role, 'customer')
  )
  on conflict (user_id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 6.2 Decrement inventory + write a stock movement when a sale line lands.
create or replace function public.tg_sale_item_stock()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_reseller uuid;
  v_business uuid;
  v_balance  integer;
begin
  select reseller_id, business_id into v_reseller, v_business
    from public.sales where id = new.sale_id;

  update public.inventory
     set quantity = quantity - new.quantity
   where product_id = new.product_id
     and reseller_id is not distinct from v_reseller
     and deleted_at is null
  returning quantity into v_balance;

  insert into public.stock_movements
    (business_id, reseller_id, product_id, movement_type, quantity,
     balance_after, reference_type, reference_id, reason, created_by, updated_by)
  values
    (v_business, v_reseller, new.product_id, 'sale', -new.quantity,
     v_balance, 'sale', new.sale_id, 'Sale line item', new.created_by, new.updated_by);

  return new;
end $$;

drop trigger if exists trg_sale_item_stock on public.sale_items;
create trigger trg_sale_item_stock
  after insert on public.sale_items
  for each row execute function public.tg_sale_item_stock();

-- 6.3 Recalculate sale header totals whenever its items change.
create or replace function public.tg_recalc_sale_totals()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_sale uuid; v_sub numeric;
begin
  v_sale := coalesce(new.sale_id, old.sale_id);
  select coalesce(sum(line_total),0) into v_sub
    from public.sale_items where sale_id = v_sale and deleted_at is null;

  update public.sales
     set subtotal = v_sub,
         total    = v_sub - discount
   where id = v_sale;
  return null;
end $$;

drop trigger if exists trg_recalc_sale_totals on public.sale_items;
create trigger trg_recalc_sale_totals
  after insert or update or delete on public.sale_items
  for each row execute function public.tg_recalc_sale_totals();

-- 6.4 Roll payments up onto the sale (amount_paid + payment_status).
create or replace function public.tg_apply_payment()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_sale uuid; v_paid numeric; v_total numeric;
begin
  v_sale := coalesce(new.sale_id, old.sale_id);
  if v_sale is null then return null; end if;

  select coalesce(sum(amount),0) into v_paid
    from public.payments
   where sale_id = v_sale and status = 'completed' and deleted_at is null;

  select total into v_total from public.sales where id = v_sale;

  update public.sales
     set amount_paid = v_paid,
         payment_status = (case
           when v_paid <= 0            then 'pending'
           when v_paid >= v_total      then 'completed'
           else                             'partial'
         end)::public.payment_status
   where id = v_sale;
  return null;
end $$;

drop trigger if exists trg_apply_payment on public.payments;
create trigger trg_apply_payment
  after insert or update or delete on public.payments
  for each row execute function public.tg_apply_payment();

-- 6.5 Accrue loyalty points (1 point / currency unit) on completed payment.
create or replace function public.tg_accrue_loyalty()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_acct uuid; v_bal integer; v_pts integer;
begin
  if new.customer_id is null or new.status <> 'completed' then return new; end if;
  v_pts := floor(new.amount)::int;
  if v_pts <= 0 then return new; end if;

  insert into public.loyalty_accounts (business_id, customer_id, created_by, updated_by)
  values (new.business_id, new.customer_id, new.created_by, new.updated_by)
  on conflict (customer_id) do nothing;

  update public.loyalty_accounts
     set points_balance  = points_balance + v_pts,
         lifetime_points = lifetime_points + v_pts,
         tier = (case
           when lifetime_points + v_pts >= 5000 then 'platinum'
           when lifetime_points + v_pts >= 2000 then 'gold'
           when lifetime_points + v_pts >= 500  then 'silver'
           else 'bronze' end)::public.loyalty_tier
   where customer_id = new.customer_id
  returning id, points_balance into v_acct, v_bal;

  insert into public.loyalty_transactions
    (account_id, customer_id, txn_type, points, balance_after,
     reference_type, reference_id, description, created_by, updated_by)
  values
    (v_acct, new.customer_id, 'earn', v_pts, v_bal,
     'payment', new.id, 'Points earned on payment', new.created_by, new.updated_by);
  return new;
end $$;

drop trigger if exists trg_accrue_loyalty on public.payments;
create trigger trg_accrue_loyalty
  after insert on public.payments
  for each row execute function public.tg_accrue_loyalty();

-- 6.6 Recalculate order totals when its items change.
create or replace function public.tg_recalc_order_totals()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_order uuid; v_sub numeric; v_thresh numeric;
begin
  v_order := coalesce(new.order_id, old.order_id);
  select coalesce(sum(line_total),0) into v_sub
    from public.order_items where order_id = v_order and deleted_at is null;

  select coalesce(b.free_delivery_threshold, 250) into v_thresh
    from public.orders o left join public.businesses b on b.id = o.business_id
   where o.id = v_order;

  update public.orders
     set subtotal = v_sub,
         delivery_fee = case when v_sub >= coalesce(v_thresh,250) then 0 else delivery_fee end,
         total = v_sub - discount
                 + case when v_sub >= coalesce(v_thresh,250) then 0 else delivery_fee end
   where id = v_order;
  return null;
end $$;

drop trigger if exists trg_recalc_order_totals on public.order_items;
create trigger trg_recalc_order_totals
  after insert or update or delete on public.order_items
  for each row execute function public.tg_recalc_order_totals();

-- =====================================================================
-- 7. Row Level Security policies
--    Admins: full access on every table. Resellers: own rows only.
-- =====================================================================

-- 7.1 businesses ------------------------------------------------------
drop policy if exists businesses_admin_all on public.businesses;
create policy businesses_admin_all on public.businesses
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists businesses_member_read on public.businesses;
create policy businesses_member_read on public.businesses
  for select using (
    deleted_at is null and id in (select business_id from public.profiles where user_id = auth.uid())
  );

-- 7.2 profiles --------------------------------------------------------
drop policy if exists profiles_admin_all on public.profiles;
create policy profiles_admin_all on public.profiles
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists profiles_self_read on public.profiles;
create policy profiles_self_read on public.profiles
  for select using (user_id = auth.uid() and deleted_at is null);
drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update on public.profiles
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 7.3 admins ----------------------------------------------------------
drop policy if exists admins_admin_all on public.admins;
create policy admins_admin_all on public.admins
  for all using (public.is_admin()) with check (public.is_admin());

-- 7.4 resellers -------------------------------------------------------
drop policy if exists resellers_admin_all on public.resellers;
create policy resellers_admin_all on public.resellers
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists resellers_self_read on public.resellers;
create policy resellers_self_read on public.resellers
  for select using (
    deleted_at is null and (
      id = public.current_reseller_id()               -- own record
      or team_leader_id = public.current_reseller_id() -- downline
    )
  );
drop policy if exists resellers_self_update on public.resellers;
create policy resellers_self_update on public.resellers
  for update using (id = public.current_reseller_id())
  with check (id = public.current_reseller_id());

-- 7.5 customers (reseller-owned) -------------------------------------
drop policy if exists customers_admin_all on public.customers;
create policy customers_admin_all on public.customers
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists customers_reseller_select on public.customers;
create policy customers_reseller_select on public.customers
  for select using (reseller_id = public.current_reseller_id() and deleted_at is null);
drop policy if exists customers_reseller_insert on public.customers;
create policy customers_reseller_insert on public.customers
  for insert with check (reseller_id = public.current_reseller_id());
drop policy if exists customers_reseller_update on public.customers;
create policy customers_reseller_update on public.customers
  for update using (reseller_id = public.current_reseller_id())
  with check (reseller_id = public.current_reseller_id());
drop policy if exists customers_reseller_delete on public.customers;
create policy customers_reseller_delete on public.customers
  for delete using (reseller_id = public.current_reseller_id());

-- 7.6 products (catalog: public read, admin write) -------------------
drop policy if exists products_admin_all on public.products;
create policy products_admin_all on public.products
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists products_public_read on public.products;
create policy products_public_read on public.products
  for select using (is_active = true and deleted_at is null);

-- 7.7 inventory (reseller-owned; central stock is admin-only) --------
drop policy if exists inventory_admin_all on public.inventory;
create policy inventory_admin_all on public.inventory
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists inventory_reseller_select on public.inventory;
create policy inventory_reseller_select on public.inventory
  for select using (reseller_id = public.current_reseller_id() and deleted_at is null);
drop policy if exists inventory_reseller_insert on public.inventory;
create policy inventory_reseller_insert on public.inventory
  for insert with check (reseller_id = public.current_reseller_id());
drop policy if exists inventory_reseller_update on public.inventory;
create policy inventory_reseller_update on public.inventory
  for update using (reseller_id = public.current_reseller_id())
  with check (reseller_id = public.current_reseller_id());
drop policy if exists inventory_reseller_delete on public.inventory;
create policy inventory_reseller_delete on public.inventory
  for delete using (reseller_id = public.current_reseller_id());

-- 7.8 sales -----------------------------------------------------------
drop policy if exists sales_admin_all on public.sales;
create policy sales_admin_all on public.sales
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists sales_reseller_select on public.sales;
create policy sales_reseller_select on public.sales
  for select using (reseller_id = public.current_reseller_id() and deleted_at is null);
drop policy if exists sales_reseller_insert on public.sales;
create policy sales_reseller_insert on public.sales
  for insert with check (reseller_id = public.current_reseller_id());
drop policy if exists sales_reseller_update on public.sales;
create policy sales_reseller_update on public.sales
  for update using (reseller_id = public.current_reseller_id())
  with check (reseller_id = public.current_reseller_id());
drop policy if exists sales_reseller_delete on public.sales;
create policy sales_reseller_delete on public.sales
  for delete using (reseller_id = public.current_reseller_id());

-- 7.9 sale_items (scoped through the parent sale) --------------------
drop policy if exists sale_items_admin_all on public.sale_items;
create policy sale_items_admin_all on public.sale_items
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists sale_items_reseller_select on public.sale_items;
create policy sale_items_reseller_select on public.sale_items
  for select using (
    deleted_at is null and exists (
      select 1 from public.sales s
      where s.id = sale_items.sale_id and s.reseller_id = public.current_reseller_id()
    )
  );
drop policy if exists sale_items_reseller_write on public.sale_items;
create policy sale_items_reseller_write on public.sale_items
  for all using (
    exists (select 1 from public.sales s where s.id = sale_items.sale_id and s.reseller_id = public.current_reseller_id())
  ) with check (
    exists (select 1 from public.sales s where s.id = sale_items.sale_id and s.reseller_id = public.current_reseller_id())
  );

-- 7.10 payments -------------------------------------------------------
drop policy if exists payments_admin_all on public.payments;
create policy payments_admin_all on public.payments
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists payments_reseller_select on public.payments;
create policy payments_reseller_select on public.payments
  for select using (reseller_id = public.current_reseller_id() and deleted_at is null);
drop policy if exists payments_reseller_insert on public.payments;
create policy payments_reseller_insert on public.payments
  for insert with check (reseller_id = public.current_reseller_id());
drop policy if exists payments_reseller_update on public.payments;
create policy payments_reseller_update on public.payments
  for update using (reseller_id = public.current_reseller_id())
  with check (reseller_id = public.current_reseller_id());
drop policy if exists payments_reseller_delete on public.payments;
create policy payments_reseller_delete on public.payments
  for delete using (reseller_id = public.current_reseller_id());

-- 7.11 orders (admin all; reseller own wholesale; customer own) ------
drop policy if exists orders_admin_all on public.orders;
create policy orders_admin_all on public.orders
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists orders_reseller_select on public.orders;
create policy orders_reseller_select on public.orders
  for select using (reseller_id = public.current_reseller_id() and deleted_at is null);
drop policy if exists orders_customer_select on public.orders;
create policy orders_customer_select on public.orders
  for select using (profile_id = public.current_profile_id() and deleted_at is null);

-- 7.12 order_items (through parent order) ----------------------------
drop policy if exists order_items_admin_all on public.order_items;
create policy order_items_admin_all on public.order_items
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists order_items_owner_select on public.order_items;
create policy order_items_owner_select on public.order_items
  for select using (
    deleted_at is null and exists (
      select 1 from public.orders o
      where o.id = order_items.order_id and (
        o.reseller_id = public.current_reseller_id()
        or o.profile_id = public.current_profile_id()
      )
    )
  );

-- 7.13 stock_movements (reseller sees own) ---------------------------
drop policy if exists stock_mov_admin_all on public.stock_movements;
create policy stock_mov_admin_all on public.stock_movements
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists stock_mov_reseller_select on public.stock_movements;
create policy stock_mov_reseller_select on public.stock_movements
  for select using (reseller_id = public.current_reseller_id() and deleted_at is null);
drop policy if exists stock_mov_reseller_insert on public.stock_movements;
create policy stock_mov_reseller_insert on public.stock_movements
  for insert with check (reseller_id = public.current_reseller_id());

-- 7.14 loyalty_accounts (via the owning reseller's customer) ---------
drop policy if exists loyalty_acct_admin_all on public.loyalty_accounts;
create policy loyalty_acct_admin_all on public.loyalty_accounts
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists loyalty_acct_reseller_select on public.loyalty_accounts;
create policy loyalty_acct_reseller_select on public.loyalty_accounts
  for select using (
    deleted_at is null and exists (
      select 1 from public.customers c
      where c.id = loyalty_accounts.customer_id and c.reseller_id = public.current_reseller_id()
    )
  );

-- 7.15 loyalty_transactions ------------------------------------------
drop policy if exists loyalty_txn_admin_all on public.loyalty_transactions;
create policy loyalty_txn_admin_all on public.loyalty_transactions
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists loyalty_txn_reseller_select on public.loyalty_transactions;
create policy loyalty_txn_reseller_select on public.loyalty_transactions
  for select using (
    deleted_at is null and exists (
      select 1 from public.customers c
      where c.id = loyalty_transactions.customer_id and c.reseller_id = public.current_reseller_id()
    )
  );

-- 7.16 activity_logs -------------------------------------------------
drop policy if exists activity_admin_all on public.activity_logs;
create policy activity_admin_all on public.activity_logs
  for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists activity_reseller_select on public.activity_logs;
create policy activity_reseller_select on public.activity_logs
  for select using (actor_reseller_id = public.current_reseller_id() and deleted_at is null);
drop policy if exists activity_self_insert on public.activity_logs;
create policy activity_self_insert on public.activity_logs
  for insert with check (
    actor_profile_id = public.current_profile_id()
    or actor_reseller_id = public.current_reseller_id()
    or public.is_admin()
  );

-- =====================================================================
-- 8. Reporting views  (security_invoker => each caller's RLS applies,
--    so a reseller only ever sees their own aggregated data)
-- =====================================================================

-- 8.1 Public product catalog (matches GET /api/products).
create or replace view public.v_product_catalog
  with (security_invoker = true) as
select id, sku, name, slug, line, inspired_by, fragrance_family, character,
       description, notes_top, notes_heart, notes_base, size_ml, concentration,
       retail_price, recommended_sell_price, emoji, image_url, accent_color,
       is_bundle, bundle_size, is_featured, sort_order
from public.products
where is_active = true and deleted_at is null
order by line, sort_order, name;

-- 8.2 Inventory status with low-stock flag.
create or replace view public.v_inventory_status
  with (security_invoker = true) as
select i.id, i.reseller_id, i.product_id, p.name as product_name, p.line,
       i.quantity, i.reserved_quantity,
       (i.quantity - i.reserved_quantity) as available,
       i.reorder_level,
       (i.quantity <= i.reorder_level) as is_low_stock,
       (i.quantity * p.retail_price)   as retail_value,
       (i.quantity * p.wholesale_price) as wholesale_value
from public.inventory i
join public.products p on p.id = i.product_id
where i.deleted_at is null;

-- 8.3 Low-stock shortlist.
create or replace view public.v_low_stock
  with (security_invoker = true) as
select * from public.v_inventory_status where is_low_stock;

-- 8.4 Customer balances (credit owed).
create or replace view public.v_customer_balances
  with (security_invoker = true) as
select c.id as customer_id, c.reseller_id, c.full_name, c.phone,
       coalesce(s.total_sales,0)      as total_sales,
       coalesce(s.total_paid,0)       as total_paid,
       coalesce(s.total_sales,0) - coalesce(s.total_paid,0) as balance_due
from public.customers c
left join (
  select customer_id,
         sum(total)       as total_sales,
         sum(amount_paid) as total_paid
  from public.sales
  where deleted_at is null and status <> 'cancelled'
  group by customer_id
) s on s.customer_id = c.id
where c.deleted_at is null;

-- 8.5 Per-reseller sales summary (report).
create or replace view public.v_reseller_sales_summary
  with (security_invoker = true) as
select r.id as reseller_id, r.reseller_code, r.display_name,
       count(s.id)                                          as sales_count,
       coalesce(sum(s.total),0)                             as gross_sales,
       coalesce(sum(s.amount_paid),0)                       as collected,
       coalesce(sum(s.total - s.amount_paid),0)             as outstanding,
       coalesce(sum(s.total) filter (where s.sold_at >= date_trunc('month', now())),0) as sales_this_month
from public.resellers r
left join public.sales s on s.reseller_id = r.id and s.deleted_at is null and s.status <> 'cancelled'
where r.deleted_at is null
group by r.id, r.reseller_code, r.display_name;

-- 8.6 Sales with their line items rolled up as JSON (detail report).
create or replace view public.v_sales_detail
  with (security_invoker = true) as
select s.*, c.full_name as customer_name,
       coalesce(jsonb_agg(jsonb_build_object(
         'product_id', si.product_id, 'description', si.description,
         'quantity', si.quantity, 'unit_price', si.unit_price, 'line_total', si.line_total
       )) filter (where si.id is not null), '[]'::jsonb) as items
from public.sales s
left join public.customers c on c.id = s.customer_id
left join public.sale_items si on si.sale_id = s.id and si.deleted_at is null
where s.deleted_at is null
group by s.id, c.full_name;

-- 8.7 Team-leader downline + override base (passive earnings report).
create or replace view public.v_team_downline
  with (security_invoker = true) as
select tl.id as team_leader_id, tl.reseller_code as leader_code,
       d.id as downline_id, d.reseller_code as downline_code, d.display_name,
       d.override_rate,
       coalesce(sum(o.total) filter (where o.order_type = 'wholesale'),0) as downline_wholesale_purchases,
       coalesce(sum(o.total) filter (where o.order_type = 'wholesale'),0) * coalesce(d.override_rate,0)/100 as override_earned
from public.resellers tl
join public.resellers d on d.team_leader_id = tl.id and d.deleted_at is null
left join public.orders o on o.reseller_id = d.id and o.deleted_at is null
where tl.deleted_at is null
group by tl.id, tl.reseller_code, d.id, d.reseller_code, d.display_name, d.override_rate;

-- 8.8 Reseller dashboard (headline KPIs).
create or replace view public.v_reseller_dashboard
  with (security_invoker = true) as
select r.id as reseller_id,
       ss.gross_sales, ss.collected, ss.outstanding, ss.sales_this_month, ss.sales_count,
       (select count(*) from public.customers c where c.reseller_id = r.id and c.deleted_at is null) as customer_count,
       (select coalesce(sum(quantity),0) from public.inventory i where i.reseller_id = r.id and i.deleted_at is null) as units_in_stock,
       (select count(*) from public.v_low_stock ls where ls.reseller_id = r.id) as low_stock_items
from public.resellers r
left join public.v_reseller_sales_summary ss on ss.reseller_id = r.id
where r.deleted_at is null;

-- =====================================================================
-- 9. Grants  (RLS still governs row visibility for anon / authenticated)
-- =====================================================================
grant usage on schema public to anon, authenticated, service_role;

grant select on public.products, public.v_product_catalog to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant select on all tables in schema public to anon;         -- gated by RLS; only products policy admits rows
grant all on all tables in schema public to service_role;    -- backend bypasses RLS
grant usage, select on all sequences in schema public to authenticated, service_role;

alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public grant all on tables to service_role;

-- =====================================================================
--  End of Mellow George schema.
-- =====================================================================
