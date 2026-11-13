# ArtemisOS installer upgrade prototype

`installer-upgrade.iss` is an experimental branch of `installer.iss`; it is not
a release installer. It discovers the two historical AppIds using the read-only
`ArtemisInstallDiscovery.psm1` and `Find-ArtemisInstallations.ps1`, and presents
the discovered paths. It fails closed if a registration is invalid or ambiguous,
if multiple installs are found during a silent run without an explicit `/DIR`,
or if the selected directory is a real existing installation.

For a fresh install the prototype uses the existing profile and installation
flow. The SDK and other shipped files use a computed destination. Under the
**fixture-only** compilation flag `ArtemisUpgradeFixture`, a validated,
unregistered directory under a dedicated temporary-directory prefix, with a
fixture marker, may enter the upgrade branch. It extracts the complete payload
into Inno Setup's private temporary directory, disables Inno's uninstaller and
shortcut changes, then calls `Upgrade-Transaction.ps1 -Action Apply` with the
old directory and staged payload. The fixture flag also suppresses actual
uninstall registration and shortcuts when testing fresh installation. Never
distribute an installer built with that flag.

The transaction's API and implementation are still under development. It
currently retains a recovery copy, so upgrading may require significant free
space. It is limited to ready local fixed NTFS volumes. The output of the
discovery tool is not an authorization token: registration, paths, processes,
and file contents can change and must be revalidated at the mutation boundary.
Matching an uninstall command and its nonempty `unins*.exe`/`.dat` pair does not
prove the AppId embedded in the log or the completeness of its uninstall script.

Existing uninstall metadata is the reason production upgrades are blocked:

* The original `unins*.dat` does not automatically know about new files that the
  separate transaction adds. A fixture proves this leaves files behind.
* A helper with the same AppId and `[UninstallDelete]` entries can append
  exact file cleanup entries; another fixture demonstrates it. It changes the
  original uninstall log and may replace the uninstaller, so this step and the
  registry's version update require backup, validation, and crash recovery.
* The helper must preserve any original uninstall `[Code]`; Inno Setup uses the
  most recent installation's uninstall script. Historical versions and other
  Inno Setup versions have not been verified. Wildcard or directory deletion
  must not remove user data or unowned files.
* Copying a separately installed candidate tree's `unins*.dat` into the real
  installation is not a supported substitute. No supported public API was found
  for safely validating and rewriting every stored path, registration and
  scripted uninstall action in that log.
* Registration identity, registry view/hive, displayed version, previous
  shortcut targets, failed and interrupted updates, rollback, data safety, and
  permissions all need end-to-end tests on multiple Windows configurations.

`tests/installer-discovery.ps1` tests discovery with fake registration records.
`tests/installer-inno-branch.ps1` tests conditional uninstall/registration
evaluation, staging, and uninstall-log behavior in temporary fixtures without
creating an uninstall registry entry. `tests/installer-upgrade-prototype.ps1`
compiles small guarded and fixture-only installers with fake SDK files; it tests
new install, existing-install blocking, upgrade, data preservation, and failed
upgrade without changing real installations, registration, or shortcuts. The
graphical selection page has not yet been exercised interactively.

`Upgrade-UninstallFixture.ps1` is a separate crash-recovery experiment, not a
registry-writing tool. It accepts only a specially marked directory immediately
under the user's TEMP directory and only the two historical AppIds. It checks
that the mock registration and quoted uninstaller refer to the same fixture
directory, snapshots and hashes the uninstaller and mock registration, appends
an exact cleanup entry using an Inno fixture helper, then changes the mock
version. `tests/installer-uninstall-recovery.ps1` injects failures at six points,
including a simulated partial uninstall-log write, and interrupts recovery twice.
Each tested interruption is restored byte-for-byte and can be retried. A helper
built with a different AppId creates an unexpected `unins001` pair; the prototype
blocks the version update and preserves those files for manual inspection.

