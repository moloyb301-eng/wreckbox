-- v0.6: sharing — a key for a whole library, or a link to one playlist, that friends open to stream / download
CREATE TABLE IF NOT EXISTS shares (
  id TEXT PRIMARY KEY,
  key_hash TEXT UNIQUE NOT NULL,   -- SHA-256 of the key; the key itself is shown once, never stored
  owner TEXT NOT NULL,             -- users.id
  computer TEXT NOT NULL,          -- devices.id of the Mac that serves it
  kind TEXT NOT NULL,              -- 'library' | 'playlist'
  playlist TEXT,                   -- the playlist's name for kind = 'playlist'
  label TEXT NOT NULL DEFAULT '',  -- who it's for ("Sam's phone")
  created INTEGER NOT NULL,
  expires INTEGER NOT NULL DEFAULT 0,  -- 0 = no expiry
  revoked INTEGER NOT NULL DEFAULT 0,
  last_used INTEGER
);
CREATE INDEX IF NOT EXISTS shares_owner ON shares (owner);
