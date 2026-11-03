"""Dōchō Sync: keeps each account's library, categories, renames, read progress and history
the same on every device that signs in to it.

Devices send the records that changed on them and get back everything other devices changed
since they last asked. Each record is a (kind, key) with a JSON value, or null once deleted.
The newest write wins, by the time the device made it, so a device that was offline for a while
can't undo newer changes from another one.

Standard library only, storing everything in one SQLite file. Settings, from the environment:
  DOCHO_SYNC_DATA          folder for the database (default ./data)
  DOCHO_SYNC_PORT          port to listen on (default 8090)
  DOCHO_SYNC_REGISTRATION  "open" lets anyone create an account; by default only the first
                           account can be created, which is the usual single-person setup
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1"
KINDS = {"manga", "category", "rename", "kind", "chapter", "history", "details"}
MAX_BODY = 32 * 1024 * 1024
MAX_CHANGES = 50_000
PAGE = 5_000
PASSWORD_ITERATIONS = 600_000

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    username TEXT NOT NULL UNIQUE COLLATE NOCASE,
    salt BLOB NOT NULL,
    password_hash BLOB NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS tokens (
    token_hash BLOB PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS records (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT,
    updated_at INTEGER NOT NULL,
    device TEXT NOT NULL,
    seq INTEGER NOT NULL,
    PRIMARY KEY (user_id, kind, key)
);
CREATE INDEX IF NOT EXISTS records_user_seq ON records(user_id, seq);
CREATE TABLE IF NOT EXISTS counters (
    user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    seq INTEGER NOT NULL
);
"""


