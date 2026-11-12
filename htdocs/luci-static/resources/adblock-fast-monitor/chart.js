'use strict';
'require baseclass';

/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * The blocked-share donut of the page and of the Status → Overview section
 * (docs/CONTRACT.md §8.5, §8.6). LuCI has no chart widget; like its own
 * realtime graphs (view/status/load.js) the SVG is built with
 * document.createElementNS, and texts are set through textContent only.
 * Colours come from the theme's CSS variables (luci-theme-bootstrap) with
 * fallbacks for themes without them. Nothing animates.
 */

const NS = 'http://www.w3.org/2000/svg';
/* r = 100 / 2π: the circumference is 100, so the dash length is the percentage */
const R = '15.91549';

function svg(name, attrs) {
	const n = document.createElementNS(NS, name);
	for (const k in attrs)
		n.setAttribute(k, attrs[k]);
	return n;
}

return baseclass.extend({
	/*
	 * Returns {node, update(pct, value, label)}: pct is a number (0..100) or
	 * null (no data: an empty ring and "—"); value the text inside ("33 %");
	 * label the accessible name. update() writes only what changed (P4).
	 */
	donut(size) {
		const root = svg('svg', { 'viewBox': '0 0 36 36', 'width': String(size), 'height': String(size),
			'role': 'img', 'class': 'abfm-donut' });
		const title = svg('title', {});
		const track = svg('circle', { 'cx': '18', 'cy': '18', 'r': R, 'fill': 'none', 'stroke-width': '3.6',
			'style': 'stroke:var(--border-color-medium, #ddd)' });
		const arc = svg('circle', { 'cx': '18', 'cy': '18', 'r': R, 'fill': 'none', 'stroke-width': '3.6',
			'stroke-dasharray': '0 100', 'transform': 'rotate(-90 18 18)',
			'style': 'stroke:var(--primary-color-high, #1976d2)' });
		const text = svg('text', { 'x': '18', 'y': '18', 'text-anchor': 'middle', 'dominant-baseline': 'central',
			'font-size': '8', 'font-weight': 'bold', 'fill': 'currentColor' });
		text.textContent = '—';
		root.append(title, track, arc, text);
		const last = {};
		return {
			node: root,
			update(pct, value, label) {
				const p = (typeof(pct) == 'number' && isFinite(pct)) ? Math.max(0, Math.min(100, pct)) : 0;
				if (last.p !== p) {
					last.p = p;
					arc.setAttribute('stroke-dasharray', p + ' ' + (100 - p));
					arc.style.display = p > 0 ? '' : 'none';
				}
				const v = value || '—';
				if (last.v !== v)
					text.textContent = last.v = v;
				const l = label || v;
				if (last.l !== l) {
					last.l = l;
					title.textContent = l;
					root.setAttribute('aria-label', l);
				}
			}
		};
	}
});
