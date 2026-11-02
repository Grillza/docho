import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

os.environ["DOCHO_SYNC_QUIET"] = "1"
import server  # noqa: E402

server.PASSWORD_ITERATIONS = 1_000


class SyncServerTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.store = server.Store(os.path.join(self.dir.name, "t.db"))
        self.httpd = server.make_server(self.store, "127.0.0.1", 0)
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}/api/v1"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.store.db.close()
        self.dir.cleanup()

    def call(self, path, body=None, token=None):
        request = urllib.request.Request(self.base + path, data=None if body is None else json.dumps(body).encode())
        request.add_header("Content-Type", "application/json")
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def change(self, key, value, at, kind="chapter"):
        return {"kind": kind, "key": key, "value": value, "updatedAt": at}

    def test_first_account_only_then_login(self):
        status, body = self.call("/register", {"username": "josh", "password": "password1", "device": "a"})
        self.assertEqual(status, 200)
        self.assertEqual(self.call("/register", {"username": "other", "password": "password1", "device": "a"})[0], 403)
        self.assertEqual(self.call("/login", {"username": "josh", "password": "nope", "device": "b"})[0], 401)
        status, login = self.call("/login", {"username": "JOSH", "password": "password1", "device": "b"})
        self.assertEqual(status, 200)
        self.assertEqual(self.call("/me", token=login["token"])[1]["username"], "josh")
        self.assertEqual(self.call("/sync", {"since": 0, "changes": [], "device": "b"})[0], 401)

    def test_newest_write_wins_and_devices_see_each_other(self):
        token = self.call("/register", {"username": "j", "password": "password1", "device": "a"})[1]["token"]
        a = self.call("/sync", {"since": 0, "device": "a", "changes": [self.change("1|/c/1", {"read": True}, 200)]}, token)[1]
        self.assertEqual(a["accepted"], 1)
        # An older write from another device loses
        b = self.call("/sync", {"since": 0, "device": "b", "changes": [self.change("1|/c/1", {"read": False}, 100)]}, token)[1]
        self.assertEqual(b["accepted"], 0)
        self.assertEqual(b["changes"][0]["value"], {"read": True})
        self.assertEqual(b["changes"][0]["device"], "a")
        # A newer one wins and only it comes back after a's seq
        self.call("/sync", {"since": b["seq"], "device": "b", "changes": [self.change("1|/c/1", {"read": False}, 300)]}, token)
        a2 = self.call("/sync", {"since": a["seq"], "device": "a", "changes": []}, token)[1]
        self.assertEqual([c["value"] for c in a2["changes"]], [{"read": False}])
        # Deleting
        self.call("/sync", {"since": 0, "device": "a", "changes": [self.change("x", None, 400, "manga")]}, token)
        a3 = self.call("/sync", {"since": a2["seq"], "device": "a", "changes": []}, token)[1]
        self.assertEqual(a3["changes"][0]["value"], None)

    def test_pages_and_validation(self):
        token = self.call("/register", {"username": "j", "password": "password1", "device": "a"})[1]["token"]
        server.PAGE = 3
        try:
            changes = [self.change(f"k{i}", {"i": i}, 10 + i) for i in range(7)]
            first = self.call("/sync", {"since": 0, "device": "a", "changes": changes}, token)[1]
            self.assertTrue(first["more"])
            seen = len(first["changes"])
            since = first["seq"]
            while True:
                page = self.call("/sync", {"since": since, "device": "a", "changes": []}, token)[1]
                seen += len(page["changes"])
                since = page["seq"]
                if not page["more"]:
                    break
            self.assertEqual(seen, 7)
        finally:
            server.PAGE = 5000
        bad = self.call("/sync", {"since": 0, "device": "a", "changes": [{"kind": "nope", "key": "k", "updatedAt": 1}]}, token)
        self.assertEqual(bad[0], 400)


if __name__ == "__main__":
    unittest.main()
