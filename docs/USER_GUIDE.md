# Harbor Vault for macOS

A native, local Mac app for separate encrypted file vaults. Requires an Apple silicon Mac running macOS 14 or later. Touch ID / Mac password unlock also requires an available Secure Enclave.

## Start

The current build updates **output/Harbor Vault.app** in place. Quit and reopen the app to load a new build. Any older “Updated” copy uses the same encrypted storage and cannot edit it concurrently. You can keep the app here or move it into Applications. There is no installer, account, subscription, server, or cloud service.

1. Create a vault and choose its own passcode (at least 10 characters; a long, unique phrase is stronger).
2. Leave **Also unlock with Touch ID / Mac password** enabled for convenient Mac authentication. Disable it to require that vault’s passcode every time.
   All app passcode fields have an eye button to show/hide the entered text. They start hidden and hide again when the app becomes inactive or the field is dismissed. The Mac’s own authentication dialog is controlled by macOS.
3. Drag files or folders from Finder, a floating macOS screenshot thumbnail, or an image from another app into the unlocked vault, or choose **Import** (⌘I).
4. The app encrypts a copy, decrypts it to verify it, and checks it against the original. Then choose **Keep originals** or **Move originals to Trash**.

Screenshot thumbnails and image drags can arrive without a saved Finder file. These imports preserve the delivered bytes, encrypt and verify them, then remove the owner-only temporary import copies. Their completion sheet shows **Done**. The copy-then-Trash choice is offered only for actual Finder originals. If delivery fails or the vault locks, temporary import copies are cleaned up; stale import copies after a crash are removed on the next successful app launch. Copies retained by macOS or the source app are separate.

Your vault copy is independent of the original. It remains usable after the original is removed. Files changed after import are kept rather than trashed. An imported folder with new or changed content is also kept.

Items in Trash remain readable until you empty it. The app does not empty Trash. Removing an original does not remove other copies, iCloud versions, Time Machine history, snapshots, or backups, and does not promise forensic erasure from an SSD.

## Use your vault

Harbor Vault starts inline Touch ID when you choose a vault with Mac unlock enabled or when that vault locks from inactivity. **Use Vault Password…** opens the vault’s passcode field. **Use Mac Password…** opens the macOS dialog. The full viewer requests verification through macOS when you return after its contents lock. After an explicit lock or sleep, select the vault again to start authentication.

In **Preferences → Appearance**, turn on **Liquid Glass** for native glass controls and a blurred view of what’s behind the window. It works with Light, Dark, and System appearance. It requires macOS 26 or later. On macOS 27 and later, change the intensity with the Liquid Glass slider in **System Settings → Appearance**. Reduce Transparency uses solid surfaces.

Press **⌘F** to search filenames. Use the sort menu in either view, or click a column heading in list view. Recently Deleted can sort by scheduled deletion date.

