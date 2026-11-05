import { access } from 'node:fs/promises';
import { chromium } from '@playwright/test';

const baseURL = process.env.OPENWRT_LUCI_BASE_URL;
const packagePath = process.env.PACKAGE_IPK;
const username = process.env.MONITOR_WRITE_LUCI_USERNAME;
const password = process.env.MONITOR_WRITE_LUCI_PASSWORD;

for (const [name, value] of Object.entries({ OPENWRT_LUCI_BASE_URL: baseURL, PACKAGE_IPK: packagePath, MONITOR_WRITE_LUCI_USERNAME: username, MONITOR_WRITE_LUCI_PASSWORD: password })) {
  if (!value) throw new Error(`${name} is required for the real LuCI Software upload test.`);
}
await access(packagePath);

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
try {
  await page.goto(`${baseURL}/cgi-bin/luci/`, { waitUntil: 'networkidle' });
  const login = page.locator('input[name="luci_username"]');
  if (await login.count()) {
    await login.fill(username);
    await page.locator('input[name="luci_password"]').fill(password);
    await page.locator('button[type="submit"], input[type="submit"]').first().click();
    await page.waitForLoadState('networkidle');
  }

  await page.goto(`${baseURL}/cgi-bin/luci/admin/system/opkg`, { waitUntil: 'networkidle' });
  const upload = page.locator('input[type="file"]');
  if (await upload.count() !== 1) throw new Error('LuCI Software page did not expose exactly one package upload input.');
  await upload.setInputFiles(packagePath);
  await page.getByRole('button', { name: /upload/i }).click();
  await page.waitForLoadState('networkidle');

  const install = page.getByRole('button', { name: /^install$/i });
  if (await install.count() !== 1) throw new Error('LuCI Software upload did not present an Install confirmation.');
  await install.click();
  await page.waitForLoadState('networkidle');
  await page.goto(`${baseURL}/cgi-bin/luci/admin/services/adblock-fast-monitor`, { waitUntil: 'networkidle' });
  if (await page.getByRole('heading', { name: 'Adblock Fast Monitor' }).count() !== 1) {
    throw new Error('LuCI upload/install completed without exposing the installed monitor route.');
  }
} finally {
  await browser.close();
}
