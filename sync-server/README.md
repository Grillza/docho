# Dōchō Sync server

Keeps Dōchō's library and categories, chapter renames and Volume/Chapter types, read progress and
history the same on every device signed in to the same account. Standard-library Python, one
SQLite file, no other dependencies.

## Run it

```sh
cd sync-server
docker compose up -d --build
```

It listens on port 8090 and keeps its data in `./data`. In Dōchō, open **Settings → Sync /
Self-hosted sources → Dōchō Sync**, enter `http://<this machine>:8090`, a username and a password,
and tap **Create account**. On your other devices, enter the same details; they sign in and sync.

Only the first account can be created, which suits one person's devices. Set
`DOCHO_SYNC_REGISTRATION=open` in `docker-compose.yml` to let more people make accounts.

Put it behind HTTPS (a reverse proxy such as Caddy) if it's reachable from outside your network,
since passwords and tokens are sent with each sign-in and sync.

## How syncing works

Every record (a series, a category, a chapter's read state, ...) is a kind, a key such as
`sourceId|url`, and a JSON value. Devices send what changed since they last synced and get back
what other devices changed. The newest write of each record wins. A device's first sync merges
instead: chapters read on either side stay read, and libraries and categories are joined.

## Tests

```sh
python3 -m unittest test_server
```
