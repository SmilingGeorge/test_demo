# Scentry — Perfume Seller Manager (PWA)

A lightweight, installable **Progressive Web App** for perfume sellers to run their
business from a phone. Track customers, the credit they owe you, your inventory, and
daily sales — all offline, with no account and no backend.

## Features

- **Dashboard** — KPI cards (outstanding credit, monthly revenue, inventory value,
  low-stock count), a 14-day revenue chart, top products, and recent sales.
- **Customers** — searchable contact book; per-customer balance, full sale/payment
  history, and one-tap "record payment" to collect credit.
- **Credit book** — every customer who owes you, sorted by amount, with running totals.
- **Inventory** — products with brand, size, cost/sell price, live stock and margin;
  quick stock adjustments and low-stock warnings.
- **Sales** — build a cart from in-stock products, take partial or full payment; any
  unpaid balance is automatically added to the customer's credit. Deleting a sale
  restocks the items.
- **Offline-first** — a service worker caches the app shell so it works with no
  network. Data is stored locally on the device (`localStorage`).
- **Backup & restore** — export/import your data as a JSON file (⋯ menu).
- **Installable** — "Add to Home Screen" on Android/iOS/desktop for an app-like
  experience.

## Run it

It's a static site — no build step. Serve the folder over HTTP (a service worker needs
`http://`/`https://`, not `file://`):

```bash
# from the project root
python3 -m http.server 8000
# then open http://localhost:8000
```

Or any static host (GitHub Pages, Netlify, etc.). On first load it seeds a few sample
customers, products and sales so you can explore; use ⋯ → **Reset** to clear them, or
just start adding your own — the sample data only appears on an empty device.

## Tech

Plain HTML, CSS and ES modules — zero dependencies. Charts are hand-rolled inline SVG.
Structure:

```
index.html            app shell + bottom tab navigation
css/styles.css        mobile-first theme (dark + light)
js/store.js           data model & localStorage persistence
js/charts.js          inline-SVG revenue & top-product charts
js/app.js             views, routing, modals, forms
service-worker.js     offline caching
manifest.webmanifest  PWA install metadata
```

## Data & privacy

All data lives on the device in `localStorage`. Clearing browser data removes it, so
export a backup periodically from the ⋯ menu.
