# Changelog

## 0.2.0 — 2026-10-31

- **Extension store:** Settings → Extensions → Store lists the extensions published in the open [yabbistir-extensions](https://github.com/berkaygkc/yabbistir-extensions) repository. Pick several, read every permission they ask for on one screen, and install them together. Updates show up as "N updates" with an "Update all" button; an update that asks for new permissions asks you first.
  - The store's catalog is signed. yabbistir checks the signature and every package's SHA-256 before installing anything, and installs exactly the version you approved.
  - The store goes online only when you open its tab or press Refresh, Install or Update. It shows the saved list when you're offline.
  - The first extensions in the store: Video Download (save a video or its audio from a link with yt-dlp), Link Clean (strip tracking from links you copy), JWT (read a token's header, payload and expiry) and Translate (on-device translation and summaries).
- **Extensions:** a manifest warning, such as a copy rule that waits for a tag it can never see, now shows in Settings → Extensions → Development. An extension that floods notices is quieted. An extension that can't reach Apple Intelligence or a language pack is no longer turned off for it.
- **Fixes:** a copy from the Passwords menu bar item is never saved. Recent copies reach extensions faster, at most 64 KB each. A long-running yabbistir no longer slowly runs out of open files when an extension's helper restarts. Extension time limits are measured from when a call starts, not from when yabbistir got to it.
- **For contributors:** a Debug build runs as "yabbistir Dev" with its own permissions, next to an installed release; opening one quits the other.

## 0.1.0 — 2026-10-30

First public release.

- **History panel:** press ⇧⌘V and a panel opens right under your text caret (under the mouse in apps that don't report one). Everything you copy is kept; start typing to search, ↵ pastes into the app you were in. Works the same on non-US keyboard layouts.
- **Categories:** add an item to a category with ⌘P. A category opens as its own column next to History, always or when you pick it from the Categories menu. Items in a category are never cleaned up. History is kept for a year from last use.
- **Stack:** copy several things in a row with ⇧⌘C, then paste them in order. Reorder the queue by dragging, and move a fresh copy to the front or second place without losing the rest.
- **Transforms:** press ⇧ on an item to see every transform that fits it, or use ⌘K for the full action list. ↵ always pastes the item as it is.
- **Extensions:**
  - Built in: UUID, Base64, Convert (colors and images) and Paste to Finder as a File.
  - Each extension asks for the permissions it needs, and you decide.
  - Long tasks run as jobs with a small progress card under the menu bar.
  - Extensions can use Apple's on-device model and Apple Translation; nothing leaves your Mac, and language packs download only when you ask.
  - More extensions, including video download, link cleaning, JWT and translation, come with the extension store.
- **Updates:** Check for Updates… in the menu bar icon's menu tells you when a new version is out. yabbistir never checks on its own.
- **Privacy:** nothing leaves your Mac unless you ask for it. Concealed and transient clipboard items, such as password manager entries, are never saved.
- **Languages:** English and Turkish.
