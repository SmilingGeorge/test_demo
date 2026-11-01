import { Store, money, fmtDate } from './store.js';
import { barTrend, hBar } from './charts.js';

const app = document.getElementById('view');
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// ---------- toast ----------
function toast(msg) {
  let t = document.getElementById('toast');
  if (!t) { t = document.createElement('div'); t.id = 'toast'; document.body.appendChild(t); }
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.classList.remove('show'), 2200);
}

// ---------- modal ----------
function modal(title, bodyHTML, onMount) {
  closeModal();
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.id = 'modal';
  overlay.innerHTML = `
    <div class="modal" role="dialog" aria-modal="true" aria-label="${esc(title)}">
      <header class="modal-head">
        <h2>${esc(title)}</h2>
        <button class="icon-btn" data-close aria-label="Close">✕</button>
      </header>
      <div class="modal-body">${bodyHTML}</div>
    </div>`;
  document.body.appendChild(overlay);
  overlay.addEventListener('click', (e) => { if (e.target === overlay || e.target.hasAttribute('data-close')) closeModal(); });
  document.addEventListener('keydown', escClose);
  if (onMount) onMount(overlay);
  const first = overlay.querySelector('input, select, textarea, button:not([data-close])');
  if (first) first.focus();
}
function escClose(e) { if (e.key === 'Escape') closeModal(); }
function closeModal() {
  const m = document.getElementById('modal');
  if (m) m.remove();
  document.removeEventListener('keydown', escClose);
}

function confirmDialog(msg, onYes) {
  modal('Please confirm', `
    <p class="confirm-msg">${esc(msg)}</p>
    <div class="form-actions">
      <button class="btn ghost" data-close>Cancel</button>
      <button class="btn danger" id="confirm-yes">Delete</button>
    </div>`, (o) => {
    o.querySelector('#confirm-yes').addEventListener('click', () => { closeModal(); onYes(); });
  });
}

// ---------- routing ----------
const routes = ['dashboard', 'customers', 'inventory', 'sales', 'credit'];
function currentRoute() {
  const r = location.hash.replace('#/', '').split('/')[0];
  return routes.includes(r) ? r : 'dashboard';
}
function navigate() { render(); }
window.addEventListener('hashchange', navigate);
window.addEventListener('scentry:change', () => render());

function render() {
  const route = currentRoute();
  document.querySelectorAll('.nav-item').forEach((n) =>
    n.classList.toggle('active', n.dataset.route === route));
  ({ dashboard: viewDashboard, customers: viewCustomers, inventory: viewInventory, sales: viewSales, credit: viewCredit }[route])();
}

// ---------- Dashboard ----------
function viewDashboard() {
  const m = Store.metrics();
  app.innerHTML = `
    <div class="page-head">
      <div><h1>Dashboard</h1><p class="sub">Your business at a glance</p></div>
      <button class="btn primary" id="quick-sale">+ New sale</button>
    </div>
    <div class="kpis">
      ${kpi('Outstanding credit', money(m.totalCredit), m.totalCredit > 0 ? 'warn' : 'ok', 'Owed by customers')}
      ${kpi('Revenue this month', money(m.monthRevenue), 'ok', m.monthCount + ' sale' + (m.monthCount === 1 ? '' : 's'))}
      ${kpi('Inventory value', money(m.invValue), 'neutral', m.products + ' products in stock')}
      ${kpi('Low stock', String(m.lowStock), m.lowStock ? 'warn' : 'ok', '≤ ' + Store.lowStock + ' units left')}
    </div>
    <div class="grid-2">
      <section class="card">
        <div class="card-head"><h2>Revenue · last 14 days</h2></div>
        <div id="chart-trend" class="chart"></div>
      </section>
      <section class="card">
        <div class="card-head"><h2>Top products</h2></div>
        <div id="chart-top" class="chart"></div>
      </section>
    </div>
    <section class="card">
      <div class="card-head"><h2>Recent sales</h2><a href="#/sales" class="link">View all</a></div>
      ${salesTable(Store.sales().slice(0, 6))}
    </section>`;
  barTrend(document.getElementById('chart-trend'), Store.dailyRevenue(14));
  hBar(document.getElementById('chart-top'), Store.topProducts(5));
  document.getElementById('quick-sale').addEventListener('click', saleForm);
}

