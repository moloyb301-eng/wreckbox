-- WreckBox accounts (Cloudflare D1)
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  salt TEXT NOT NULL,          -- server-side salt
  hash TEXT NOT NULL,          -- SHA-256(salt || client key); the client key is PBKDF2(password) made on the device
  created INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
  hash TEXT PRIMARY KEY,       -- SHA-256 of the session token (the token itself is never stored)
  user TEXT NOT NULL,
  device TEXT NOT NULL DEFAULT '',
  created INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
  user TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  url TEXT,                    -- the computer's current tunnel address (null for phones)
  sync_token TEXT,             -- its phone-sync token, so the account's phones can reach it
  last_seen INTEGER NOT NULL,
  PRIMARY KEY (user, id)
);
CREATE TABLE IF NOT EXISTS blobs (
  user TEXT NOT NULL,
  name TEXT NOT NULL,          -- library | state | analysis
  updated INTEGER NOT NULL,
  size INTEGER NOT NULL,
  device TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (user, name)
);
CREATE TABLE IF NOT EXISTS login_attempts (
  key TEXT PRIMARY KEY,        -- email or ip + hour
  n INTEGER NOT NULL
);
