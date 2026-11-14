'use strict';
'require baseclass';
'require adblock-fast-monitor.model as model';
'require adblock-fast-monitor.chart as chart';

/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Three candidate visual directions for the page (docs/CONTRACT.md §8.5),
 * chosen with `?design=quiet|cards|compact` while one is picked; without
 * it the page keeps its current look. Each direction is a statistics
 * block plus a stylesheet scoped to `#abfm-overview[data-design=…]`. The
 * stylesheet is a constant set through textContent (no dynamic data), and
 * uses the theme's CSS variables (luci-theme-bootstrap, light and dark)
 * with fallbacks. Dynamic values are text nodes only; a poll rewrites only
 * what changed (P4).
 */

const DESIGNS = [ 'quiet', 'cards', 'compact' ];
const TOP = 3;

const C = {
	blocked: 'var(--error-color-high, #d00000)',
	allowed: 'var(--success-color-high, #00ac59)',
	other: 'var(--text-color-low, #999)',
	muted: 'var(--text-color-medium, #555)',
	line: 'var(--border-color-medium, #ddd)',
	surface: 'var(--background-color-high, #fff)',
	surface2: 'var(--background-color-medium, #f6f6f6)'
};

/* Shared by the three: result dot, quieter action buttons, change chips, short footer. */
function common(d) {
	const R = '#abfm-overview[data-design="' + d + '"]';
	return [
		R + ' .abfm-dot{display:inline-block;width:.55em;height:.55em;border-radius:50%;margin-right:.45em;vertical-align:.08em;background:' + C.other + '}',
		R + ' tr[data-decision="blocked"] .abfm-dot{background:' + C.blocked + '}',
		R + ' tr[data-decision="allowed"] .abfm-dot{background:' + C.allowed + '}',
		R + ' .abfm-src{color:' + C.muted + ';font-size:.85em;margin-left:.4em}',
		R + ' .abfm-act{min-width:4.5em}',
		R + ' .abfm-domain{font-weight:500}',
		R + ' #abfm-changes{display:flex;flex-wrap:wrap;align-items:center;gap:.5em 1em}',
		R + ' #abfm-changes>.right{margin-left:auto}',
		R + ' #abfm-pending{list-style:none;display:flex;flex-wrap:wrap;gap:.4em;margin:0;padding:0}',
		R + ' #abfm-pending li{display:inline-flex;align-items:center;gap:.4em;padding:.15em .2em .15em .75em;border:1px solid ' + C.line + ';border-radius:999px;background:' + C.surface + '}',
		R + ' #abfm-pending .cbi-button{padding:0 .6em;line-height:1.7;min-height:0}',
		R + ' .abfm-muted{color:' + C.muted + '}',
		R + ' .abfm-num{font-variant-numeric:tabular-nums}',
		R + ' .abfm-top{list-style:none;margin:0;padding:0}',
		R + ' .abfm-top li{display:flex;justify-content:space-between;gap:1em}',
		R + ' .abfm-top li span{overflow-wrap:anywhere}'
	];
}