function kpi(label, value, tone, hint) {
  return `<div class="kpi ${tone}">
    <span class="kpi-label">${esc(label)}</span>
    <span class="kpi-value">${esc(value)}</span>
    <span class="kpi-hint">${esc(hint)}</span>
  </div>`;
}

// ---------- Customers ----------
function viewCustomers() {
  const list = Store.customers();
  app.innerHTML = `
    <div class="page-head">
      <div><h1>Customers</h1><p class="sub">${list.length} total</p></div>
      <button class="btn primary" id="add-customer">+ Add customer</button>
    </div>
    <input class="search" id="cust-search" placeholder="Search by name or phone…" aria-label="Search customers">
    <div class="list" id="cust-list">${list.map(customerRow).join('') || emptyState('No customers yet.')}</div>`;

  document.getElementById('add-customer').addEventListener('click', () => customerForm());
  document.getElementById('cust-search').addEventListener('input', (e) => {
    const q = e.target.value.toLowerCase();
    const filtered = list.filter((c) => c.name.toLowerCase().includes(q) || c.phone.toLowerCase().includes(q));
    document.getElementById('cust-list').innerHTML = filtered.map(customerRow).join('') || emptyState('No matches.');
    bindCustomerRows();
  });
  bindCustomerRows();
}

function customerRow(c) {
  const bal = Store.balance(c.id);
  const owes = bal > 0.005;
  return `<div class="list-row" data-cust="${c.id}">
    <div class="avatar">${esc(c.name.slice(0, 1).toUpperCase())}</div>
    <div class="row-main">
      <span class="row-title">${esc(c.name)}</span>
      <span class="row-sub">${esc(c.phone || 'No phone')}${c.note ? ' · ' + esc(c.note) : ''}</span>
    </div>
    <div class="row-end">
      ${owes ? `<span class="pill warn">${money(bal)} owed</span>` : `<span class="pill ok">Clear</span>`}
    </div>
  </div>`;
}

function bindCustomerRows() {
  document.querySelectorAll('#cust-list .list-row').forEach((row) =>
    row.addEventListener('click', () => customerDetail(row.dataset.cust)));
}

function customerForm(existing) {
  const c = existing || { name: '', phone: '', note: '' };
  modal(existing ? 'Edit customer' : 'Add customer', `
    <form id="cust-form" class="form">
      <label>Name<input name="name" required value="${esc(c.name)}" autocomplete="off"></label>
      <label>Phone<input name="phone" value="${esc(c.phone)}" inputmode="tel" autocomplete="off"></label>
      <label>Note<textarea name="note" rows="2">${esc(c.note)}</textarea></label>
      <div class="form-actions">
        <button type="button" class="btn ghost" data-close>Cancel</button>
        <button type="submit" class="btn primary">${existing ? 'Save' : 'Add'}</button>
      </div>
    </form>`, (o) => {
    o.querySelector('#cust-form').addEventListener('submit', (e) => {
      e.preventDefault();
      const f = new FormData(e.target);
      const data = { name: f.get('name'), phone: f.get('phone'), note: f.get('note') };
      if (!data.name.trim()) return;
      if (existing) { Store.updateCustomer(existing.id, data); toast('Customer updated'); }
      else { Store.addCustomer(data); toast('Customer added'); }
      closeModal();
    });
  });
}

