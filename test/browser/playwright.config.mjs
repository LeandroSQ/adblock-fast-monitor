import { defineConfig } from '@playwright/test';

const baseURL = process.env.MONITOR_BASE_URL;

export default defineConfig({
  testDir: '.',
  testMatch: '*.spec.mjs',
  use: { baseURL: baseURL || 'http://127.0.0.1:0' },
  reporter: [['list'], ['html', { open: 'never' }]]
});
