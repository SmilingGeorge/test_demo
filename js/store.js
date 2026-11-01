// Scentry data store — localStorage persistence, no backend required.
// Data model:
//   customers: { id, name, phone, note, createdAt }
//   products:  { id, name, brand, size, cost, price, stock, createdAt }
//   sales:     { id, customerId, items:[{productId, name, qty, price}], total, paid, createdAt }
//   payments:  { id, customerId, amount, note, createdAt }
// A customer's outstanding credit = Σ(sale.total − sale.paid) − Σ(payment.amount).

const KEY = 'scentry.db.v1';

const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
const now = () => new Date().toISOString();

function seed() {
  const t = Date.now();
  const day = 86400000;
  const iso = (offset) => new Date(t - offset * day).toISOString();

  const products = [
    { id: uid(), name: 'Oud Royale', brand: 'Maison Noir', size: 100, cost: 22, price: 55, stock: 14, createdAt: iso(30) },
    { id: uid(), name: 'Rose Absolue', brand: 'Fleur', size: 50, cost: 15, price: 40, stock: 6, createdAt: iso(28) },
    { id: uid(), name: 'Citrus Bloom', brand: 'Aqua', size: 75, cost: 12, price: 32, stock: 3, createdAt: iso(20) },
    { id: uid(), name: 'Amber Nuit', brand: 'Maison Noir', size: 100, cost: 25, price: 60, stock: 9, createdAt: iso(18) },
    { id: uid(), name: 'Vanilla Musk', brand: 'Fleur', size: 50, cost: 10, price: 28, stock: 2, createdAt: iso(12) }
  ];
  const customers = [
    { id: uid(), name: 'Amina Yusuf', phone: '0712 445 118', note: 'Prefers oud & amber', createdAt: iso(26) },
    { id: uid(), name: 'David Okoro', phone: '0803 221 907', note: '', createdAt: iso(21) },
    { id: uid(), name: 'Grace Wangui', phone: '0722 908 334', note: 'Buys for resale', createdAt: iso(15) },
    { id: uid(), name: 'Samuel Otieno', phone: '0733 654 210', note: '', createdAt: iso(9) }
  ];

  const p = (i) => products[i];
  const c = (i) => customers[i];
  const line = (prod, qty) => ({ productId: prod.id, name: prod.name, qty, price: prod.price });

  const sales = [
    { id: uid(), customerId: c(0).id, items: [line(p(0), 1)], total: 55, paid: 55, createdAt: iso(6) },
    { id: uid(), customerId: c(2).id, items: [line(p(1), 2), line(p(4), 1)], total: 108, paid: 50, createdAt: iso(5) },
    { id: uid(), customerId: c(1).id, items: [line(p(3), 1)], total: 60, paid: 0, createdAt: iso(4) },
    { id: uid(), customerId: c(0).id, items: [line(p(2), 1)], total: 32, paid: 32, createdAt: iso(3) },
    { id: uid(), customerId: c(3).id, items: [line(p(0), 1), line(p(3), 1)], total: 115, paid: 60, createdAt: iso(1) },
    { id: uid(), customerId: c(2).id, items: [line(p(4), 2)], total: 56, paid: 56, createdAt: iso(0) }
  ];
  const payments = [
    { id: uid(), customerId: c(2).id, amount: 30, note: 'Part payment', createdAt: iso(2) }
  ];

  return { customers, products, sales, payments, settings: { currency: 'KSh', lowStock: 5 } };
}

let db = load();

function load() {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) return JSON.parse(raw);
  } catch (e) { /* fall through to seed */ }
  const fresh = seed();
  localStorage.setItem(KEY, JSON.stringify(fresh));
  return fresh;
}

function persist() {
  localStorage.setItem(KEY, JSON.stringify(db));
  window.dispatchEvent(new CustomEvent('scentry:change'));
}

