// SPDX-License-Identifier: Apache-2.0
import { defineConfig } from '@playwright/test';

// T22 runs on a guest WITHOUT the package, so it must not use the suite's
// global setup (which configures an installed monitor). Used by
// test/guest/package-luci-install.host.sh.
export default defineConfig({
  testDir: '.',
  testMatch: 'install-luci.spec.mjs',
  workers: 1,
  timeout: 20 * 60 * 1000,
  expect: { timeout: 30_000 },
  use: {
    baseURL: process.env.MONITOR_BASE_URL || 'http://127.0.0.1:0',
    navigationTimeout: 120_000,
    actionTimeout: 60_000,
    trace: 'retain-on-failure'
  },
  reporter: [['list']]
});