const STYLE = {
	quiet: [
		'#abfm-overview[data-design="quiet"] .abfm-stats{display:flex;align-items:center;gap:1em;margin:.25em 0 1.25em}',
		'#abfm-overview[data-design="quiet"] .abfm-donut{flex:none}',
		'#abfm-overview[data-design="quiet"] .abfm-head{margin:0;font-size:1.35em;line-height:1.3}',
		'#abfm-overview[data-design="quiet"] .abfm-head strong{font-size:1.25em}',
		'#abfm-overview[data-design="quiet"] .abfm-sub{margin:.15em 0 0}',
		'#abfm-overview[data-design="quiet"] #abfm-changes{background:' + C.surface2 + ';border:1px solid ' + C.line + ';border-radius:6px;padding:.6em .8em;margin:0 0 1em}',
		'#abfm-overview[data-design="quiet"] .table .td{padding-top:.4em;padding-bottom:.4em}'
	],
	cards: [
		'#abfm-overview[data-design="cards"] .abfm-tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(15em,1fr));gap:1em;margin:.25em 0 1.25em}',
		'#abfm-overview[data-design="cards"] .abfm-tile{border:1px solid ' + C.line + ';border-radius:8px;padding:1em 1.1em;background:' + C.surface + ';box-shadow:0 1px 2px rgba(0,0,0,.06)}',
		'#abfm-overview[data-design="cards"] .abfm-tile h4{margin:0 0 .75em;padding:0;border:0;font-size:1em;font-weight:600;line-height:1.3}',
		'#abfm-overview[data-design="cards"] .abfm-share{display:flex;align-items:center;gap:1em}',
		'#abfm-overview[data-design="cards"] .abfm-share p{margin:0}',
		'#abfm-overview[data-design="cards"] .abfm-donut{flex:none}',
		'#abfm-overview[data-design="cards"] .abfm-facts{display:grid;grid-template-columns:1fr auto;gap:.35em 1em;margin:0}',
		'#abfm-overview[data-design="cards"] .abfm-facts dt{color:' + C.muted + ';font-weight:normal}',
		'#abfm-overview[data-design="cards"] .abfm-facts dd{margin:0;text-align:right;font-weight:600;font-variant-numeric:tabular-nums}',
		'#abfm-overview[data-design="cards"] .abfm-top li{flex-wrap:wrap;row-gap:.2em;margin-bottom:.55em}',
		'#abfm-overview[data-design="cards"] .abfm-bar{flex-basis:100%;height:4px;border-radius:2px;background:' + C.surface2 + '}',
		'#abfm-overview[data-design="cards"] .abfm-bar>div{height:100%;border-radius:2px;background:' + C.blocked + ';opacity:.7}',
		'#abfm-overview[data-design="cards"] #abfm-changes{border:1px solid var(--primary-color-high, #1976d2);border-radius:8px;padding:.7em 1em;margin:0 0 1em;background:' + C.surface + '}',
		'#abfm-overview[data-design="cards"] tr[data-decision="blocked"] .td{background:rgba(var(--error-color-high-rgb, 246, 43, 18), .05)}',
		'#abfm-overview[data-design="cards"] .table .td{padding-top:.4em;padding-bottom:.4em}'
	],
	compact: [
		'#abfm-overview[data-design="compact"]{display:flex;flex-direction:column}',
		'#abfm-overview[data-design="compact"] #abfm-queries-section{order:5}',
		'#abfm-overview[data-design="compact"] #abfm-changes-section{order:6;position:sticky;bottom:0;z-index:2}',
		'#abfm-overview[data-design="compact"] #abfm-logging{order:7}',
		'#abfm-overview[data-design="compact"] .abfm-strip{margin:.25em 0 .75em}',
		'#abfm-overview[data-design="compact"] .abfm-line{display:flex;flex-wrap:wrap;align-items:baseline;gap:.25em 1.25em}',
		'#abfm-overview[data-design="compact"] .abfm-line strong{font-size:1.25em}',
		'#abfm-overview[data-design="compact"] .abfm-split{display:flex;height:6px;border-radius:3px;overflow:hidden;margin:.45em 0;background:' + C.allowed + '}',
		'#abfm-overview[data-design="compact"] .abfm-split>div{background:' + C.blocked + '}',
		'#abfm-overview[data-design="compact"] .abfm-tops{margin:0}',
		'#abfm-overview[data-design="compact"] #abfm-queries{max-height:70vh}',
		'#abfm-overview[data-design="compact"] .table .td,#abfm-overview[data-design="compact"] .table .th{padding:.25em .6em}',
		'#abfm-overview[data-design="compact"] .table .cbi-button{padding:0 .6em;line-height:1.7;min-height:0}',
		'#abfm-overview[data-design="compact"] .abfm-act{opacity:0;transition:opacity .15s ease-out}',
		'#abfm-overview[data-design="compact"] tr:hover .abfm-act,#abfm-overview[data-design="compact"] tr:focus-within .abfm-act{opacity:1}',
		'@media (hover: none){#abfm-overview[data-design="compact"] .abfm-act{opacity:1}}',
		'@media (prefers-reduced-motion: reduce){#abfm-overview[data-design="compact"] .abfm-act{transition:none}}',
		'#abfm-overview[data-design="compact"] #abfm-changes{margin:0;border-radius:6px 6px 0 0;padding:.5em .8em;box-shadow:0 -2px 8px rgba(0,0,0,.12)}',
		'#abfm-overview[data-design="compact"] tr[data-decision="blocked"] .td{background:rgba(var(--error-color-high-rgb, 246, 43, 18), .05)}'
	]
};

