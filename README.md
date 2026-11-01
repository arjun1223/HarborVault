# Harbor Vault for macOS

A native, local Mac app for separate encrypted file vaults. Requires an Apple silicon Mac running macOS 14 or later. Touch ID / Mac password unlock also requires an available Secure Enclave.

## Start

The current build updates **output/Harbor Vault.app** in place. Quit and reopen the app to load a new build. Any older “Updated” copy uses the same encrypted storage and cannot edit it concurrently. You can keep the app here or move it into Applications. There is no installer, account, subscription, server, or cloud service.

1. Create a vault and choose its own passcode (at least 10 characters; a long, unique phrase is stronger).
2. Leave **Also unlock with Touch ID / Mac password** enabled for convenient Mac authentication. Disable it to require that vault’s passcode every time.
   All app passcode fields have an eye button to show/hide the entered text. They start hidden and hide again when the app becomes inactive or the field is dismissed. The Mac’s own authentication dialog is controlled by macOS.
3. Drag files or folders from Finder into the unlocked vault, or choose **Import** (⌘I).
4. The app encrypts a copy, decrypts it to verify it, and checks it against the original. Then choose **Keep originals** or **Move originals to Trash**.

Your vault copy is independent of the original. It remains usable after the original is removed. Files changed after import are kept rather than trashed. An imported folder with new or changed content is also kept.

Items in Trash remain readable until you empty it. The app does not empty Trash. Removing an original does not remove other copies, iCloud versions, Time Machine history, snapshots, or backups, and does not promise forensic erasure from an SSD.

## Use your vault

- Create more vaults with the **+** beside Your Vaults or **File → New vault** (⌘N). Each has a separate passcode and random encryption key.
- Choose a vault in the sidebar to switch. Switching locks the current vault.
- Double-click a folder to open it. Use the breadcrumb bar to go back.
- Search matches filenames and folder names across the current unlocked vault; it does not index file contents.
- Files open in a table by default; use the list/grid controls to change views. Right-click a file or folder to preview, export, rename, move, or delete it.
- Grid view shows actual image, first-page PDF, and text thumbnails where supported. Use the bottom-right slider to adjust thumbnail size. Thumbnails are generated in memory and cleared when locked; unsupported or oversized files use their file-type icons.
- Shift-click selects a range, Command-click toggles individual items, and dragging a rectangle from empty browser space selects the intersecting items. Hold Shift to add to the selection or Command to toggle it. ⌘A selects the current visible files. Arrow keys move selection; Shift-arrow extends it.
- Back/forward buttons and ⌘[/⌘] restore folder visits and searches. ⌘↑ opens the enclosing folder.
- Single-click a file to select it immediately. Single-clicking never opens a preview. Shift/Command selection clicks also select without opening popovers.
- Double-click a file for the larger, separate viewer. Double-click within a multiple selection to open that selected group together, with a thumbnail sidebar. Different file types can coexist in the same window. Images, PDFs, and small UTF-8 text render in the app; other formats appear with their file information and a preview-unavailable message.
- Press **Space** while the file browser has keyboard focus to show/hide its small preview. In the full viewer, **left/right** switch files, **up/down** do not switch files, and Space/Escape close it. Sidebar items can also be clicked. Image/PDF previews have zoom controls.
- Pinch with two fingers to zoom image/PDF previews in either preview size. Two-finger scrolling pans zoomed images; the native image viewport also supports smart zoom. The full viewer’s zoom buttons and Fit control stay synchronized with native zoom. Zoom is bounded to 25%–500% relative to the fitted image/page size.
- Dismissing either preview clears its readable content and **keeps the vault unlocked**. Switching away from the separate full viewer locks **only that viewer window** and clears its readable contents. The vault browser stays unlocked. Returning to that viewer requires fresh Touch ID / Mac password verification when enabled, or the vault’s own passcode. The small popover dismisses when the app becomes inactive. Ordinary folder navigation stays inside the browser window, and normal vault idle/sleep locking still applies.
- Open **Preferences** at the bottom of the sidebar (⌘,) for Light, Dark, or System appearance; Small, Standard, or Large text; and Compact or Comfortable density. These choices save automatically.
- Preview images, PDFs, and small UTF-8 text files in the app. Other formats can be exported. Preview input is limited to 50 MB; text display is limited to 2 MB.
- **Export** (⌘E) creates a decrypted copy outside the vault. That copy is readable normally in Finder and other apps. Existing destination files are never overwritten; choose another name.
- **Lock** (⌘L) clears the current catalog, selection, search, key reference, and preview. Vaults also lock on sleep, screen lock, user-session change, and after 5 minutes without interaction in the app. Change the idle interval in Preferences.
- The **…** menu changes the current vault’s passcode or enables/disables Mac unlock.
- To rename a vault, unlock it and choose **Rename vault…** from its sidebar context menu, the **…** menu, or the Vault menu. This changes its visible label only.

