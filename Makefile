SHELL := /bin/bash
# macOS ships GNU Make 3.81, which ignores .SHELLFLAGS (3.82+): every recipe that pipes xcodebuild into grep
# starts with `set -o pipefail;` itself, or a failed build or test would exit 0.
.SHELLFLAGS := -o pipefail -c
PKG := Packages/YabbistirKit
DEST := platform=macOS,arch=arm64
ONLY ?=

.PHONY: generate build test run install extensions audit release-build release

generate:
	xcodegen generate --quiet

build: generate
	set -o pipefail; xcodebuild -project Yabbistir.xcodeproj -scheme Yabbistir -configuration Debug -destination '$(DEST)' -derivedDataPath DerivedData build 2>&1 | grep -E "error:|warning: .*\\.swift|BUILD (SUCCEEDED|FAILED)"

# make test                         -> whole package suite
# make test ONLY=YabCoreTests/Suite -> one test target or suite
test:
	set -o pipefail; cd $(PKG) && xcodebuild test -scheme YabbistirKit-Package -destination '$(DEST)' $(if $(ONLY),-only-testing:$(ONLY),) 2>&1 | grep -E "✘|error:|Test run with|TEST (SUCCEEDED|FAILED)|Issue recorded|Expectation failed"

run: build
	open DerivedData/Build/Products/Debug/yabbistir.app

# Copies the last build to ~/Applications so it opens from Spotlight/Launchpad. Only the copy there is stopped:
# a release installed in /Applications keeps running.
install:
	pkill -f "$(HOME)/Applications/yabbistir.app/Contents/MacOS/yabbistir" || true
	mkdir -p $(HOME)/Applications
	ditto DerivedData/Build/Products/Debug/yabbistir.app $(HOME)/Applications/yabbistir.app
	open $(HOME)/Applications/yabbistir.app

# Builds the built-in extensions: TypeScript in Extensions/builtin → Extensions/BuiltinExtensions,
# which the app bundles. If Extensions/reference exists (a local-only folder, absent in a public clone) it is built
# too, into Extensions/ReferenceExtensions, for tests only (never bundled). Needs Node; run after changing anything
# under Extensions/.
extensions:
	cd Extensions && npm ci --no-audit --no-fund && npm run typecheck && npm run build


# Scans the whole git history for secrets, personal paths, e-mails, big blobs and real-data traces.
# Exit 1 on findings; the report goes to build/audit.txt.
audit:
	mkdir -p build
	@scripts/publish-audit.sh > build/audit.txt; s=$$?; cat build/audit.txt; exit $$s

# A Developer ID signed Release build with hardened runtime and a secure timestamp, arm64 only.
# The app and its embedded helper (yabbistir-extension-host) are both signed. Output: build/yabbistir.app.
# Needs the "Developer ID Application" certificate in the login keychain; contacts Apple's timestamp server.
release-build: generate
	rm -rf build/DerivedData build/yabbistir.app
	set -o pipefail; xcodebuild -project Yabbistir.xcodeproj -scheme Yabbistir -configuration Release -destination 'platform=macOS,arch=arm64' \
		-derivedDataPath build/DerivedData \
		CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=9MX558XNV6 \
		OTHER_CODE_SIGN_FLAGS=--timestamp ENABLE_HARDENED_RUNTIME=YES ARCHS=arm64 ONLY_ACTIVE_ARCH=YES DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES build 2>&1 | grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)"
	ditto build/DerivedData/Build/Products/Release/yabbistir.app build/yabbistir.app
	# The next release-build wipes build/DerivedData, so keep the symbols for the shipped binaries.
	rm -rf build/dsym && mkdir -p build/dsym
	cp -R build/DerivedData/Build/Products/Release/*.dSYM build/dsym/ 2>/dev/null || true

# Signed, notarized and stapled app and DMG in build/ (needs the notarytool profile; submits to Apple twice).
# Refuses a dirty tree. See scripts/release.sh.
release:
	scripts/release.sh
