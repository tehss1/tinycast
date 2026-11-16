# Migrations

A migration repairs state that an older release left behind, such as a retired key in
`settings.json` or an orphaned default. It ships in exactly one stable release and is then deleted,
so the codebase never carries a history of its past formats.

## Invariants

- **Every migration lives in `Tinycast/Migrations/`**, one file and one `<Subject>Migration` type
  each. Its call sites name that type, so deleting the file fails the build at every one of them.
- **One stable release, then gone.** `Scripts/check-migrations.sh` fails `lint.sh` and the Release
  workflow once a stable tag (`vX.Y.Z`) contains the commit that added the file. Beta tags do not
  count: the beta channel runs it on the way to that stable release.
- **Missing it must be harmless.** A user who skips that release never runs it, so a migration only
  tidies. A value a later release depends on is never left to one.
- **Except a dated row.** When no later release can work without the migration, its row names a
  `YYYY-MM-DD` instead, and the check fails from that day rather than at the first stable tag. The
  bundle id move is the one case: without it a copy opens empty, its data still under the old id.
- **Idempotent and silent.** It runs on every launch of its release, does nothing when there is
  nothing to repair, and reports nothing.
- **Every live migration has a row below.** The check fails for a file the table does not name.

## Adding one

Write the type in `Migrations/` and call it from `AppCore.start()` before anything reads the state it
repairs, or from `TinycastLaunch.main` when that state is read before `AppCore` exists. Cover it
with a harness of its own, so deleting it removes a whole file, one `run-tests.sh` entry and one row
in [testing.md](testing.md). Then add its row here.

## Deleting one

When the check fails, delete everything the row lists, then the row. Then run `xcodegen generate`,
`./Scripts/run-tests.sh` and `./Scripts/lint.sh`.

## Live migrations

| Migration | Repairs | Delete with it |
| --- | --- | --- |
| `BundleIdentifierMigration` | Disabled in this fork: no legacy namespace is configured, and equal namespaces or identifiers return before any preferences or filesystem access. Upstream implementation and isolated fixture tests are retained to keep merges small. Kept until **2027-05-13** | The migration source, its harness and run-tests entry, and the call in TinycastLaunch.main. |

The fork retains `com.tinycast.app` and its beta and dev channels. It ships no handoff and moves no
preferences, Keychain items, user data, caches or login items. The upstream handoff sources and
packaging tools remain inert: the project has no handoff target and the release pipeline never calls
them. The dated migration check still applies to the retained source.
