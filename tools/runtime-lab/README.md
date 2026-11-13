# Runtime installation-size lab

This experiment reuses the same verified Qt resource source for two SDK target
paths in Inno Setup. It does not remove any runtime capabilities or change the
Android system image. Keep it behind an explicit experimental build option until
the full installer and fresh/upgrade scenarios have been exercised.

1. Run `Measure-RuntimeDuplicates.ps1` to inventory files and equal hashes.
2. Run `Write-InnoReuseSnippet.ps1` with the selected `-SdkRoot` and a **new**
   `-OutputDirectory` beneath `build\runtime-slim-exp`. It verifies matching
   resource and locale sets and both file hashes before emitting the snippets.
3. The installer may conditionally include either generated snippet in `[Files]`
   in place of the SDK wildcard, ahead of the SDK image. The snippet emits each
   pair together, then the original recursive wildcard with *exact* anchored
   exclusions for both paths. Newly added, unlisted files remain covered by the
   wildcard. `onlyifdoesntexist` remains on all entries. `MergeDuplicateFiles`
   must be enabled. The `-solidbreak` variant starts a new solid block at each
   pair; compare its full-package size and install time before selecting it.
4. Generated ISPP checks compare each paired path to its expected SHA-256 at
   preprocessing time. This does not prevent mutation *after* that check: the
   selected SDK must remain immutable from generation through compilation, e.g.
   through an isolated read-only build snapshot. Verify resulting installed
   files and preserve version-specific license and redistribution notices.

`Test-InnoSdkReuse.ps1` uses copies in the lab and isolated, non-registered
installers. It compares fresh/partial-existing installs, records target
extraction order, and verifies installed hashes. Inno Setup logs show destination
order rather than direct reads of compressed blocks. `Test-InnoReuseGuards.ps1`
uses tiny synthetic files and output-disabled preprocessing to test both hash
and name mismatches without a compression run. `Test-InnoDuplicateSources.ps1`
is the earlier broad-exclusion demonstration and must not be used as a recipe
for production integration.

An Inno Setup 6.7.3, `lzma2/fast`, solid-compression Qt-only fixture produced
43,469,741 B baseline, 22,834,202 B interleaved, and 22,878,967 B with per-pair
solid breaks. Single-run log timings were 20.11/13.93 s, 24.18/15.02 s, and
17.30/10.09 s respectively for fresh/partial-existing installations. Other work
was running concurrently, so timings are illustrative only. The fixture verifies
119 files, including a newly added unlisted file, and preserves three preexisting
files. These figures do not predict savings or performance for the full product's
`lzma2/max` installer.
