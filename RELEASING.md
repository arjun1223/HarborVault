# Building a release

The downloadable build targets Apple silicon and macOS 14 or newer. The application source and generated artwork are public; runtime vaults, photos, exports, credentials, signing material, logs, and local history must never be committed or packaged.

1. Start from a clean checkout of the intended release commit.
2. Run `bash test.sh` with disposable generated fixtures.
3. Run `bash build.sh` to build and ad-hoc sign the app without launching it.
4. Run `bash Tools/PackageRelease.sh` to create the DMG and `SHA256SUMS.txt` in `output/releases/`.
5. Audit the exact tracked source/history and the finished app package separately. Verify font provenance, generated artwork, the app signature, binary architecture, app contents, and the mounted read-only DMG. Never copy an existing user's Application Support folder, preferences, Keychain items, or vault data.
6. Create a GitHub release at the audited commit and attach only the DMG and checksum file. Confirm the remote commit, visibility, release assets, and checksum after upload.

The package script uses a fresh staging directory containing only the built app, a generated installation note, and an Applications alias. It creates and verifies the disk image without opening Finder or running the application.

This build has an ad-hoc signature, not a Developer ID signature or Apple notarization. Do not describe it as notarized. A future notarized release requires a developer-owned Developer ID certificate and Apple notarization credentials, kept outside this repository.
