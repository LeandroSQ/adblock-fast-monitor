// SPDX-License-Identifier: Apache-2.0
// Playwright config for the README screenshots (scripts/docs/screenshots.sh).
// Reuses the browser suite's guest setup: the fixture block list and a fake
// upstream that answers *.example.test with TEST-NET addresses.
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  testMatch: 'screenshots.spec.mjs',
  globalSetup: '../../test/browser/global-setup.mjs',
  workers: 1,
  timeout: 600_000,
  expect: { timeout: 60_000 },
  use: {
    baseURL: process.env.MONITOR_BASE_URL || 'http://127.0.0.1:0',
    viewport: { width: 1280, height: 800 },
    deviceScaleFactor: 1,
    colorScheme: 'light',
    navigationTimeout: 120_000,
    actionTimeout: 60_000
  },
  reporter: [['list']]
});
