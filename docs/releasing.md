# Releasing a signed `.pkg`

How to build the notarized installer and publish it on GitHub Releases. `make pkg`
does the whole build → sign → notarize → staple pipeline in one command, via the
templates' shared scripts (`xcodegen-templates/scripts`). Assumes the signing
identities from [building.md](building.md#code-signing) are already in your keychain.

## Where the `.pkg` lives

`make pkg` writes `dist/Soundboard-<version>.pkg` — already Developer ID-signed,
**notarized, and stapled**. **`dist/` is git-ignored** (it holds build artifacts),
so the `.pkg` is *not* committed to the repo — that's deliberate. Binaries don't
belong in git history; they belong on **GitHub Releases**, which is built for
versioned downloadable assets. So the flow is:

```
make pkg  →  dist/Soundboard-1.0.0.pkg  (signed + notarized + stapled)  →  upload to a GitHub Release
```

`dist/` is just your local staging/output area. Treat everything in it as
disposable and regenerable.

## 1. Build + notarize the `.pkg`

```sh
make pkg     # → dist/Soundboard-1.0.0.pkg  (signed + notarized + stapled)
```

`make pkg` runs the templates' shared scripts: it archives the app with a
**Developer ID** export (hardened runtime + secure timestamp — this also re-signs
the embedded HAL driver), wraps it in a `.pkg` signed with **Developer ID
Installer**, then submits it to Apple's notary service, waits, staples the ticket,
and verifies with `spctl`. The `.pkg` postinstall installs the driver into
`/Library/Audio/Plug-Ins/HAL` and restarts `coreaudiod` on the target Mac.

The marketing version comes from `VERSION` in `Version.xcconfig` (the single source
of truth — bump it there to change the release version).

The signing identities default to a prefix match against the single Developer ID
certs in your keychain. If you have more than one, set them in `.envrc`:

```sh
export APP_SIGN_ID="Developer ID Application: NAME (TEAMID)"
export INSTALLER_SIGN_ID="Developer ID Installer: NAME (TEAMID)"
```

`make dmg` builds a notarized `.dmg` the same way (drag-install; it does **not**
install the driver). `make dist` builds both.

## 2. Notarization credentials

`make pkg` notarizes automatically; it needs notary credentials in your environment
(set them in `.envrc`):

- **Recommended — a keychain profile.** Create it once, then reference it:
  ```sh
  xcrun notarytool store-credentials soundboard-notary \
    --apple-id you@example.com --team-id "$DEVELOPMENT_TEAM" --password APP_SPECIFIC_PW
  export NOTARY_PROFILE=soundboard-notary
  ```
- **Or inline:** `export NOTARY_APPLE_ID=…` and `export NOTARY_PASSWORD=…`
  (team ID falls back to `DEVELOPMENT_TEAM`).

`APP_SPECIFIC_PW` is an **app-specific password** from
[appleid.apple.com](https://appleid.apple.com) (Sign-In & Security ▸ App-Specific
Passwords), *not* your Apple ID password. See [building.md](building.md) and
`.envrc.default` for the full env-var list.

The scripts (`xcodegen-templates/scripts/build-pkg.sh`, `notarize.sh`) run these
underlying tools — to do the notarize + staple step by hand:

```sh
xcrun notarytool submit dist/Soundboard-1.0.0.pkg --keychain-profile soundboard-notary --wait
xcrun stapler staple dist/Soundboard-1.0.0.pkg
spctl --assess --type install -vvv dist/Soundboard-1.0.0.pkg   # → "accepted, source=Notarized Developer ID"
```

## 3. Publish on GitHub Releases

A release is a tag + notes + attached files. Tag the commit you built from so the
download is traceable to source.

### Using the `gh` CLI (recommended)

```sh
# one-time: brew install gh && gh auth login
gh release create v1.0.0 dist/Soundboard-1.0.0.pkg \
  --repo BorisVanin/soundboard \
  --title "Soundboard 1.0.0" \
  --notes "First signed + notarized release. Installs Soundboard.app and the loopback driver."
```

To attach a `.pkg` to an existing release instead:

```sh
gh release upload v1.0.0 dist/Soundboard-1.0.0.pkg --repo BorisVanin/soundboard
```

### Using the GitHub web UI

1. Push your commits and create the tag (`git tag v1.0.0 && git push origin v1.0.0`),
   or let the Releases form create the tag for you.
2. Go to **Releases ▸ Draft a new release** on
   `https://github.com/BorisVanin/soundboard/releases`.
3. Pick/create tag `v1.0.0`, add a title and notes.
4. **Drag `dist/Soundboard-1.0.0.pkg` into the "Attach binaries" area.**
5. Publish. The `.pkg` is now a direct download link on the release.

> Keep the tag, `VERSION` in `Version.xcconfig`, and the version in the release
> title in sync (e.g. all `1.0.0`).

## Installing (for end users)

```sh
sudo installer -pkg Soundboard-1.0.0.pkg -target /
```

…or just double-click it in Finder (it prompts for a password). The install
scripts handle the lifecycle around an update:

- **preinstall** — if Soundboard is already running, it asks for permission to
  quit it (declining cancels the install), then quits the old instance so its
  bundle can be replaced cleanly.
- **postinstall** — installs the embedded HAL driver into
  `/Library/Audio/Plug-Ins/HAL` and restarts `coreaudiod` so it loads
  immediately; if the app had been running, it relaunches the new version.

On first run the app will request the microphone, audio-capture, and (optionally)
accessibility permissions described in
[architecture.md](architecture.md#apple-constraints-baked-into-this-design).

## GitHub repo settings checklist

Suggested "About" description, topics, and other repo settings live in
`docs/github-repo-setup.md` (a gitignored personal checklist).
