# MetaScrub

- Build with `./build.sh`; run tests with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`. Both need Xcode's
  toolchain (macOS 26 SDK); the Command Line Tools alone are not enough.
- The repository is local only. Commit validated work locally; do not create a remote, push, or
  publish without the user asking.
- Cleaning must not re-encode content silently. If a path has to re-compress or drop something
  beyond metadata, return a note so the app shows it, and document it in the README table.
- Tests and experiments work on generated fixtures or copies in temporary folders. Never point
  cleaning or saving at the user's own files or at system files in place.
- When adding or changing format support, update the README format table and add a fixture-based
  test that reads, edits (if supported) and cleans the format.
