# Contributing

Contributions are welcome. To get a clean build going:

1. Install [mise](https://mise.jdx.dev) (`brew install mise`); the pinned XcodeGen +
   SwiftLint come from `mise.toml`. Run `mise run templates` once to vendor the
   xcodegen-templates into `./xcodegen-templates`.
2. `export DEVELOPMENT_TEAM=<your Apple Developer Team ID>` (see
   [building.md](building.md#set-your-apple-developer-team-id)) — generation fails
   without it, and the driver can't be signed/loaded without one.
3. `make scratch` to regenerate every module and open the workspace.
4. `make test` to run the shared-memory ring + protocol unit tests. Please keep
   these green and add coverage for protocol or ring changes.

Notes:

- The repo tracks **only sources** — generated `.xcodeproj`/`.xcworkspace`, `dist/`
  (build artifacts + the installer `.pkg`), and `.bin/` are git-ignored and recreated
  by `make`.
- Architecture lives in [architecture.md](architecture.md), [protocol.md](protocol.md),
  and [`shmem.md`](shmem.md); read the shmem-ring
  contract before touching the driver↔app boundary.
- The HAL driver ships embedded in the app and installs via the `.pkg` postinstall
  (into `/Library/Audio/Plug-Ins/HAL`, restarting `coreaudiod`). To test driver
  changes end-to-end, build + install `make pkg`.
- Open an issue to discuss larger changes (new lanes, protocol revisions) before a PR.
