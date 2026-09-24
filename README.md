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

## Using a generated script

1. Build a filter and check the match count.
2. Click **Copy** and paste the script into Photo Supreme's Script Studio, or
   **Save…** it as a `.psc` file (File › Save Script…, ⌘S).
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
