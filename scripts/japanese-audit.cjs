// Extract explicit UI literals for the Japanese desktop edition. No source changes.
const ts = require('typescript');
const fs = require('node:fs');
const path = require('node:path');
const results = new Map();
const properties = new Set(['label', 'title', 'description', 'header', 'placeholder', 'message', 'emptyText', 'error']);
const attributes = new Set(['placeholder', 'title', 'aria-label', 'alt', 'label', 'description', 'emptyMessage']);
function scan(file) {
  const source = fs.readFileSync(file, 'utf8');
  const tree = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  function visit(node) {
    let visible = false;
    if (ts.isJsxText(node)) visible = true;
    else if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
      let leaf = node;
      while (true) {
        const parent = leaf.parent;
        if (ts.isParenthesizedExpression(parent) ||
            (ts.isConditionalExpression(parent) && parent.condition !== leaf) ||
            (ts.isBinaryExpression(parent) && [ts.SyntaxKind.QuestionQuestionToken, ts.SyntaxKind.BarBarToken].includes(parent.operatorToken.kind))) leaf = parent;
        else break;
      }
      const p = leaf.parent;
      const expression = ts.isJsxExpression(p) ? p :
        (ts.isConditionalExpression(p) && p.condition !== node && ts.isJsxExpression(p.parent) ? p.parent : null);
      const rendered = expression && (!ts.isJsxAttribute(expression.parent) || attributes.has(expression.parent.name.getText(tree)));
      visible = (ts.isJsxAttribute(p) && attributes.has(p.name.getText(tree))) ||
        rendered ||
        (ts.isPropertyAssignment(p) && p.initializer === leaf && properties.has(p.name.getText(tree).replaceAll('"', '').replaceAll("'", ''))) ||
        (ts.isNewExpression(p) && p.expression.getText(tree) === 'Error') ||
        (ts.isCallExpression(p) && /(?:toast|notify|alert|confirm|setError|setMessage)|\.(?:min|max|email|url|regex|refine)$/.test(p.expression.getText(tree)));
    }
    if (visible) {
      const value = node.text.trim().replace(/\s+/g, ' ');
      if (/[A-Za-z]{2}/.test(value) && !/[\u3040-\u30ff\u3400-\u9fff]/.test(value)) {
        const entry = results.get(value) || [];
        entry.push({file, start:node.getStart(tree), end:node.end, kind:ts.SyntaxKind[node.kind], line:tree.getLineAndCharacterOfPosition(node.getStart(tree)).line+1});
        results.set(value, entry);
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(tree);
}
function walk(dir) {
  for (const entry of fs.readdirSync(dir, {withFileTypes:true})) {
    const f = path.join(dir, entry.name);
    if (entry.isDirectory() && !['node_modules', '__tests__', '__mocks__', 'generated'].includes(entry.name)) walk(f);
    else if (entry.isFile() && /\.(tsx?|jsx?)$/.test(f) && !/\.(test|spec)\./.test(f)) scan(f);
  }
}
for (const dir of ['app','components','emails','actions','lib','plugins','types']) walk(dir);
fs.writeFileSync(process.argv[2] || '/tmp/nextcrm-ui-literals.json', JSON.stringify(Object.fromEntries(results), null, 2));
console.log(JSON.stringify({unique:results.size, occurrences:[...results.values()].reduce((n,v)=>n+v.length,0)}));
