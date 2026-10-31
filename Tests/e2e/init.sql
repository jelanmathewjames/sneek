-- Throwaway E2E fixture. No real data, no real credentials.
CREATE TABLE tickets (id int primary key, note text, updated_at timestamptz default now());
INSERT INTO tickets VALUES (1, 'original');
CREATE TABLE access_tokens (id int primary key, token text);
INSERT INTO access_tokens VALUES (1, 'canary-denied-table-token');
-- A password holding every character that breaks a connection URI or a pgpass
-- line (`:` `\` space `$` `"` `'` `@` `/` `#` `%`). It reaches psql through PGPASSFILE
-- only — see Tests/e2e/secrets/pg_ro_password, which holds the unescaped value.
CREATE ROLE ro LOGIN PASSWORD E'r:o\\p w$"''@/#%';
GRANT CONNECT ON DATABASE app TO ro;
GRANT USAGE ON SCHEMA public TO ro;
GRANT SELECT ON tickets TO ro;          -- access_tokens deliberately not granted