function customerDetail(id) {
  const c = Store.customer(id);
  if (!c) return;
  const bal = Store.balance(id);
  const sales = Store.sales().filter((s) => s.customerId === id);
  const payments = Store.payments().filter((p) => p.customerId === id);
  const history = [
    ...sales.map((s) => ({ t: s.createdAt, type: 'sale', label: s.items.map((i) => `${i.qty}× ${i.name}`).join(', '), amt: s.total, paid: s.paid })),
    ...payments.map((p) => ({ t: p.createdAt, type: 'payment', label: p.note || 'Payment received', amt: p.amount }))
  ].sort((a, b) => b.t.localeCompare(a.t));

  modal(c.name, `
    <div class="detail-head">
      <div>
        <p class="detail-sub">${esc(c.phone || 'No phone')}</p>
        ${c.note ? `<p class="detail-note">${esc(c.note)}</p>` : ''}
      </div>
      <div class="balance ${bal > 0.005 ? 'warn' : 'ok'}">
        <span>${bal > 0.005 ? 'Owes you' : 'Balance'}</span>
        <strong>${money(Math.max(0, bal))}</strong>
      </div>
    </div>
    <div class="btn-row">
      <button class="btn primary" id="c-sale">+ Sale</button>
      <button class="btn ok" id="c-pay" ${bal > 0.005 ? '' : 'disabled'}>Record payment</button>
      <button class="btn ghost" id="c-edit">Edit</button>
      <button class="btn danger" id="c-del">Delete</button>
    </div>
    <h3 class="section-label">History</h3>
    <div class="history">
      ${history.length ? history.map((h) => `
        <div class="hist-row">
          <span class="hist-icon ${h.type}">${h.type === 'sale' ? '🛍️' : '💵'}</span>
          <div class="hist-main">
            <span>${esc(h.label)}</span>
            <span class="hist-date">${fmtDate(h.t)}</span>
          </div>
          <span class="hist-amt ${h.type}">${h.type === 'payment' ? '−' : ''}${money(h.amt)}${h.type === 'sale' && h.paid < h.amt ? `<em>${money(h.amt - h.paid)} credit</em>` : ''}</span>
        </div>`).join('') : emptyState('No activity yet.')}
    </div>`, (o) => {
    o.querySelector('#c-sale').addEventListener('click', () => saleForm(id));
    o.querySelector('#c-edit').addEventListener('click', () => customerForm(c));
    const pay = o.querySelector('#c-pay');
    if (pay && !pay.disabled) pay.addEventListener('click', () => paymentForm(id, bal));
    o.querySelector('#c-del').addEventListener('click', () =>
      confirmDialog(`Delete ${c.name}? This also removes their sales and payments.`, () => { Store.deleteCustomer(id); toast('Customer deleted'); closeModal(); }));
  });
}

function paymentForm(customerId, bal) {
  modal('Record payment', `
    <form id="pay-form" class="form">
      <p class="hint-line">Outstanding: <strong>${money(Math.max(0, bal))}</strong></p>
      <label>Amount received<input name="amount" type="number" min="0" step="any" value="${Math.max(0, bal)}" required></label>
      <label>Note<input name="note" placeholder="Optional"></label>
      <div class="form-actions">
        <button type="button" class="btn ghost" data-close>Cancel</button>
        <button type="submit" class="btn ok">Record</button>
      </div>
    </form>`, (o) => {
    o.querySelector('#pay-form').addEventListener('submit', (e) => {
      e.preventDefault();
      const f = new FormData(e.target);
      const amount = +f.get('amount');
      if (amount <= 0) return;
      Store.addPayment({ customerId, amount, note: f.get('note') });
      toast('Payment recorded');
      closeModal();
    });
  });
}

// ---------- Inventory ----------
function viewInventory() {
  const products = Store.products();
  app.innerHTML = `
    <div class="page-head">
      <div><h1>Inventory</h1><p class="sub">${products.length} products</p></div>
      <button class="btn primary" id="add-product">+ Add product</button>
    </div>
    <input class="search" id="prod-search" placeholder="Search products…" aria-label="Search products">
    <div class="list" id="prod-list">${products.map(productRow).join('') || emptyState('No products yet.')}</div>`;

  document.getElementById('add-product').addEventListener('click', () => productForm());
  document.getElementById('prod-search').addEventListener('input', (e) => {
    const q = e.target.value.toLowerCase();
    const filtered = products.filter((p) => (p.name + ' ' + p.brand).toLowerCase().includes(q));
    document.getElementById('prod-list').innerHTML = filtered.map(productRow).join('') || emptyState('No matches.');
    bindProductRows();
  });
  bindProductRows();
}

