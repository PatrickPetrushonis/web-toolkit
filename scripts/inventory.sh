#!/usr/bin/env bash
# Read-only inventory of a gulp/Nunjucks site, to plan porting it into a
# new project from a profile. With --dump it also writes the source files
# the port is written from. Nothing in the target is modified; output goes
# to the terminal and to logs/<target>.inventory.log. Ported from
# vite_site_inventory.sh and vite_site_dump.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage: inventory.sh --target <dir> [--dump]

  --target <dir>   Site directory to inventory.
  --dump           After the inventory, dump the source files under a
                   "#### path (N bytes)" header each:
                     gulpfile.js, readme.md, README.md, .gitignore, CNAME
                     dev/pages, dev/templates, dev/data   all files
                     dev/js     files up to 30000 bytes in full; larger
                                files list their first 40 lines
                     dev/scss   entry files (not starting with "_") in
                                full; partials by name and size only
                   The built output and binary assets are not dumped.

The inventory reports git state, package.json, top-level entries, files
by extension, gulpfile task names, templates with tag counts and
include/extends targets, data files and CNAME, scripts and styles, and
the 20 largest assets.
USAGE
}

TARGET_DIR=""
DUMP=0
CAP=30000

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)  TARGET_DIR="$2"; shift 2 ;;
        --dump)    DUMP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

[[ -n "$TARGET_DIR" ]] || { echo "ERROR: --target is required" >&2; usage; exit 1; }
SITE="$(cd "$TARGET_DIR" 2>/dev/null && pwd)" || { echo "ERROR: --target must be an existing directory: $TARGET_DIR" >&2; exit 1; }

init_log_file "$(basename -- "$SITE").inventory.log"
exec > >(tee -a "$LOG_FILE") 2>&1

read -r -d '' NODE_INV <<'NODE_EOF' || true
const fs = require('fs');
const path = require('path');
const root = process.env.SITE_DIR;
const SKIP = new Set(['node_modules', 'dist', '.git']);
const files = [];
(function walk(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    if (SKIP.has(e.name)) continue;
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.isFile()) files.push({ rel: path.relative(root, p), size: fs.statSync(p).size });
  }
})(root);
const ext = (f) => (path.extname(f).slice(1) || '(none)').toLowerCase();
const kb = (n) => (n / 1024).toFixed(1) + ' kB';
const h = (t) => console.log('\n-- ' + t);

h('package.json');
try {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  console.log('name: ' + pkg.name + '  version: ' + pkg.version + '  type: ' + (pkg.type || '(unset)'));
  Object.entries(pkg.scripts || {}).forEach(([k, v]) => console.log('  script ' + k + ': ' + v));
  ['dependencies', 'devDependencies'].forEach((s) => {
    const o = pkg[s] || {};
    console.log(s + ' (' + Object.keys(o).length + '): ' + Object.entries(o).map(([k, v]) => k + '@' + v).join(', '));
  });
} catch (err) { console.log('none or unreadable (' + err.message + ')'); }

h('top-level entries');
fs.readdirSync(root, { withFileTypes: true }).filter((e) => !SKIP.has(e.name)).forEach((e) => {
  if (e.isDirectory()) {
    const inside = files.filter((f) => f.rel.startsWith(e.name + path.sep));
    console.log('  ' + e.name + '/  ' + inside.length + ' files, ' + kb(inside.reduce((a, f) => a + f.size, 0)));
  } else console.log('  ' + e.name);
});

h('files by extension');
const by = {};
files.forEach((f) => { const x = ext(f.rel); by[x] = by[x] || { n: 0, s: 0 }; by[x].n += 1; by[x].s += f.size; });
Object.entries(by).sort((a, b) => b[1].n - a[1].n).forEach(([x, v]) => console.log('  .' + x + ': ' + v.n + ' files, ' + kb(v.s)));

