// SPDX-License-Identifier: Apache-2.0
// Captures the README screenshots (scripts/docs/screenshots.sh) from the
// guest's LuCI: the overview with blocked and allowed rows, then two staged
// changes with the Apply confirmation open. Traffic is test-only: A queries
// for *.example.test names, blocked by the fixture list or answered by the
// fake upstream with 192.0.2.10. Nothing is applied; the staged changes are
// discarded at the end.
import { expect, test } from '@playwright/test';
import { admin, dnsQuery, login, pending, queries, queryRow } from '../../test/browser/lib/guest.mjs';

const OUT = new URL('../../docs/images/', import.meta.url);
const STORAGE = 'adblock-fast-monitor.pending.v2';

// Oldest first; the page lists the newest first. Blocked by the fixture list:
// ads, telemetry and metrics.example.test; names under up.example.test are
// answered by the fake upstream with 192.0.2.10.
const TRAFFIC = [
  'www.up.example.test', 'cdn.up.example.test', 'ads.example.test', 'api.up.example.test',
  'telemetry.example.test', 'mail.up.example.test', 'tracker.up.example.test', 'news.up.example.test',
  'metrics.example.test', 'photos.up.example.test', 'ads.example.test', 'www.up.example.test'
];

test('README screenshots', async ({ page }) => {
  await login(page, admin);
  await page.evaluate(`localStorage.removeItem(${JSON.stringify(STORAGE)})`);
  await page.reload();
  await page.locator('#abfm-overview').waitFor();

  for (const name of TRAFFIC) {
    let answered = null;
    for (let i = 0; i < 5 && !answered; i++) answered = await dnsQuery(name);
    if (!answered) throw new Error(`dnsmasq never answered ${name}`);
    // spread the traffic over a few seconds, as real clients would
    await page.waitForTimeout(700);
  }
  for (const name of new Set(TRAFFIC)) await expect(queryRow(page, name)).toBeVisible();
  await expect(queries(page).locator('tr[data-domain="ads.example.test"][data-decision="blocked"]')).toHaveCount(2);
  await expect(queryRow(page, 'www.up.example.test')).toHaveAttribute('data-decision', 'allowed');

  // the whole page down to the end of the dashboard, LuCI's menu bar included
  const box = await page.locator('#view').boundingBox();
  await page.screenshot({
    path: new URL('overview.png', OUT).pathname, animations: 'disabled', fullPage: true,
    clip: { x: 0, y: 0, width: 1280, height: Math.ceil(box.y + box.height + 16) }
  });

  await queryRow(page, 'metrics.example.test').getByRole('button', { name: 'Allow metrics.example.test' }).click();
  await queryRow(page, 'tracker.up.example.test').getByRole('button', { name: 'Block tracker.up.example.test' }).click();
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(2);
  await page.locator('#abfm-pending-section').scrollIntoViewIfNeeded();
  await page.getByRole('button', { name: 'Apply changes' }).click();
  const modal = page.locator('.modal');
  await expect(modal.getByRole('button', { name: 'Apply' })).toBeVisible();
  await expect(modal.locator('li')).toHaveCount(2);
  await page.screenshot({ path: new URL('apply.png', OUT).pathname, animations: 'disabled' });

  await modal.getByRole('button', { name: 'Cancel' }).click();
  await page.getByRole('button', { name: 'Discard all' }).click();
  await expect(pending(page).locator('tr[data-domain]')).toHaveCount(0);
});
