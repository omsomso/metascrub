# MetaScrub

- Build with `./build.sh` and test with `./test.sh`. Both need Xcode's toolchain (macOS 26 SDK);
  the Command Line Tools alone are not enough.
- omso Builder builds this repository from `omso-build.json` (build, tests, `--self-test`, copy
  into `/Applications/omso`). Keep that file working when build or test commands change, and
  check it with an omso Builder preview or a build that is not installed.
- The remote is the private GitHub repository `omsomso/metascrub`. Commit validated work
  locally; push only when the user asks, and never publish releases without being asked.
- Cleaning must not re-encode content silently. If a path has to re-compress or drop something
  beyond metadata, return a note so the app shows it, and document it in the README table.
- Tests and experiments work on generated fixtures or copies in temporary folders. Never point
  cleaning or saving at the user's own files or at system files in place.
- When adding or changing format support, update the README format table and add a fixture-based
  test that reads, edits (if supported) and cleans the format.