- Create more vaults with the **+** beside Your Vaults or **File → New vault** (⌘N). Each has a separate passcode and random encryption key.
- Choose a vault in the sidebar to switch. Switching locks the current vault.
- Double-click a folder to open it. Use the breadcrumb bar to go back.
- Search matches filenames and folder names across the current unlocked vault; it does not index file contents.
- Files open in a table by default; use the list/grid controls to change views. Right-click a file or folder to preview, export, rename, move, or delete it.
- Grid view shows actual image, first-page PDF, and text thumbnails where supported. Use the bottom-right slider to adjust thumbnail size. Thumbnails are generated in memory and cleared when locked; unsupported or oversized files use their file-type icons.
- Shift-click selects a range, Command-click toggles individual items, and dragging a rectangle from empty browser space selects the intersecting items. Hold Shift to add to the selection or Command to toggle it. ⌘A selects the current visible files. Arrow keys move selection; Shift-arrow extends it.
- Drag selected items onto a folder to move them. After moving the pointer 10 points, a stacked preview shows the selection count and the sidebar fades into Quick Actions. Drop on Move to Trash, Share, Export, or Move to All Files. The trash lid opens on hover. Releasing over Trash moves the selection into Recently Deleted immediately. Releasing elsewhere restores the sidebar.
- Back/forward buttons and ⌘[/⌘] restore folder visits and searches. ⌘↑ opens the enclosing folder.
- Single-click a file to select it immediately. Single-clicking never opens a preview. Shift/Command selection clicks also select without opening popovers.
- Double-click a file for the larger, separate viewer. Double-click within a multiple selection to open that selected group together, with a thumbnail sidebar. Different file types can coexist in the same window. Images, PDFs, and small UTF-8 text render in the app; other formats appear with their file information and a preview-unavailable message.
- Press **Space** while the file browser has keyboard focus to show/hide its small preview. In the full viewer, **left/right** switch files, **up/down** do not switch files, and Space/Escape close it. Sidebar items can also be clicked. Image/PDF previews have zoom controls.
- Click **Text** in either preview to recognize text from an image or scanned PDF on this Mac. For images, drag across the words on the preview and press **⌘C**. For scanned PDFs, select text in the results pane or choose **Copy**. PDFs are recognized page by page, with progress and page separators. **Cancel** stops a running recognition. No text is automatically saved or added to search, and the original file is unchanged. OCR results may contain mistakes, so check them before use.
- Recognized text is cleared when its preview closes, when you switch files, when the full viewer locks, or when the vault locks. Copying deliberately places readable text on the Mac clipboard; that copy is outside the vault’s protection and can be retained by clipboard tools. Images use their first frame/page; PDF recognition supports up to 500 pages within the existing preview-size limit.
- Pinch with two fingers to zoom image/PDF previews in either preview size. Two-finger scrolling pans zoomed images; the native image viewport also supports smart zoom. The full viewer’s zoom buttons and Fit control stay synchronized with native zoom. Zoom is bounded to 25%–500% relative to the fitted image/page size.
- Dismissing either preview clears its readable content and **keeps the vault unlocked**. Switching away from the separate full viewer locks **only that viewer window** and clears its readable contents. The vault browser stays unlocked. Returning to that viewer requires fresh Touch ID / Mac password verification when enabled, or the vault’s own passcode. The small popover dismisses when the app becomes inactive. Ordinary folder navigation stays inside the browser window, and normal vault idle/sleep locking still applies.
- Open **Preferences** at the bottom of the sidebar (⌘,) for Light, Dark, or System appearance; Small, Standard, or Large text; and Compact or Comfortable density. These choices save automatically.
- Preview images, PDFs, and small UTF-8 text files in the app. Play supported videos such as MP4 and MOV in either preview. Videos stream from encrypted storage. Image, PDF, and text preview input is limited to 50 MB, and text display is limited to 2 MB.
- **Export** (⌘E) creates a decrypted copy outside the vault. Click **Show in Finder** in the completion message to reveal the file or batch folder. Choose a different filename if the destination already exists.
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

## Portable vaults (.harb)

### Public copies

Choose **Vault → Export public vault…** to create a copy anyone can open without a sharing key or password. Confirm the public-copy notice and choose where to save it. The export includes active files and folders, excludes Recently Deleted, and leaves your local vault private. Exporting does not upload or publish anything online.

The HTML reader opens a public file automatically when you choose or drop it, labels it **Public copy**, and allows viewing and downloads. In the Mac app, importing a public file requires no sharing key; choose a new local vault password to protect your imported copy on that Mac. Protecting an imported copy does not make the public export private.

Public copies use the distinct `HARBPB01` marker followed by a deliberately included 32-byte decoding key and a standard `HARBPK02` archive. This offers **no confidentiality**: anyone holding the file can decode its contents, modify it, and create another valid copy. Integrity checks still catch damage, but do not prove the sender's identity or authenticity. Public copies can be kept, downloaded, or forwarded and cannot be recalled. Private exports remain the default and continue to require their separate key.

### Private copies

