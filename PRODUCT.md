# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

## Stack

Swift + SwiftUI, macOS 14+, GRDB.swift for read-only SQLite, XcodeGen with
`project.yml` as the tracked source of truth (the `.xcodeproj` is gitignored
and regenerated). Existing, not a decision to revisit.

## Users

One user: the repo owner, working against their own Photo Supreme (IDimager)
catalog of several million items. They are not a developer of Photo Supreme and
have no API access to it — the catalog file on disk is the only interface.

The job: pull a random sample of photos out of that catalog, narrowed by
metadata, so a manageable subset can be worked on. The catalog is far too
large to browse or hand-pick from, and Photo Supreme's own UI has no
"give me N random photos matching this filter" operation.

This is a personal tool. No other users, no distribution, no multi-user or
multi-catalog concerns are in scope.

## Product Purpose

SupremeSampler generates Photo Supreme `.psc` scripts that random-sample
photos from a large catalog, filtered by metadata (rating, category/keyword).

It reads the Photo Supreme SQLite catalog directly — read-only, always — to
build filters and show a live pre-flight match count before any script is
generated. It does not write to the catalog, and it does not run scripts: it
produces `.psc` source for the user to review and run inside Photo Supreme's
own Script Studio.

Success means the generated script compiles and runs in Script Studio and
returns the sample the filter described — the count shown in the app and the
photos the script actually selects agree.

## Positioning

Two mechanisms a neighboring tool could not truthfully copy:

- **Live pre-flight against the real catalog.** The app opens the actual
  catalog file (WAL-aware, read-only) and counts matching photos as the filter
  is edited, so the user never generates a script for a filter they haven't
  already validated against real data.
- **Random-rowid sampling in the emitted script.** The generated `.psc` draws
  random rowids and keeps the ones that match, rather than
  `ORDER BY RANDOM() LIMIT N` — roughly 10x faster on the real catalog, because
  the latter still evaluates `RANDOM()` for every row passing the `WHERE`
  clause.

The catalog schema knowledge behind both is reverse-engineered and documented
locally; it is not published by IDimager.

## Operating Context

- **Photo Supreme Script Studio** is where generated scripts are pasted,
  reviewed, compiled, and run. It is closed-source, embedded, and does not
  support the full Delphi/Object Pascal language — see the interpreter quirks
  below.
- **The pascal repo** (`~/Projects/pascal/photo supreme`) is a
  separate git repo holding the actual generated and hand-written `.psc`
  scripts. Its git history is a curation audit trail, not app source history.
  The app writes into that directory but does not own its history.
- **Reverse-engineered schema docs** live at
  `~/Pictures/Photo Supreme/docs` (`schema.md`,
  `relationships.md`, `queries.md`, `write-behavior.md`, `schema.sql`). These
  are the authority for any query logic.
- **`RandomCatalogSample.psc`** in the pascal repo is the real, committed,
  verified-compiling-and-running reference script the generator's boilerplate
  was hand-transcribed from.
- **The catalog changes while the app is open** (WAL mode). Connections are
  read-only (`mode=ro`) and no stable snapshot across queries is assumed.

## Capabilities and Constraints

**Filters available today**

- Rating: exactly / at least / at most, value 0–5.
- Category/keyword: any of / all of / none of, chosen from a genuine
  hierarchical multi-select tree (cmd/shift-click, native macOS `List`).
  Selecting a category or keyword includes all of its subcategories.
- Sample size: 1…1,000,000, step 100, default 10,000.
- Rules combine in groups — Match all / any / none of — and a group can
  contain nested groups, Lightroom Smart Collection style. A "none of"
  group excludes photos. The builder starts empty (whole catalog).

**Hard constraints**

- **Read-only, always.** The app never writes to the live catalog. The catalog
  has no foreign keys, only triggers, cascading deletes, and non-stable rowids
  — writing to it from outside Photo Supreme is unsafe.
- **The app does not run scripts.** Output is source text for the user to run.
- **Copy-to-clipboard is the current save action.** There is no save-to-file
  yet; the user pastes into Script Studio to review and test before anything
  is written to disk.
- **Not sandboxed.** No security-scoped bookmark handling; a plain path string
  is persisted for the last-opened catalog. Sandboxing would require revisiting
  both the picker and the recent-catalog store.
- **Photo Supreme's built-in categories are deliberately excluded** from the
  picker. Built-in categories have brace-wrapped GUIDs (`{XXXXXXXX-…}`);
  user-created ones are plain 32-character hex. Only user-created categories
  are listed. This is a deliberate choice, not an oversight.
- **Generated script text is constrained by the Photo Supreme interpreter:**
  `Random` takes no parameters; `try…except…raise` is unsupported (only
  `try…finally`); a `const` section cannot interleave multiple declarations
  with comments; long multi-paragraph `//` comments can break compilation;
  Script Studio's reported error position is unreliable. Generated scripts
  therefore keep comments to one or two lines and put documentation elsewhere.
- **Two independent predicate renderers exist on purpose** — plain SQL text for
  the generated script, GRDB-parameterized for live queries. A semantic change
  to a rating or category rule must be made in both.

**Confirmed direction (not yet built)**

- Saving the generated script to disk, replacing clipboard-only as the save
  action.
- More filter dimensions beyond rating and category.

**Platform vocabulary gap:** this is a native macOS app, but the Impeccable
product schema only recognizes `web`, `ios`, `android`, and `adaptive`. The
truthful value `macos` is recorded above; tooling that does not recognize it
falls back to treating the project as `web`. Do not "fix" this to `web` — the
app renders macOS AppKit/SwiftUI, not HTML/CSS, so web-only tooling
(`impeccable detect`, browser-based verification, `live`) has no verdict here.
Treat it as a native Apple-platform project and verify by running the app.

## Brand Commitments

The name **SupremeSampler** and bundle identifier
`com.nateledford.SupremeSampler` are established. No brand assets, voice
guidelines, or identity constraints beyond that were established — the app
icon and accent color are unset asset-catalog slots.

## Evidence on Hand

- A real Photo Supreme catalog of several million items, used for benchmarking
  and manual verification.
- The verified-compiling reference script
  `~/Projects/pascal/photo supreme/RandomCatalogSample.psc`.
- The reverse-engineered schema documentation at
  `~/Pictures/Photo Supreme/docs`.
- A 98%+ source-coverage test suite, including a line-for-line comparison
  against the real reference script.

**Absences future work must not fabricate:** no testimonials, customers,
benchmarks beyond the ~10x sampling note above, pricing, licensing terms,
screenshots, or deployment claims exist. This is a personal tool with one user.

## Product Principles

1. **Read-only, always.** The catalog is an irreplaceable library. No feature
   justifies writing to it from this app.
2. **Generate, don't execute.** The deliverable is reviewable source text the
   user runs in Photo Supreme. The app never becomes a script runner.
3. **Pre-flight truth before generation.** The live match count is the point of
   the app. Never let a script be generated for a filter the user hasn't seen
   validated against real data.
4. **Filtering is the core.** The rule builder is where the product's value
   lives. Extend it — subgroups, include/exclude — rather than adding adjacent
   features.
5. **Personal-tool honesty.** One user, one catalog. No onboarding ceremony, no
   multi-user abstraction, no distribution scaffolding until explicitly asked
   for.