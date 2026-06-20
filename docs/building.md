# Building from source

Full build setup: toolchain, signing identities, and the `make` targets. For
packaging and shipping a `.pkg`, see [releasing.md](releasing.md).

## Prerequisites

- macOS with Xcode + command-line tools.
- [mise](https://mise.jdx.dev) (`brew install mise`) — pins XcodeGen + SwiftLint
  (see `mise.toml`) and vendors the build templates via `mise run templates`.
- An Apple Developer account (needed because the loopback driver loads
  out-of-process in `coreaudiod` and must be code-signed).
- Optional but recommended: [direnv](https://direnv.net) (`brew install direnv`).

Each module's `project.yml` is built from the composable
[xcodegen-templates](https://github.com/BorisVanin/xcodegen-templates), vendored
into `./xcodegen-templates` by `mise run templates` and `include`d by env-var path
(`${TEMPLATES_HOME}/Base.yml`, …). The vendored copy is git-ignored — fetch it once
before generating.

## Set your Apple Developer Team ID

Every module signs against the `DEVELOPMENT_TEAM` environment variable (and
`PROJECT_IDENTIFIER`, which defaults to `ca.borisvanin.soundboard`); XcodeGen
substitutes both into each `project.yml` at generation time. The templates also
need `PROJECT_HOME` (where `Version.xcconfig` lives) and `TEMPLATES_HOME` (the
vendored `./xcodegen-templates`) — all four come from `.envrc`.

These build vars are loaded from a gitignored `.envrc` via direnv, so every `make`
invocation shares one source of truth. direnv loads it in subdirectories too, so
each module's XcodeGen sees the same values. Install direnv, add the shell hook
(e.g. `eval "$(direnv hook zsh)"` in `~/.zshrc`), then:

```sh
cp .envrc.default .envrc   # then edit: set DEVELOPMENT_TEAM (Xcode ▸ Settings ▸ Accounts ▸ Team ID)
direnv allow               # one-time approval; direnv auto-loads .envrc on cd from now on
```

`PROJECT_HOME` / `TEMPLATES_HOME` are pre-filled with `$(pwd)`-relative paths in
`.envrc.default`, so usually only `DEVELOPMENT_TEAM` needs a value.

Not using direnv? `.envrc` is a plain `export` script, so either `source .envrc`
or just `export DEVELOPMENT_TEAM=ABCDE12345` in your shell works as a fallback.

To build under a different account/fork, override the bundle prefix too:

```sh
make PROJECT_IDENTIFIER=com.acme.soundboard   # or export it via .envrc
```

## Make targets

```sh
mise run templates   # one-time: vendor xcodegen-templates into ./xcodegen-templates
make              # generate every module's .xcodeproj + the workspace
make debug        # generate + build the Debug configuration
make open         # open Soundboard.xcworkspace
make scratch      # clean + regenerate + open
make pkg          # build a signed, notarized .pkg into dist/ (app → /Applications, driver → HAL)
make dmg          # build a signed, notarized .dmg into dist/ (drag the app to Applications)
make dist         # both distribution artifacts (pkg + dmg)
make test         # unit tests for the driver's shared-memory ring + protocol
make tools        # build the dev CLI tools (soundboardctl, tap_feed, make_icon) into dist/
```

`make pkg`, `make dmg`, and `make dist` are the distribution pipeline — each
generates the projects, builds a Developer ID-signed artifact via the templates'
shared scripts (`xcodegen-templates/scripts`), and notarizes + staples it. See
[releasing.md](releasing.md) for credentials and publishing.

Frameworks are generated before their consumers (projectReferences need the
referenced `.xcodeproj` on disk). Order is encoded in the `Makefile`.

The HAL driver is built and **embedded inside the app bundle** (signed by the same
Developer ID export); the `.pkg` postinstall installs it into
`/Library/Audio/Plug-Ins/HAL` and restarts `coreaudiod`. To test driver changes
end-to-end, build and install the `.pkg` (coreaudiod caches loaded plug-ins, so it
must restart to pick up a new build).

## Code signing

Every target uses **manual signing** (`CODE_SIGN_STYLE: Manual` in each
`project.yml`), and Xcode picks the certificate per build configuration:

| Configuration | `CODE_SIGN_IDENTITY` | Used for |
|---------------|----------------------|----------|
| **Debug**     | `Apple Development`   | local build + run in Xcode |
| **Release**   | `Developer ID Application` | the distributable `.app` + loopback driver |

Because the app bundles a CoreAudio HAL driver it ships **Developer ID** (direct
distribution + notarization) — it cannot go through the Mac App Store. The two
identities you need in your keychain:

- **Developer ID Application** — signs the Release `.app` and the loopback driver
- **Developer ID Installer** — signs the distributable `.pkg`

Get them from the [Apple Developer portal](https://developer.apple.com/account/resources/certificates)
(Certificates ▸ +) or via Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates, then
verify they're installed:

```sh
security find-identity -v -p codesigning     # should list both Developer ID certs + Apple Development
```
