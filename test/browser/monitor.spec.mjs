import { expect, test } from '@playwright/test';

async function authenticate(page, username, password) {
  const login = page.locator('input[name="luci_username"]');
  if (!await login.isVisible().catch(() => false)) return;

  if (!username || !password) {
    throw new Error(
      'Browser test prerequisite blocked: provisioned LuCI credentials are required for the real target.'
    );
  }

  await login.fill(username);
  await page.locator('input[name="luci_password"]').fill(password);
  await page.locator('button[type="submit"], input[type="submit"]').first().click();
  await page.waitForLoadState('networkidle');
}

test('monitor runtime exposes accessible read-only status and filtering controls', async ({ page }) => {
  const username = process.env.MONITOR_READONLY_LUCI_USERNAME;
  const password = process.env.MONITOR_READONLY_LUCI_PASSWORD;
  const response = await page.goto('/cgi-bin/luci/admin/services/adblock-fast-monitor');
  expect(response?.ok(), 'LuCI monitor route must be served by the supplied runtime').toBeTruthy();
  await authenticate(page, username, password);

  await expect(page.getByRole('main')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Adblock Fast Monitor' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Health and coverage' })).toBeVisible();
  await expect(page.getByRole('status')).toBeVisible();
  await expect(page.getByRole('textbox', { name: 'Search activity' })).toBeVisible();
  await expect(page.getByRole('combobox', { name: 'Show' })).toBeVisible();
  await expect(page.getByRole('table', { name: 'Activity timeline' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Purge activity' })).toHaveCount(0);
});

test('write-capable session exposes an accessible purge action', async ({ page }) => {
  const username = process.env.MONITOR_WRITE_LUCI_USERNAME;
  const password = process.env.MONITOR_WRITE_LUCI_PASSWORD;

  await page.goto('/cgi-bin/luci/admin/services/adblock-fast-monitor');
  await authenticate(page, username, password);
  await expect(page.getByRole('button', { name: 'Purge activity' })).toBeEnabled();
});
