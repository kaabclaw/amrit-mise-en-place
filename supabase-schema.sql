-- ============================================================================
-- Amrit Mise en Place — Supabase Schema
-- ============================================================================
-- Run this entire file in your Supabase SQL Editor (in order).
-- It is idempotent where possible (uses IF NOT EXISTS / CREATE OR REPLACE).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Enable required extensions
-- ----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";  -- for fuzzy search / similarity

-- ============================================================================
-- Table: sops
-- ----------------------------------------------------------------------------
-- The core document table. Each row is either an SOP or a Checklist.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.sops (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    slug            TEXT NOT NULL UNIQUE,                 -- URL-safe identifier, e.g. "tula-steps-of-service"
    title           TEXT NOT NULL,
    type            TEXT NOT NULL CHECK (type IN ('SOP', 'Checklist')),
    department      TEXT NOT NULL CHECK (department IN (
                        'Food & Beverage',
                        'Spa & Wellness',
                        'Recreation',
                        'Safety & Security',
                        'HR & Training'
                    )),
    outlet          TEXT NOT NULL,                        -- e.g. "Tula", "IRD", "Resort-wide"
    tags            TEXT[] DEFAULT '{}',                  -- free-form keywords
    important_rules JSONB DEFAULT '[]'::jsonb,            -- array of strings
    steps           JSONB DEFAULT '[]'::jsonb,            -- array of {number, text} for checklists
    sections        JSONB DEFAULT '[]'::jsonb,            -- array of {title, body_html} for narrative SOPs
    version         INT NOT NULL DEFAULT 1,
    published       BOOLEAN NOT NULL DEFAULT true,
    author          TEXT,
    notes           TEXT,                                  -- for review flags, e.g. content mismatches
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Generated tsvector column for full-text search
    search_vector   TSVECTOR GENERATED ALWAYS AS (
                        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
                        setweight(to_tsvector('english', coalesce(outlet, '')), 'B') ||
                        setweight(to_tsvector('english', coalesce(department, '')), 'B') ||
                        setweight(to_tsvector('english', coalesce(array_to_string(tags, ' '), '')), 'C') ||
                        setweight(to_tsvector('english', coalesce(important_rules::text, '')), 'D') ||
                        setweight(to_tsvector('english', coalesce(steps::text, '')), 'D') ||
                        setweight(to_tsvector('english', coalesce(sections::text, '')), 'D')
                    ) STORED
);

CREATE INDEX IF NOT EXISTS sops_search_idx ON public.sops USING GIN (search_vector);
CREATE INDEX IF NOT EXISTS sops_dept_idx ON public.sops (department);
CREATE INDEX IF NOT EXISTS sops_outlet_idx ON public.sops (outlet);
CREATE INDEX IF NOT EXISTS sops_type_idx ON public.sops (type);
CREATE INDEX IF NOT EXISTS sops_updated_idx ON public.sops (updated_at DESC);
CREATE INDEX IF NOT EXISTS sops_title_trgm_idx ON public.sops USING GIN (title gin_trgm_ops);

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS sops_updated_at ON public.sops;
CREATE TRIGGER sops_updated_at
    BEFORE UPDATE ON public.sops
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================================
-- Table: sop_signoffs
-- ----------------------------------------------------------------------------
-- Tracks which user acknowledged which version of which SOP.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.sop_signoffs (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    sop_id          UUID NOT NULL REFERENCES public.sops(id) ON DELETE CASCADE,
    version_signed  INT NOT NULL,
    signed_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, sop_id, version_signed)
);

CREATE INDEX IF NOT EXISTS signoffs_user_idx ON public.sop_signoffs (user_id);
CREATE INDEX IF NOT EXISTS signoffs_sop_idx ON public.sop_signoffs (sop_id);

