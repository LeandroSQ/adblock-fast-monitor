// SPDX-License-Identifier: Apache-2.0
import { defineConfig } from '@playwright/test';

const baseURL = process.env.MONITOR_BASE_URL;

// One guest, shared state: tests run serially. Timeouts allow for TCG guests,
// where a LuCI page load or an adblock-fast rebuild takes tens of seconds.
export default defineConfig({
  testDir: '.',
  testMatch: '*.spec.mjs',
  // T22 runs on its own guest with install-luci.config.mjs
  testIgnore: 'install-luci.spec.mjs',
  globalSetup: './global-setup.mjs',
  workers: 1,
  fullyParallel: false,
  timeout: 600_000,
  expect: { timeout: 30_000 },
  use: {
    baseURL: baseURL || 'http://127.0.0.1:0',
    navigationTimeout: 120_000,
    actionTimeout: 60_000,
    trace: 'retain-on-failure'
  },
  reporter: [['list'], ['html', { open: 'never' }]]
});
