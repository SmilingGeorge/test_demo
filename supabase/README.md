# Mellow George — Supabase / PostgreSQL schema

Complete multi-tenant reseller database for **Mellow George Perfumes**.

## Files

| File | Purpose |
|------|---------|
| `migrations/20260707000000_mellow_george_schema.sql` | Full schema: tables, enums, indexes, RLS policies, triggers, functions, views |
| `seed.sql` | Business row + full product catalog (FOR HER / FOR HIM / Bundles) |

## Tables (16)

`businesses`, `profiles`, `admins`, `resellers`, `customers`, `products`,
`inventory`, `sales`, `sale_items`, `payments`, `orders`, `order_items`,
`stock_movements`, `loyalty_accounts`, `loyalty_transactions`, `activity_logs`.

Every table carries `id (uuid)`, `created_at`, `updated_at`, `deleted_at`
(soft delete), `created_by`, `updated_by`. Timestamps and the `*_by` columns are
filled automatically by the `trg_audit` trigger.

## Access model (Row Level Security)

- **Admins** (`profiles.role = 'admin'`) → full access to every table.
- **Resellers** → only **their own** customers, sales, inventory, payments,
  sale items, stock movements, loyalty and reports (scoped by
  `current_reseller_id()`). Team leaders can additionally read their downline.
- **Anonymous / storefront** → read active products only.
- **Backend (Tornado)** uses the `service_role` key, which bypasses RLS.

Helper functions `is_admin()`, `current_reseller_id()`, `current_profile_id()`
and `is_team_leader_of()` are `SECURITY DEFINER` so policy checks don't recurse.

## Automation (triggers)

- `handle_new_user` — creates a `profiles` row when an `auth.users` row is added.
- `tg_sale_item_stock` — decrements inventory and logs a `stock_movement` per sale line.
- `tg_recalc_sale_totals` / `tg_recalc_order_totals` — keep header totals in sync with line items (order totals apply the R250 free-delivery threshold).
- `tg_apply_payment` — rolls payments up into `sales.amount_paid` / `payment_status`.
- `tg_accrue_loyalty` — awards loyalty points (1 pt / R1) and bumps tier on completed payments.

`wholesale_unit_price(qty)` returns the tiered wholesale price
(R84 → R58 by volume).

## Reporting views (RLS-scoped via `security_invoker`)

`v_product_catalog`, `v_inventory_status`, `v_low_stock`, `v_customer_balances`,
`v_reseller_sales_summary`, `v_sales_detail`, `v_team_downline`,
`v_reseller_dashboard`.

## Apply it

**Supabase CLI (local):**
```bash
supabase db reset          # applies migrations, then seed.sql
```

**Any Postgres:**
```bash
psql "$DATABASE_URL" -f migrations/20260707000000_mellow_george_schema.sql
psql "$DATABASE_URL" -f seed.sql
```

> Requires the Supabase `auth` schema (`auth.users`, `auth.uid()`), which exists
> by default on Supabase. The migration is **idempotent** — safe to re-run.

## Validation

This schema was applied to a clean PostgreSQL cluster and exercised end-to-end:
RLS correctly isolates one reseller's customers/sales/payments from another's;
admins see everything; anon sees only products; and the sale → stock → payment →
loyalty triggers all compute the expected values.
