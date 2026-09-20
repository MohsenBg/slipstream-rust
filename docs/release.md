# Release Checklist

## Trust Model
Release tags are published through GitHub Releases, not by a personal
maintainer signing key. This project treats the canonical GitHub repository as
the release authority: GitHub creates the release tag, release immutability
locks the tag and assets after publication, and GitHub generates the release
attestation for consumers who want platform-backed provenance.

This is intentionally different from an OpenPGP-signed Git tag. Do not promise
Arch-style `?signed#tag=` verification unless the project later adopts a
separate tag-signing key.

A published release must include the CI-built binary archives and checksums
listed below. Source-only releases are not allowed under this workflow. If a
release is published without the required assets, do not mutate or reuse that
tag; cut the next version instead.

## Prep
- Bump versions in `Cargo.toml` (workspace and crates) as needed.
- Ensure `Cargo.lock` is updated and committed.
- Confirm vendor/picoquic is at the intended commit and submodules are initialized.
- Ensure release immutability is enabled for the repository before publishing
  the release:
  https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/preventing-changes-to-your-releases
- Confirm the release tag does not already exist on `origin`:
  `git ls-remote --exit-code --tags origin refs/tags/vX.Y.Z`

## Validation
- `cargo fmt`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo test -p slipstream-dns`
- `cargo test`

## Hygiene
- Verify build outputs stay untracked: `.interop/`, `.picoquic-build/`, `target/`.
- Regenerate vectors and docs if DNS behavior changed:
  `./scripts/gen_vectors.sh`, `docs/protocol.md`, `docs/dns-codec.md`.

## Release Assets
Every published release must contain exactly these CI-built binary artifacts and
their checksums:

- `libslipstream-client-android-arm64-v8a.so`
- `libslipstream-client-android-arm64-v8a.sha256`
- `libslipstream-client-android-armeabi-v7a.so`
- `libslipstream-client-android-armeabi-v7a.sha256`
- `libslipstream-client-android-x86.so`
- `libslipstream-client-android-x86.sha256`
- `libslipstream-client-android-x86_64.so`
- `libslipstream-client-android-x86_64.sha256`
- `libslipstream-client-linux-arm64.so`
- `libslipstream-client-linux-arm64.sha256`
- `libslipstream-client-linux-arm32-v7a.so`
- `libslipstream-client-linux-arm32-v7a.sha256`
- `libslipstream-client-linux-64.so`
- `libslipstream-client-linux-64.sha256`
- `libslipstream-client-linux-32.so`
- `libslipstream-client-linux-32.sha256`
- `libslipstream-client-macos-arm64.dylib`
- `libslipstream-client-macos-arm64.sha256`
- `libslipstream-client-macos-64.dylib`
- `libslipstream-client-macos-64.sha256`
- `libslipstream-client-windows-amd64.dll`
- `libslipstream-client-windows-amd64.sha256`
- `libslipstream-client-windows-arm64.dll`
- `libslipstream-client-windows-arm64.sha256`

## Release
Use the `Release` GitHub Actions workflow. Do not use `gh release create`
manually for a published release.

```sh
gh workflow run release.yml \
  --repo Mygod/slipstream-rust \
  -f version=vX.Y.Z \
  -f target=COMMIT_SHA \
  -f publish=false
gh run watch --repo Mygod/slipstream-rust
```

Use the exact commit SHA that passed validation. Do not create or push a local
Git tag first for this workflow.

The workflow builds all six binary artifacts, creates a draft release, uploads
the required assets, verifies the draft asset list, and asks GitHub to generate
release notes. Leave `publish=false` to inspect the draft before publication.
Use `publish=true` only when the release should be published immediately after
the asset check. Release
immutability locks the tag and assets after publication, so a missing asset
after publication means the release is bad and the fix is a new version.

- Verify the published release:

  ```sh
  gh release view vX.Y.Z --repo Mygod/slipstream-rust --json assets --jq '.assets[].name'
  git ls-remote --tags origin refs/tags/vX.Y.Z
  ```

  `gh release verify` requires a GitHub CLI version with immutable release
  verification support. If the installed `gh` does not provide that command,
  verify the release metadata through the API instead:

  ```sh
  gh api repos/Mygod/slipstream-rust/releases/tags/vX.Y.Z \
    -H X-GitHub-Api-Version:2026-03-10
  gh api repos/Mygod/slipstream-rust/immutable-releases \
    -H X-GitHub-Api-Version:2026-03-10
  ```

  The release metadata should show `"immutable": true`, and
  `target_commitish` should match the validated release commit.

- Fetch the tag locally after publication if needed:

  ```sh
  git fetch --tags origin
  ```

## Packager Notes
- Source packages can track `vX.Y.Z` tags from the canonical GitHub repository.
- GitHub release verification uses GitHub's release attestation and immutable
  release state:
  https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verifying-the-integrity-of-a-release
- GitHub-generated source archives are created on download, so verify the
  release/tag identity rather than treating those archives as pre-attached
  release assets.
