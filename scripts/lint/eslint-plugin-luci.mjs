// SPDX-License-Identifier: Apache-2.0
// ESLint rule for LuCI 25.12 class files (views and resources). luci.js
// evaluates each file as `function(window, document, L, <one parameter per
// leading 'require' directive>)`: `'require a.b as x'` binds `x`,
// `'require a.b'` binds `a_b` (luci.js compileClass). Core `no-undef` cannot
// know those per-file parameters, so this rule replaces it for LuCI files: it
// reports identifiers that are neither declared, configured globals nor
// required, and requires whose binding is never used (each one is an extra
// HTTP fetch and module instantiation in the browser).
const REQUIRE = /^require[ \t]+(\S+)(?:[ \t]+as[ \t]+([a-zA-Z_]\S*))?$/;
const STRICT = /^use[ \t]+strict$/;

export function requireBindings(program) {
  const bound = new Map();
  for (const statement of program.body) {
    const value = statement.type === 'ExpressionStatement' && statement.expression.type === 'Literal'
      ? statement.expression.value : null;
    if (typeof value !== 'string') break;
    const m = REQUIRE.exec(value);
    if (m) bound.set(m[2] || m[1].replace(/[^a-zA-Z0-9_]/g, '_'), statement);
    else if (!STRICT.test(value)) break;
  }
  return bound;
}

const requireBindingsRule = {
  meta: {
    type: 'problem',
    docs: { description: 'Undefined identifiers and unused requires in LuCI class files' },
    schema: [],
    messages: {
      undef: "'{{name}}' is not defined (no declaration, global or 'require' directive).",
      unused: "'require' binding '{{name}}' is never used; drop the directive."
    }
  },
  create(context) {
    return {
      'Program:exit'(program) {
        const bound = requireBindings(program);
        const used = new Set();
        const globalScope = context.sourceCode.scopeManager.globalScope;
        // A binding may share its name with a configured browser global
        // (`model` is one): ESLint resolves those references to the global.
        for (const name of bound.keys())
          if (globalScope.set.get(name)?.references.length) used.add(name);
        // ESLint removes references to configured globals from `through`.
        for (const ref of globalScope.through) {
          const { name, parent } = ref.identifier;
          if (bound.has(name)) used.add(name);
          else if (!(parent.type === 'UnaryExpression' && parent.operator === 'typeof'))
            context.report({ node: ref.identifier, messageId: 'undef', data: { name } });
        }
        for (const [name, statement] of bound)
          if (!used.has(name)) context.report({ node: statement, messageId: 'unused', data: { name } });
      }
    };
  }
};

export default { meta: { name: 'abfm-luci' }, rules: { 'require-bindings': requireBindingsRule } };