function productRow(p) {
  const low = p.stock <= Store.lowStock;
  return `<div class="list-row" data-prod="${p.id}">
    <div class="row-main">
      <span class="row-title">${esc(p.name)} <span class="muted">${p.size ? p.size + 'ml' : ''}</span></span>
      <span class="row-sub">${esc(p.brand || '—')} · ${money(p.price)}</span>
    </div>
    <div class="row-end">
      <span class="stock ${low ? 'warn' : 'ok'}">${p.stock} <em>in stock</em></span>
    </div>
  </div>`;
}

function bindProductRows() {
  document.querySelectorAll('#prod-list .list-row').forEach((row) =>
    row.addEventListener('click', () => productDetail(row.dataset.prod)));
}

function productForm(existing) {
  const p = existing || { name: '', brand: '', size: '', cost: '', price: '', stock: '' };
  modal(existing ? 'Edit product' : 'Add product', `
    <form id="prod-form" class="form">
      <label>Name<input name="name" required value="${esc(p.name)}" autocomplete="off"></label>
      <label>Brand<input name="brand" value="${esc(p.brand)}" autocomplete="off"></label>
      <div class="form-cols">
        <label>Size (ml)<input name="size" type="number" min="0" value="${esc(p.size)}"></label>
        <label>Stock (units)<input name="stock" type="number" min="0" value="${esc(p.stock)}"></label>
      </div>
      <div class="form-cols">
        <label>Cost price<input name="cost" type="number" min="0" step="any" value="${esc(p.cost)}"></label>
        <label>Sell price<input name="price" type="number" min="0" step="any" value="${esc(p.price)}" required></label>
      </div>
      <div class="form-actions">
        <button type="button" class="btn ghost" data-close>Cancel</button>
        <button type="submit" class="btn primary">${existing ? 'Save' : 'Add'}</button>
      </div>
    </form>`, (o) => {
    o.querySelector('#prod-form').addEventListener('submit', (e) => {
      e.preventDefault();
      const f = new FormData(e.target);
      const data = { name: f.get('name'), brand: f.get('brand'), size: f.get('size'), cost: f.get('cost'), price: f.get('price'), stock: f.get('stock') };
      if (!data.name.trim()) return;
      if (existing) { Store.updateProduct(existing.id, data); toast('Product updated'); }
      else { Store.addProduct(data); toast('Product added'); }
      closeModal();
    });
  });
}

function productDetail(id) {
  const p = Store.product(id);
  if (!p) return;
  const margin = p.price - p.cost;
  const marginPct = p.price ? Math.round((margin / p.price) * 100) : 0;
  modal(p.name, `
    <div class="detail-grid">
      <div><span>Brand</span><strong>${esc(p.brand || '—')}</strong></div>
      <div><span>Size</span><strong>${p.size ? p.size + ' ml' : '—'}</strong></div>
      <div><span>Sell price</span><strong>${money(p.price)}</strong></div>
      <div><span>Cost</span><strong>${money(p.cost)}</strong></div>
      <div><span>Margin</span><strong>${money(margin)} (${marginPct}%)</strong></div>
      <div><span>Stock value</span><strong>${money(p.stock * p.price)}</strong></div>
    </div>
    <h3 class="section-label">Stock: <span class="${p.stock <= Store.lowStock ? 'text-warn' : ''}">${p.stock} units</span></h3>
    <div class="stepper">
      <button class="btn ghost" data-delta="-1">−1</button>
      <button class="btn ghost" data-delta="-5">−5</button>
      <button class="btn ghost" data-delta="1">+1</button>
      <button class="btn ghost" data-delta="5">+5</button>
      <button class="btn ghost" data-delta="10">+10</button>
    </div>
    <div class="btn-row">
      <button class="btn primary" id="p-edit">Edit</button>
      <button class="btn danger" id="p-del">Delete</button>
    </div>`, (o) => {
    o.querySelectorAll('[data-delta]').forEach((b) =>
      b.addEventListener('click', () => { Store.adjustStock(id, +b.dataset.delta); toast('Stock updated'); productDetail(id); }));
    o.querySelector('#p-edit').addEventListener('click', () => productForm(p));
    o.querySelector('#p-del').addEventListener('click', () =>
      confirmDialog(`Delete ${p.name}?`, () => { Store.deleteProduct(id); toast('Product deleted'); closeModal(); }));
  });
}