class ApiError(Exception):
    def __init__(self, status: HTTPStatus, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def now_ms() -> int:
    return int(time.time() * 1000)


def hash_password(password: str, salt: bytes) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", password.encode(), salt, PASSWORD_ITERATIONS)


def hash_token(token: str) -> bytes:
    return hashlib.sha256(token.encode()).digest()


class Store:
    def __init__(self, path: str, registration_open: bool = False):
        self.path = path
        self.registration_open = registration_open
        self.lock = threading.Lock()
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript(SCHEMA)

    # Accounts

    def register(self, username: str, password: str, device: str) -> dict:
        username = username.strip()
        if not username or len(username) > 100:
            raise ApiError(HTTPStatus.BAD_REQUEST, "Enter a username")
        if len(password) < 8:
            raise ApiError(HTTPStatus.BAD_REQUEST, "The password needs at least 8 characters")
        with self.lock:
            users = self.db.execute("SELECT COUNT(*) FROM users").fetchone()[0]
            if users > 0 and not self.registration_open:
                raise ApiError(HTTPStatus.FORBIDDEN, "This server doesn't take new accounts")
            salt = secrets.token_bytes(16)
            try:
                cursor = self.db.execute(
                    "INSERT INTO users (username, salt, password_hash, created_at) VALUES (?, ?, ?, ?)",
                    (username, salt, hash_password(password, salt), now_ms()),
                )
            except sqlite3.IntegrityError:
                raise ApiError(HTTPStatus.CONFLICT, "That username is taken") from None
            return self._new_token(cursor.lastrowid, username, device)

    def login(self, username: str, password: str, device: str) -> dict:
        with self.lock:
            row = self.db.execute(
                "SELECT id, username, salt, password_hash FROM users WHERE username = ?", (username.strip(),)
            ).fetchone()
            # Hash even for unknown users, so the time taken doesn't say which usernames exist.
            salt = row[2] if row else b"\0" * 16
            given = hash_password(password, salt)
            if row is None or not hmac.compare_digest(given, row[3]):
                raise ApiError(HTTPStatus.UNAUTHORIZED, "Wrong username or password")
            return self._new_token(row[0], row[1], device)

    def _new_token(self, user_id: int, username: str, device: str) -> dict:
        token = secrets.token_urlsafe(32)
        stamp = now_ms()
        self.db.execute(
            "INSERT INTO tokens (token_hash, user_id, device, created_at, last_used_at) VALUES (?, ?, ?, ?, ?)",
            (hash_token(token), user_id, device[:200], stamp, stamp),
        )
        return {"token": token, "username": username}

    def user_for(self, token: str | None) -> tuple[int, str]:
        if not token:
            raise ApiError(HTTPStatus.UNAUTHORIZED, "Sign in first")
        with self.lock:
            row = self.db.execute(
                "SELECT t.user_id, u.username FROM tokens t JOIN users u ON u.id = t.user_id WHERE t.token_hash = ?",
                (hash_token(token),),
            ).fetchone()
            if row is None:
                raise ApiError(HTTPStatus.UNAUTHORIZED, "Signed out, sign in again")
            self.db.execute("UPDATE tokens SET last_used_at = ? WHERE token_hash = ?", (now_ms(), hash_token(token)))
            return row[0], row[1]

    def logout(self, token: str) -> None:
        with self.lock:
            self.db.execute("DELETE FROM tokens WHERE token_hash = ?", (hash_token(token),))

    # Records

    def sync(self, user_id: int, since: int, device: str, changes: list) -> dict:
        """Takes the device's changes, newest write winning, then returns what changed after `since`."""
        if len(changes) > MAX_CHANGES:
            raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "Too many changes at once")
        parsed = [self._parse_change(change) for change in changes]
        with self.lock:
            self.db.execute("BEGIN IMMEDIATE")
            try:
                seq = self._seq(user_id)
                accepted = 0
                for kind, key, value, updated_at in parsed:
                    current = self.db.execute(
                        "SELECT updated_at, device FROM records WHERE user_id = ? AND kind = ? AND key = ?",
                        (user_id, kind, key),
                    ).fetchone()
                    # Newest wins; on the same millisecond, the device id breaks the tie the same
                    # way every time, so devices can't keep overwriting each other.
                    if current is not None and (current[0], current[1]) >= (updated_at, device):
                        continue
                    seq += 1
                    accepted += 1
                    self.db.execute(
                        """INSERT INTO records (user_id, kind, key, value, updated_at, device, seq)
                           VALUES (?, ?, ?, ?, ?, ?, ?)
                           ON CONFLICT (user_id, kind, key) DO UPDATE SET
                             value = excluded.value, updated_at = excluded.updated_at,
                             device = excluded.device, seq = excluded.seq""",
                        (user_id, kind, key, value, updated_at, device, seq),
                    )
                self.db.execute(
                    "INSERT INTO counters (user_id, seq) VALUES (?, ?) ON CONFLICT (user_id) DO UPDATE SET seq = excluded.seq",
                    (user_id, seq),
                )
                rows = self.db.execute(
                    """SELECT kind, key, value, updated_at, device, seq FROM records
                       WHERE user_id = ? AND seq > ? ORDER BY seq LIMIT ?""",
                    (user_id, since, PAGE + 1),
                ).fetchall()
                self.db.execute("COMMIT")
            except BaseException:
                self.db.execute("ROLLBACK")
                raise
        more = len(rows) > PAGE
        rows = rows[:PAGE]
        return {
            "accepted": accepted,
            "seq": rows[-1][5] if more else max(seq, since),
            "more": more,
            "changes": [
                {
                    "kind": kind,
                    "key": key,
                    "value": json.loads(value) if value is not None else None,
                    "updatedAt": updated_at,
                    "device": change_device,
                }
                for kind, key, value, updated_at, change_device, _ in rows
            ],
        }

    def _seq(self, user_id: int) -> int:
        row = self.db.execute("SELECT seq FROM counters WHERE user_id = ?", (user_id,)).fetchone()
        return row[0] if row else 0

    @staticmethod
    def _parse_change(change) -> tuple[str, str, str | None, int]:
        if not isinstance(change, dict):
            raise ApiError(HTTPStatus.BAD_REQUEST, "Each change must be an object")
        kind, key, updated_at = change.get("kind"), change.get("key"), change.get("updatedAt")
        if kind not in KINDS:
            raise ApiError(HTTPStatus.BAD_REQUEST, f"Unknown kind: {kind}")
        if not isinstance(key, str) or not key or len(key) > 4000:
            raise ApiError(HTTPStatus.BAD_REQUEST, "Each change needs a key")
        if not isinstance(updated_at, int) or isinstance(updated_at, bool) or updated_at <= 0:
            raise ApiError(HTTPStatus.BAD_REQUEST, "Each change needs updatedAt in milliseconds")
        value = change.get("value")
        encoded = None if value is None else json.dumps(value, separators=(",", ":"), sort_keys=True)
        if encoded is not None and len(encoded) > 64_000:
            raise ApiError(HTTPStatus.BAD_REQUEST, "A value is too large")
        return kind, key, encoded, updated_at


