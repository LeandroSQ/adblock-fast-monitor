// SPDX-License-Identifier: Apache-2.0
// ESLint flat config, matched to the existing style (tabs in LuCI code, two
// spaces in Node .mjs, single quotes, semicolons, no trailing commas); no
// Prettier. Run through `npm run lint` (scripts/lint/run.mjs), which also
// applies the temporary per-file baseline in scripts/lint/baseline.json.
import js from '@eslint/js';
import json from '@eslint/json';
import stylistic from '@stylistic/eslint-plugin';
import { defineConfig, globalIgnores } from 'eslint/config';
import globals from 'globals';
import luci from './scripts/lint/eslint-plugin-luci.mjs';

// LuCI class files. `root/www/` until the move to `htdocs/` (luci.mk layout)
// lands; both are listed so the config works on either side of it.
const LUCI = ['root/www/**/*.js', 'htdocs/**/*.js'];
const RULE6 = 'render dynamic data as text (AGENTS.md hard restriction 6)';
const SINK = `HTML sink: ${RULE6}`;
// luci.js dom.append assigns a non-array, non-node child to innerHTML.
const CHILD = `is set as innerHTML by LuCI dom.append; pass T(text) or an array: ${RULE6}`;
const STR = '/^(Literal|TemplateLiteral|BinaryExpression)$/';

export default defineConfig([
  // ESLint does not read .gitignore: keep in sync with it. test/fixtures/ is
  // captured data and must not be rewritten.
  globalIgnores(['.local-validation/', '.ci-work/', 'dist/', 'node_modules/', 'playwright-report/',
    'test-results/', 'test/fixtures/', 'openwrt-sdk-*/']),
  { linterOptions: { reportUnusedDisableDirectives: 'error' } },
  {
    files: ['**/*.{js,mjs}'],
    extends: [js.configs.recommended],
    plugins: { '@stylistic': stylistic },
    rules: {
      'no-new-func': 'error',
      '@stylistic/quotes': ['error', 'single', { avoidEscape: true, allowTemplateLiterals: 'always' }],
      '@stylistic/semi': ['error', 'always'],
      '@stylistic/comma-dangle': ['error', 'never'],
      '@stylistic/no-trailing-spaces': 'error',
      '@stylistic/eol-last': 'error',
      '@stylistic/no-multiple-empty-lines': ['error', { max: 2 }]
    }
  },
  {
    files: ['**/*.mjs'],
    languageOptions: { globals: globals.node },
    rules: {
      '@stylistic/indent': ['error', 2, { SwitchCase: 0 }],
      '@stylistic/brace-style': ['error', '1tbs', { allowSingleLine: true }]
    }
  },
  // page.evaluate() callbacks run in the browser, on LuCI pages (L).
  { files: ['test/browser/**/*.mjs', 'scripts/perf/browser.mjs'], languageOptions: { globals: { ...globals.browser, L: 'readonly' } } },
  {
    files: LUCI,
    plugins: { luci },
    languageOptions: {
      ecmaVersion: 2021, // LuCI 25.12 core's own floor (form.js uses ??=)
      sourceType: 'script',
      parserOptions: { ecmaFeatures: { globalReturn: true } },
      // window, document and L are factory parameters; E, _ and N_ are set on window by luci.js.
      globals: { ...globals.browser, L: 'readonly', E: 'readonly', _: 'readonly', N_: 'readonly' }
    },
    rules: {
      'no-undef': 'off', // replaced by luci/require-bindings, which knows the 'require' parameters
      'luci/require-bindings': 'error',
      strict: ['error', 'global'],
      'no-unused-vars': ['error', { args: 'none', caughtErrors: 'none' }], // LuCI override signatures, catch (e)
      'no-empty': ['error', { allowEmptyCatch: true }],
      'no-restricted-globals': ['error', 'name', 'status', 'event', 'length', 'top', 'parent', 'self', 'close', 'open', 'origin'],
      'no-restricted-properties': ['error',
        ...['innerHTML', 'outerHTML', 'insertAdjacentHTML'].map((property) => ({ property, message: SINK })),
        { object: 'dom', property: 'parse', message: SINK }],
      'no-restricted-syntax': ['error',
        { selector: `CallExpression[callee.name='E'][arguments.2.type=${STR}]`, message: `A string child of E() ${CHILD}` },
        { selector: `CallExpression[callee.name='E'][arguments.length=2][arguments.1.type=${STR}]`, message: `A string child of E() ${CHILD}` },
        { selector: "CallExpression[callee.name='E'][arguments.2.callee.name=/^(_|String)$/]", message: `A string child of E() ${CHILD}` },
        { selector: "CallExpression[callee.name='E'][arguments.2.callee.property.name='format']", message: `A string child of E() ${CHILD}` },
        { selector: `CallExpression[callee.object.name='dom'][callee.property.name=/^(content|append)$/][arguments.1.type=${STR}]`, message: `A string passed to dom.content/append ${CHILD}` },
        { selector: "CallExpression[callee.name='_'][arguments.0.type!='Literal']", message: 'i18n-scan.pl extracts only string literals' }],
      '@stylistic/indent': ['error', 'tab', { SwitchCase: 0 }],
      '@stylistic/brace-style': ['error', 'stroustrup', { allowSingleLine: true }], // LuCI: }⏎else
      '@stylistic/keyword-spacing': ['error', { overrides: { typeof: { after: false } } }] // LuCI: typeof(x)
    }
  },
  {
    files: ['**/*.json'],
    ignores: ['package-lock.json'],
    plugins: { json },
    language: 'json/json',
    extends: ['json/recommended']
  }
]);