-- ============================================================================
-- Table: checklist_progress
-- ----------------------------------------------------------------------------
-- Per-user in-progress checklist state. One row per (user, sop, step).
-- When all required steps are completed, a checklist can be "submitted" which
-- creates a completion record and clears progress.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.checklist_progress (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    sop_id          UUID NOT NULL REFERENCES public.sops(id) ON DELETE CASCADE,
    step_number     INT NOT NULL,
    completed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, sop_id, step_number)
);

CREATE INDEX IF NOT EXISTS progress_user_sop_idx ON public.checklist_progress (user_id, sop_id);

-- ============================================================================
-- Table: checklist_completions
-- ----------------------------------------------------------------------------
-- Historical record of each completed checklist run. Separate from progress
-- so you can run the same checklist multiple times (e.g., daily).
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.checklist_completions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    sop_id          UUID NOT NULL REFERENCES public.sops(id) ON DELETE CASCADE,
    version         INT NOT NULL,
    completed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    notes           TEXT
);

CREATE INDEX IF NOT EXISTS completions_user_idx ON public.checklist_completions (user_id);
CREATE INDEX IF NOT EXISTS completions_sop_idx ON public.checklist_completions (sop_id);
CREATE INDEX IF NOT EXISTS completions_date_idx ON public.checklist_completions (completed_at DESC);

-- ============================================================================
-- Table: sop_comments
-- ----------------------------------------------------------------------------
-- Threaded comments on SOPs. parent_id null for top-level.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.sop_comments (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sop_id          UUID NOT NULL REFERENCES public.sops(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    parent_id       UUID REFERENCES public.sop_comments(id) ON DELETE CASCADE,
    body            TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS comments_sop_idx ON public.sop_comments (sop_id, created_at);

DROP TRIGGER IF EXISTS comments_updated_at ON public.sop_comments;
CREATE TRIGGER comments_updated_at
    BEFORE UPDATE ON public.sop_comments
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================================
-- Table: profiles
-- ----------------------------------------------------------------------------
-- Lightweight user profile. One row per auth user. Used to display names
-- next to comments and sign-offs.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.profiles (
    id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    full_name       TEXT,
    role            TEXT DEFAULT 'staff' CHECK (role IN ('staff', 'manager', 'admin')),
    department      TEXT,
    avatar_url      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TRIGGER IF EXISTS profiles_updated_at ON public.profiles;
CREATE TRIGGER profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Auto-create profile when a user signs up
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, full_name)
    VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============================================================================
-- Row-Level Security (RLS)
-- ----------------------------------------------------------------------------
-- NOTE: The preview route on the frontend uses the anon key against a view
-- (sops_public) that doesn't expose notes/author. Authed users get full access.
-- ============================================================================

ALTER TABLE public.sops ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sop_signoffs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.checklist_progress ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.checklist_completions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sop_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- sops: anyone authed can read published docs; only admins can write
DROP POLICY IF EXISTS "sops_read_authed" ON public.sops;
CREATE POLICY "sops_read_authed" ON public.sops
    FOR SELECT TO authenticated
    USING (published = true);

DROP POLICY IF EXISTS "sops_read_anon_published" ON public.sops;
CREATE POLICY "sops_read_anon_published" ON public.sops
    FOR SELECT TO anon
    USING (published = true);

DROP POLICY IF EXISTS "sops_admin_write" ON public.sops;
CREATE POLICY "sops_admin_write" ON public.sops
    FOR ALL TO authenticated
    USING (EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
    ))
    WITH CHECK (EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
    ));

-- sop_signoffs: users see/create their own only
DROP POLICY IF EXISTS "signoffs_own" ON public.sop_signoffs;
CREATE POLICY "signoffs_own" ON public.sop_signoffs
    FOR ALL TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- Managers and admins can see all signoffs (for reporting)
DROP POLICY IF EXISTS "signoffs_managers_read" ON public.sop_signoffs;
CREATE POLICY "signoffs_managers_read" ON public.sop_signoffs
    FOR SELECT TO authenticated
    USING (EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.role IN ('manager', 'admin')
    ));