class Handler(BaseHTTPRequestHandler):
    store: Store
    server_version = f"DochoSync/{VERSION}"

    def log_message(self, format, *args):  # noqa: A002 - BaseHTTPRequestHandler's name
        if os.environ.get("DOCHO_SYNC_QUIET") != "1":
            super().log_message(format, *args)

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def _handle(self, method: str):
        try:
            status, body = self._route(method, self.path.split("?", 1)[0].rstrip("/"))
        except ApiError as error:
            status, body = error.status, {"error": error.message}
        except json.JSONDecodeError:
            status, body = HTTPStatus.BAD_REQUEST, {"error": "The body isn't JSON"}
        except Exception as error:  # noqa: BLE001 - reported to the client, logged here
            self.log_error("Error: %r", error)
            status, body = HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "Server error"}
        data = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _route(self, method: str, path: str):
        store = self.store
        if method == "GET" and path in ("/api/v1/health", ""):
            return HTTPStatus.OK, {"name": "Dōchō Sync", "version": VERSION}
        if method == "POST" and path == "/api/v1/register":
            body = self._json()
            return HTTPStatus.OK, store.register(str(body.get("username", "")), str(body.get("password", "")), self._device(body))
        if method == "POST" and path == "/api/v1/login":
            body = self._json()
            return HTTPStatus.OK, store.login(str(body.get("username", "")), str(body.get("password", "")), self._device(body))
        token = self._token()
        if method == "GET" and path == "/api/v1/me":
            _, username = store.user_for(token)
            return HTTPStatus.OK, {"username": username}
        if method == "POST" and path == "/api/v1/logout":
            store.user_for(token)
            store.logout(token)
            return HTTPStatus.OK, {}
        if method == "POST" and path == "/api/v1/sync":
            user_id, _ = store.user_for(token)
            body = self._json()
            since = body.get("since", 0)
            changes = body.get("changes", [])
            if not isinstance(since, int) or since < 0 or not isinstance(changes, list):
                raise ApiError(HTTPStatus.BAD_REQUEST, "Send since and changes")
            return HTTPStatus.OK, store.sync(user_id, since, self._device(body), changes)
        raise ApiError(HTTPStatus.NOT_FOUND, "Not found")

    def _json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "Too large")
        body = json.loads(self.rfile.read(length) or b"{}")
        if not isinstance(body, dict):
            raise ApiError(HTTPStatus.BAD_REQUEST, "Send a JSON object")
        return body

    def _token(self) -> str | None:
        header = self.headers.get("Authorization", "")
        return header[7:].strip() if header.lower().startswith("bearer ") else None

    @staticmethod
    def _device(body: dict) -> str:
        device = body.get("device")
        if not isinstance(device, str) or not device.strip():
            raise ApiError(HTTPStatus.BAD_REQUEST, "Send the device id")
        return device.strip()[:200]


def make_server(store: Store, host: str = "0.0.0.0", port: int = 8090) -> ThreadingHTTPServer:
    handler = type("BoundHandler", (Handler,), {"store": store})
    return ThreadingHTTPServer((host, port), handler)


def main():
    data = os.environ.get("DOCHO_SYNC_DATA", "data")
    os.makedirs(data, exist_ok=True)
    store = Store(os.path.join(data, "docho-sync.db"), os.environ.get("DOCHO_SYNC_REGISTRATION") == "open")
    port = int(os.environ.get("DOCHO_SYNC_PORT", "8090"))
    server = make_server(store, port=port)
    print(f"Dōchō Sync listening on port {port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
