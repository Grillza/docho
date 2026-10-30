# Self-hosted servers and sync

Dōchō can read straight from your own Kavita, BookOrbit or Komga server, and keep your reading
progress in sync with it, and read from the extensions on a Suwayomi server. It can also sync progress through a KOReader sync server instead.

Everything here is set up in **More → Settings → Sync / Self-hosted sources**. Each server has its
own section: tap it to open it. When a server is set up, its series also appear under
**Browse → Sources**, and you add them to your library like any other manga.

## Kavita

1. In Kavita, open your user settings and copy your key from **API Key / OPDS**.
2. In Dōchō, open **Kavita** and enter:
   - **Server address**: the address you open Kavita at, e.g. `https://kavita.example.com`
   - **API key**: the key you copied
3. **Connection** turns green once Dōchō has signed in.

## BookOrbit

1. In Dōchō, open **BookOrbit** and enter:
   - **Server address**: the address you open BookOrbit at, e.g. `http://bookorbit.lan:3010`
   - **Username** and **Password**: the account you sign in to BookOrbit with
2. **Connection** turns green once Dōchō has signed in.

Comic archives (CBZ, CBR, CB7) can be read; ebooks are left out.

## Komga

1. In Komga, open your account settings and create a key under **API Keys**.
2. In Dōchō, open **Komga** and enter:
   - **Server address**: the address you open Komga at, e.g. `http://komga.lan:25600`
   - **API key**: the key you created
3. **Connection** turns green once Dōchō has connected.

Comic archives and PDFs can be read; text-only EPUBs are left out.

## Suwayomi

[Suwayomi](https://github.com/Suwayomi/Suwayomi-Server) runs Mihon's extensions on a computer or
server. If you already use one, Dōchō can read from its sources without installing the extensions
on your phone.

1. In Dōchō, open **Suwayomi** and enter:
   - **Server address**: the address you open Suwayomi at, e.g. `http://192.168.1.20:4567`
   - **Username** and **Password**: only if your server has basic authentication turned on
2. **Connection** turns green once Dōchō has reached the server.

The extensions installed on the server then appear under **Browse → Sources** beside the ones on
your device, filtered by your source languages like any other. Extensions on the device keep
working as usual; if the same extension is installed in both places, the device's copy is used.
NSFW sources stay hidden unless you turn on **Show NSFW sources**. To install, update or remove
extensions on the server, tap **Manage extensions** to open Suwayomi in your browser.

Suwayomi sources don't sync reading progress back to the server.

## How progress syncs

With **Sync reading progress** on, every page you read is sent to the server, and the page reached
on the server's own reader or your other devices is picked up. Whichever side has read further
wins. **Sync library now** reconciles every series from that server in your library at once.

Progress that can't be sent, for example while you're offline, is kept and sent later.

## KOReader sync

Instead of syncing each series with the server it comes from, Dōchō can sync everything through a
KOReader sync server, so progress is shared with KOReader on an e-reader.

1. Under **Reading progress**, set **Sync progress with** to **KOReader**.
2. Open **KOReader sync** and enter the server address, username and password KOReader uses.
   BookOrbit has a KOReader sync server built in: create the account in BookOrbit under
   **Settings → KOReader**, and use an address like `http://bookorbit.lan:3010/api/v1/koreader`.

KOReader recognises a book by a fingerprint of its file, so a chapter can only sync if Dōchō can
reach the same file. That works for Kavita, BookOrbit and local chapters that are a single archive
(or a PDF on Kavita). Online sources have no files to match, so they don't sync.

Komga can only send whole files, so matching a Komga book means downloading it once. Dōchō asks
before doing this, and you can change your answer later with **Match Komga books** under
KOReader sync. The download isn't kept, but large books can use a lot of data.

## Removing a server

Each section ends with **Delete**, which erases that server's address, sign-in details, sync
options and any progress not yet sent. Nothing is deleted on the server, and your other settings
stay as they are.
