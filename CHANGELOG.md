# Changelog

## 1.4.6

- Unlock vaults with inline Touch ID, including automatic prompting after idle locking and before sharing.
- Use the vault password as the primary fallback, with Mac authentication also available.
- Play supported videos in the small preview and full viewer directly from encrypted storage.
- Enter full screen in the double-click viewer with the green button or Control–Command–F.
- Drag selected files onto folders or breadcrumb locations, including All files.
- Drop onto sidebar actions for Trash, Share, Export, or moving to the vault root. Sidebar actions fade in during dragging and use proportionally rendered icons.
- Sort files by name, date, size, or kind, and Recently Deleted by scheduled deletion date.
- Enable native Liquid Glass on macOS 26 or later, with system-controlled intensity on macOS 27.
- Keep renamed image thumbnails working and restore missing image extensions on shared and exported copies.
- Reveal exported files and folders with Show in Finder.

Requires an Apple silicon Mac running macOS 14 or later. This download is ad hoc signed and has not been notarized by Apple.

## 1.3.1

- Select and copy recognized text directly on images in either preview.
- Publishes the on-device OCR and screenshot-drag improvements from the previous local builds.

## 1.3.0 — Local build

- Add a **Text** button to full and small previews for local image and scanned-PDF OCR using Apple Vision.
- Select or copy recognized text, with per-page PDF progress, page separators, cancellation, and a Back action.
- Keep recognition results in memory and clear them on file changes, preview dismissal, viewer focus locking, or vault locking. Ignore late results after cancellation.
- Preserve the original encrypted file and catalog. Copying text deliberately writes to the system clipboard.

Validation: 258 automated checks using generated fixtures and isolated test pasteboards. Recognition, image orientation, scanned PDF page ordering, cancellation, privacy clearing, and clipboard action were checked without personal files or app windows.

## 1.2.1 — Local build

- Accept floating macOS screenshot thumbnails through native file promises and raw image drops from other apps, alongside existing Finder file/folder drops.
- Preserve original image bytes, clean up private temporary import copies, and offer the original-removal action only for real Finder files.
- Report failed or unfinished screenshot deliveries and cancel pending imports when the vault locks.
- Keep completion-sheet identity stable for screenshot-only imports.

Validation: 229 automated checks with generated fixtures and isolated test pasteboards. A real interactive screenshot drag has not been exercised under the owner's privacy restriction.

## 1.2.0 — Public Preview

The first public Harbor Vault download for Apple silicon Macs running macOS 14 or newer.

- Separate encrypted vaults with individual passcodes and optional Touch ID / Mac password unlock.
- Native folders, list/grid browsing, filename search, adjustable thumbnails, multiselection, and back/forward history.
- Small Space previews and a separate double-click viewer; grouped previews, left/right file switching, and image/PDF pinch zoom.
- A full viewer that locks independently when you leave it, without locking the browser.
- Copy-and-verify import before offering to move Finder originals to Trash.
- Per-vault Recently Deleted with retention controls, exact deletion dates, and confirmed restoration to the prior or another folder.
- Verified moves and duplicates between vaults, plus fresh authentication before native sharing.
- Vault renaming, verified deletion with an exact confirmation phrase, and password visibility controls.
- A downloadable DMG and SHA-256 checksum. Ad-hoc signed; not Apple-notarized.

Validation: 190 automated checks with generated disposable fixtures. This is not an independent security audit. See the user guide for security and backup limitations.
