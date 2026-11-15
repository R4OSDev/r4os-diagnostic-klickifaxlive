# KFXLIVE.R4X

`KFXLIVE.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.2.28`
- Image target: `/R4OS/SOFTWARE/TERMINAL/DIAG/KFXLIVE.R4X`
- Image scope: `none` (included only by the explicit browser test)
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux:

    ./Build.sh

Regular workspace profile builds deliberately omit this large live
diagnostic. Use `Tools/Build.bat -testbrowser` or
`./Tools/Build.sh -testbrowser` from the workspace root to build and include
it together with Klickifax and the browser protocols. KFXLIVE itself needs a
network-enabled manual guest session for its live probes; the automated
headless browser run has networking disabled.

`Settings.R4S` selects the SDK tool owner. Its profiles define the verified
SDK, Contract and system library sources. `build.zig.zon` records the exact
standalone archive identities. The shared PowerShell build path binds the
actual selected sources and records its normal or explicit development mode.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

API migration0.90.75 uses SDK0.64.208 with `r4os-zig-generation2`.

The CSS owner in SDK 0.64.224 prepares selector parts and bounded ordered
candidate indexes at stylesheet load. Exact matching, cascade, responsive
layout and live DOM/state reads are preserved; computed styles are not
persistently cached. This artifact includes that implementation.

The embedded SDK 0.64.225 JavaScript front end rejects excessive recursive syntax/AST traversal with existing CallDepth, retaining normal parse recovery and the independent runtime call limit.
