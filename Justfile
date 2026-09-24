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
    open "$(xcodebuild -project SupremeSampler.xcodeproj -scheme SupremeSampler -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')/SupremeSampler.app"

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
    rm -rf dist/SupremeSampler.app
    mkdir -p dist
    ditto "$products/SupremeSampler.app" dist/SupremeSampler.app

# Verify the packaged app: universal binary, valid ad-hoc signature.
verify-app: app
    #!/usr/bin/env bash
    set -euo pipefail
    app="dist/SupremeSampler.app"
    test -d "$app" || { echo "missing $app; run: just app" >&2; exit 1; }

    archs="$(lipo -archs "$app/Contents/MacOS/SupremeSampler")"
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

    echo "ok: universal, ad-hoc signed"

# Package dist/SupremeSampler.app into dist/SupremeSampler-<version>.dmg.
dmg: verify-app
    #!/usr/bin/env bash
    set -euo pipefail
    command -v create-dmg >/dev/null || {
        echo "create-dmg not found; install with: brew install create-dmg" >&2
        exit 1
    }

    version="$(xcodebuild -project SupremeSampler.xcodeproj -scheme SupremeSampler \
        -configuration Release -derivedDataPath .build -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')"
    test -n "$version" || { echo "could not resolve MARKETING_VERSION" >&2; exit 1; }

    rm -rf dist/dmg-stage
    mkdir -p dist/dmg-stage
    ditto dist/SupremeSampler.app dist/dmg-stage/SupremeSampler.app

    # Remove any previous image first: the guard below tolerates a non-zero
    # create-dmg exit when a valid DMG is present, and a stale file from an
    # earlier run would satisfy that check for a run that actually failed.
    rm -f "dist/SupremeSampler-$version.dmg"

    create-dmg \
        --volname SupremeSampler \
        --window-size 540 380 \
        --icon-size 128 \
        --icon SupremeSampler.app 140 190 \
        --app-drop-link 400 190 \
        --overwrite \
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
trust path="dist/SupremeSampler.app":
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

# Remove build artifacts and the generated project.
clean:
    rm -rf SupremeSampler.xcodeproj DerivedData .build dist

# (Re)generate the project and open it in Xcode.
xcode: generate
    open SupremeSampler.xcodeproj
