# Contributing to Kronos

Thanks for looking. Kronos is a small, opinionated app: the bar for a change is "does it lower the energy it takes to start the next task?". Removing a step beats adding a control.

## Before you open a pull request

- **Open an issue first** for anything larger than a fix, so nobody builds something that will not be merged.
- **Build and test:**
  ```sh
  xcodegen generate
  xcodebuild -scheme Kronos -configuration Alpha -derivedDataPath build build   # must finish with zero warnings
  cd Packages/KronosCore && swift test
  ```
- **Logic goes in `Packages/KronosCore`** with a test. The core has no UI dependency; keep it that way.
- **User-facing text** lives in `Kronos/Resources/Localizable.xcstrings`, in English and Croatian, with literal keys (a key built by string interpolation at runtime prints the raw key on screen).
- **Buttons** styled `.plain` are only clickable on opaque pixels: put the frame and `contentShape` inside the label.
- **Never reach the real Keychain, calendar, Notes or the user's store from a test.** Inject a fake (`FakeSecretStore`, fixture bridges, an in-memory `TaskStore`).
- **Files stay under 500 lines.** Split by responsibility, not by line count.
- Fixtures use invented names only (Acme, Globex, Initech, Umbrella, Alex).

## Style

Match the surrounding code. Comments explain why, not what. No new dependencies for something a few lines can do.

## Licence of contributions

By contributing you agree that your contribution is licensed under the Apache License 2.0, as described in section 5 of the [LICENSE](LICENSE).
