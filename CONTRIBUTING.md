# Contributing to Where Was I

Thanks for helping. Issues and pull requests are welcome. Small, focused changes are easiest to review; for anything big, please open an issue first so we can agree on the direction.

## Build and test

You need macOS 14+ and Xcode 16 (or a Swift 6.0 toolchain).

```sh
swift build                 # CLI, app and core library
swift test                  # all unit tests
swift test --filter PrivacyTests
swift run wwi --help

scripts/build-app.sh        # release build -> .build/Where Was I.app (ad-hoc signed)
```

`swift test` must pass before you open a pull request. The package has three parts: `WWICore` (model, SQLite store, ingest, resolver, Orca sync), `wwi` (command line tool) and `WhereWasI` (the menu bar app). Keep logic that can be tested in `WWICore` or `WWIAppCore`; the SwiftUI/AppKit views only draw.

## Coding rules

1. **Tests never touch the real machine.** A test must not read or write the real `~/.claude`, `~/.codex`, `~/Library/Application Support/jtm` database, `~/Library/Logs/jtm` or `~/Applications`. Use a temporary directory, pass explicit paths (`--claude-settings`, `--codex-hooks`, `WWI_DB_PATH`, `WWI_LOG_PATH`, `WWI_INSTALL_DIR`) and inject the clock, the process runner and the home directory. Tests also must not launch `orca`, `open` or `pbcopy` for real: use the fake runner in `Tests/WWICoreTests/FakeRunner.swift`.
2. **Test data is made up.** `PrivacyTests` scans everything under `Tests/` and fails on real names, home directories other than `/Users/me/`, and identifiers that are known to be real. Use placeholder values such as `/Users/me/Work/app` and `00000000-0000-4000-8000-000000000001`. Do not paste real hook payloads, prompts, session ids or chat urls into fixtures; reduce them to invented ones first.
3. **Never execute the binary inside the app bundle.** Start the app with `open` (`open .build/Where Was I.app`) only. Running `Where Was I.app/Contents/MacOS/WhereWasI` from a terminal makes macOS remember the menu bar item as hidden for that bundle id, and later launches can quit immediately. Tests and scripts must not do it either.
4. **Hooks must never get in the way of an agent.** `wwi ingest` is non-blocking, finishes within seconds and always exits 0, even on bad input. Hook installation only adds entries marked `# wwi-managed`, makes a backup first and is idempotent.
5. **Keep external commands behind the runner.** Calls to `orca`, `open` and `pbcopy` go through the process runner with a timeout, and only `http`, `https`, `codex` and `claude` urls are passed to `open`.
6. **Small and dependency-light.** Prefer the standard library and system frameworks. The only package dependency today is `swift-argument-parser`; discuss before adding another.
7. Match the surrounding code: naming, comment density and idiom. Comments say why, not what.

## Commit style

One logical change per commit, in the form `type(scope): subject`, lower case, imperative, no trailing period:

```
feat(cli): wwi keep|unkeep|ignore|restore, ls --archived
fix(app-ui): hide row buttons while editing
test(app): deterministic watcher debounce tests
docs: describe how deep links work
```

Common types are `feat`, `fix`, `test`, `docs`, `chore` and `refactor`. Scopes in use include `cli`, `store`, `ingest`, `reconcile`, `sync`, `app-core`, `app-ui` and `publish`. Add a short body when the reason is not obvious from the diff.

## Pull requests

- Describe what changed and why, and how you tested it.
- Include tests for behavior changes and bug fixes.
- Do not include generated files, build output (`.build/`, `dist/`) or editor settings.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
