# Changelog

## Unreleased

- **Extensions that talk to other apps:** yabbistir can now ask macOS for Automation access when a store extension needs it, such as Browser Tabs reading Safari's open tabs or Send To adding a note to Notes. macOS asks once for each app, and System Settings › Privacy & Security › Automation keeps your answers. Before this, macOS refused those requests without asking.

## 0.4.0 — 2026-11-03

- **First run:** a short window on a new install. Pick English or Turkish, bring over another clipboard manager's library, check the shortcut that opens the panel, allow pasting and choose whether yabbistir opens at login. Settings → About → Run First Setup Again… brings it back.
- **Import:** Settings → Import brings over the history and pinboards of another clipboard manager when yabbistir supports it. Pick the history, the pinboards or both; pinboards become categories that open when you pick them. Items keep the dates they were copied and aren't removed by your history's time limit right after they come in. Nothing is imported twice, so importing again brings over only what's new. The other app's data is only read: yabbistir copies it aside first and never writes to it.
- **Settings, every section:**
  - General: language, appearance, open at login, the menu bar icon, and hiding the panel, the Stack and notices from screen sharing.
  - Shortcuts: record the shortcuts that open the panel and copy to the Stack, and see the panel's own keys.
  - Panel: whether it opens under the text caret or the mouse pointer, the preview delay, whether ↵ pastes or only copies, and always pasting plain text.
  - History: how long items are kept, counted from their last use, with a warning that says how many items go before anything is removed. Also ignored apps, copies from iPhone, extension results in History, how much space history uses, and clearing it. Items in a category are never removed.
  - Categories: rename, color, reorder, choose when each opens as a column, and delete.
  - Permissions: where Accessibility and Input Monitoring stand right now, with a short guide and a button that opens the right place in System Settings.
  - About: the version, updates, release notes, licenses and a quiet link to support the project.

## 0.3.0 — 2026-11-02

- **New icon:** a "y" made of stacked glass cards, like the copies waiting in the Stack.
- **Extension columns:** an extension can now bring a category of its own, filled with rows it lists, such as the entries of a password vault. It works like your other categories: search finds its rows, and it can open always or when you pick it. A row shows a name and a short second line, never a secret.
  - The first one is **LastPass**, in the store. It reads your vault through the `lpass` command-line tool: ↵ pastes the password into the field you're in, ⇧↵ the username, and ⌘C copies the username. While LastPass is locked, the column shows one row with the command that signs you in.
  - A password is pasted as a concealed item for this Mac only, which clipboard managers (yabbistir's own history included) skip, and your clipboard comes back a moment later. It's never shown, saved or logged. The rows stay in memory only and go when your Mac locks or sleeps, or when yabbistir quits.
  - Before you install an extension that pastes secrets, yabbistir tells you: "Can read and paste secrets such as passwords. They're never written to history or disk."
- **⇧↵:** pastes an item's second choice. On rich text that's plain text, as before; for any kind of item, it can be a transform you pick with "Make default for ⇧↵" in the ⇧ panel's ⌘K menu. Otherwise ⇧↵ pastes like ↵. Hold ⇧ to see what it will do.
- **Password fields:** yabbistir pastes into them directly, and into Terminal with Secure Keyboard Entry on, instead of copying the item and asking you to press ⌘V. The Stack moves on when you paste into a password field too.
- **Fixes:** ⇧⌘C copies the selection in Terminal. In a full-screen command-line program that copies a selection on its own, ⇧⌘C takes that copy.

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