export const Store = {
  get currency() { return db.settings.currency; },
  get lowStock() { return db.settings.lowStock; },
  setSettings(patch) { Object.assign(db.settings, patch); persist(); },

  // ---- reads ----
  customers: () => [...db.customers].sort((a, b) => a.name.localeCompare(b.name)),
  products: () => [...db.products].sort((a, b) => a.name.localeCompare(b.name)),
  sales: () => [...db.sales].sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
  payments: () => [...db.payments].sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
  customer: (id) => db.customers.find((c) => c.id === id),
  product: (id) => db.products.find((p) => p.id === id),

  balance(customerId) {
    const owed = db.sales
      .filter((s) => s.customerId === customerId)
      .reduce((sum, s) => sum + (s.total - s.paid), 0);
    const paid = db.payments
      .filter((p) => p.customerId === customerId)
      .reduce((sum, p) => sum + p.amount, 0);
    return owed - paid;
  },

  // ---- customers ----
  addCustomer({ name, phone, note }) {
    db.customers.push({ id: uid(), name: name.trim(), phone: phone.trim(), note: (note || '').trim(), createdAt: now() });
    persist();
  },
  updateCustomer(id, patch) {
    const c = db.customers.find((x) => x.id === id);
    if (c) { Object.assign(c, patch); persist(); }
  },
  deleteCustomer(id) {
    db.customers = db.customers.filter((c) => c.id !== id);
    db.sales = db.sales.filter((s) => s.customerId !== id);
    db.payments = db.payments.filter((p) => p.customerId !== id);
    persist();
  },

  // ---- products ----
  addProduct({ name, brand, size, cost, price, stock }) {
    db.products.push({
      id: uid(), name: name.trim(), brand: (brand || '').trim(),
      size: +size || 0, cost: +cost || 0, price: +price || 0, stock: +stock || 0, createdAt: now()
    });
    persist();
  },
  updateProduct(id, patch) {
    const p = db.products.find((x) => x.id === id);
    if (p) {
      ['size', 'cost', 'price', 'stock'].forEach((k) => { if (k in patch) patch[k] = +patch[k] || 0; });
      Object.assign(p, patch); persist();
    }
  },
  adjustStock(id, delta) {
    const p = db.products.find((x) => x.id === id);
    if (p) { p.stock = Math.max(0, p.stock + delta); persist(); }
  },
  deleteProduct(id) {
    db.products = db.products.filter((p) => p.id !== id);
    persist();
  },

  // ---- sales ----
  // items: [{productId, qty}] — prices & names snapshotted from current product.
  addSale({ customerId, items, paid }) {
    const lines = [];
    let total = 0;
    for (const it of items) {
      const p = db.products.find((x) => x.id === it.productId);
      if (!p || it.qty <= 0) continue;
      const qty = Math.min(it.qty, p.stock);
      if (qty <= 0) continue;
      p.stock -= qty;
      total += qty * p.price;
      lines.push({ productId: p.id, name: p.name, qty, price: p.price });
    }
    if (!lines.length) return null;
    const paidAmount = Math.max(0, Math.min(+paid || 0, total));
    const sale = { id: uid(), customerId, items: lines, total, paid: paidAmount, createdAt: now() };
    db.sales.push(sale);
    persist();
    return sale;
  },
  deleteSale(id) {
    const sale = db.sales.find((s) => s.id === id);
    if (sale) {
      // return stock
      sale.items.forEach((it) => {
        const p = db.products.find((x) => x.id === it.productId);
        if (p) p.stock += it.qty;
      });
      db.sales = db.sales.filter((s) => s.id !== id);
      persist();
    }
  },

  // ---- payments (credit collection) ----
  addPayment({ customerId, amount, note }) {
    db.payments.push({ id: uid(), customerId, amount: Math.max(0, +amount || 0), note: (note || '').trim(), createdAt: now() });
    persist();
  },
  deletePayment(id) {
    db.payments = db.payments.filter((p) => p.id !== id);
    persist();
  },

  // ---- derived metrics ----
  metrics() {
    const totalCredit = db.customers.reduce((s, c) => s + Math.max(0, this.balance(c.id)), 0);
    const invValue = db.products.reduce((s, p) => s + p.stock * p.price, 0);
    const invCost = db.products.reduce((s, p) => s + p.stock * p.cost, 0);
    const lowStock = db.products.filter((p) => p.stock <= db.settings.lowStock).length;
    const monthStart = new Date(); monthStart.setDate(1); monthStart.setHours(0, 0, 0, 0);
    const monthSales = db.sales.filter((s) => new Date(s.createdAt) >= monthStart);
    const monthRevenue = monthSales.reduce((s, x) => s + x.total, 0);
    return {
      customers: db.customers.length,
      products: db.products.length,
      totalCredit, invValue, invCost, lowStock,
      monthRevenue, monthCount: monthSales.length
    };
  },

  // Daily revenue for the last `days` days (oldest → newest).
  dailyRevenue(days = 14) {
    const out = [];
    const base = new Date(); base.setHours(0, 0, 0, 0);
    for (let i = days - 1; i >= 0; i--) {
      const d = new Date(base); d.setDate(base.getDate() - i);
      const next = new Date(d); next.setDate(d.getDate() + 1);
      const total = db.sales
        .filter((s) => { const t = new Date(s.createdAt); return t >= d && t < next; })
        .reduce((sum, s) => sum + s.total, 0);
      out.push({ date: d, total });
    }
    return out;
  },

  // Top products by units sold.
  topProducts(limit = 5) {
    const map = new Map();
    db.sales.forEach((s) => s.items.forEach((it) => {
      const cur = map.get(it.name) || { name: it.name, qty: 0, revenue: 0 };
      cur.qty += it.qty; cur.revenue += it.qty * it.price;
      map.set(it.name, cur);
    }));
    return [...map.values()].sort((a, b) => b.qty - a.qty).slice(0, limit);
  },

  // ---- data management ----
  export() { return JSON.stringify(db, null, 2); },
  import(json) {
    const parsed = JSON.parse(json);
    if (!parsed.customers || !parsed.products) throw new Error('Invalid backup file');
    db = parsed;
    if (!db.settings) db.settings = { currency: 'KSh', lowStock: 5 };
    if (!db.payments) db.payments = [];
    persist();
  },
  reset() { db = seed(); persist(); }
};

export function money(n) {
  const v = Math.round((+n || 0) * 100) / 100;
  return Store.currency + ' ' + v.toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
}

export function fmtDate(iso) {
  const d = new Date(iso);
  return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short' }) +
    ', ' + d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}