Unlock a vault, then choose **Vault → Export portable vault…** or use the vault’s sidebar context menu. Save the .harb file and save its separate HARB sharing key before closing the completion sheet. Export includes active files, folders, and empty folders. Recently Deleted is excluded. The source vault is kept.

Send the .harb file and its sharing key separately. Anyone holding both can open that exported copy, and access to downloaded copies cannot be revoked.

**Copy key** marks the clipboard entry as concealed and transient, and clears it after 60 seconds or when the vault locks, provided you have not copied something else. Clipboard managers may ignore those hints. **Save protected key…** saves a password-encrypted `.harbkey` file instead of a readable key; keep its password separate. Use a long, unique password because someone holding this key file can try password guesses offline.

Double-click a .harb file, or choose **File → Open portable vault…**. Enter its sharing key, choose a new local password of at least 10 characters, and optionally enable Touch ID / Mac password on this Mac. You can give the imported vault a different name. Import creates an independent vault with a new identity and encryption key. Later changes are local to each copy.

Portable vaults work offline. Catalogs and filenames are encrypted, and files are re-encrypted under a fresh sharing key for each export. Import verifies each file before registering the new vault. Up to 10,000 items and a 16 MB encrypted catalog are supported. A lost sharing key cannot be recovered from the .harb file. If you still have the source vault, export a new copy.

Version 1.5.1 exports `HARBPK02`: an additional authenticated envelope hides individual file boundaries, exact sizes, and item counts. Its encrypted payload is padded to at least 1 MiB and then to a power of two; this can make exports substantially larger. The format marker and coarse padded total size remain visible. Each 1 MiB record uses a separate HKDF-derived key and authenticates its position and the envelope header. A new random sharing key and salt are generated for every export.

Older `HARBPK01` exports still import, but retain their original observable boundaries and sizes. Export them again to obtain the new protections. This cannot change copies already distributed.

Import warns about an already imported package or an export no newer than one known on this Mac. **Import another or older copy** explicitly allows that choice. These checks use authenticated export metadata and local Keychain history; they do not prove who sent the file, establish the newest copy worldwide, or survive every loss/restoration of that history. A sharing-key holder can create another valid archive.

## Share with AirDrop, Messages, and other Mac services

Select files and choose the Share button or **Share… (verify identity)** in their context menu. The preview window also has a Share button: it shares the explicitly selected group for a grouped preview, or just the current file for a single-file preview.

The verification sheet starts inline Touch ID automatically when the vault supports Mac unlock. It also accepts the vault’s passcode or Mac authentication. After verification, choose where to share the files.

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

Changing a passcode now generates a fresh vault key and re-encrypts every stored file, including Recently Deleted, before atomically switching to the new vault. Keep enough free space for a second encrypted copy. This also upgrades older vault settings to authenticated version 2. Existing vaults should change their passcode once to receive that upgrade. Removing Mac unlock changes the current header only. Older backups and exported copies remain accessible with their earlier credentials; keep them protected too.

On this Mac, Keychain checkpoints detect replacement of verified vault metadata with an older or externally changed copy. Do not overwrite current storage with an older backup and expect it to open automatically. Use a separate Mac or isolated recovery environment to inspect a trusted backup. First use on another Mac cannot establish whether that backup is the latest version. An interrupted commit can temporarily admit either its old or new checkpoint until the next successful verification.

## Storage and implementation

