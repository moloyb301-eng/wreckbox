-- for databases created before v0.3 (schema.sql has these for new ones)
ALTER TABLE users ADD COLUMN google_sub TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS users_google_sub ON users (google_sub);
ALTER TABLE devices ADD COLUMN ticket_secret TEXT;
