-- Companion Platform Supabase Initialization
-- Creates schemas and roles for hivemind and vexa services

-- Create schemas
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS _realtime;
CREATE SCHEMA IF NOT EXISTS hivemind;
CREATE SCHEMA IF NOT EXISTS vexa;

-- Grant schema access
GRANT ALL ON SCHEMA auth TO supabase_admin;
GRANT ALL ON SCHEMA _realtime TO supabase_admin;
GRANT ALL ON SCHEMA hivemind TO supabase_admin;
GRANT ALL ON SCHEMA vexa TO supabase_admin;

-- Create Supabase roles if they don't exist
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'postgres') THEN
    CREATE ROLE postgres SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role;
  END IF;
END
$$;

-- Grant schema usage to Supabase roles
GRANT USAGE ON SCHEMA hivemind TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA vexa TO anon, authenticated, service_role;

-- Enable pgvector for embeddings (if extension available)
CREATE EXTENSION IF NOT EXISTS vector;

-- Enable pgcrypto for gen_random_uuid (Postgres 13+)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ─── Hivemind schema tables ─────────────────────────────────────────────────

SET search_path TO hivemind, public;

CREATE TABLE IF NOT EXISTS companies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(64) UNIQUE NOT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_companies_slug ON companies(slug);

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    password_hash TEXT NOT NULL,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

CREATE TABLE IF NOT EXISTS company_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role VARCHAR(16) NOT NULL DEFAULT 'member',
    joined_at BIGINT NOT NULL,
    UNIQUE(company_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_members_company ON company_members(company_id);
CREATE INDEX IF NOT EXISTS idx_members_user ON company_members(user_id);

CREATE TABLE IF NOT EXISTS company_invites (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    email VARCHAR(255) NOT NULL,
    role VARCHAR(16) NOT NULL DEFAULT 'member',
    created_at BIGINT NOT NULL,
    used_at BIGINT,
    UNIQUE(company_id, email)
);
CREATE INDEX IF NOT EXISTS idx_invites_company ON company_invites(company_id);

CREATE TABLE IF NOT EXISTS member_api_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider VARCHAR(32) NOT NULL,
    key_encrypted TEXT NOT NULL,
    ollama_url VARCHAR(255),
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    UNIQUE(company_id, user_id, provider)
);

CREATE TABLE IF NOT EXISTS company_config (
    company_id UUID PRIMARY KEY REFERENCES companies(id) ON DELETE CASCADE,
    allowed_models JSONB NOT NULL DEFAULT '[]',
    default_provider VARCHAR(32) NOT NULL DEFAULT 'anthropic',
    default_model VARCHAR(128) NOT NULL DEFAULT 'claude-sonnet-4-5',
    hivemind_enabled BOOLEAN NOT NULL DEFAULT true,
    updated_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS meetings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    title VARCHAR(512) NOT NULL,
    date BIGINT NOT NULL,
    duration_seconds INT NOT NULL DEFAULT 0,
    participants JSONB NOT NULL DEFAULT '[]',
    summary TEXT,
    created_at BIGINT NOT NULL,
    vexa_meeting_id INT,
    vexa_platform VARCHAR(32),
    vexa_native_meeting_id VARCHAR(255)
);
CREATE INDEX IF NOT EXISTS idx_meetings_company_date ON meetings(company_id, date DESC);

CREATE TABLE IF NOT EXISTS knowledge_chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id UUID NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    segment_id UUID,
    text TEXT NOT NULL,
    speaker VARCHAR(255),
    timestamp BIGINT,
    chunk_type VARCHAR(32) NOT NULL DEFAULT 'transcript',
    embedding vector(768),
    metadata JSONB NOT NULL DEFAULT '{}',
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chunks_meeting ON knowledge_chunks(meeting_id);
CREATE INDEX IF NOT EXISTS idx_chunks_type ON knowledge_chunks(chunk_type);
CREATE INDEX IF NOT EXISTS idx_chunks_embedding ON knowledge_chunks USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);
CREATE INDEX IF NOT EXISTS idx_chunks_text_gin ON knowledge_chunks USING GIN(to_tsvector('english', text));