- SwiftUI / AppKit application, using only Apple frameworks. No runtime dependencies or network service.
- Instrument Sans interface text and Manrope headings are bundled locally, along with their SIL Open Font License files. Font sources: [Instrument Sans](https://github.com/google/fonts/tree/main/ofl/instrumentsans) and [Manrope](https://github.com/google/fonts/tree/main/ofl/manrope). No font download is needed at runtime.
- AES-256-GCM via CryptoKit for the catalog and file contents. Files use independently authenticated 4 MB chunks with authenticated file/vault identity, chunk position, total length, and chunk count.
- A random 256-bit key per vault. Passcode wrapping uses PBKDF2-HMAC-SHA256 with a random 32-byte salt and 600,000 iterations.
- Version 2 settings are authenticated with a separate HKDF-derived HMAC key; version-specific wrapping contexts prevent changing the format version to bypass that authentication. Vault labels remain readable while locked.
- Mac unlock uses a Secure Enclave P-256 key with `.privateKeyUsage` and `.userPresence` access control. An ephemeral ECDH key and HKDF-SHA256 derive a wrapping key. The hardware-bound private-key representation is opaque, not an exported private key. There is no plaintext vault key stored in preferences or on disk.
- File data and the encrypted catalog are staged and verified before the catalog is atomically committed. File operations run off the UI thread. Late operation results are discarded after locking.
- Preview data is supplied from memory to native image, PDF, text, and video views. For video, the app decrypts and authenticates only the chunks the player requests. Exports write a readable copy to your selected destination.
- Sharing intentionally creates temporary plaintext copies after fresh authentication, as described above. Its separate authentication permit is bound to the vault and settings, expires after 60 seconds, and is cleared on cancellation, locking, or session changes.
- Storage directories use owner-only permissions. A process lock prevents two instances from concurrently editing the same store.
- Catalog and header reads have size limits. Manifest validation limits item counts and folder depth, rejects nonzero folder sizes, and checks aggregate sizes for overflow. Regular-file reads reject final-component symbolic links. These checks do not make a compromised Mac trustworthy.

Temporary share and screenshot-import copies are excluded from ordinary backups where macOS supports it. Cleanup failures are reported. Removing a temporary file does not guarantee erasure from filesystem snapshots, existing backups, another app, or storage hardware.

This is a first local build, not an independently audited security product. It is designed to protect files at rest when a vault is locked. It does not protect against malware, a compromised/admin-controlled Mac, screen capture, a person viewing an unlocked vault, or privileged memory inspection. Swift/OS memory copies and swap are not guaranteed to be securely erased. Native document frameworks and macOS control their own internal caching. Test with disposable copies and maintain a separate backup before entrusting it with irreplaceable files.

## Build and verify

Local builds now use an available Apple Development signing identity to preserve the app's Keychain identity across updates. Without one, the build falls back to ad-hoc signing and reports that future updates may need Keychain permissions again. Set `HARBOR_SIGNING_IDENTITY` to choose a specific certificate, or `-` for an explicitly ad-hoc build. None of this provides Developer ID distribution signing or Apple notarization. No system security settings need to be disabled.

When switching an existing ad-hoc installation to certificate-backed signing, older Keychain history records can require one final **Always Allow** permission per record. Touch ID unlocks the vault; these legacy Keychain access permissions are separate. Do not delete the history records to suppress the prompts, because that discards rollback history. Later builds using the same trusted signing identity should retain access.

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

With a development signing identity available, run `bash Tests/SigningHistoryTests.sh` to check access across two differently built, consistently signed test programs. It uses randomly named disposable history records, forbids authentication UI for cross-build reads, checks rollback rejection, and removes its test records afterward. It does not inspect your existing history or vaults.

Tests use only generated fixtures. They cover independent vault passcodes, wrong-password rejection, encrypted catalogs, empty/multi-chunk files, ciphertext corruption and identity binding, export recovery, folder preservation, source-change detection, symbolic-link rejection, passcode changes, deletion boundaries, locking and cancellation, selection/range/marquee rules, folder history, thumbnail generation, preview keyboard policy, fresh deletion authorization and exact phrases, and temporary sharing-copy cleanup. The latest native gestures, focus transitions, and sharing-service handoff still require an explicitly approved interactive check; tests do not claim that a message or AirDrop was sent.

Apple API references: [Secure Enclave keys](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave), [CryptoKit Secure Enclave key restoration](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/keyagreement/privatekey/init(datarepresentation:authenticationcontext:)), [user-presence access control](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/userpresence), [AES-GCM authenticated decryption](https://developer.apple.com/documentation/cryptokit/aes/gcm/open(_:using:authenticating:)).
