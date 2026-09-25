# SupremeSampler

A macOS app that builds random-sample scripts for
[Photo Supreme](https://www.idimager.com) (IDimager). You describe which
photos you want with Lightroom-style smart-collection rules, see how many
photos in your catalog match, and get a `.psc` script that picks a random
sample of them. You then run that script in Photo Supreme's Script Studio.

It's a personal tool, built for one very large catalog, and it isn't
affiliated with IDimager.

## What it does

- **Opens your catalog read-only.** It reads the Photo Supreme SQLite catalog
  (`.cat.db`) directly and never writes to it.
- **Builds rules like a Lightroom Smart Collection.** Groups match *all*,
  *any* or *none* of their rules, and groups can nest. Each rule reads as one
  line: `[Field] [operator] [value]`. The fields are:
  - **Rating** (is, is at least, is at most, is not)
  - **Keyword**: pick keywords from the category tree, where a parent includes
    everything under it, or match a keyword's path text such as
    `Nature\Trees\Oak`
  - **File path**
  - **Color label**
  - **File type**
  - **Bookmark**
  - **Pending deletion**
- **Shows a live match count** against the real catalog as you edit, before
  any script exists.
- **Can balance the sample across folders**, so a few huge folders don't take
  over the sample.
- **Generates the script and shows it as you edit.** You can copy it, or save
  it as a `.psc` file (UTF-8, LF line endings).

It doesn't run scripts itself. Photo Supreme has no API, so the generated
script is what does the sampling, inside Photo Supreme.

## Requirements

- macOS 14 or later
- Xcode (Swift 5.10)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): the Xcode project is
  generated from `project.yml` and isn't checked in
- [just](https://github.com/casey/just), optional, for the shortcuts below
- A Photo Supreme catalog to point it at

## Build and run

```bash
brew install xcodegen just
```

```bash
just run
```

Other recipes (run `just` to list them all):

| Command | What it does |
|---|---|
| `just generate` | Regenerate `SupremeSampler.xcodeproj` from `project.yml` |
| `just build` | Debug build |
| `just test` | Run the test suite |
| `just xcode` | Regenerate the project and open it in Xcode |

Without `just`, run `xcodegen generate` and then build the `SupremeSampler`
scheme in Xcode.

On first launch, choose your catalog file. The app reopens it on later
launches, and File › Open Catalog… (⌘O) switches catalogs.

## Releases

Releases are cut by pushing a `vX.Y.Z` tag. `just release X.Y.Z` bumps
`MARKETING_VERSION` in `project.yml`, commits, tags and pushes; the `Release`
workflow then builds the DMG and publishes a GitHub Release with the DMG and a
`SHA256SUMS` file attached. The workflow refuses a tag that disagrees with
`MARKETING_VERSION`, so the tag and the built app can't drift apart.

The very first release is the exception: `MARKETING_VERSION` is already `0.1.0`,
and `just release` refuses a version equal to the current one, so tag it by hand
(`git tag v0.1.0 && git push origin v0.1.0`). Every later release goes through
`just release X.Y.Z`.

The DMG is **ad-hoc signed, not notarized**, so macOS quarantines it and
refuses the first launch. Right-click the app in Applications and choose
**Open**, or run:

```bash
xattr -cr /Applications/SupremeSampler.app
```

## Versioning

The version lives in `project.yml` (`MARKETING_VERSION`); the git tag is
`v<MARKETING_VERSION>`, and the release workflow refuses a tag that disagrees.

- **Major** — a change that makes a previously generated `.psc` script select
  different photos or stop compiling in Script Studio; a removed rule kind or
  operator; a raised macOS floor. (The app persists no filters, so there is no
  saved-filter contract to break.)
- **Minor** — additive: a new rule kind, operator, folder-balance mode, or
  script capability, where existing scripts behave identically.
- **Patch** — a fix that restores intended behavior without changing the
  contract; docs, icon, CI, dependency bumps.

While the version is `0.y.z`, `y` is a feature and `z` is a fix, and `0.y.0` is
reserved for anything that would be major at 1.0.0. **`1.0.0` is the gate for
"the generated-script contract is stable"**, which is not yet met: folder
balance and keyword path rules have not been run in Script Studio.

Prereleases (`v0.2.0-rc.1`) are tagged by hand, not via `just release`, which
accepts only `X.Y.Z`. A prerelease tag is accepted by the release workflow when
its core matches `MARKETING_VERSION`, and is published with `--prerelease`.

## Using a generated script

1. Build a filter and check the match count at the top of the rules. It warns
   when fewer photos match than the sample size asks for.
2. Click **Copy** in the toolbar (Edit › Copy Script, ⇧⌘C) and paste the
   script into Photo Supreme's Script Studio, or **Save…** it as a `.psc` file
   (File › Save Script…, ⌘S).
3. Run it in Script Studio. The sample opens in a new Photo Supreme tab.

Photo Supreme's script interpreter is a limited, closed-source Object Pascal
dialect. The generator keeps to the parts known to work: generated SQL is
plain ASCII, and script comments are kept short. Two features haven't yet been
run in Script Studio itself, only against Photo Supreme's bundled SQLite:
folder balance and keyword path rules. If a script fails to compile, please
open an issue with the script attached.

## Project layout

```
Sources/SupremeSampler/
  Catalog/           read-only catalog access (GRDB) and the filter model
  ScriptGeneration/  .psc generation: SQL rendering, file encoding
  UI/                SwiftUI views and the view model
Tests/SupremeSamplerTests/
project.yml          XcodeGen spec (source of truth for the Xcode project)
AGENTS.md            detailed design notes and conventions
PRODUCT.md           who it's for and what it's for
```

[`AGENTS.md`](AGENTS.md) has the full design notes. It explains why the
catalog is only ever opened read-only, how the two SQL renderers are kept in
agreement, and the Script Studio quirks the generator works around. Read it
before changing query or script-generation code.

## License

[MIT](LICENSE). Photo Supreme and IDimager are the property of their
owners; this project isn't affiliated with or endorsed by them.
