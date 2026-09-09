# gh-pages-toolkit

Bash scripts that bring GitHub Pages projects into exact parity with
one chosen profile, at three different starting points: new,
existing, and legacy (pre-migration). Each project is built under one
**profile**: a self-contained baseline for one category of site
(`vite-react` for client-routed SPAs, `astro-static` for prerendering
static-site generation). Profiles are never mixed; see "Master/child
relationship" below for why.

## Layout

```
web/
├── README.md          (this file)
├── .gitignore
├── logs/               (generated at runtime, gitignored, see Logging below)
├── configs/
│   └── base/
│       └── profiles/
│           ├── vite-react/       (client-routed SPA, see Master/child relationship)
│           │   ├── manifest.json
│           │   ├── package.json
│           │   ├── tsconfig.json
│           │   ├── eslint.config.js
│           │   ├── .nvmrc
│           │   ├── vite.config.ts
│           │   └── tool-roles.json
│           └── astro-static/     (prerendering static-site generation)
│               ├── manifest.json
│               ├── package.json
│               ├── tsconfig.json
│               ├── eslint.config.js
│               ├── .nvmrc
│               ├── astro.config.mjs
│               ├── src/content/config.ts
│               └── tool-roles.json
└── scripts/
    ├── init.sh
    ├── update.sh
    ├── convert.sh
    └── lib/
        └── common.sh
```

All commands below assume you're running from `web/` (the repo root),
invoking scripts as `./scripts/<name>.sh`. If you prefer to `cd
scripts/` first, use `./<name>.sh` instead; pick one and stay
consistent, since the two aren't interchangeable mid-session without
adjusting every relative `--master-config`/`--target`/`--source` path
you pass in.

Per this project's repo conventions, a `scripts/` directory is expected
to carry its own `scripts/lint.sh` (the `llm/scripts/lint.sh` template
pattern). That file isn't included here; paste its contents in if you
want it added rather than have one reconstructed from scratch.

## Prerequisites

Linux only. `bash` 4.0+, `node` 20+, `npm`, `git`, `jq`, `flock`
(`util-linux`), `sha256sum` (`coreutils`): all standard on any Linux
distribution. Every script checks for these at startup and fails
immediately with a clear error if one is missing (see `lib/common.sh`).

None of these scripts should be run with `sudo`. They create
`node_modules`, `dist`, and git commits that need to belong to your
normal user account; running as root will make those unusable
afterward and each script refuses to start under `EUID 0`.

## Master/child relationship

**A profile is the single source of truth for its category of site.
There is no drift between a profile and a child built under it, ever,
and profiles are never mixed within one project.**

A `vite-react` SPA and an `astro-static` prerendering site aren't two
variations of the same thing that happened to diverge; they're
different categories with different baselines by necessity (a
client-routed SPA produces one `index.html` for every route; a
prerendering generator produces a distinct file per route with its own
`<head>`, so no shared file set can honestly serve both). Forcing one
universal file set across every project is what would make "single
source of truth" too rigid to fit a project like this; letting each
project pick its own arbitrary config per-file is what reintroduces the
drift this toolkit exists to prevent. A profile is the resolution:
exactly one enforced baseline per category, chosen once per project, at
`init.sh` time, never layered or overridden afterward.

- For anything a profile declares (a script, a dependency and its
  version, `tsconfig.json`, `eslint.config.js`, `.nvmrc`), every child
  under that profile matches it exactly. If one child needs a new
  package that other children under the same profile will also need,
  it gets added to that profile directly, not pinned per-child, not
  layered on top via a second config. The profile is edited, and every
  child under it is re-synced via `update.sh`.
- A child may still declare `dependencies`/`devDependencies`/`scripts`
  entries its profile doesn't mention at all; those are genuinely
  project-specific (an MDX plugin for a blog, a payments SDK for a
  storefront) and are left untouched. **Exception:** a package or
  config file that fills the same role as something the profile already
  provides is not "unmentioned" just because its key name differs;
  see Tool roles below.
- `--master-config` takes exactly one directory (the profiles root),
  and `--profile` takes exactly one name, in every script. There is no
  overlay flag and no repeatable form for either: a single source of
  truth per category is the only way to guarantee no per-child version
  drift, and mixing pieces of two profiles on one project would be the
  same drift risk one level up.
