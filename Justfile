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

# Remove build artifacts and the generated project.
clean:
    rm -rf SupremeSampler.xcodeproj DerivedData

# (Re)generate the project and open it in Xcode.
xcode: generate
    open SupremeSampler.xcodeproj