## Recently Deleted and restoring files

Each vault has its own **Recently Deleted** section. Deleting a file or folder moves it there; it stays encrypted and disappears from the active browser and search. The default recovery period is 30 days. In Recently Deleted, set that vault’s future retention to 7, 30, 60, 90, or 365 days, or **Until I delete them**. Select items and choose **Change date** for an exact future permanent-deletion date or no automatic deletion. Changing the vault default leaves existing deletion dates unchanged.

**Restore** first asks “Restore this file?” with **Restore** and **No**. “Restore this file to its prior location” is checked by default. **Choose other location…** selects All files or another active folder inside the same vault. If the original folder is unavailable, restoration falls back to All files. A numbered name preserves both files when the destination already contains that name. Restoring a folder restores its grouped contents; separately deleted children retain their own recovery status.

Expired copies are removed while the vault is unlocked, or on its next unlock. Locked vaults are not decrypted for cleanup. **Delete Permanently…** and **Empty…** require confirmation and remove the selected recovery copies. Other vaults, Finder originals, and backups are separate.

This version reads existing version-1 catalogs. A catalog is saved as version 2 when changed, including the encrypted recovery metadata. Older builds do not support version-2 catalogs; use this build after making changes.

## Send files to another vault

Select files or folders and choose **Send to another vault…** from the context menu, toolbar, or Vault menu. Choose a destination and one of:

- **Move · one copy total**: removes the source after the destination has been encrypted, committed, and freshly verified. The source is not put into Recently Deleted. If the final move cannot finish, the original is kept and a warning explains that both copies remain.
- **Duplicate · keep both**: preserves the source and creates an independent copy in the destination vault.

Verify the destination with Touch ID / Mac password when enabled, or that destination’s passcode. Verification expires after 60 seconds and is cleared when the destination changes, the operation is cancelled, or the vault locks. Files arrive in the destination’s All files section; folder structure and empty folders are retained. Existing destination names are preserved with numbered copies. Deleted children are not included: restore them first to transfer them.

Transfers stream authenticated chunks through memory and re-encrypt them with the destination’s independent key and fresh file identities. No decrypted temporary files are created for vault-to-vault transfers. The app never overwrites an existing destination file, and a failed pre-commit transfer keeps the source intact.

## Delete a vault

Choose **Delete vault…** from the vault’s sidebar context menu or the Vault menu. The app locks the vault and requires **fresh authentication**, even if you already had it open. Use Touch ID / Mac login password when enabled for that vault, or its own passcode. Authentication expires after 60 seconds.

Then type **`DELETE <vault name>`**, including the exact current name and capitalization. The Delete button remains disabled until both verification and the phrase are valid. Confirmation permanently removes that vault and its encrypted files. Other vaults and outside originals are preserved. There is no undo, and deletion does not erase exports, shared copies, backups, or filesystem snapshots.

## Share with AirDrop, Messages, and other Mac services

Select files and choose the Share button or **Share… (verify identity)** in their context menu. The preview window also has a Share button: it shares the explicitly selected group for a grouped preview, or just the current file for a single-file preview.

Sharing locks the browser and requires fresh authentication. After verification, choose **Choose where to share…** to open the native macOS share picker. The services offered depend on your Mac and selected file types. You choose the destination, recipients, and any final Send action yourself.

macOS sharing services require readable file URLs. The app therefore creates verified plaintext copies in an owner-only temporary directory **after authentication**. It removes them after the service reports completion, failure, or cancellation. A service that has already received the copies may retain its own copies; locking cannot recall a share already handed to macOS. If the app crashes, temporary share copies may remain until the next successful app launch, when stale copies are cleaned up. The app does not automatically send anything, select a recipient, or empty Trash.

Mac unlock is an **alternative** to the vault passcode. It is not a requirement to provide both. Anyone who can satisfy your Mac’s authentication can unlock a vault with this option enabled. Choose passcode-only when you want access kept separate from your Mac login.

Vault labels remain visible while locked and are stored in the unencrypted settings header. Use neutral labels. File and folder names, hierarchy, hashes, and file contents are encrypted. Encrypted file counts, approximate sizes, and filesystem timestamps remain observable in the storage directory.

## Recovery and backup

