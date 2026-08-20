-- MedLock local schema. Idempotent. Requires PostgreSQL 14+; pgvector optional.
-- Applied by scripts/setup_postgres.sh

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "vector";

CREATE TABLE IF NOT EXISTS users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username        TEXT NOT NULL UNIQUE,
    password_hash   TEXT NOT NULL,
    role            TEXT NOT NULL DEFAULT 'chat' CHECK (role IN ('owner', 'chat')),
    disabled        BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS conversations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title           TEXT NOT NULL DEFAULT 'New chat',
    model           TEXT NOT NULL DEFAULT 'medlock-llm',
    user_id         UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    demo            BOOLEAN NOT NULL DEFAULT FALSE
);

ALTER TABLE conversations ADD COLUMN IF NOT EXISTS user_id UUID;

CREATE TABLE IF NOT EXISTS messages (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role            TEXT NOT NULL CHECK (role IN ('system', 'user', 'assistant', 'tool')),
    content         TEXT NOT NULL,
    token_in        INTEGER,
    token_out       INTEGER,
    latency_ms      INTEGER,
    model           TEXT,
    rag_used        BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS messages_conversation_idx ON messages (conversation_id, created_at);

CREATE TABLE IF NOT EXISTS audit_events (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    event_type      TEXT NOT NULL,
    path            TEXT,
    method          TEXT,
    client_host     TEXT,
    api_key_id      UUID,
    user_id         UUID,
    model           TEXT,
    request_in      JSONB,
    request_out     JSONB,
    status_code     INTEGER,
    latency_ms      INTEGER,
    error           TEXT
);

ALTER TABLE audit_events ADD COLUMN IF NOT EXISTS user_id UUID;

CREATE INDEX IF NOT EXISTS audit_events_created_idx ON audit_events (created_at DESC);
CREATE INDEX IF NOT EXISTS audit_events_type_idx ON audit_events (event_type);
CREATE INDEX IF NOT EXISTS audit_events_user_idx ON audit_events (user_id);

CREATE TABLE IF NOT EXISTS api_keys (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    key_prefix      TEXT NOT NULL,
    key_hash        TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at    TIMESTAMPTZ,
    revoked         BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS documents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    filename        TEXT NOT NULL,
    source_path     TEXT,
    mime_type       TEXT,
    byte_size       INTEGER,
    demo            BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS chunks (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id     UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    chunk_index     INTEGER NOT NULL,
    content         TEXT NOT NULL,
    embedding       VECTOR(384),
    embedding_json  JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS chunks_document_idx ON chunks (document_id);

CREATE TABLE IF NOT EXISTS settings (
    key             TEXT PRIMARY KEY,
    value           JSONB NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO settings (key, value) VALUES
    ('inference.allow_cloud_llm', 'false'::jsonb),
    ('network.servicenow_enabled', 'false'::jsonb)
ON CONFLICT (key) DO NOTHING;
