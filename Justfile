# The app's name as people see it ("Supreme Sampler"), read from
# PRODUCT_NAME in project.yml -- its one source. SupremeSampler, with no
# space, is only the module/scheme/project name. Backticks run a shell
# command when the Justfile loads, like $(...) in a shell.
app_name := `awk -F': *' '/^[[:space:]]*PRODUCT_NAME:/{gsub(/"/, "", $2); print $2; exit}' project.yml`

# Run `just` with no arguments to list recipes.
default:
    @just --list

# (Re)generate SupremeSampler.xcodeproj from project.yml.
generate:
    xcodegen generate

# Build in debug configuration.
build: generate
    xcodebuild -project SupremeSampler.xcodeproj -scheme SupremeSampler -configuration Debug build

# Build and launch the app.
run: build
    open "$(xcodebuild -project SupremeSampler.xcodeproj -scheme SupremeSampler -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/{{app_name}}.app"

# Run the test suite.
test: generate
    xcodebuild -project SupremeSampler.xcodeproj -scheme SupremeSampler -configuration Debug test -destination 'platform=macOS'

# Build a Release .app into dist/.
app: generate
    #!/usr/bin/env bash
    set -euo pipefail
    settings="$(xcodebuild -project SupremeSampler.xcodeproj -scheme SupremeSampler \
        -configuration Release -derivedDataPath .build -showBuildSettings 2>/dev/null)"
    products="$(printf '%s\n' "$settings" | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
    xcodebuild -project SupremeSampler.xcodeproj -scheme SupremeSampler \
        -configuration Release -derivedDataPath .build build
    app={{quote(app_name + ".app")}}
    rm -rf dist/*.app
    mkdir -p dist
    ditto "$products/$app" "dist/$app"

# Verify the packaged app: its name, universal binary, valid ad-hoc signature.
verify-app: app
    #!/usr/bin/env bash
    set -euo pipefail
    name={{quote(app_name)}}
    app="dist/$name.app"
    test -d "$app" || { echo "missing $app; run: just app" >&2; exit 1; }

    # The app menu shows CFBundleName, so check the name there, not just the
    # file name; a second copy in CFBundleDisplayName could drift again.
    info="$app/Contents/Info.plist"
    bundle_name="$(plutil -extract CFBundleName raw "$info")"
    test "$bundle_name" = "$name" || {
        echo "expected CFBundleName \"$name\", got: \"$bundle_name\"" >&2
        exit 1
    }
    if plutil -extract CFBundleDisplayName raw "$info" >/dev/null 2>&1; then
        echo "CFBundleDisplayName is set; the name belongs in PRODUCT_NAME only" >&2
        exit 1
    fi
    echo "name: $bundle_name"

    executable="$(plutil -extract CFBundleExecutable raw "$info")"
    archs="$(lipo -archs "$app/Contents/MacOS/$executable")"
    echo "architectures: $archs"
    case "$archs" in
        *arm64*x86_64*|*x86_64*arm64*) ;;
        *) echo "expected a universal binary, got: $archs" >&2; exit 1 ;;
    esac

    codesign --verify --strict --verbose=2 "$app"

    signature="$(codesign -dv --verbose=2 "$app" 2>&1 | awk -F= '/^Signature=/{print $2; exit}')"
    echo "signature: $signature"
    test "$signature" = "adhoc" || {
        echo "expected an ad-hoc signature, got: $signature" >&2
        echo "if a Developer ID identity was added, update this recipe and the plan's Context" >&2
        exit 1
    }

    echo "ok: named $name, universal, ad-hoc signed"

# Package the app in dist/ into dist/SupremeSampler-<version>.dmg.
dmg: (_dmg "false")

# Package the DMG the way CI does: no Finder cosmetics, works headless.
dmg-headless: (_dmg "true")

[private]
_dmg headless: verify-app
    #!/usr/bin/env bash
    set -euo pipefail
    # create-dmg's Finder AppleScript needs a GUI session; --skip-jenkins
    # skips it. The /Applications symlink is made before that step, so the
    # image stays functional -- it only loses icon positions and background.
    # Unquoted on purpose: bash 3.2 (GitHub's /bin/bash) errors on an empty
    # array under `set -u`, and word splitting is exactly what we want here.
    skip_jenkins=""
    if [ "{{headless}}" = "true" ]; then
        skip_jenkins="--skip-jenkins"
    fi
    command -v create-dmg >/dev/null || {
        echo "create-dmg not found; install with: brew install create-dmg" >&2
        exit 1
    }

    version="$(xcodebuild -project SupremeSampler.xcodeproj -scheme SupremeSampler \
        -configuration Release -derivedDataPath .build -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')"
    test -n "$version" || { echo "could not resolve MARKETING_VERSION" >&2; exit 1; }

    # The DMG's file name keeps the space-free name, so download URLs have
    # no %20; the app inside it carries the real name.
    name={{quote(app_name)}}
    rm -rf dist/dmg-stage
    mkdir -p dist/dmg-stage
    ditto "dist/$name.app" "dist/dmg-stage/$name.app"

    # Remove any previous image first: the guard below tolerates a non-zero
    # create-dmg exit when a valid DMG is present, and a stale file from an
    # earlier run would satisfy that check for a run that actually failed.
    rm -f "dist/SupremeSampler-$version.dmg"

    create-dmg \
        --volname "$name" \
        --window-size 540 380 \
        --icon-size 128 \
        --icon "$name.app" 140 190 \
        --app-drop-link 400 190 \
        --overwrite \
        $skip_jenkins \
        "dist/SupremeSampler-$version.dmg" dist/dmg-stage || {
            rc=$?
            # Tolerate a non-zero exit only if the image is actually usable.
            # Existence alone is not enough: a create-dmg that dies mid-write
            # leaves a truncated file that exists but cannot be mounted, and
            # reporting success for that would ship a broken artifact.
            if [ -f "dist/SupremeSampler-$version.dmg" ] \
                && hdiutil verify "dist/SupremeSampler-$version.dmg" >/dev/null 2>&1; then
                echo "create-dmg exited $rc but produced a valid DMG; continuing" >&2
            else
                echo "create-dmg failed (exit $rc) and left no valid DMG" >&2
                rm -f "dist/SupremeSampler-$version.dmg"
                exit "$rc"
            fi
        }

# Clear the quarantine flag on a packaged app or DMG (usage: just trust [path]).
trust path=("dist/" + app_name + ".app"):
    #!/usr/bin/env bash
    set -euo pipefail
    # `just` substitutes recipe parameters textually; quote() shell-quotes the
    # value so a path with spaces or quotes survives. (Parameters are not
    # passed as $1 or as environment variables.)
    target={{quote(path)}}
    test -e "$target" || { echo "no such path: $target" >&2; exit 1; }

    # The app is ad-hoc signed (no Developer ID, no notarization), so macOS
    # refuses to launch it once it carries com.apple.quarantine -- which any
    # copy that travelled through a browser, AirDrop, Mail or a download gets.
    # Clearing that attribute is the whole fix; the signature itself is valid.
    # -c clears all attributes, -r recurses into the bundle.
    xattr -cr "$target"

    if xattr -r "$target" 2>/dev/null | grep -q com.apple.quarantine; then
        echo "warning: quarantine attributes remain on $target" >&2
        exit 1
    fi
    echo "cleared quarantine on $target"
    echo "note: spctl still rejects an ad-hoc signature; that is expected and does not block launch."

# Build the latest stable release tag and install it in /Applications.
install:
    #!/usr/bin/env bash
    set -euo pipefail
    git fetch --tags --quiet origin
    # Stable means a plain vX.Y.Z tag; hand-made prereleases (v0.3.0-beta.1)
    # are skipped. sort -V orders 0.10.0 after 0.9.0, unlike plain sort.
    tag="$(git tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)"
    test -n "$tag" || { echo "no stable vX.Y.Z tag found" >&2; exit 1; }

    # Releases up to v0.2.0 were named SupremeSampler (bundle and process);
    # later ones are named Supreme Sampler. Check for either running.
    if pgrep -x 'SupremeSampler|Supreme Sampler' >/dev/null; then
        echo "Supreme Sampler is running; quit it before installing $tag" >&2
        exit 1
    fi

    # Build in a throwaway worktree so the current checkout (and any
    # uncommitted work in it) is untouched, using the tag's own Justfile.
    tree="$(mktemp -d)"
    trap 'git worktree remove --force "$tree" >/dev/null 2>&1 || true; rm -rf "$tree"' EXIT
    git worktree add --detach --quiet "$tree" "$tag"
    echo "building $tag"
    just --justfile "$tree/Justfile" --working-directory "$tree" verify-app

    # Install the bundle under the name the tag built it with, rather than
    # renaming it here: a rename would be a second copy of the name.
    shopt -s nullglob
    built=("$tree"/dist/*.app)
    test "${#built[@]}" -eq 1 || { echo "expected one .app in dist/, found ${#built[@]}" >&2; exit 1; }
    bundle="$(basename "${built[0]}")"
    dest="/Applications/$bundle"

    # Copy next to the destination first, then swap, so a failed copy never
    # leaves /Applications without the app.
    staged="/Applications/.$bundle.installing"
    rm -rf "$staged"
    ditto "${built[0]}" "$staged"
    rm -rf "$dest"
    mv "$staged" "$dest"
    # A copy under the other name would otherwise sit beside this one.
    for other in "/Applications/SupremeSampler.app" "/Applications/Supreme Sampler.app"; do
        if [ "$other" != "$dest" ]; then
            rm -rf "$other"
        fi
    done
    echo "installed $tag at $dest"

# Check that a release tag matches MARKETING_VERSION in project.yml.
release-check tag:
    scripts/release-version.sh check {{quote(tag)}}

# Bump MARKETING_VERSION, commit, tag and push a release (usage: just release 0.2.0).
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    version={{quote(version)}}
    case "$version" in
        *[!0-9.]*|.*|*.) echo "not a version: $version" >&2; exit 2 ;;
    esac
    # Reject leading zeros (00.2.0): semver forbids them, and sort -V treats
    # them as equal to the unpadded form, so they would slip past the ordering
    # guard below.
    if printf '%s' "$version" | grep -Eq '(^|\.)0[0-9]'; then
        echo "not a version: $version (leading zeros)" >&2
        exit 2
    fi
    IFS=. read -r major minor patch extra <<< "$version"
    if [ -n "${extra:-}" ] || [ -z "${major:-}" ] || [ -z "${minor:-}" ] || [ -z "${patch:-}" ]; then
        echo "not a version: $version (want X.Y.Z)" >&2
        exit 2
    fi
    test -z "$(git status --porcelain)" || { echo "working tree is dirty" >&2; exit 1; }
    test "$(git rev-parse --abbrev-ref HEAD)" = "main" || { echo "not on main" >&2; exit 1; }
    test -z "$(git tag -l "v$version")" || { echo "tag v$version already exists locally" >&2; exit 1; }
    test -z "$(git ls-remote --tags origin "v$version")" || { echo "tag v$version already exists on origin" >&2; exit 1; }
    current="$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/{print $2}' project.yml)"
    build="$(awk -F'"' '/^[[:space:]]*CURRENT_PROJECT_VERSION:/{print $2}' project.yml)"
    test "$(printf '%s' "$current" | grep -c .)" -eq 1 || { echo "expected exactly one MARKETING_VERSION in project.yml" >&2; exit 1; }
    test "$(printf '%s' "$build" | grep -c .)" -eq 1 || { echo "expected exactly one CURRENT_PROJECT_VERSION in project.yml" >&2; exit 1; }
    case "$build" in
        *[!0-9]*|"") echo "CURRENT_PROJECT_VERSION is not an integer: $build" >&2; exit 1 ;;
    esac
    # 10# forces base 10: a leading-zero build number (08) is invalid octal and
    # would otherwise abort the arithmetic, silently skipping the bump.
    next_build=$((10#$build + 1))
    test "$version" != "$current" || { echo "v$version is already the current version" >&2; exit 1; }
    printf '%s\n' "$current" "$version" | sort -V -C || { echo "v$version is not greater than v$current" >&2; exit 1; }
    sed -i '' "s/^\([[:space:]]*MARKETING_VERSION:[[:space:]]*\).*/\1\"$version\"/" project.yml
    sed -i '' "s/^\([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*\).*/\1\"$next_build\"/" project.yml
    # Verify both rewrites landed: a sed pattern that misses one line would
    # otherwise leave the tag and MARKETING_VERSION disagreeing.
    test "$(awk -F'"' '/^[[:space:]]*MARKETING_VERSION:/{print $2}' project.yml)" = "$version" \
        || { echo "MARKETING_VERSION was not rewritten to $version; check project.yml" >&2; exit 1; }
    test "$(awk -F'"' '/^[[:space:]]*CURRENT_PROJECT_VERSION:/{print $2}' project.yml)" = "$next_build" \
        || { echo "CURRENT_PROJECT_VERSION was not rewritten to $next_build; check project.yml" >&2; exit 1; }
    git add project.yml
    git commit -m "Release v$version"
    git tag "v$version"
    git push origin main
    git push origin "v$version"

# Remove build artifacts and the generated project.
clean:
    rm -rf SupremeSampler.xcodeproj DerivedData .build dist

# Redraw the app icon PNGs from scripts/make-app-icon.swift.
icon:
    swift scripts/make-app-icon.swift Sources/SupremeSampler/Assets.xcassets/AppIcon.appiconset

# (Re)generate the project and open it in Xcode.
xcode: generate
    open SupremeSampler.xcodeproj