**Keep each vault’s passcode safe. There is no reset or recovery service.** The passcode is also needed if you change Macs, replace hardware, lose the Secure Enclave key, or Mac unlock stops working. The app never needs you to tell it your Mac password directly: macOS handles that authentication.

Choose **Vault → Show encrypted storage in Finder**. The default location is:

`~/Library/Application Support/HarborVault.noindex/`

While the app is closed, back up this entire folder to a trusted location. A vault’s UUID folder must include **vault.json**, **catalog.sealed**, and **objects/** together. Do not edit these files. The passcode alone cannot reconstruct missing vault data.

To restore onto a new Mac, quit Harbor Vault, restore the complete storage folder to the same location, and reopen the app. Unlock with the vault passcode, then disable and re-enable Mac unlock to bind it to the new Mac.

Changing a passcode or removing Mac unlock changes the current header. Older backups can still contain earlier unlock options and passcodes; keep them protected too.

## Storage and implementation

- SwiftUI / AppKit application, using only Apple frameworks. No runtime dependencies or network service.
- Instrument Sans interface text and Manrope headings are bundled locally, along with their SIL Open Font License files. Font sources: [Instrument Sans](https://github.com/google/fonts/tree/main/ofl/instrumentsans) and [Manrope](https://github.com/google/fonts/tree/main/ofl/manrope). No font download is needed at runtime.
- AES-256-GCM via CryptoKit for the catalog and file contents. Files use independently authenticated 4 MB chunks with authenticated file/vault identity, chunk position, total length, and chunk count.
- A random 256-bit key per vault. Passcode wrapping uses PBKDF2-HMAC-SHA256 with a random 32-byte salt and 600,000 iterations.
- Mac unlock uses a Secure Enclave P-256 key with `.privateKeyUsage` and `.userPresence` access control. An ephemeral ECDH key and HKDF-SHA256 derive a wrapping key. The hardware-bound private-key representation is opaque, not an exported private key. There is no plaintext vault key stored in preferences or on disk.
- File data and the encrypted catalog are staged and verified before the catalog is atomically committed. File operations run off the UI thread. Late operation results are discarded after locking.
- Preview data is supplied from memory to native image/PDF/text views. The app does not explicitly write decrypted preview files, use Quick Look, or create an external search index. Exports intentionally write plaintext to your selected destination.
- Sharing intentionally creates temporary plaintext copies after fresh authentication, as described above. Its separate authentication permit is bound to the vault and settings, expires after 60 seconds, and is cleared on cancellation, locking, or session changes.
- Storage directories use owner-only permissions. A process lock prevents two instances from concurrently editing the same store.

This is a first local build, not an independently audited security product. It is designed to protect files at rest when a vault is locked. It does not protect against malware, a compromised/admin-controlled Mac, screen capture, a person viewing an unlocked vault, or privileged memory inspection. Swift/OS memory copies and swap are not guaranteed to be securely erased. Native document frameworks and macOS control their own internal caching. Test with disposable copies and maintain a separate backup before entrusting it with irreplaceable files.

## Build and verify

This build is signed locally with an ad-hoc signature. It is not notarized or signed with a paid Developer ID. No system security settings need to be disabled.

```sh
bash build.sh
bash test.sh
```

The scripts use the full Xcode toolchain at `/Applications/Xcode.app/Contents/Developer`, with a workspace-local compiler cache; they do not change the machine’s selected toolchain. Override `DEVELOPER_DIR` if needed. `test.sh` uses temporary fixtures and deletes them afterward. It does not import or remove your personal files.

For the hardware-only test, on an unlocked Mac:

```sh
output/storage-tests --hardware
```

That test creates a temporary hardware key and checks that unwrapping is rejected when authentication UI is forbidden. It does not authenticate as you or save a vault.

Tests use only generated fixtures. They cover independent vault passcodes, wrong-password rejection, encrypted catalogs, empty/multi-chunk files, ciphertext corruption and identity binding, export recovery, folder preservation, source-change detection, symbolic-link rejection, passcode changes, deletion boundaries, locking and cancellation, selection/range/marquee rules, folder history, thumbnail generation, preview keyboard policy, fresh deletion authorization and exact phrases, and temporary sharing-copy cleanup. The latest native gestures, focus transitions, and sharing-service handoff still require an explicitly approved interactive check; tests do not claim that a message or AirDrop was sent.

Apple API references: [Secure Enclave keys](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave), [CryptoKit Secure Enclave key restoration](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/keyagreement/privatekey/init(datarepresentation:authenticationcontext:)), [user-presence access control](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/userpresence), [AES-GCM authenticated decryption](https://developer.apple.com/documentation/cryptokit/aes/gcm/open(_:using:authenticating:)).