-- checklist_progress: users only see/edit their own
DROP POLICY IF EXISTS "progress_own" ON public.checklist_progress;
CREATE POLICY "progress_own" ON public.checklist_progress
    FOR ALL TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

-- checklist_completions: users see their own, managers see all
DROP POLICY IF EXISTS "completions_own" ON public.checklist_completions;
CREATE POLICY "completions_own" ON public.checklist_completions
    FOR ALL TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "completions_managers_read" ON public.checklist_completions;
CREATE POLICY "completions_managers_read" ON public.checklist_completions
    FOR SELECT TO authenticated
    USING (EXISTS (
        SELECT 1 FROM public.profiles
        WHERE profiles.id = auth.uid() AND profiles.role IN ('manager', 'admin')
    ));

-- sop_comments: anyone authed can read, authored user can edit/delete
DROP POLICY IF EXISTS "comments_read_authed" ON public.sop_comments;
CREATE POLICY "comments_read_authed" ON public.sop_comments
    FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "comments_insert_authed" ON public.sop_comments;
CREATE POLICY "comments_insert_authed" ON public.sop_comments
    FOR INSERT TO authenticated
    WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "comments_update_own" ON public.sop_comments;
CREATE POLICY "comments_update_own" ON public.sop_comments
    FOR UPDATE TO authenticated
    USING (user_id = auth.uid())
    WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "comments_delete_own_or_admin" ON public.sop_comments;
CREATE POLICY "comments_delete_own_or_admin" ON public.sop_comments
    FOR DELETE TO authenticated
    USING (
        user_id = auth.uid() OR
        EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.uid() AND profiles.role = 'admin')
    );

-- profiles: anyone authed can read, users can edit their own
DROP POLICY IF EXISTS "profiles_read_authed" ON public.profiles;
CREATE POLICY "profiles_read_authed" ON public.profiles
    FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
CREATE POLICY "profiles_update_own" ON public.profiles
    FOR UPDATE TO authenticated
    USING (id = auth.uid())
    WITH CHECK (id = auth.uid());

-- ============================================================================
-- Search function (RPC)
-- ----------------------------------------------------------------------------
-- Called from the frontend to do ranked full-text search.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.search_sops(q TEXT)
RETURNS TABLE (
    id UUID,
    slug TEXT,
    title TEXT,
    type TEXT,
    department TEXT,
    outlet TEXT,
    tags TEXT[],
    step_count INT,
    updated_at TIMESTAMPTZ,
    rank REAL
) LANGUAGE sql STABLE AS $$
    SELECT
        s.id,
        s.slug,
        s.title,
        s.type,
        s.department,
        s.outlet,
        s.tags,
        COALESCE(jsonb_array_length(s.steps), 0)::INT AS step_count,
        s.updated_at,
        ts_rank(s.search_vector, plainto_tsquery('english', q)) AS rank
    FROM public.sops s
    WHERE s.published = true
      AND (
        s.search_vector @@ plainto_tsquery('english', q)
        OR s.title ILIKE '%' || q || '%'
      )
    ORDER BY rank DESC, s.updated_at DESC
    LIMIT 50;
$$;

GRANT EXECUTE ON FUNCTION public.search_sops(TEXT) TO anon, authenticated;

-- ============================================================================
-- Convenience view for the card grid
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.sops_index AS
SELECT
    id,
    slug,
    title,
    type,
    department,
    outlet,
    tags,
    version,
    COALESCE(jsonb_array_length(steps), 0)::INT AS step_count,
    COALESCE(jsonb_array_length(important_rules), 0)::INT AS rules_count,
    updated_at
FROM public.sops
WHERE published = true;

GRANT SELECT ON public.sops_index TO anon, authenticated;

-- ============================================================================
-- DONE. Next step: import sops-seed.json via the Supabase Table Editor,
-- or run the Node/browser import script included in README-deployment.md
-- ============================================================================