Those tests do not prove a production recovery protocol. The registry is a JSON
fixture; no real registry mutation is implemented. The simulated partial write
is not an actual terminated Inno helper. Concurrent uninstall/update, a helper
left running after its parent exits, loss of power or storage write caches,
permissions and ACLs, alternate streams, and old Inno uninstall script behavior
remain unresolved. A fixture hash supplied beside the helper also does not bind
the helper to the managed-file manifest or establish its provenance. The test
intentionally stops on unexpected files or unverifiable backups instead of
deleting them.

## Signed-OTA bootstrap template: future experiments only

`installer-ota-bootstrap.iss` and `Invoke-OtaBootstrap.ps1` are a separate
experimental template, not the shipping installer or a completed production
upgrade. A fixture uses a simulated **1.0.0 to 1.0.1** update. This does not
establish that any real 1.0.0 installation is upgradeable using this template.
Compiling the template requires `ArtemisBootstrapExperimental`; its default
output directory and filename mark it experimental. The former experimental
0.3.6-to-1.0.0 bootstrap and its inventories under `build` are obsolete and must
not be distributed or used for migration.

The versions are compile-time parameters (`BootstrapFromVersion` and
`BootstrapToVersion`); the called script independently receives and validates
the same values. `New-OtaBootstrapInventories.ps1` accepts trusted, complete,
immutable source and target installation snapshots and these versions. It
generates both inventories only after checking that every managed file has a
matching counterpart, the version advances, and each changed path is accepted
by the **source** updater. It excludes user data, the previous migration-data
backup, the configured server file, and uninstaller files. It dot-sources the
source snapshot's `update/core.ps1`, so snapshots must be trusted build inputs,
not arbitrary user-supplied files. Its output is not signed by this script.

The bootstrap compares the complete installed managed tree to the pinned source
inventory. It verifies the normal OTA signature with the source release's key,
then requires exact equality between signed paths/base hashes/target hashes and
the source-to-target inventory differences. It rejects added or deleted files,
changes to `update/recovery.ps1` or the trusted public key, unsupported updater
paths, invalid signatures and unavailable updates. The source OTA mechanism
cannot update `recovery.ps1`; therefore it cannot deliver the actual 1.0.0
release from 0.3.6, which includes a recovery change. Never reuse the old bridge
to perform that migration. A different, separately designed and verified
migration mechanism is required for such changes.

Only an already-registered `ArtemisOS15-Release` per-user install is accepted
by the experimental OTA application step. Multiple installations require an
explicit choice; unattended selection is refused unless unambiguous or an exact
registered `/DIR` is specified. Existing user disks, preferences and uninstall
records are not intentionally modified; the updater does write update state
under `data/update`. Existing running emulator processes and inaccessible
process paths block an update. A nested fresh installer is extracted only when
no installation was selected. These are fixture-tested behaviors, not a claim
of unattended production safety.

Run the isolated tests with:

```powershell
rtk proxy powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\installer-ota-bootstrap.ps1
```

The test generates its own signing key and local HTTP repository, fake registry
records and a small nested installer under a marked temporary fixture. It
disables the real registration-writing callback in the fixture copy of the
installed updater and replaces real registration reads with test seams. It
checks exact 1.0.0-to-1.0.1 replacement, data and uninstall-log preservation,
multiple/silent selection, process and junction rejection, offline and invalid
signature failure, mismatched paths and hashes, and a valid signature over a
wrong source hash. No real install, registration, shortcut or update server is
changed by the fixture. The test compiles a tiny experimental wrapper inside its
temporary directory; it does not build or publish an actual product installer.

Before any real use, authenticate the whole wrapper and pinned inventories,
define release-key ownership, bind the actual release snapshots to the shipped
installer, and perform real isolated end-to-end registration and uninstall
tests. The prototype does not fully solve interrupted transactions or a version
registration failure after file replacement. Its path and running-process
checks still have check-to-use races; concurrent launch, uninstall or hostile
filesystem changes are not prevented. Its tests do not prove power-loss
recovery, writable-hive/ACL behavior, or complete compatibility across Windows
versions. A pre-existing uninstaller's embedded identity cannot be verified
through an established public Inno Setup API. Until those gaps are resolved,
this is a research template, not a production automatic-upgrade path.
