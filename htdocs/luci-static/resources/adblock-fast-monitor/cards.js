'use strict';
'require baseclass';
'require adblock-fast-monitor.model as model';
'require adblock-fast-monitor.chart as chart';

/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * The page's look (docs/CONTRACT.md §8.5, §8.6): the statistics tiles
 * (blocked share with the ring, the counts, the most blocked names), the
 * result dot, the changes chips and the two-line rows of narrow screens.
 * The stylesheet is a constant set through textContent (no dynamic data),
 * scoped to the page or the Status section, and uses the theme's CSS
 * variables (luci-theme-bootstrap, light and dark) with fallbacks.
 * Dynamic values are text nodes only; a poll rewrites only what changed
 * (P4).
 */

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

/* The tile and the blocked-share block: shared by the page and the Status section. */
function tileRules(R) {
	return [
		R + ' .abfm-tile{border:1px solid ' + C.line + ';border-radius:8px;padding:1em 1.1em;background:' + C.surface + ';box-shadow:0 1px 2px rgba(0,0,0,.06);box-sizing:border-box}',
		R + ' .abfm-tile h4{margin:0 0 .75em;padding:0;border:0;font-size:1em;font-weight:600;line-height:1.3}',
		R + ' .abfm-share{display:flex;align-items:center;gap:1em}',
		R + ' .abfm-share p{margin:0}',
		R + ' .abfm-donut{flex:none}',
		R + ' .abfm-muted{color:' + C.muted + '}'
	];
}

function pageRules(R) {
	return tileRules(R).concat([
		R + ' .abfm-tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(15em,1fr));gap:1em;margin:.25em 0 1.25em}',
		R + ' .abfm-facts{display:grid;grid-template-columns:1fr auto;gap:.35em 1em;margin:0}',
		R + ' .abfm-facts dt{color:' + C.muted + ';font-weight:normal}',
		R + ' .abfm-facts dd{margin:0;text-align:right;font-weight:600;font-variant-numeric:tabular-nums}',
		R + ' .abfm-top{list-style:none;margin:0;padding:0}',
		R + ' .abfm-top li{display:flex;flex-wrap:wrap;justify-content:space-between;gap:.2em 1em;margin-bottom:.55em}',
		R + ' .abfm-top li span{overflow-wrap:anywhere}',
		R + ' .abfm-bar{flex-basis:100%;height:4px;border-radius:2px;background:' + C.surface2 + '}',
		R + ' .abfm-bar>div{height:100%;border-radius:2px;background:' + C.blocked + ';opacity:.7}',
		R + ' .abfm-dot{display:inline-block;width:.55em;height:.55em;border-radius:50%;margin-right:.45em;vertical-align:.08em;background:' + C.other + '}',
		R + ' tr[data-decision="blocked"] .abfm-dot{background:' + C.blocked + '}',
		R + ' tr[data-decision="allowed"] .abfm-dot{background:' + C.allowed + '}',
		R + ' .abfm-src{color:' + C.muted + ';font-size:.85em;margin-left:.4em}',
		R + ' .abfm-act{min-width:4.5em}',
		R + ' .abfm-domain{font-weight:500}',
		R + ' tr[data-decision="blocked"] .td{background:rgba(var(--error-color-high-rgb, 246, 43, 18), .05)}',
		R + ' .table .td{padding-top:.4em;padding-bottom:.4em}',
		R + ' #abfm-changes{display:flex;flex-wrap:wrap;align-items:center;gap:.5em 1em;border:1px solid var(--primary-color-high, #1976d2);border-radius:8px;padding:.7em 1em;margin:0 0 1em;background:' + C.surface + '}',
		R + ' #abfm-changes>.right{margin-left:auto}',
		R + ' #abfm-pending{list-style:none;display:flex;flex-wrap:wrap;gap:.4em;margin:0;padding:0}',
		R + ' #abfm-pending li{display:inline-flex;align-items:center;gap:.4em;padding:.15em .2em .15em .75em;border:1px solid ' + C.line + ';border-radius:999px;background:' + C.surface + '}',
		R + ' #abfm-pending .cbi-button{padding:0 .6em;line-height:1.7;min-height:0}',
		/*
		 * Narrow screens: luci-theme-bootstrap's mobile.css stacks every cell
		 * under its column label. Here a row is two lines instead: the dot,
		 * the domain and the action, then time · client · decision and
		 * source, muted, without the column labels.
		 */
		'@media screen and (max-width: 600px){' + [
			R + ' #abfm-queries .tr.table-titles{display:none}',
			R + ' #abfm-queries .tr[data-domain]{display:grid;grid-template-columns:auto auto 1fr auto;grid-template-areas:"dom dom dom act" "time client res act";align-items:center;column-gap:.5em;row-gap:0;padding:.35em .25em;margin:0}',
			R + ' #abfm-queries .tr[data-domain] .td{display:block;padding:0;border:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;font-size:inherit}',
			R + ' #abfm-queries .tr[data-domain] .td::before{content:none;display:none}',
			R + ' #abfm-queries .td.abfm-domain{grid-area:dom;white-space:normal;overflow-wrap:anywhere}',
			R + ' #abfm-queries .td.abfm-domain::before{content:"";display:inline-block;width:.55em;height:.55em;border-radius:50%;margin-right:.45em;vertical-align:.08em;background:' + C.other + '}',
			R + ' #abfm-queries tr[data-decision="blocked"] .td.abfm-domain::before{background:' + C.blocked + '}',
			R + ' #abfm-queries tr[data-decision="allowed"] .td.abfm-domain::before{background:' + C.allowed + '}',
			R + ' #abfm-queries .td.abfm-time{grid-area:time;color:' + C.muted + ';font-size:.85em}',
			R + ' #abfm-queries .td.abfm-client{grid-area:client;color:' + C.muted + ';font-size:.85em}',
			R + ' #abfm-queries .td.abfm-client::after{content:" ·"}',
			R + ' #abfm-queries .td.abfm-time::after{content:" ·"}',
			R + ' #abfm-queries .td.abfm-result{grid-area:res;color:' + C.muted + ';font-size:.85em}',
			R + ' #abfm-queries .td.abfm-result .abfm-dot{display:none}',
			R + ' #abfm-queries .td.abfm-result .abfm-src{font-size:inherit}',
			R + ' #abfm-queries .td.cbi-section-actions{grid-area:act;flex:none;max-width:none;padding:0;text-align:right}',
			R + ' #abfm-queries .abfm-act,' + R + ' #abfm-queries .td.cbi-section-actions .cbi-button{min-height:2.75em;min-width:4.5em}',
			R + ' #abfm-changes>.right{margin-left:0;width:100%;display:flex;justify-content:flex-end;gap:.5em}'
		].join('') + '}'
	]);
}

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

