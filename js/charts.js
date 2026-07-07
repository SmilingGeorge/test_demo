// Lightweight inline-SVG charts. Single-series → sequential blue, no legend.
// Marks are thin with 4px rounded data-ends; a shared tooltip handles hover.
import { money } from './store.js';

const SVG = 'http://www.w3.org/2000/svg';
const el = (name, attrs = {}) => {
  const n = document.createElementNS(SVG, name);
  for (const k in attrs) n.setAttribute(k, attrs[k]);
  return n;
};

// Palette (validated dataviz steps): sequential blue + accent gold.
const BLUE = '#2a78d6';
const BLUE_SOFT = '#9ec5f4';
const GRID = 'var(--grid)';
const INK = 'var(--text-secondary)';

function tooltip() {
  let tip = document.getElementById('chart-tip');
  if (!tip) {
    tip = document.createElement('div');
    tip.id = 'chart-tip';
    tip.className = 'chart-tip';
    document.body.appendChild(tip);
  }
  return tip;
}

function showTip(evt, html) {
  const tip = tooltip();
  tip.innerHTML = html;
  tip.style.opacity = '1';
  const pad = 12;
  let x = evt.clientX + pad, y = evt.clientY + pad;
  const r = tip.getBoundingClientRect();
  if (x + r.width > window.innerWidth) x = evt.clientX - r.width - pad;
  if (y + r.height > window.innerHeight) y = evt.clientY - r.height - pad;
  tip.style.left = x + 'px';
  tip.style.top = y + 'px';
}
function hideTip() { const t = document.getElementById('chart-tip'); if (t) t.style.opacity = '0'; }

// Vertical bar chart of daily revenue.
export function barTrend(mount, data) {
  mount.innerHTML = '';
  const W = mount.clientWidth || 320, H = 180;
  const pad = { t: 12, r: 8, b: 22, l: 8 };
  const iw = W - pad.l - pad.r, ih = H - pad.t - pad.b;
  const max = Math.max(1, ...data.map((d) => d.total));
  const n = data.length;
  const gap = 4;
  const bw = Math.max(3, (iw - gap * (n - 1)) / n);

  const svg = el('svg', { viewBox: `0 0 ${W} ${H}`, width: '100%', height: H, role: 'img', 'aria-label': 'Daily revenue trend' });

  // baseline
  svg.appendChild(el('line', { x1: pad.l, y1: pad.t + ih, x2: pad.l + iw, y2: pad.t + ih, stroke: GRID, 'stroke-width': 1 }));

  data.forEach((d, i) => {
    const h = (d.total / max) * ih;
    const x = pad.l + i * (bw + gap);
    const y = pad.t + ih - h;
    const bar = el('rect', {
      x, y: h < 1 ? pad.t + ih - 2 : y, width: bw, height: Math.max(2, h),
      rx: Math.min(4, bw / 2), fill: d.total ? BLUE : BLUE_SOFT, opacity: d.total ? 1 : 0.5
    });
    bar.style.cursor = 'default';
    bar.addEventListener('mouseenter', (e) => showTip(e, `<strong>${money(d.total)}</strong><br><span>${d.date.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' })}</span>`));
    bar.addEventListener('mousemove', (e) => showTip(e, `<strong>${money(d.total)}</strong><br><span>${d.date.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' })}</span>`));
    bar.addEventListener('mouseleave', hideTip);
    svg.appendChild(bar);

    // sparse date labels (first, middle, last)
    if (i === 0 || i === n - 1 || i === Math.floor(n / 2)) {
      const label = el('text', { x: x + bw / 2, y: H - 6, 'text-anchor': 'middle', 'font-size': 10, fill: INK });
      label.textContent = d.date.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
      svg.appendChild(label);
    }
  });

  mount.appendChild(svg);
}

// Horizontal bars for top products (single series → sequential blue by rank shade).
export function hBar(mount, rows) {
  mount.innerHTML = '';
  if (!rows.length) { mount.innerHTML = '<p class="empty">No sales recorded yet.</p>'; return; }
  const W = mount.clientWidth || 320;
  const rowH = 34, pad = { t: 6, r: 10, b: 6, l: 10 };
  const H = pad.t + pad.b + rows.length * rowH;
  const labelW = Math.min(120, W * 0.42);
  const trackX = pad.l + labelW + 8;
  const trackW = W - trackX - pad.r - 44;
  const max = Math.max(1, ...rows.map((r) => r.qty));
  const shades = ['#2a78d6', '#3987e5', '#5598e7', '#6da7ec', '#86b6ef'];

  const svg = el('svg', { viewBox: `0 0 ${W} ${H}`, width: '100%', height: H, role: 'img', 'aria-label': 'Top products by units sold' });

  rows.forEach((r, i) => {
    const cy = pad.t + i * rowH + rowH / 2;
    const name = el('text', { x: pad.l, y: cy + 4, 'font-size': 12, fill: 'var(--text-primary)' });
    name.textContent = r.name.length > 16 ? r.name.slice(0, 15) + '…' : r.name;
    svg.appendChild(name);

    svg.appendChild(el('rect', { x: trackX, y: cy - 6, width: trackW, height: 12, rx: 4, fill: GRID, opacity: 0.5 }));
    const w = Math.max(4, (r.qty / max) * trackW);
    const bar = el('rect', { x: trackX, y: cy - 6, width: w, height: 12, rx: 4, fill: shades[i % shades.length] });
    bar.addEventListener('mouseenter', (e) => showTip(e, `<strong>${r.name}</strong><br><span>${r.qty} sold · ${money(r.revenue)}</span>`));
    bar.addEventListener('mousemove', (e) => showTip(e, `<strong>${r.name}</strong><br><span>${r.qty} sold · ${money(r.revenue)}</span>`));
    bar.addEventListener('mouseleave', hideTip);
    svg.appendChild(bar);

    const val = el('text', { x: trackX + trackW + 8, y: cy + 4, 'font-size': 12, fill: INK });
    val.textContent = r.qty;
    svg.appendChild(val);
  });

  mount.appendChild(svg);
}
