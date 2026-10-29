# Dōki privacy policy

_Last updated: 30 October 2026_

Dōki is a free, open source manga reader for Android, built on [Mihon](https://github.com/mihonapp/mihon).
This policy explains what happens to your information when you use it. The short version: Dōki has
no accounts, no servers of its own, no ads and no analytics. What you do in the app stays on your
device, except for the requests you ask it to make to the services you choose.

## What Dōki keeps on your device

- Your library, reading history, categories, downloads and settings.
- The addresses, usernames, passwords and API keys you enter for Kavita, BookOrbit, Komga or a
  KOReader sync server. Passwords and API keys are left out of backups.
- Sign-in details for any trackers you connect (such as AniList or MyAnimeList).
- Crash logs, if the app crashes. They stay on your device unless you choose to share them.

None of this is sent to us. We have no way to see it.

## What Dōki sends, and to whom

Dōki only connects to services you set up or choose to use:

- **Your own servers.** If you set up Kavita, BookOrbit or Komga, Dōki signs in to that server with
  the details you entered, reads your series from it and, if progress sync is on, sends the pages
  you read. If you set up a KOReader sync server, Dōki sends it your reading progress, a
  fingerprint of each book's file (not the file itself), the device name "Doki" and a random device
  id. For Komga books, working out that fingerprint means downloading the book; Dōki asks before
  doing this and doesn't keep the download.
- **Extensions and the sites they read.** Extensions are made by third parties, not by us. When you
  browse or read with one, it contacts the website it reads from, which sees your IP address and
  whatever the extension sends. Those sites' own privacy policies apply. Install only extensions
  you trust.
- **Trackers.** If you connect a tracker, Dōki sends it the titles you track and your progress, under
  that tracker's privacy policy.
- **Links you open.** Guides, the source code and similar links open in your browser.

Requests to these services identify the app as "Doki" with its version number.

Dōki doesn't include analytics, advertising or crash reporting services, and doesn't sell or share
your information with anyone.

## Permissions

Dōki asks for:

- **Storage (a folder you pick):** for downloads, backups and local manga.
- **Install apps:** to install extensions you choose.
- **Notifications:** for library updates, downloads and backups.
- **Unrestricted battery use (optional):** so long updates and downloads aren't interrupted.

## Removing your information

Each server in **Settings → Sync / Self-hosted sources** has a **Delete** option that erases its
details from your device. Clearing the app's data, or uninstalling it, removes everything Dōki keeps.
Anything already sent to your own servers, trackers or other sites is held by them, under their
policies.

## Children

Dōki isn't directed at children and doesn't knowingly collect information from anyone.

## Changes

If this policy changes, the new version will be published here with a new date. The full history is
in this repository's commits.

## Contact

Questions about this policy can be raised as an
[issue on GitHub](https://github.com/Grillza/mihonka/issues).
