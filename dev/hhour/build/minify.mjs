// Minify the single-file app for deployment.
//
// The readable source (happyhourly-complete.html) stays the editable source of
// truth; deploy.sh runs this to produce the minified copy it actually ships, then
// restores the readable file. Keeps global function names intact (mangle.toplevel
// = false) so the countless inline onclick="fn()" handlers keep working.
//
// Usage:  node build/minify.mjs <in.html> <out.html>
import { minify } from 'html-minifier-terser';
import fs from 'node:fs';

const [inPath, outPath] = process.argv.slice(2);
if (!inPath || !outPath) { console.error('usage: node build/minify.mjs <in> <out>'); process.exit(1); }

const src = fs.readFileSync(inPath, 'utf8');
const out = await minify(src, {
  collapseWhitespace: true,
  conservativeCollapse: true,      // leave one space where whitespace can be significant
  removeComments: true,
  minifyCSS: true,
  // toplevel:false keeps global function/var names — required because thousands of
  // inline onclick="handler()" attributes reference them by name.
  minifyJS: { compress: true, mangle: { toplevel: false }, format: { comments: false } },
  keepClosingSlash: true,
  removeScriptTypeAttributes: false,
});

fs.writeFileSync(outPath, out);
const kb = n => Math.round(n / 1024);
console.error(`  minified ${kb(Buffer.byteLength(src))}KB → ${kb(Buffer.byteLength(out))}KB`);