h('gulpfile tasks');
const gulpFiles = files.filter((f) => /^gulpfile(\.[a-z]+)?$/i.test(path.basename(f.rel)) || /^gulpfile\.js\//.test(f.rel));
if (!gulpFiles.length) console.log('  no gulpfile found');
gulpFiles.forEach((f) => {
  const t = fs.readFileSync(path.join(root, f.rel), 'utf8');
  const names = new Set();
  for (const m of t.matchAll(/gulp\.task\(\s*['"]([^'"]+)['"]/g)) names.add(m[1]);
  for (const m of t.matchAll(/exports\.([A-Za-z0-9_$]+)\s*=/g)) names.add(m[1]);
  for (const m of t.matchAll(/export\s+(?:async\s+)?(?:function|const)\s+([A-Za-z0-9_$]+)/g)) names.add(m[1]);
  console.log('  ' + f.rel + ': ' + (names.size ? [...names].join(', ') : '(no task names matched)'));
});

h('templates (.njk, .nunjucks, .html)');
const tpl = files.filter((f) => /\.(njk|nunjucks|html|htm)$/i.test(f.rel));
if (!tpl.length) console.log('  none');
const tags = ['extends', 'include', 'import', 'from', 'macro', 'set', 'for', 'if', 'block'];
const targets = new Map();
tpl.forEach((f) => {
  const t = fs.readFileSync(path.join(root, f.rel), 'utf8');
  const c = tags.map((k) => [k, (t.match(new RegExp('{%-?\\s*' + k + '\\b', 'g')) || []).length]).filter(([, n]) => n);
  const vars = (t.match(/{{/g) || []).length;
  console.log('  ' + f.rel + '  ' + kb(f.size) + '  vars:' + vars + (c.length ? '  ' + c.map(([k, n]) => k + ':' + n).join(' ') : ''));
  for (const m of t.matchAll(/{%-?\s*(extends|include|import|from)\s+['"]([^'"]+)['"]/g)) {
    const key = m[1] + ' ' + m[2];
    targets.set(key, (targets.get(key) || 0) + 1);
  }
});
if (targets.size) { console.log('  references:'); [...targets].sort().forEach(([k, n]) => console.log('    ' + k + ' (' + n + ')')); }

h('data files and CNAME');
const data = files.filter((f) => /\.(json|ya?ml)$/i.test(f.rel) && !/package(-lock)?\.json$/.test(f.rel) && !/(^|\/)\.[a-z]/i.test(f.rel));
if (!data.length) console.log('  no data files');
data.forEach((f) => console.log('  ' + f.rel + '  ' + kb(f.size)));
files.filter((f) => path.basename(f.rel) === 'CNAME').forEach((f) => console.log('  ' + f.rel + ': ' + fs.readFileSync(path.join(root, f.rel), 'utf8').trim()));

h('scripts and styles (not templates)');
['js', 'mjs', 'ts', 'tsx', 'jsx', 'scss', 'sass', 'less', 'css'].forEach((x) => {
  const l = files.filter((f) => ext(f.rel) === x && !/^gulpfile/.test(path.basename(f.rel)));
  if (l.length) console.log('  .' + x + ': ' + l.length + ' files; e.g. ' + l.slice(0, 5).map((f) => f.rel).join(', '));
});

h('20 largest asset files');
files.filter((f) => /\.(png|jpe?g|gif|svg|webp|avif|ico|woff2?|ttf|otf|eot|mp4|webm|pdf)$/i.test(f.rel))
  .sort((a, b) => b.size - a.size).slice(0, 20).forEach((f) => console.log('  ' + kb(f.size).padStart(11) + '  ' + f.rel));
NODE_EOF

size_of() { wc -c < "$1" | tr -d ' '; }

dump_full() {
    local f="$1" rel="${1#"${SITE}"/}"
    echo
    echo "#### ${rel} ($(size_of "$f") bytes)"
    cat -- "$f"
    echo
}

dump_capped() {
    local f="$1" rel="${1#"${SITE}"/}" n
    n="$(size_of "$f")"
    if (( n <= CAP )); then
        dump_full "$f"
    else
        echo
        echo "#### ${rel} (${n} bytes, over ${CAP}; first 40 lines)"
        head -n 40 -- "$f"
        echo "[truncated]"
    fi
}

dump_sources() {
    local f d
    echo
    echo "== source dump"
    for f in gulpfile.js readme.md README.md .gitignore CNAME; do
        if [[ -f "${SITE}/${f}" ]]; then dump_full "${SITE}/${f}"; fi
    done
    for d in dev/pages dev/templates dev/data; do
        [[ -d "${SITE}/${d}" ]] || { echo; echo "#### ${d}: not found"; continue; }
        while IFS= read -r f; do dump_full "$f"; done < <(find "${SITE}/${d}" -type f | LC_ALL=C sort)
    done
    if [[ -d "${SITE}/dev/js" ]]; then
        while IFS= read -r f; do dump_capped "$f"; done < <(find "${SITE}/dev/js" -type f -name '*.js' | LC_ALL=C sort)
    else
        echo; echo "#### dev/js: not found"
    fi
    if [[ -d "${SITE}/dev/scss" ]]; then
        echo
        echo "#### dev/scss: entry files in full, partials by size"
        while IFS= read -r f; do
            if [[ "$(basename "$f")" == _* ]]; then
                echo "  partial ${f#"${SITE}"/} ($(size_of "$f") bytes)"
            else
                dump_full "$f"
            fi
        done < <(find "${SITE}/dev/scss" -type f -name '*.scss' | LC_ALL=C sort)
    else
        echo; echo "#### dev/scss: not found"
    fi
}

log_info "inventory of ${SITE}"
echo "-- git"
if git -C "$SITE" rev-parse --is-inside-work-tree &>/dev/null; then
    echo "  branch: $(git -C "$SITE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')  HEAD: $(git -C "$SITE" log -1 --format='%h %s' 2>/dev/null || echo 'no commits')"
    echo "  dirty entries: $(git -C "$SITE" status --porcelain | wc -l)"
    git -C "$SITE" remote -v | sed 's/^/  /'
else
    echo "  not a git repository"
fi
SITE_DIR="$SITE" node -e "$NODE_INV" || echo "  FAILED (inventory error)"

if (( DUMP )); then dump_sources; fi

echo
echo "Log: $LOG_FILE"