- **Which files get brought to byte-for-byte parity, and which are
  hand-authored and only warned about, is declared per profile in that
  profile's `manifest.json`, not a fixed filename list true of every
  profile.** `vite-react`'s `manifest.json` names `tsconfig.json`,
  `eslint.config.js`, and `.nvmrc` as always-copy and `vite.config.ts`
  as hand-authored; `astro-static`'s names the same first three
  always-copy files plus `astro.config.mjs` and
  `src/content/config.ts` as hand-authored. `apply_master_config` in
  `lib/common.sh` reads whichever profile's `manifest.json` was
  resolved for the run; it has no hardcoded file list of its own.
  `package.json` is always merged field-by-field regardless of
  profile (`scripts`, `dependencies`, `devDependencies`): the profile's
  value always wins on any shared key, and child-only keys are
  preserved.
- `manifest.json` also declares `scaffold_command` (the actual
  `npm create ...` invocation `init.sh` runs, since a Vite scaffold and
  an Astro scaffold are different tools entirely) and
  `route_parity_check` (which named check, if any, `update.sh` should
  run for this profile, see "The three scripts" below).

### Tool roles

A key-by-key merge has a blind spot on its own: if a child has
`"lint": "oxlint"` and an `oxlint` devDependency, and the profile's
lint role is filled by `eslint` instead, the merge forces `scripts.lint`
to the profile's value but has no way to know `oxlint` the
*devDependency* is now an orphan: `oxlint` isn't a key the profile
mentions, so a pure key-by-key merge preserves it as if it were a
legitimate, unrelated, project-specific package.

Each profile's own `tool-roles.json` closes this gap. It's optional
per profile (absent means this step is a no-op for that profile), and
maps a role name to the packages and config files that role supersedes.
`vite-react`'s:

```json
{
  "lint": {
    "superseded_packages": ["oxlint", "tslint", "standard"],
    "superseded_config_files": [".eslintrc", ".eslintrc.json", ".eslintrc.js", ".oxlintrc.json", "tslint.json"]
  }
}
```

This closes more than a linter-naming gap. `astro-static`'s
`tool-roles.json` uses the same mechanism to enforce a framework-level
deploy-model conflict: this profile's architecture requires the
`actions/deploy-pages` Actions-artifact deploy flow, not the `gh-pages`
branch-publish CLI `vite-react` uses, so `gh-pages` is declared
superseded under a `deploy_mechanism` role, and gets stripped from any
`astro-static` child the same way `oxlint` gets stripped in favor of
`eslint`:

```json
{
  "deploy_mechanism": {
    "superseded_packages": ["gh-pages"],
    "superseded_config_files": []
  }
}
```

`remove_superseded_tooling` in `lib/common.sh` reads the resolved
profile's `tool-roles.json` and, for every role, removes any listed
package (from `dependencies` or `devDependencies`) and deletes any
listed config file if present in the target, before
`merge_package_json` ever reads the target's `package.json`, so a
package about to be removed here is never also logged as "child-only,
preserved" in the same run. This runs automatically as the first step
of `apply_master_config`, so both `init.sh` and `update.sh` enforce it,
for whichever profile was resolved.

**This is a maintained list, not a one-time setup, and that's expected
rather than a gap to eventually close.** `tool-roles.json` only detects
what it's told to detect: a newly-released competing linter, test
runner, bundler, or deploy mechanism that isn't yet added to the
relevant role's `superseded_packages`/`superseded_config_files` will
sit there undetected, the same blind spot this file exists to close for
the tools already listed. Keeping each profile's list current as its
ecosystem changes is an ongoing part of maintaining that profile, the
same way keeping `package.json`'s own pinned versions current is, not
a defect in the mechanism itself (Bash_Style_Guide §7: a keyword list
is only as complete as what's been added to it, and that's a real,
accepted tradeoff of matching by name at all, not a bug to fix later).

## The three scripts

| Script | Starting point | What it does |
|---|---|---|
| `init.sh` | Nothing (empty target) | Scaffolds a new project via the chosen profile's `scaffold_command`, brings it into parity with that profile |
| `update.sh` | An existing project | Re-enforces parity with the chosen profile, runs that profile's route parity check if `manifest.json` declares one |
| `convert.sh` | A legacy gulp+nunjucks project | Inventories the legacy project for LLM-assisted conversion, then scaffolds via `init.sh` under the chosen profile |

All three require both `--master-config` (the profiles root) and
`--profile` (which one), and all three default to a **dry run**: they
report what they'd do and write nothing until you pass `--apply`. All
three write a log to `logs/<target-basename>.<script>.log`, resolved
relative to the script's own location (`scripts/../logs`, i.e.
`web/logs/`) rather than `/tmp` (see Logging below).