function T(value) {
	return [ (value == null) ? '' : String(value) ];
}

function text() {
	return document.createTextNode('');
}

function set(node, value) {
	const v = (value == null) ? '' : String(value);
	if (node.data !== v)
		node.data = v;
}

function shown(node, on) {
	const d = on ? '' : 'none';
	if (node.style.display != d)
		node.style.display = d;
}

/* "4 of 12 queries in the last 8 s", or why there is no share. */
function sub(sum) {
	return (sum.pct == null) ? sum.text : _('%s of %s queries in the last %s').format(sum.blocked, sum.queries, sum.window);
}

/* The three most blocked names as reusable slots: [{li, name, count, bar}]. */
function topSlots(withBars) {
	const out = [];
	for (let i = 0; i < TOP; i++) {
		const name = text(), count = text();
		const kids = [ E('span', {}, [ name ]), E('strong', { 'class': 'abfm-num' }, [ count ]) ];
		let bar = null;
		if (withBars) {
			bar = E('div', { 'style': 'width:0%' });
			kids.push(E('div', { 'class': 'abfm-bar', 'aria-hidden': 'true' }, [ bar ]));
		}
		out.push({ li: E('li', { 'style': 'display:none' }, kids), name: name, count: count, bar: bar });
	}
	return out;
}

function fillTop(slots, top) {
	const max = top.length ? top[0].count : 1;
	slots.forEach((s, i) => {
		const t = top[i];
		set(s.name, t ? t.domain : '');
		set(s.count, t ? model.formatCount(t.count) : '');
		shown(s.li, !!t);
		if (t)
			s.li.setAttribute('data-domain', t.domain);
		if (s.bar && t) {
			const w = Math.round(100 * t.count / max) + '%';
			if (s.bar.style.width != w)
				s.bar.style.width = w;
		}
	});
}

