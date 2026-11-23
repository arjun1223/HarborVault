# Harbor Reader

Open **HarborReader.html** in a current desktop Safari, Chrome, Edge, or Firefox. Choose a `.harb` export and enter its HARB sharing key, or load a password-encrypted `.harbkey`. The vault's local Mac password/passcode cannot unlock a portable export.

Public exports open automatically when selected or dropped, with no sharing key or password, and show a **Public copy** badge. Create one in Harbor Vault using **Vault → Export public vault…**. Anyone holding a public file can decode, download, modify, and forward its contents. It is not confidential or sender-authenticated. The original vault and ordinary private exports retain their protection. Exporting a public file does not host it online.

This is a standalone, read-only HTML file. It needs no installation, account, server, external scripts, fonts, or network connection. Copy this one HTML file wherever you need it. Do not send the sharing key together with the vault.

## Supported

- Original `HARBPK01` and padded `HARBPK02` exports, plus password-encrypted `.harbkey` files.
- Explicitly public `HARBPB01` exports with their decoding key included in the file.
- Folder browsing, empty folders, filename search, and individual verified file downloads.
- Raster image, text, video, and audio previews where supported by the browser. HTML/SVG documents are never executed. PDFs can be downloaded to a separate PDF viewer.
- Automatic locking when the tab is hidden or after five idle minutes, plus a manual Lock button.

The input limit is **256 MiB per .harb file** and 10,000 items. Larger vaults should use the native app. The reader holds the encrypted archive and the file being viewed in memory. New-format padding contributes to the input limit. Mobile browsers can have lower practical memory limits; mobile behavior has not been verified.

## Security boundaries

The reader uses Web Crypto AES-GCM, HKDF-SHA256, PBKDF2-HMAC-SHA256, and SHA-256 to match the Mac format. It authenticates every outer record before opening a v2 catalog, and authenticates the complete selected file and verifies its hash before returning plaintext. Catalog names and text are inserted as text, never HTML. The page has a Content Security Policy that blocks network requests, embeds, and scripts other than the two included scripts.

It doesn't store keys or vault contents in browser storage. Locking clears its references, revokes preview URLs, and overwrites its own mutable buffers where possible. JavaScript, browser media decoders, garbage collection, swap, and downloaded files prevent any guarantee of complete memory or disk erasure. Downloads and copied text leave the reader's protection. It has no Touch ID or Mac Keychain history, sender verification, or detection of an older valid export. Keep using the native app for that device's history checks.

Only open an HTML reader you trust. A modified reader could steal an entered key or file contents. This is not an independently audited browser application.

## Generated-fixture tests

From the project root:

```sh
bash test.sh
output/storage-tests --browser-fixtures output/browser-fixtures
node Tests/BrowserReaderTests.mjs
node Tests/BrowserReaderUITests.mjs
```

The fixture command creates only fictional generated files and keys under the specified output folder. Never substitute personal exports. The compatibility tests run the HTML's actual cryptographic code against Mac-generated exports. They cover old and new formats, chunked/empty files, saved keys, wrong keys, tampering, reordered records, invalid catalogs, cancellation, and lock rejection.

The UI tests require Chrome at its standard macOS application path. They launch a separate headless browser with a disposable profile and only the generated fixtures; they never attach to your existing browser. They verify root and nested-folder rendering, unique element IDs, search, previews, locking, combined vault/key drops, and visible error recovery. The temporary browser and profile are removed afterward.

Made by [Arjun Tyagi](https://github.com/arjun1223/HarborVault).