/* The blocked-share tile: the ring with its number and a text alternative, and one muted line. */
function shareTile(id) {
	const donut = chart.donut(80);
	const cap = text();
	const node = E('section', { 'class': 'abfm-tile', 'aria-labelledby': id, 'data-stat': 'share' }, [
		E('h4', { 'id': id }, T(_('Blocked share'))),
		E('div', { 'class': 'abfm-share' }, [ donut.node, E('p', { 'class': 'abfm-muted', 'data-stat': 'text' }, [ cap ]) ])
	]);
	return { node: node, update(sum) {
		donut.update(sum.pct, sum.value, sum.label || sum.text);
		set(cap, sub(sum));
	} };
}

return baseclass.extend({
	TOP: TOP,

	/* A <style> element with the constant rules, scoped to the element with this id. */
	style(scopeId, page) {
		const el = document.createElement('style');
		const R = '#' + scopeId;
		el.textContent = (page ? pageRules(R) : tileRules(R)).join('\n');
		return el;
	},

	/* The page's three tiles: share, counts, most blocked (with bars by count). */
	stats() {
		const share = shareTile('abfm-t1');
		const facts = {}, empty = E('p', { 'class': 'abfm-muted', 'style': 'margin:0' }, T(_('Nothing blocked yet')));
		const fact = (k, label) => {
			facts[k] = text();
			return [ E('dt', {}, T(label)), E('dd', { 'data-stat': k }, [ facts[k] ]) ];
		};
		const slots = [];
		for (let i = 0; i < TOP; i++) {
			const name = text(), count = text(), bar = E('div', { 'style': 'width:0%' });
			slots.push({ name: name, count: count, bar: bar, li: E('li', { 'style': 'display:none' }, [
				E('span', {}, [ name ]), E('strong', {}, [ count ]),
				E('div', { 'class': 'abfm-bar', 'aria-hidden': 'true' }, [ bar ])
			]) });
		}
		const top = E('section', { 'class': 'abfm-tile', 'aria-labelledby': 'abfm-t3', 'id': 'abfm-top-blocked' }, [
			E('h4', { 'id': 'abfm-t3' }, T(_('Most blocked'))),
			E('ol', { 'class': 'abfm-top', 'aria-labelledby': 'abfm-t3' }, slots.map(s => s.li)),
			empty
		]);
		const node = E('div', { 'class': 'abfm-tiles', 'data-stat': 'blocked_pct' }, [
			share.node,
			E('section', { 'class': 'abfm-tile', 'aria-labelledby': 'abfm-t2' }, [
				E('h4', { 'id': 'abfm-t2' }, T(_('Recent queries'))),
				E('dl', { 'class': 'abfm-facts' }, [].concat(fact('blocked', _('Blocked')), fact('allowed', _('Allowed')),
					fact('queries', _('Answered')), fact('window', _('Time span'))))
			]),
			top
		]);
		return { node: node, update(sum, list, hideTop) {
			share.update(sum);
			for (const k in facts)
				set(facts[k], sum[k]);
			shown(top, !hideTop);
			const max = list.length ? list[0].count : 1;
			slots.forEach((s, i) => {
				const t = list[i];
				set(s.name, t ? t.domain : '');
				set(s.count, t ? model.formatCount(t.count) : '');
				shown(s.li, !!t);
				if (t) {
					s.li.setAttribute('data-domain', t.domain);
					const w = Math.round(100 * t.count / max) + '%';
					if (s.bar.style.width != w)
						s.bar.style.width = w;
				}
				else
					s.li.removeAttribute('data-domain');
			});
			shown(empty, !list.length);
		} };
	},

	/* The Status → Overview card: the same blocked-share tile (§8.6). */
	share(id) {
		return shareTile(id);
	}
});