const BUILD = {
	/* One line: a small decorative ring, the share as words, the rest muted. */
	quiet() {
		const donut = chart.donut(44, { text: false, decorative: true });
		const pct = text(), line = text(), tops = text();
		const node = E('div', { 'class': 'abfm-stats', 'data-stat': 'blocked_pct' }, [
			donut.node,
			E('div', {}, [
				E('p', { 'class': 'abfm-head' }, [ E('strong', { 'class': 'abfm-num' }, [ pct ]), ' ', E('span', {}, T(_('blocked'))) ]),
				E('p', { 'class': 'abfm-sub abfm-muted' }, [ line, tops ])
			])
		]);
		return { node: node, update(sum, top) {
			donut.update(sum.pct, sum.value, sum.label || sum.text);
			set(pct, sum.value || '—');
			set(line, sub(sum));
			set(tops, top.length ? ' · ' + _('Most blocked: %s').format(top.map(t => t.domain + ' (' + t.count + ')').join(', ')) : '');
		} };
	},

	/* Three tiles: the share, the counts, the most blocked names with bars. */
	cards() {
		const donut = chart.donut(80);
		const cap = text(), facts = {}, empty = E('p', { 'class': 'abfm-muted', 'style': 'margin:0' }, T(_('Nothing blocked yet')));
		const fact = (k, label) => {
			facts[k] = text();
			return [ E('dt', {}, T(label)), E('dd', { 'data-stat': k }, [ facts[k] ]) ];
		};
		const slots = topSlots(true);
		const node = E('div', { 'class': 'abfm-tiles', 'data-stat': 'blocked_pct' }, [
			E('section', { 'class': 'abfm-tile', 'aria-labelledby': 'abfm-t1' }, [
				E('h4', { 'id': 'abfm-t1' }, T(_('Blocked share'))),
				E('div', { 'class': 'abfm-share' }, [ donut.node, E('p', { 'class': 'abfm-muted' }, [ cap ]) ])
			]),
			E('section', { 'class': 'abfm-tile', 'aria-labelledby': 'abfm-t2' }, [
				E('h4', { 'id': 'abfm-t2' }, T(_('Recent queries'))),
				E('dl', { 'class': 'abfm-facts' }, [].concat(fact('blocked', _('Blocked')), fact('allowed', _('Allowed')),
					fact('queries', _('Answered')), fact('window', _('Time span'))))
			]),
			E('section', { 'class': 'abfm-tile', 'aria-labelledby': 'abfm-t3', 'id': 'abfm-top-blocked' }, [
				E('h4', { 'id': 'abfm-t3' }, T(_('Most blocked'))),
				E('ol', { 'class': 'abfm-top', 'aria-labelledby': 'abfm-t3' }, slots.map(s => s.li)),
				empty
			])
		]);
		return { node: node, update(sum, top) {
			donut.update(sum.pct, sum.value, sum.label || sum.text);
			set(cap, sub(sum));
			for (const k in facts)
				set(facts[k], sum[k]);
			fillTop(slots, top);
			shown(empty, !top.length);
		} };
	},

	/* A slim strip over the table: the share, the counts, a split bar, the top names. */
	compact() {
		const pct = text(), b = text(), a = text(), q = text(), w = text(), tops = text();
		const split = E('div', { 'style': 'width:0%' });
		const splitBar = E('div', { 'class': 'abfm-split', 'aria-hidden': 'true' }, [ split ]);
		const node = E('div', { 'class': 'abfm-strip', 'data-stat': 'blocked_pct' }, [
			E('div', { 'class': 'abfm-line' }, [
				E('span', {}, [ E('strong', { 'class': 'abfm-num' }, [ pct ]), ' ', E('span', {}, T(_('blocked'))) ]),
				E('span', { 'class': 'abfm-num' }, [ b, ' ', E('span', { 'class': 'abfm-muted' }, T(_('blocked'))) ]),
				E('span', { 'class': 'abfm-num' }, [ a, ' ', E('span', { 'class': 'abfm-muted' }, T(_('allowed'))) ]),
				E('span', { 'class': 'abfm-num' }, [ q, ' ', E('span', { 'class': 'abfm-muted' }, T(_('answered'))) ]),
				E('span', { 'class': 'abfm-muted' }, [ w ])
			]),
			splitBar,
			E('p', { 'class': 'abfm-tops abfm-muted' }, [ tops ])
		]);
		return { node: node, update(sum, top) {
			set(pct, sum.value || '—');
			set(b, sum.blocked);
			set(a, sum.allowed);
			set(q, sum.queries);
			set(w, sum.pct == null ? sum.text : _('last %s').format(sum.window));
			const width = (sum.pct == null ? 0 : Math.max(0, Math.min(100, sum.pct))) + '%';
			if (split.style.width != width)
				split.style.width = width;
			shown(splitBar, sum.pct != null);
			set(tops, top.length ? _('Most blocked: %s').format(top.map(t => t.domain + ' ' + t.count).join(' · ')) : _('Nothing blocked yet'));
		} };
	}
};

return baseclass.extend({
	TOP: TOP,

	/* The direction asked for in the page address, or null for the current look. */
	pick(search) {
		const m = /(?:^|[?&])design=([a-z]+)/.exec(String(search || ''));
		return (m && DESIGNS.indexOf(m[1]) >= 0) ? m[1] : null;
	},

	/* A <style> element with the direction's constant rules. */
	style(design) {
		const el = document.createElement('style');
		el.textContent = common(design).concat(STYLE[design]).join('\n');
		return el;
	},

	stats(design) {
		return BUILD[design]();
	}
});