// ---------- Sales ----------
function viewSales() {
  app.innerHTML = `
    <div class="page-head">
      <div><h1>Sales</h1><p class="sub">${Store.sales().length} recorded</p></div>
      <button class="btn primary" id="new-sale">+ New sale</button>
    </div>
    <section class="card">${salesTable(Store.sales())}</section>`;
  document.getElementById('new-sale').addEventListener('click', () => saleForm());
  bindSaleRows();
}

function salesTable(sales) {
  if (!sales.length) return emptyState('No sales recorded yet.');
  return `<div class="table-wrap"><table class="table">
    <thead><tr><th>Customer</th><th>Items</th><th class="num">Total</th><th class="num">Status</th><th>When</th></tr></thead>
    <tbody>
      ${sales.map((s) => {
        const c = Store.customer(s.customerId);
        const credit = s.total - s.paid;
        return `<tr data-sale="${s.id}">
          <td>${esc(c ? c.name : 'Unknown')}</td>
          <td class="items">${esc(s.items.map((i) => `${i.qty}× ${i.name}`).join(', '))}</td>
          <td class="num">${money(s.total)}</td>
          <td class="num">${credit > 0.005 ? `<span class="pill warn">${money(credit)} due</span>` : `<span class="pill ok">Paid</span>`}</td>
          <td class="when">${fmtDate(s.createdAt)}</td>
        </tr>`;
      }).join('')}
    </tbody>
  </table></div>`;
}

function bindSaleRows() {
  document.querySelectorAll('[data-sale]').forEach((row) =>
    row.addEventListener('click', () => saleDetail(row.dataset.sale)));
}

function saleDetail(id) {
  const s = Store.sales().find((x) => x.id === id);
  if (!s) return;
  const c = Store.customer(s.customerId);
  const credit = s.total - s.paid;
  modal('Sale details', `
    <div class="detail-head">
      <div><p class="detail-sub">${esc(c ? c.name : 'Unknown')}</p><p class="detail-note">${fmtDate(s.createdAt)}</p></div>
    </div>
    <div class="table-wrap"><table class="table">
      <thead><tr><th>Item</th><th class="num">Qty</th><th class="num">Price</th><th class="num">Sum</th></tr></thead>
      <tbody>${s.items.map((i) => `<tr><td>${esc(i.name)}</td><td class="num">${i.qty}</td><td class="num">${money(i.price)}</td><td class="num">${money(i.qty * i.price)}</td></tr>`).join('')}</tbody>
      <tfoot>
        <tr><td colspan="3">Total</td><td class="num"><strong>${money(s.total)}</strong></td></tr>
        <tr><td colspan="3">Paid</td><td class="num">${money(s.paid)}</td></tr>
        ${credit > 0.005 ? `<tr class="due"><td colspan="3">On credit</td><td class="num">${money(credit)}</td></tr>` : ''}
      </tfoot>
    </table></div>
    <div class="btn-row">
      <button class="btn danger" id="s-del">Delete &amp; restock</button>
    </div>`, (o) => {
    o.querySelector('#s-del').addEventListener('click', () =>
      confirmDialog('Delete this sale? Stock will be returned to inventory.', () => { Store.deleteSale(id); toast('Sale deleted'); closeModal(); }));
  });
}