None of these scripts publish anything (no `git push`, no `gh-pages -d
dist`, no `actions/deploy-pages` trigger). They stop at local,
reviewable file changes; publishing is a separate, manual step; see
"Build and publish" below.

`update.sh`'s route parity check (comparing `App.tsx`'s routes against
`vite.config.ts`'s SPA-routing `routes` array) is only meaningful for a
profile that actually has client-side routing in the first place.
Rather than guess this from whether `App.tsx` happens to exist,
`update.sh` reads the resolved profile's `manifest.json`
`route_parity_check` field: `"vite-react-spa"` runs the check,
anything else (including `astro-static`'s `"none"`) skips it with an
explicit log line stating why, not a silent file-not-found fallback.

## Hand-authored files are never auto-applied

GitHub Pages has no server-side rewrite, so a hard refresh or direct
link to any route but `/` 404s unless something serves that route's
HTML directly. `vite-react`'s SPA-routing plugin's job is exactly
that: copy `index.html` into a matching directory per pre-renderable
route, plus a `404.html` fallback for anything else. That's the
mechanism behind the warning below, not just a name for it.

Every profile's `manifest.json` names at least one file that mixes
structural and instance-specific concerns and is therefore never
copied, only warned about: `vite-react`'s `vite.config.ts` (React
support and the GH Pages SPA-routing plugin are structural; image
processing, dev-server proxies, hardcoded ports, and a project's own
routes array are not) and `astro-static`'s `astro.config.mjs` plus
`src/content/config.ts` (the latter's content-collection schema is
inherently per-project: a serial-fiction site's chapter frontmatter
and a blog's post frontmatter are different shapes). Copying any of
these wholesale would leak one project's specifics into every other
one under the same profile. Both `init.sh` and `update.sh` print a
warning pointing at each `hand_authored` file for manual review instead
of touching it; these are the files you edit by hand every time,
profile policy notwithstanding.

### Authoring App.tsx

No script touches `App.tsx`: it isn't in any profile's `manifest.json`
at all, and it's the one file with real page content in it, not
infrastructure config. Two things worth knowing when writing it by
hand under `vite-react`:

- Entry-file naming isn't universal. Vite's own scaffold defaults to
  `main.tsx`; some projects use `index.tsx` with a two-tier stylesheet
  pattern instead (a base CSS import in the entry file, a separate
  Sass layer in `App.tsx`). Neither is a rule this profile enforces;
  match whatever convention the actual project already uses.
- If `App.tsx` ends up with a near-identical wrapper repeated per
  route (the same layout component around every page, only the path,
  title, and data differing), generate it from a mapped array of
  `{path, title, Component, data}` instead of reproducing that block
  once per route. Same Bash_Style_Guide §4 rule already cited
  elsewhere in this README for shell duplication, just applying to a
  file this toolkit happens not to manage.

## vite-react: version and tooling rationale

Why this profile's `package.json` pins what it pins, not a copy of
the values themselves, which live in
`configs/base/profiles/vite-react/package.json` and would only go
stale here if repeated.

- **`vite` is pinned below `8.x`.** `vite@8.x` ships Rolldown as its
  default engine, and a confirmed, open issue
  ([rolldown/rolldown#9330](https://github.com/rolldown/rolldown/issues/9330))
  reports roughly 7× higher **dev-server** memory footprint than Vite 7
  on a large monorepo workload. Two things this isn't: a documented
  production build-time regression (independent reporting shows Vite 8
  builds getting *faster*, not slower), and universal (it's
  workload-dependent; a small project may never see it). The pin is
  about dev-server memory stability during active development, not
  build speed; re-evaluate it if that regression is ever fixed.
- **`@vitejs/plugin-react@^5.0.0` was confirmed against a real working
  repo**, not trusted from that package's own changelog claims. Real
  evidence outranks a changelog, but it's still not a guarantee this
  profile's exact dependency tree resolves identically for you; see
  the verification steps in "New project" below.
- **`.nvmrc` floats on `lts/*`** rather than pinning an exact Node
  version, a deliberate divergence from the exact-pin approach used
  for `vite`/`@vitejs/plugin-react`, not an inconsistency. Node version
  drift matters far less than bundler version drift for this profile's
  actual failure mode.
- **No `postcss.config.js`, `autoprefixer`, or `browserslist` field.**
  This is a decision, not a gap; add them only if a specific project
  needs a stated browser-support policy, don't add them by default
  just because their absence looks unusual.
- **`eslint.config.js` is ESLint 9's flat config.** ESLint 9 requires
  it; there's no `.eslintrc` equivalent to fall back to, which is why
  the file looks the way it does rather than following an older
  convention.

## Quick reference

Every invocation needs `--master-config ./configs/base` and one
`--profile`. Substitute your own `--target`/`--source` paths; `--apply`
is omitted below (dry run); add it to actually write anything.

| Task | Command |
|---|---|
| New `vite-react` project | `./scripts/init.sh --master-config ./configs/base --profile vite-react --target ../my-new-site` |
| New `astro-static` project | `./scripts/init.sh --master-config ./configs/base --profile astro-static --target ../my-new-site` |
| Re-sync existing `vite-react` project | `./scripts/update.sh --master-config ./configs/base --profile vite-react --target ../my-existing-site` |
| Re-sync existing `astro-static` project | `./scripts/update.sh --master-config ./configs/base --profile astro-static --target ../my-existing-site` |
| Convert legacy site to `vite-react` | `./scripts/convert.sh --source ../old-site --target ../new-site --master-config ./configs/base --profile vite-react` |
| Convert legacy site to `astro-static` | `./scripts/convert.sh --source ../old-site --target ../new-site --master-config ./configs/base --profile astro-static` |

See "Usage" below for what each command actually does; see
"Master/child relationship" for why `--profile` isn't optional and
can't be stacked.

## Usage

### New project

```bash
./scripts/init.sh --master-config ./configs/base --profile vite-react --target ../my-new-site --apply
```

Runs the profile's `scaffold_command` (`npm create vite@latest ...
--template react-ts` for `vite-react`; `npm create astro@latest ...`
for `astro-static`), then brings `package.json` into parity (the
profile's scripts/dependencies win, child-only keys, none yet on a
fresh scaffold, would be preserved) and overwrites every file in the
profile's `manifest.json` `always_copy` list with the profile's
versions. The scaffold tool ships its own default config files;
`copy_template_file` always overwrites rather than skipping on an
existing file, so the profile's versions replace them. Stops with a
warning to hand-review each file in `manifest.json`'s `hand_authored`
list.

For `vite-react`, verify the pin actually resolves in this project
before writing application code; a real precedent for one repo isn't
a guarantee for every dependency tree:

```bash
npm install
npx vite -v      # expect a 7.x version, not 8.x
npm run build    # must complete without plugin resolution errors
```

If `npx vite -v` prints `8.x`, `node_modules` has a stale install:
`rm -rf node_modules package-lock.json && npm install` and recheck. If
`npm run build` fails on plugin resolution, don't work around it with
a version bump that pulls in Vite 8; that reintroduces the regression
this profile pins against in the first place.

### Existing project

```bash
./scripts/update.sh --master-config ./configs/base --profile vite-react --target ../my-existing-site
```

Run without `--apply` first; it reports what's out of parity (which
`package.json` keys the profile would force to a different value,
which `always_copy` files don't byte-for-byte match the profile, and,
for `vite-react` only, any mismatch between `App.tsx`'s routes and
`vite.config.ts`'s SPA-routing `routes` array) without writing
anything. Add `--apply` to actually write the parity-enforcing changes.
For a profile like `astro-static` whose `manifest.json` declares
`"route_parity_check": "none"`, that check is skipped outright with a
log line saying why, rather than silently no-op'd on missing files.

The route-parity check itself (when it runs) is grep-based, not a real
parser: it expects a flat string-literal `path="..."` style (as used
throughout this profile's own templates) and will miss a route path
built from a template literal or split across lines. It correctly
excludes dynamic segments (`:id`) and the catch-all (`*`) from the
comparison, since those can't appear in the static pre-render `routes`
array either.

### Legacy gulp+nunjucks project

```bash
./scripts/convert.sh --source ../old-site --target ../new-site \
  --master-config ./configs/base --profile vite-react --apply
```

This does **not** attempt to auto-convert nunjucks templates into the
target profile's components; that's a semantic re-authoring task, not
a mechanical one, and treating it as automatable is how a conversion
script produces confidently wrong output. Instead it builds a
structured JSON inventory at
`logs/inventory/<target-basename>_inventory.json`:

```json
{
  "pages": [
    { "path": "pages/example.njk", "extends": "base.njk", "includes": ["header.njk", "card.njk"] }
  ],
  "shared_macros": [
    { "macro": "example_card", "used_in_files": 5 }
  ]
}
```

- `pages` resolves each template's `{% extends %}` parent and `{%
  include %}` children, so an LLM conversion pass gets one page's full
  assembled context at once instead of a base template and its
  fragments with no stated relationship.
- `shared_macros` is the highest-value signal in the inventory: a
  macro used across multiple templates is a de facto reusable
  component candidate, close to a mechanical mapping to a component
  with props under whichever profile is the conversion target.

This inventory logic is itself profile-agnostic: it describes the
legacy *source*, not the target profile, so nothing about it changes
based on `--profile`.

This is also a grep-based extraction, not a real nunjucks parser;
known limitation: a macro or include referenced via a computed/variable
path (not a literal string) won't be found.

With `--apply`, `convert.sh` writes the inventory and then calls
`init.sh` to scaffold the target project skeleton against the same
`--master-config`/`--profile` you passed in. That scaffold is at full
profile parity from the moment it's created; nothing left to do there.
What's left is entirely the content-porting work `convert.sh`
deliberately doesn't automate. In order:

1. **Read the inventory.** Open
   `logs/inventory/<target-basename>_inventory.json`. `shared_macros`
   is sorted by nothing in particular; re-sort or scan it yourself for
   the highest `used_in_files` counts first, those are your best
   component candidates.
2. **Author each shared macro as a real component before touching any
   page**, highest `used_in_files` first. Under `vite-react`, a
   component under `src/components/`; under `astro-static`, an
   `.astro` component under `src/components/`. Every page that used
   that macro will import this component instead of duplicating markup.
3. **For `astro-static` only: define the content-collection schema in
   `src/content/config.ts` before porting any page**, if pages will be
   stored as collection entries rather than standalone `.astro` files.
   This file is in `manifest.json`'s `hand_authored` list for exactly
   this reason: it has to exist and match your actual content shape
   before content depending on it can be added.
4. **Port pages one at a time, using `pages`' `extends`/`includes`
   fields to know what to gather.** For each entry, that page's real
   content is spread across its base template plus every included
   fragment; assemble all of them (or point an LLM conversion pass at
   all of them together) as one unit, not the base template alone.
   Route the ported result per profile: a new `<Route>` in `App.tsx`
   plus, if the route is static, a matching entry in `vite.config.ts`'s
   `routes` array for `vite-react`; a new page file or collection entry
   for `astro-static`.
5. **Migrate the assets each page's template chain actually
   references** (images, fonts) to the profile's convention
   (`public/` for either profile, or `src/assets/` if the profile's
   own template already uses that pattern) as you port that page, not
   as a separate bulk pass afterward, so a missing asset surfaces
   immediately against the one page that needs it.
6. **Build after every page, not once at the end.** `npm run build`
   (both profiles use this script name). A break introduced by page 3
   should be caught before page 4 is ported on top of it.
7. **Run `update.sh` against the finished project once every page is
   ported.** This is the actual completion check: a clean, no-drift
   report means the converted project is genuinely on the profile with
   nothing project-specific left over from the conversion process
   itself, not just "the pages look right."
8. **Only after step 7 reports no drift**, treat the conversion as
   done and retire the legacy source.

Nothing enforces this order or tracks partial progress across
sessions; if a conversion spans multiple sessions, note which pages
are ported yourself (a checklist in the new repo, an issue, whatever
fits): `convert.sh` doesn't have a "half-converted" state of its own to
resume from.

## Build and publish

Every profile's `predeploy-check` script builds to `dist/` and stops
there; publishing is always a separate, explicit step after that, not
something either script above does for you:

```bash
npm run predeploy-check
npx gh-pages -d dist
```

Before the first publish, confirm the repo's GitHub Pages settings
point at the `gh-pages` branch (Settings → Pages → Source).

**If this repo is a submodule child of a parent monorepo, stop at
`npm run predeploy-check`.** Don't run `gh-pages -d dist` from inside a
submodule child; publishing happens from the parent after it advances
this submodule's pinned commit, on the parent's own trigger, not from
a script inside the child. Decide which case applies (standalone repo
with its own Pages site, or submodule child that only builds and
verifies itself) before the first publish, since it changes whether
this repo has a publish step of its own at all.

## Logging

Every script's `LOG_FILE`, and `convert.sh`'s inventory JSON, resolve
under `logs/` at the repo root (`web/logs/`) via `init_log_file` in
`lib/common.sh`: never `/tmp`, and never dependent on the caller's
current directory. This matches the same script-relative-default
principle already applied to `.nvmrc`/master-config resolution
elsewhere in these scripts (Bash_Style_Guide §5: a default output path
should resolve relative to the script's own location, not the caller's
cwd).

`logs/` is created automatically on first run and is gitignored as a
single directory entry (see `.gitignore` below) rather than as a set
of per-extension patterns, since everything under it is disposable
runtime output, not a mix of tracked and untracked files.

## `.gitignore`

```gitignore
# All toolkit-generated output (logs and the convert.sh inventory)
# lives under one directory, ignored as a whole rather than by
# per-extension pattern (see Logging above).
logs/

# Defensive: node_modules/dist should never legitimately appear in this
# repo (init.sh/convert.sh scaffold into a separate --target), but
# ignore them in case a target is ever pointed here by mistake
node_modules/
dist/

# OS / editor cruft
.DS_Store
*.swp
*~
```

`configs/` (including every profile under it) is **not**
covered by any of the above; it's source content the scripts read
from, not generated output, and stays tracked.

## Design notes

- **`init.sh`, `update.sh`, and `convert.sh` are independent
  entry points**, not subcommands of a dispatcher: there's no
  existing orchestrator script this suite hooks into (unlike, e.g., a
  `submodule_ctl.sh`-style parent), so there was nothing to match by
  keeping them separate.
- **`--master-config` names the profiles root; `--profile` selects
  which subdirectory under it is the effective master config for this
  run** (`PROFILE_DIR="${MASTER_CONFIG}/profiles/${PROFILE}"`, in
  every script). This is still exactly one source of truth per
  invocation, just addressed in two parts instead of one path; the
  two-part addressing is what makes adding a second profile a new
  directory plus a new `manifest.json`, not a code change to
  `apply_master_config` itself.
- **The parity-enforcement logic lives once, in `lib/common.sh`'s
  `apply_master_config`**, and both `init.sh` and `update.sh` call it
  directly rather than each re-implementing the package.json merge and
  the manifest-driven file copy loop. `init.sh` applies it to an empty
  target, `update.sh` applies it as a re-sync against an existing
  target, `convert.sh` applies it indirectly by calling `init.sh` with
  `--profile` threaded through; same underlying operation, three call
  sites, one implementation, now working from whichever profile was
  resolved rather than a hardcoded file list.
- **`apply_master_config` reads `manifest.json`'s `always_copy` and
  `hand_authored` arrays instead of a fixed `for f in tsconfig.json
  eslint.config.js .nvmrc` loop.** This is what lets `astro-static`
  declare a different hand-authored set (`astro.config.mjs` plus
  `src/content/config.ts`, versus `vite-react`'s single
  `vite.config.ts`) without any change to the function itself; a
  third profile with yet another file set is a manifest change, not a
  script change.
- **`manifest.json` is read via `jq`, so it needs the same `jq empty`
  validation `tool-roles.json` already had**, for the identical reason:
  `apply_master_config` reads it via `< <(jq -r '.always_copy[]?'
  ...)`, and a command's failure inside `< <(...)` isn't visible to
  `set -e` (see the caveat comment near the top of `lib/common.sh`).
- **Every script takes a non-blocking `flock` on its target** via
  `acquire_target_lock`, scoped to a hash of the target's canonicalized
  path, so two runs against the same target can't execute concurrently
  while runs against different targets never block each other.
  `convert.sh` locks `--source` rather than `--target`, since it
  invokes `init.sh` as a separate process against the same target at
  the end of its run; locking the target itself first would make
  `init.sh`'s own lock attempt fail every time.
- **`remove_superseded_tooling` runs first inside `apply_master_config`**,
  before `merge_package_json` reads the target's `package.json`. A
  package about to be removed as superseded must not also be logged as
  "child-only, preserved" by `report_package_changes` in the same run;
  ordering this any other way would produce a log that contradicts
  itself within a single invocation.
- **`reject_if_already_set` and `resolve_profile_dir` centralize
  `--master-config`/`--profile` validation** for all three scripts.
  `resolve_profile_dir` sets `PROFILE_DIR` and is the only place that
  checks for a missing flag, a missing directory, or a missing
  profile, each with its own distinct error message, so no script's
  copy of this logic can drift from another's.
- **Node version checks extract the numeric major version and compare
  with `(( ))`**, never `[[ x < y ]]` string comparison: `"v9"` sorts
  after `"v22"` lexicographically, a real bug class documented in
  `Bash_Style_Guide.md` §2.
