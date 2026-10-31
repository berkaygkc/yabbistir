# Contributing

Thanks for your interest in yabbistir! Bug reports and pull requests are welcome.

## Building and testing

You need macOS 26, Xcode 26.2+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make test      # run the package test suite
make build     # generate the Xcode project and build the app
make install   # copy the build to ~/Applications and open it
```

The Xcode project is generated from `project.yml`; don't edit `Yabbistir.xcodeproj` by hand. The built-in extensions are TypeScript: after changing anything under `Extensions/`, run `make extensions` (needs Node).

A dev build is named "yabbistir Dev" and has its own bundle ID (`dev.yabbistir.app.debug`), so macOS keeps separate Accessibility and Input Monitoring entries for it and for an installed release. It uses the same history. Launching one quits the other, so only one copy is running at a time.

Tests that open a window on screen only run with `TEST_RUNNER_YAB_ONSCREEN=1`.

## Extensions

Third-party extensions live in their own repository, `yabbistir-extensions` (coming soon). Extension authors don't need to build the app; they build against the extension API and drop the result into a folder.

## Guidelines

- **Keep it native.** AppKit and SwiftUI, macOS 26 Liquid Glass. Design details matter here: spacing, type, motion and every state (hover, selected, empty) are worth getting right, and a change should look like it belongs next to the rest of the app.
- **Nothing leaves the Mac unless the user asks.** No background network calls, no analytics.
- **Code comments are in English.**
- **User-visible text goes in the String Catalogs** (English and Turkish), never in code.
- **Before opening a pull request**, make sure `make test` passes. Run `make audit` if you touched repository files or history.