function saleForm(presetCustomerId) {
  const customers = Store.customers();
  const products = Store.products().filter((p) => p.stock > 0);
  if (!customers.length) { toast('Add a customer first'); return; }
  if (!products.length) { toast('No products in stock'); return; }

  let cart = [];
  modal('New sale', `
    <form id="sale-form" class="form">
      <label>Customer
        <select name="customer" required>
          ${customers.map((c) => `<option value="${c.id}" ${c.id === presetCustomerId ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}
        </select>
      </label>
      <label>Add product
        <select id="prod-picker">
          <option value="">Choose a product…</option>
          ${products.map((p) => `<option value="${p.id}">${esc(p.name)} — ${money(p.price)} (${p.stock} left)</option>`).join('')}
        </select>
      </label>
      <div id="cart" class="cart"></div>
      <div class="sale-total"><span>Total</span><strong id="sale-total-val">${money(0)}</strong></div>
      <label>Amount paid now
        <input name="paid" type="number" min="0" step="any" value="0">
        <button type="button" class="mini-link" id="pay-full">Mark fully paid</button>
      </label>
      <p class="credit-note" id="credit-note"></p>
      <div class="form-actions">
        <button type="button" class="btn ghost" data-close>Cancel</button>
        <button type="submit" class="btn primary">Record sale</button>
      </div>
    </form>`, (o) => {
    const picker = o.querySelector('#prod-picker');
    const cartEl = o.querySelector('#cart');
    const totalEl = o.querySelector('#sale-total-val');
    const paidInput = o.querySelector('[name=paid]');
    const creditNote = o.querySelector('#credit-note');

    const total = () => cart.reduce((s, it) => s + it.qty * it.price, 0);
    function refresh() {
      cartEl.innerHTML = cart.length ? cart.map((it, idx) => `
        <div class="cart-row">
          <span class="cart-name">${esc(it.name)}</span>
          <div class="qty">
            <button type="button" data-dec="${idx}">−</button>
            <span>${it.qty}</span>
            <button type="button" data-inc="${idx}">+</button>
          </div>
          <span class="cart-sum">${money(it.qty * it.price)}</span>
          <button type="button" class="cart-rm" data-rm="${idx}" aria-label="Remove">✕</button>
        </div>`).join('') : '<p class="empty">No items added.</p>';
      totalEl.textContent = money(total());
      updateCredit();
      cartEl.querySelectorAll('[data-inc]').forEach((b) => b.onclick = () => changeQty(+b.dataset.inc, 1));
      cartEl.querySelectorAll('[data-dec]').forEach((b) => b.onclick = () => changeQty(+b.dataset.dec, -1));
      cartEl.querySelectorAll('[data-rm]').forEach((b) => b.onclick = () => { cart.splice(+b.dataset.rm, 1); refresh(); });
    }
    function changeQty(idx, delta) {
      const it = cart[idx];
      const prod = Store.product(it.productId);
      it.qty = Math.max(1, Math.min(prod.stock, it.qty + delta));
      refresh();
    }
    function updateCredit() {
      const t = total(), paid = Math.min(+paidInput.value || 0, t);
      const credit = t - paid;
      creditNote.textContent = credit > 0.005 ? `${money(credit)} will be added to the customer's credit.` : (t > 0 ? 'Fully paid.' : '');
      creditNote.className = 'credit-note' + (credit > 0.005 ? ' warn' : '');
    }
    picker.addEventListener('change', () => {
      const pid = picker.value;
      if (!pid) return;
      const prod = Store.product(pid);
      const existing = cart.find((it) => it.productId === pid);
      if (existing) { if (existing.qty < prod.stock) existing.qty++; }
      else cart.push({ productId: pid, name: prod.name, price: prod.price, qty: 1 });
      picker.value = '';
      refresh();
    });
    paidInput.addEventListener('input', updateCredit);
    o.querySelector('#pay-full').addEventListener('click', () => { paidInput.value = total(); updateCredit(); });

    o.querySelector('#sale-form').addEventListener('submit', (e) => {
      e.preventDefault();
      if (!cart.length) { toast('Add at least one product'); return; }
      const f = new FormData(e.target);
      const sale = Store.addSale({ customerId: f.get('customer'), items: cart.map((it) => ({ productId: it.productId, qty: it.qty })), paid: +f.get('paid') || 0 });
      if (sale) { toast('Sale recorded'); closeModal(); }
    });
    refresh();
  });
}

