// SPDX-License-Identifier: Apache-2.0
// Captures the candidate visual directions of the page (`?design=quiet|
// cards|compact`, htdocs/.../adblock-fast-monitor/designs.js) into
// docs/images/options/: for each, 1280 px light and dark, and 360 px light,
// with two staged changes so the changes bar shows. Same test-only traffic
// as screenshots.spec.mjs; nothing is applied. Run with ABFM_OPTIONS=1
// (scripts/docs/playwright.config.mjs).
import { mkdirSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import { admin, dnsQuery, login, OVERVIEW, queries, queryRow } from '../../test/browser/lib/guest.mjs';

const OUT = new URL('../../docs/images/options/', import.meta.url);
const STORAGE = 'adblock-fast-monitor.pending.v2';
const TRAFFIC = [
  'www.up.example.test', 'cdn.up.example.test', 'ads.example.test', 'api.up.example.test',
  'telemetry.example.test', 'mail.up.example.test', 'tracker.up.example.test', 'news.up.example.test',
  'metrics.example.test', 'photos.up.example.test', 'ads.example.test', 'www.up.example.test'
];
const SHOTS = [
  { name: '1280-light', viewport: { width: 1280, height: 800 }, colorScheme: 'light' },
  { name: '1280-dark', viewport: { width: 1280, height: 800 }, colorScheme: 'dark' },
  { name: '360-light', viewport: { width: 360, height: 780 }, colorScheme: 'light' }
];

test('candidate visual directions', async ({ browser }) => {
  mkdirSync(OUT, { recursive: true });
  for (const name of TRAFFIC) {
    let answered = null;
    for (let i = 0; i < 5 && !answered; i++) answered = await dnsQuery(name);
    if (!answered) throw new Error(`dnsmasq never answered ${name}`);
    await new Promise((r) => setTimeout(r, 700));
  }
  for (const design of ['quiet', 'cards', 'compact']) {
    for (const shot of SHOTS) {
      const context = await browser.newContext({ viewport: shot.viewport, colorScheme: shot.colorScheme, deviceScaleFactor: 1 });
      const page = await context.newPage();
      await login(page, admin);
      await page.evaluate((k) => localStorage.removeItem(k), STORAGE);
      await page.goto(`${OVERVIEW}?design=${design}`);
      await expect(page.locator(`#abfm-overview[data-design="${design}"]`)).toBeVisible();
      for (const n of new Set(TRAFFIC)) await expect(queryRow(page, n)).toBeVisible();
      await expect(queries(page).locator('tr[data-domain="ads.example.test"][data-decision="blocked"]')).toHaveCount(2);
      await queryRow(page, 'metrics.example.test').getByRole('button', { name: 'Allow metrics.example.test' }).click();
      await queryRow(page, 'tracker.up.example.test').getByRole('button', { name: 'Block tracker.up.example.test' }).click();
      await expect(page.locator('#abfm-pending li')).toHaveCount(2);
      // the list starts at its top, without the focus ring of the last click
      await page.locator('#abfm-queries').evaluate((n) => { n.ownerDocument.activeElement?.blur(); n.scrollTop = 0; });
      // compact shows a row's action on hover or focus: point at a blocked row so the shot shows it
      if (design === 'compact') await queryRow(page, 'ads.example.test').hover();
      else await page.mouse.move(0, 0);
      // LuCI's header is sticky; a full-page capture would paint it mid-page on a narrow screen
      await page.addStyleTag({ content: 'header{position:static !important}' });
      await page.screenshot({ path: new URL(`${design}-${shot.name}.png`, OUT).pathname, animations: 'disabled', fullPage: true });
      await page.getByRole('button', { name: 'Discard', exact: true }).click();
      await context.close();
    }
  }
});
