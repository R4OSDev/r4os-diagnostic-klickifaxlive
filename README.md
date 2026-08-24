# KFXLIVE.R4X

`KFXLIVE.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.2.9`
- Image target: `/R4OS/SOFTWARE/TERMINAL/DIAG/KFXLIVE.R4X`
- Image scope: `none` (included only by the explicit browser test)
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

Regular workspace profile builds deliberately omit this large live
diagnostic. Use `Tools/Build.bat -testbrowser` or
`./Tools/Build.sh -testbrowser` from the workspace root to build and include
it together with Klickifax and the browser protocols. KFXLIVE itself needs a
network-enabled manual guest session for its live probes; the automated
headless browser run has networking disabled.

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