CREATE TABLE IF NOT EXISTS token_usage (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_id VARCHAR(64) NOT NULL,
    model VARCHAR(128) NOT NULL,
    provider VARCHAR(32) NOT NULL,
    input_tokens BIGINT NOT NULL DEFAULT 0,
    output_tokens BIGINT NOT NULL DEFAULT 0,
    cost_cents INT NOT NULL DEFAULT 0,
    recorded_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_token_usage_company ON token_usage(company_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_token_usage_user ON token_usage(user_id, company_id);

CREATE TABLE IF NOT EXISTS auth_tokens (
    token VARCHAR(128) PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_auth_tokens_user ON auth_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_auth_tokens_company ON auth_tokens(company_id);

-- ─── Vexa schema tables ─────────────────────────────────────────────────────
-- These match the SQLAlchemy models in companion-voice/libs/shared-models/shared_models/models.py
-- Tables are created with CREATE TABLE IF NOT EXISTS so they are idempotent.
-- Column types and names must match the SQLAlchemy model definitions exactly.

SET search_path TO vexa, public;

CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    name VARCHAR(100),
    image_url TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    max_concurrent_bots INT NOT NULL DEFAULT 1,
    data JSONB NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS api_tokens (
    id SERIAL PRIMARY KEY,
    token VARCHAR(255) UNIQUE NOT NULL,
    user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_api_tokens_token_vexa ON api_tokens(token);
CREATE INDEX IF NOT EXISTS idx_api_tokens_user_id ON api_tokens(user_id);

CREATE TABLE IF NOT EXISTS meetings (
    id SERIAL PRIMARY KEY,
    user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    platform VARCHAR(100) NOT NULL,
    platform_specific_id VARCHAR(255),
    status VARCHAR(50) NOT NULL DEFAULT 'requested',
    bot_container_id VARCHAR(255),
    start_time TIMESTAMP,
    end_time TIMESTAMP,
    data JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS ix_meeting_user_platform_native_id_created_at ON meetings(user_id, platform, platform_specific_id, created_at);
CREATE INDEX IF NOT EXISTS ix_meeting_data_gin ON meetings USING GIN(data);
CREATE INDEX IF NOT EXISTS idx_meeting_status ON meetings(status);

CREATE TABLE IF NOT EXISTS transcriptions (
    id SERIAL PRIMARY KEY,
    meeting_id INT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    start_time FLOAT NOT NULL,
    end_time FLOAT NOT NULL,
    text TEXT NOT NULL,
    speaker VARCHAR(255),
    language VARCHAR(10),
    created_at TIMESTAMP DEFAULT NOW(),
    session_uid VARCHAR
);
CREATE INDEX IF NOT EXISTS ix_transcription_meeting_start ON transcriptions(meeting_id, start_time);
CREATE INDEX IF NOT EXISTS idx_transcription_session_uid ON transcriptions(session_uid);

CREATE TABLE IF NOT EXISTS meeting_sessions (
    id SERIAL PRIMARY KEY,
    meeting_id INT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    session_uid VARCHAR NOT NULL,
    session_start_time TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT _meeting_session_uc UNIQUE(meeting_id, session_uid)
);
CREATE INDEX IF NOT EXISTS idx_meeting_sessions_meeting_id ON meeting_sessions(meeting_id);
CREATE INDEX IF NOT EXISTS idx_meeting_sessions_session_uid ON meeting_sessions(session_uid);

CREATE TABLE IF NOT EXISTS recordings (
    id SERIAL PRIMARY KEY,
    meeting_id INT REFERENCES meetings(id) ON DELETE CASCADE,
    user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_uid VARCHAR,
    source VARCHAR(50) NOT NULL DEFAULT 'bot',
    status VARCHAR(50) NOT NULL DEFAULT 'in_progress',
    error_message TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    completed_at TIMESTAMP
);
CREATE INDEX IF NOT EXISTS ix_recording_meeting_session ON recordings(meeting_id, session_uid);
CREATE INDEX IF NOT EXISTS ix_recording_user_created ON recordings(user_id, created_at);
CREATE INDEX IF NOT EXISTS idx_recording_status ON recordings(status);

CREATE TABLE IF NOT EXISTS media_files (
    id SERIAL PRIMARY KEY,
    recording_id INT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
    type VARCHAR(50) NOT NULL,
    format VARCHAR(20) NOT NULL,
    storage_path VARCHAR(1024) NOT NULL,
    storage_backend VARCHAR(50) NOT NULL DEFAULT 'minio',
    file_size_bytes INT,
    duration_seconds FLOAT,
    metadata JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_media_files_recording_id ON media_files(recording_id);

CREATE TABLE IF NOT EXISTS transcription_jobs (
    id SERIAL PRIMARY KEY,
    recording_id INT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
    meeting_id INT REFERENCES meetings(id) ON DELETE CASCADE,
    user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    language VARCHAR(10),
    task VARCHAR(50) NOT NULL DEFAULT 'transcribe',
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    error_message TEXT,
    progress FLOAT,
    segments_count INT,
    session_uid VARCHAR,
    created_at TIMESTAMP DEFAULT NOW(),
    started_at TIMESTAMP,
    completed_at TIMESTAMP
);
CREATE INDEX IF NOT EXISTS ix_transcription_job_status_created ON transcription_jobs(status, created_at);
CREATE INDEX IF NOT EXISTS ix_transcription_job_user_created ON transcription_jobs(user_id, created_at);

-- Grant table permissions to Supabase roles
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA hivemind TO anon, authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA hivemind TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA vexa TO anon, authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA vexa TO anon, authenticated, service_role;

-- Reset search_path
SET search_path TO public;
