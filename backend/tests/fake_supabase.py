"""Tiny in-memory stand-in for the supabase-py query builder used in main.py.

Supports: table().select(cols).eq().is_().order().limit().execute(),
table().insert(row).execute(), table().update(patch).eq()...[.select()].execute(),
and storage.from_(bucket).upload/download/remove (in-memory private bucket).
"""

from __future__ import annotations

import copy
import uuid
from types import SimpleNamespace


class _Query:
    def __init__(self, store: "FakeSupabase", table: str):
        self._store = store
        self._table = table
        self._mode = "select"
        self._columns: list[str] | None = None
        self._filters: list = []
        self._order: tuple[str, bool] | None = None
        self._limit: int | None = None
        self._payload: dict | None = None

    # -- builders ---------------------------------------------------------
    def select(self, columns: str = "*", *_a, **_k):
        if self._mode == "select":
            self._columns = None if columns.strip() == "*" else [
                c.strip() for c in columns.split(",") if c.strip()
            ]
        else:  # update(...).select(...) → return representation with these cols
            self._columns = [c.strip() for c in columns.split(",") if c.strip()]
        return self

    def insert(self, row: dict):
        self._mode = "insert"
        self._payload = row
        return self

    def update(self, patch: dict):
        self._mode = "update"
        self._payload = patch
        return self

    def eq(self, key, value):
        self._filters.append(lambda r, k=key, v=value: r.get(k) == v)
        return self

    def is_(self, key, value):
        assert value == "null"
        self._filters.append(lambda r, k=key: r.get(k) is None)
        return self

    def order(self, key, desc=False):
        self._order = (key, desc)
        return self

    def limit(self, n):
        self._limit = n
        return self

    # -- execution --------------------------------------------------------
    def _project(self, row: dict) -> dict:
        if self._columns is None:
            return copy.deepcopy(row)
        return {c: copy.deepcopy(row.get(c)) for c in self._columns}

    def execute(self):
        rows = self._store.tables.setdefault(self._table, [])
        self._store.calls.append((self._mode, self._table, self._payload))
        if self._mode == "insert" and self._store.fail_inserts:
            raise RuntimeError("insert failed")
        if self._mode == "select" and self._store.fail_selects:
            raise RuntimeError("select failed")
        if self._mode == "insert":
            row = {
                "id": str(uuid.uuid4()),
                "hub_status": None,
                "notes": "",
                "tags": [],
                "image_urls": [],
                "image_paths": [],
                "share_token": None,
                "shared_at": None,
                "seller_username": None,
                "seller_url": None,
                "checked_at": "2026-10-07T12:00:00+00:00",
                **copy.deepcopy(self._payload),
            }
            rows.append(row)
            return SimpleNamespace(data=[copy.deepcopy(row)])

        matched = [r for r in rows if all(f(r) for f in self._filters)]
        if self._mode == "update":
            for r in matched:
                r.update(copy.deepcopy(self._payload))
            return SimpleNamespace(data=[self._project(r) for r in matched])

        if self._order:
            key, desc = self._order
            matched = sorted(matched, key=lambda r: r.get(key) or "", reverse=desc)
        if self._limit is not None:
            matched = matched[: self._limit]
        return SimpleNamespace(data=[self._project(r) for r in matched])


class FakeBucket:
    def __init__(self, storage: "FakeStorage", name: str):
        self._storage = storage
        self.name = name

    def upload(self, path, data, file_options=None):
        if self._storage.fail_uploads:
            raise RuntimeError("storage down")
        if path in self._storage.objects.get(self.name, {}):
            raise RuntimeError("Duplicate")  # x-upsert: false
        self._storage.objects.setdefault(self.name, {})[path] = (bytes(data), dict(file_options or {}))
        return SimpleNamespace(path=path)

    def download(self, path, *_a, **_k):
        try:
            return self._storage.objects[self.name][path][0]
        except KeyError as exc:
            raise RuntimeError("Object not found") from exc

    def remove(self, paths):
        for path in paths:
            self._storage.objects.get(self.name, {}).pop(path, None)
        self._storage.removed.extend(paths)
        return []


class FakeStorage:
    def __init__(self):
        self.objects: dict[str, dict[str, tuple[bytes, dict]]] = {}
        self.removed: list[str] = []
        self.fail_uploads = False

    def from_(self, bucket: str) -> FakeBucket:
        return FakeBucket(self, bucket)


class FakeSupabase:
    def __init__(self, rows: list[dict] | None = None):
        self.tables: dict[str, list[dict]] = {"reports": copy.deepcopy(rows or [])}
        self.calls: list = []
        self.storage = FakeStorage()
        self.fail_inserts = False
        self.fail_selects = False

    def table(self, name: str) -> _Query:
        return _Query(self, name)