// ---------- Credit ----------
function viewCredit() {
  const debtors = Store.customers()
    .map((c) => ({ c, bal: Store.balance(c.id) }))
    .filter((x) => x.bal > 0.005)
    .sort((a, b) => b.bal - a.bal);
  const total = debtors.reduce((s, d) => s + d.bal, 0);

  app.innerHTML = `
    <div class="page-head">
      <div><h1>Credit book</h1><p class="sub">${debtors.length} customer${debtors.length === 1 ? '' : 's'} owe you</p></div>
    </div>
    <div class="kpis">
      ${kpi('Total outstanding', money(total), total > 0 ? 'warn' : 'ok', 'Across all customers')}
      ${kpi('Payments received', money(Store.payments().reduce((s, p) => s + p.amount, 0)), 'ok', 'All time')}
    </div>
    <div class="list">
      ${debtors.length ? debtors.map(({ c, bal }) => `
        <div class="list-row" data-cust="${c.id}">
          <div class="avatar warn">${esc(c.name.slice(0, 1).toUpperCase())}</div>
          <div class="row-main">
            <span class="row-title">${esc(c.name)}</span>
            <span class="row-sub">${esc(c.phone || 'No phone')}</span>
          </div>
          <div class="row-end"><span class="pill warn">${money(bal)}</span></div>
        </div>`).join('') : `<div class="all-clear">✓ Everyone's paid up. No outstanding credit.</div>`}
    </div>`;
  document.querySelectorAll('#view .list-row').forEach((row) =>
    row.addEventListener('click', () => customerDetail(row.dataset.cust)));
}

// ---------- shared ----------
function emptyState(msg) { return `<p class="empty">${esc(msg)}</p>`; }

// ---------- data menu ----------
function dataMenu() {
  modal('Data & backup', `
    <p class="hint-line">Your data lives on this device only. Back it up regularly.</p>
    <div class="btn-row">
      <button class="btn primary" id="d-export">Export backup</button>
      <button class="btn ghost" id="d-import">Import backup</button>
    </div>
    <label class="danger-zone">Reset app
      <button class="btn danger" id="d-reset">Reset to sample data</button>
    </label>
    <input type="file" id="import-file" accept="application/json" hidden>`, (o) => {
    o.querySelector('#d-export').addEventListener('click', () => {
      const blob = new Blob([Store.export()], { type: 'application/json' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = `scentry-backup-${new Date().toISOString().slice(0, 10)}.json`;
      a.click();
      URL.revokeObjectURL(a.href);
      toast('Backup downloaded');
    });
    const file = o.querySelector('#import-file');
    o.querySelector('#d-import').addEventListener('click', () => file.click());
    file.addEventListener('change', () => {
      const f = file.files[0];
      if (!f) return;
      const reader = new FileReader();
      reader.onload = () => {
        try { Store.import(reader.result); toast('Backup restored'); closeModal(); }
        catch (err) { toast('Invalid backup file'); }
      };
      reader.readAsText(f);
    });
    o.querySelector('#d-reset').addEventListener('click', () =>
      confirmDialog('Reset all data and reload sample data? This cannot be undone.', () => { Store.reset(); toast('Reset done'); closeModal(); }));
  });
}
document.getElementById('data-btn').addEventListener('click', dataMenu);

// ---------- boot ----------
if (!location.hash) location.hash = '#/dashboard';
render();

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => navigator.serviceWorker.register('./service-worker.js').catch(() => {}));
}

// Install prompt
let deferredPrompt = null;
const installBtn = document.getElementById('install-btn');
window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault();
  deferredPrompt = e;
  installBtn.hidden = false;
});
installBtn.addEventListener('click', async () => {
  if (!deferredPrompt) return;
  deferredPrompt.prompt();
  await deferredPrompt.userChoice;
  deferredPrompt = null;
  installBtn.hidden = true;
});
