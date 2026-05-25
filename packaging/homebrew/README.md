# Homebrew Source-Build Distribution

This is the free distribution path. It does not require a paid Apple Developer
Program account because it does not distribute a Developer ID signed or
notarized app bundle.

The Homebrew formula builds SteezFlow from source on the user's Mac, installs
the built `.app` into Homebrew's Cellar, and exposes `steezflow-install-app` to
copy that app into `/Applications`.

## Release Checklist

1. Tag a source release in this repository.

   ```sh
   git tag v2.0.0
   git push origin v2.0.0
   ```

2. Compute the source tarball SHA.

   ```sh
   curl -L "https://github.com/YOUR_GITHUB_OWNER/steezflow2/archive/refs/tags/v2.0.0.tar.gz" \
     | shasum -a 256
   ```

3. Copy `Formula/steezflow.rb.template` into your tap as
   `Formula/steezflow.rb`.

4. Replace:

   - `YOUR_GITHUB_OWNER`
   - `v2.0.0`
   - `REPLACE_WITH_SOURCE_TARBALL_SHA256`

5. Install from the tap.

   ```sh
   brew tap YOUR_GITHUB_OWNER/tap
   brew install steezflow
   steezflow-install-app
   open /Applications/SteezFlowMacApp.app
   ```

## Signing Behavior

`scripts/build-local-app.sh` prefers an Apple Development certificate when one
is available. That can be created with a free Apple ID in Xcode and is more
stable for local macOS permissions than an ad-hoc signature.

If no Apple Development certificate is available, the script falls back to an
ad-hoc local signature. That keeps the install free, but users may need to
re-grant Microphone, Speech Recognition, or Accessibility permissions after
some rebuilds.

You can force a mode when testing locally:

```sh
STEEZFLOW_LOCAL_SIGNING=development DEVELOPMENT_TEAM=YOURTEAMID scripts/build-local-app.sh
STEEZFLOW_LOCAL_SIGNING=adhoc scripts/build-local-app.sh
```

This flow intentionally does not remove `com.apple.quarantine` from downloaded
binary app bundles. The app is built locally from source instead.
