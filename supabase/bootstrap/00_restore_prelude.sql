ALTER DEFAULT PRIVILEGES IN SCHEMA public
REVOKE ALL ON TABLES FROM anon, authenticated;
CREATE EXTENSION IF NOT EXISTS pgcrypto
WITH SCHEMA extensions;
-- The LIVE schema dump contains indexes explicitly using
-- public.gin_trgm_ops, so reproduce the extension schema used by LIVE.
CREATE EXTENSION pg_trgm
WITH SCHEMA public;
