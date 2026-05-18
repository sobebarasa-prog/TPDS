-- ════════════════════════════════════════════════════════════════════
--  TPDS PORTAL — COMPLETE SETUP SQL  (V13 Final)
--  English Teacher Professional Documents System
--  Atiaket / Kopiya Junior Secondary School
--
--  ▸ Paste entire file into Supabase → SQL Editor → Run
--  ▸ Safe to re-run on an existing project (uses IF NOT EXISTS / OR REPLACE)
--  ▸ After running: verification query at the bottom shows 27 ✅ rows
--
--  WHAT THIS CREATES:
--    4 tables   · 4 RPC functions · 12 views · 4 admin functions
--    Full RLS   · Comprehensive grants · Sync audit log
--
--  KEYS (Supabase → Project Settings → API):
--    anon/public key    → app Setup → Cloud Sync (share with teachers)
--    service_role key   → app Setup → Service Role Key (admin only, never share)
-- ════════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════════
-- STEP 0 — CLEAN SLATE (drop old views/functions; tables kept intact)
-- ════════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS public.v_tpds_sync_lagging          CASCADE;
DROP VIEW IF EXISTS public.v_tpds_school_summary         CASCADE;
DROP VIEW IF EXISTS public.v_tpds_all_ieps               CASCADE;
DROP VIEW IF EXISTS public.v_tpds_all_lessons            CASCADE;
DROP VIEW IF EXISTS public.v_tpds_pending_submissions    CASCADE;
DROP VIEW IF EXISTS public.v_tpds_all_submissions        CASCADE;
DROP VIEW IF EXISTS public.v_tpds_teacher_directory      CASCADE;
DROP VIEW IF EXISTS public.v_tpds_no_sync                CASCADE;
DROP VIEW IF EXISTS public.v_tpds_inactive_logins        CASCADE;
DROP VIEW IF EXISTS public.v_tpds_active_teachers        CASCADE;
DROP VIEW IF EXISTS public.v_tpds_dept_summary           CASCADE;
DROP VIEW IF EXISTS public.v_tpds_all_cal                CASCADE;
DROP VIEW IF EXISTS public.v_tpds_lesson_summary         CASCADE;
DROP VIEW IF EXISTS public.v_tpds_teacher_profiles       CASCADE;
DROP VIEW IF EXISTS public.v_tpds_recent_sync_activity   CASCADE;

DROP FUNCTION IF EXISTS public.tpds_upsert(TEXT,TEXT,TEXT,JSONB,TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS public.tpds_fetch(TEXT)                               CASCADE;
DROP FUNCTION IF EXISTS public.tpds_upsert_teacher(JSONB)                    CASCADE;
DROP FUNCTION IF EXISTS public.tpds_fetch_cloud_user(TEXT)                   CASCADE;
DROP FUNCTION IF EXISTS public.tpds_current_user_header()                    CASCADE;
DROP FUNCTION IF EXISTS public.fn_log_sync_upsert()                          CASCADE;
DROP FUNCTION IF EXISTS public.fn_export_teacher_backup(TEXT)                CASCADE;
DROP FUNCTION IF EXISTS public.fn_export_all_teachers_backup()               CASCADE;
DROP FUNCTION IF EXISTS public.fn_school_summary()                           CASCADE;
DROP FUNCTION IF EXISTS public.fn_remove_teacher_data(TEXT)                  CASCADE;
DROP FUNCTION IF EXISTS public.tpds_teachers_set_updated_at()                CASCADE;
DROP FUNCTION IF EXISTS public.tpds_users_cloud_updated_at()                 CASCADE;


-- ════════════════════════════════════════════════════════════════════
-- STEP 1 — EXTENSIONS
-- ════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";


-- ════════════════════════════════════════════════════════════════════
-- STEP 2 — TABLES
-- ════════════════════════════════════════════════════════════════════

-- ── 2a. Main sync table ─────────────────────────────────────────────
-- One row per teacher per data category (12 categories max per teacher).
-- All sync goes through the tpds_upsert RPC — never direct table POST.

CREATE TABLE IF NOT EXISTS public.tpds_sync (
  id          TEXT        NOT NULL,
  user_id     TEXT        NOT NULL,
  data_key    TEXT        NOT NULL,
  payload     JSONB       NOT NULL DEFAULT '[]',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT tpds_sync_pkey PRIMARY KEY (id),

  -- All 12 data keys used by the app.
  -- V12 had only 8 — missing 4 caused "partial sync" on every save.
  CONSTRAINT tpds_sync_key_check CHECK (
    data_key IN (
      'setup',          -- teacher profile & school setup
      'lessons',        -- lesson plans (Grades 7–9)
      'ieps',           -- Individual Education Plans
      'cal',            -- Competency Assessment Log
      'deleted',        -- recycle bin
      'submitted_docs', -- documents submitted for approval
      'iep_logs',       -- IEP progress log entries
      'admin_config',   -- school-wide admin settings
      'letterhead',     -- school letterhead config
      'sow_taught',     -- Scheme of Work taught tracker
      'users',          -- teacher account list (admin only)
      'uploads_meta'    -- uploaded file metadata (no base64)
    )
  )
);

CREATE INDEX IF NOT EXISTS idx_tpds_sync_user_id    ON public.tpds_sync (user_id);
CREATE INDEX IF NOT EXISTS idx_tpds_sync_data_key   ON public.tpds_sync (data_key);
CREATE INDEX IF NOT EXISTS idx_tpds_sync_updated_at ON public.tpds_sync (updated_at DESC);

COMMENT ON TABLE  public.tpds_sync IS 'Main JSONB sync store. 12 categories per teacher max.';
COMMENT ON COLUMN public.tpds_sync.id IS 'Composite key: username__data_key e.g. "sobe__lessons"';


-- ── 2b. Teacher directory ───────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.tpds_teachers (
  username        TEXT        PRIMARY KEY,
  display_name    TEXT,
  tsc_number      TEXT,
  department      TEXT,
  role            TEXT        DEFAULT 'Teacher',
  phone           TEXT,
  email           TEXT,
  school_name     TEXT,
  grades_taught   TEXT,
  registered_at   TIMESTAMPTZ,
  last_login_at   TIMESTAMPTZ,
  is_active       BOOLEAN     DEFAULT TRUE,
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tpds_teachers_role       ON public.tpds_teachers (role);
CREATE INDEX IF NOT EXISTS idx_tpds_teachers_dept       ON public.tpds_teachers (department);
CREATE INDEX IF NOT EXISTS idx_tpds_teachers_last_login ON public.tpds_teachers (last_login_at DESC);

CREATE OR REPLACE FUNCTION public.tpds_teachers_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS tpds_teachers_updated_at ON public.tpds_teachers;
CREATE TRIGGER tpds_teachers_updated_at
  BEFORE INSERT OR UPDATE ON public.tpds_teachers
  FOR EACH ROW EXECUTE FUNCTION public.tpds_teachers_set_updated_at();


-- ── 2c. Cloud user accounts ─────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.tpds_users_cloud (
  id              TEXT        PRIMARY KEY,
  username        TEXT        NOT NULL UNIQUE,
  password_hash   TEXT        NOT NULL,
  role            TEXT        DEFAULT 'Teacher',
  name            TEXT,
  dept            TEXT,
  email           TEXT,
  phone           TEXT,
  assignments     JSONB,
  is_active       BOOLEAN     DEFAULT TRUE,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tpds_users_cloud_username  ON public.tpds_users_cloud (username);
CREATE INDEX IF NOT EXISTS idx_tpds_users_cloud_is_active ON public.tpds_users_cloud (is_active);

CREATE OR REPLACE FUNCTION public.tpds_users_cloud_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS tpds_users_cloud_ts ON public.tpds_users_cloud;
CREATE TRIGGER tpds_users_cloud_ts
  BEFORE INSERT OR UPDATE ON public.tpds_users_cloud
  FOR EACH ROW EXECUTE FUNCTION public.tpds_users_cloud_updated_at();


-- ── 2d. Sync audit log ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.tpds_sync_log (
  id          BIGSERIAL   PRIMARY KEY,
  user_id     TEXT        NOT NULL,
  data_key    TEXT,
  action      TEXT        NOT NULL,
  row_count   INT,
  synced_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_synclog_user_id   ON public.tpds_sync_log (user_id);
CREATE INDEX IF NOT EXISTS idx_synclog_synced_at ON public.tpds_sync_log (synced_at DESC);

CREATE OR REPLACE FUNCTION public.fn_log_sync_upsert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.tpds_sync_log (user_id, data_key, action, row_count)
  VALUES (NEW.user_id, NEW.data_key, 'upsert', 1);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tpds_sync_log ON public.tpds_sync;
CREATE TRIGGER trg_tpds_sync_log
  AFTER INSERT OR UPDATE ON public.tpds_sync
  FOR EACH ROW EXECUTE FUNCTION public.fn_log_sync_upsert();


-- ════════════════════════════════════════════════════════════════════
-- STEP 3 — ROW LEVEL SECURITY
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.tpds_sync         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tpds_teachers     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tpds_users_cloud  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tpds_sync_log     ENABLE ROW LEVEL SECURITY;

-- Helper: extract x-tpds-user header (handles both PostgREST v9-11 and v12+)
CREATE OR REPLACE FUNCTION public.tpds_current_user_header()
RETURNS TEXT LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE v_result TEXT := ''; v_headers TEXT;
BEGIN
  -- Try PostgREST v12+ (request.header.{name})
  BEGIN
    v_result := current_setting('request.header.x-tpds-user', true);
    IF v_result IS NOT NULL AND TRIM(v_result) <> '' THEN
      RETURN LOWER(TRIM(v_result));
    END IF;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  -- Fallback: PostgREST v9-11 (request.headers as JSON blob)
  BEGIN
    v_headers := current_setting('request.headers', true);
    IF v_headers IS NOT NULL AND v_headers <> '' THEN
      v_result := (v_headers::JSONB)->>'x-tpds-user';
      IF v_result IS NOT NULL AND TRIM(v_result) <> '' THEN
        RETURN LOWER(TRIM(v_result));
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  RETURN '';
END;
$$;

-- tpds_sync policies
DROP POLICY IF EXISTS "tpds_teacher_select"  ON public.tpds_sync;
DROP POLICY IF EXISTS "tpds_teacher_insert"  ON public.tpds_sync;
DROP POLICY IF EXISTS "tpds_teacher_update"  ON public.tpds_sync;
DROP POLICY IF EXISTS "tpds_teacher_delete"  ON public.tpds_sync;
DROP POLICY IF EXISTS "authenticated_full"   ON public.tpds_sync;
DROP POLICY IF EXISTS "anon_insert_own"      ON public.tpds_sync;
DROP POLICY IF EXISTS "anon_select_own"      ON public.tpds_sync;
DROP POLICY IF EXISTS "anon_update_own"      ON public.tpds_sync;
DROP POLICY IF EXISTS "anon_delete_own"      ON public.tpds_sync;

-- SELECT locked per teacher (privacy)
CREATE POLICY "tpds_teacher_select" ON public.tpds_sync
  FOR SELECT TO anon
  USING (LOWER(user_id) = LOWER(public.tpds_current_user_header()));

-- INSERT/UPDATE/DELETE: open — app always sends a valid user_id.
-- NOTE: Direct table access is no longer used by the app (all writes go
-- through SECURITY DEFINER RPC functions). These policies exist as a
-- safety net and do not affect RPC-based sync.
CREATE POLICY "tpds_teacher_insert" ON public.tpds_sync
  FOR INSERT TO anon
  WITH CHECK (user_id IS NOT NULL AND user_id <> '');

CREATE POLICY "tpds_teacher_update" ON public.tpds_sync
  FOR UPDATE TO anon
  USING (true)
  WITH CHECK (user_id IS NOT NULL AND user_id <> '');

CREATE POLICY "tpds_teacher_delete" ON public.tpds_sync
  FOR DELETE TO anon
  USING (LOWER(user_id) = LOWER(public.tpds_current_user_header()));

CREATE POLICY "authenticated_full" ON public.tpds_sync
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- tpds_teachers policies
DROP POLICY IF EXISTS "tpds_teachers_self_select" ON public.tpds_teachers;
DROP POLICY IF EXISTS "tpds_teachers_self_insert" ON public.tpds_teachers;
DROP POLICY IF EXISTS "tpds_teachers_self_update" ON public.tpds_teachers;

CREATE POLICY "tpds_teachers_self_select" ON public.tpds_teachers
  FOR SELECT TO anon
  USING (LOWER(username) = LOWER(public.tpds_current_user_header()));

CREATE POLICY "tpds_teachers_self_insert" ON public.tpds_teachers
  FOR INSERT TO anon
  WITH CHECK (username IS NOT NULL AND username <> '');

CREATE POLICY "tpds_teachers_self_update" ON public.tpds_teachers
  FOR UPDATE TO anon
  USING (true)
  WITH CHECK (username IS NOT NULL AND username <> '');

-- tpds_users_cloud policies (all teachers can read for login check)
DROP POLICY IF EXISTS "users_cloud_select" ON public.tpds_users_cloud;
DROP POLICY IF EXISTS "users_cloud_insert" ON public.tpds_users_cloud;
DROP POLICY IF EXISTS "users_cloud_update" ON public.tpds_users_cloud;

CREATE POLICY "users_cloud_select" ON public.tpds_users_cloud
  FOR SELECT TO anon USING (true);

CREATE POLICY "users_cloud_insert" ON public.tpds_users_cloud
  FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "users_cloud_update" ON public.tpds_users_cloud
  FOR UPDATE TO anon USING (true) WITH CHECK (true);

-- tpds_sync_log policy
DROP POLICY IF EXISTS "anon_read_own_log" ON public.tpds_sync_log;
CREATE POLICY "anon_read_own_log" ON public.tpds_sync_log
  FOR SELECT TO anon USING (true);


-- ════════════════════════════════════════════════════════════════════
-- STEP 4 — TABLE-LEVEL GRANTS
-- (RLS alone is not enough — anon also needs explicit table grants)
-- ════════════════════════════════════════════════════════════════════

GRANT SELECT, INSERT, UPDATE, DELETE ON public.tpds_sync        TO anon;
GRANT SELECT, INSERT, UPDATE         ON public.tpds_teachers    TO anon;
GRANT SELECT, INSERT, UPDATE         ON public.tpds_users_cloud TO anon;
GRANT SELECT                         ON public.tpds_sync_log    TO anon;
GRANT USAGE ON SEQUENCE public.tpds_sync_log_id_seq             TO anon;

GRANT EXECUTE ON FUNCTION public.tpds_current_user_header()     TO anon;

GRANT ALL ON public.tpds_sync        TO authenticated;
GRANT ALL ON public.tpds_teachers    TO authenticated;
GRANT ALL ON public.tpds_users_cloud TO authenticated;
GRANT ALL ON public.tpds_sync_log    TO authenticated;
GRANT USAGE ON SEQUENCE public.tpds_sync_log_id_seq             TO authenticated;


-- ════════════════════════════════════════════════════════════════════
-- STEP 5 — RPC FUNCTIONS (SECURITY DEFINER)
--
--  WHY RPC INSTEAD OF DIRECT TABLE CALLS:
--    Supabase's new sb_publishable_ / sb_secret_ key format does not
--    reliably forward custom headers (x-tpds-user) to PostgREST.
--    RLS policies that read those headers therefore return '' and
--    silently block every write — causing all 12 keys to fail.
--
--    SECURITY DEFINER functions run as the table owner (postgres),
--    bypassing RLS entirely. No header tricks needed. Works with any
--    Supabase key format and any PostgREST version.
--
--  APP ↔ FUNCTION MAPPING:
--    _sbUpsert()            → POST /rest/v1/rpc/tpds_upsert
--    _sbFetch()             → POST /rest/v1/rpc/tpds_fetch
--    _sbUpsertTeacher()     → POST /rest/v1/rpc/tpds_upsert_teacher
--    _sbFetchCloudUser()    → POST /rest/v1/rpc/tpds_fetch_cloud_user
-- ════════════════════════════════════════════════════════════════════

-- ── 5a. tpds_upsert ─────────────────────────────────────────────────
-- Saves one data category for one teacher. Called 12× per full sync.

CREATE OR REPLACE FUNCTION public.tpds_upsert(
  p_id         TEXT,
  p_user_id    TEXT,
  p_data_key   TEXT,
  p_payload    JSONB,
  p_updated_at TIMESTAMPTZ DEFAULT NOW()
)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_id IS NULL OR TRIM(p_id) = '' THEN
    RAISE EXCEPTION 'tpds_upsert: p_id required';
  END IF;
  IF p_user_id IS NULL OR TRIM(p_user_id) = '' THEN
    RAISE EXCEPTION 'tpds_upsert: p_user_id required';
  END IF;
  IF p_data_key IS NULL OR TRIM(p_data_key) = '' THEN
    RAISE EXCEPTION 'tpds_upsert: p_data_key required';
  END IF;

  INSERT INTO public.tpds_sync (id, user_id, data_key, payload, updated_at)
  VALUES (
    p_id,
    LOWER(TRIM(p_user_id)),
    LOWER(TRIM(p_data_key)),
    COALESCE(p_payload, '[]'::JSONB),
    COALESCE(p_updated_at, NOW())
  )
  ON CONFLICT (id) DO UPDATE SET
    payload    = EXCLUDED.payload,
    updated_at = EXCLUDED.updated_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.tpds_upsert(TEXT,TEXT,TEXT,JSONB,TIMESTAMPTZ) TO anon;
GRANT EXECUTE ON FUNCTION public.tpds_upsert(TEXT,TEXT,TEXT,JSONB,TIMESTAMPTZ) TO authenticated;
COMMENT ON FUNCTION public.tpds_upsert IS 'SECURITY DEFINER upsert for tpds_sync. Bypasses RLS. Called by app _sbUpsert().';


-- ── 5b. tpds_fetch ──────────────────────────────────────────────────
-- Returns the payload for one data category, or NULL if not found.
-- Also used by sbVerifyCredentials() to confirm SQL setup is complete.

CREATE OR REPLACE FUNCTION public.tpds_fetch(p_id TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_payload JSONB;
BEGIN
  SELECT payload INTO v_payload
  FROM   public.tpds_sync
  WHERE  id = p_id;
  RETURN v_payload; -- NULL if row not found (handled gracefully by app)
END;
$$;

GRANT EXECUTE ON FUNCTION public.tpds_fetch(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.tpds_fetch(TEXT) TO authenticated;
COMMENT ON FUNCTION public.tpds_fetch IS 'SECURITY DEFINER fetch from tpds_sync. Returns JSONB payload or NULL. Also used for connection verification.';


-- ── 5c. tpds_upsert_teacher ─────────────────────────────────────────
-- Creates/updates one teacher's directory row. Called on every login
-- and every profile save.

CREATE OR REPLACE FUNCTION public.tpds_upsert_teacher(p_row JSONB)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_username TEXT := LOWER(TRIM(p_row->>'username'));
BEGIN
  IF v_username IS NULL OR v_username = '' THEN
    RAISE EXCEPTION 'tpds_upsert_teacher: username required';
  END IF;

  INSERT INTO public.tpds_teachers (
    username, display_name, tsc_number, department, role,
    phone, email, school_name, grades_taught,
    registered_at, last_login_at, is_active
  )
  VALUES (
    v_username,
    p_row->>'display_name',
    p_row->>'tsc_number',
    p_row->>'department',
    COALESCE(NULLIF(p_row->>'role',''), 'Teacher'),
    p_row->>'phone',
    p_row->>'email',
    p_row->>'school_name',
    p_row->>'grades_taught',
    COALESCE(NULLIF(p_row->>'registered_at','')::TIMESTAMPTZ, NOW()),
    COALESCE(NULLIF(p_row->>'last_login_at','')::TIMESTAMPTZ, NOW()),
    COALESCE((p_row->>'is_active')::BOOLEAN, TRUE)
  )
  ON CONFLICT (username) DO UPDATE SET
    display_name  = EXCLUDED.display_name,
    tsc_number    = EXCLUDED.tsc_number,
    department    = EXCLUDED.department,
    role          = EXCLUDED.role,
    phone         = EXCLUDED.phone,
    email         = EXCLUDED.email,
    school_name   = EXCLUDED.school_name,
    grades_taught = EXCLUDED.grades_taught,
    last_login_at = EXCLUDED.last_login_at,
    is_active     = EXCLUDED.is_active;
END;
$$;

GRANT EXECUTE ON FUNCTION public.tpds_upsert_teacher(JSONB) TO anon;
GRANT EXECUTE ON FUNCTION public.tpds_upsert_teacher(JSONB) TO authenticated;
COMMENT ON FUNCTION public.tpds_upsert_teacher IS 'SECURITY DEFINER upsert for tpds_teachers. Called on login and profile save.';


-- ── 5d. tpds_fetch_cloud_user ───────────────────────────────────────
-- Cross-device login: returns the cloud user row for a given username.
-- Returns NULL if user not found or is inactive.

CREATE OR REPLACE FUNCTION public.tpds_fetch_cloud_user(p_username TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_row JSONB;
BEGIN
  SELECT to_jsonb(u) INTO v_row
  FROM   public.tpds_users_cloud u
  WHERE  LOWER(u.username) = LOWER(TRIM(p_username))
    AND  u.is_active = TRUE
  LIMIT 1;
  RETURN v_row; -- NULL if not found
END;
$$;

GRANT EXECUTE ON FUNCTION public.tpds_fetch_cloud_user(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.tpds_fetch_cloud_user(TEXT) TO authenticated;
COMMENT ON FUNCTION public.tpds_fetch_cloud_user IS 'SECURITY DEFINER user lookup for cross-device login. Returns full user row as JSONB.';


-- ════════════════════════════════════════════════════════════════════
-- STEP 6 — ADMIN VIEWS
-- ════════════════════════════════════════════════════════════════════

-- 6a. Teacher directory with sync stats
CREATE OR REPLACE VIEW public.v_tpds_teacher_directory AS
SELECT
  t.username, t.display_name, t.tsc_number, t.department,
  t.role, t.phone, t.email, t.school_name, t.grades_taught,
  t.registered_at, t.last_login_at, t.is_active,
  s.categories_synced,
  s.last_sync,
  NOW() - s.last_sync                                       AS time_since_sync,
  lc.n  AS lesson_count,
  ic.n  AS iep_count,
  cc.n  AS cal_count,
  dc.n  AS doc_count
FROM public.tpds_teachers t
LEFT JOIN (
  SELECT user_id, COUNT(*) AS categories_synced, MAX(updated_at) AS last_sync
  FROM public.tpds_sync GROUP BY user_id
) s  ON LOWER(s.user_id)  = LOWER(t.username)
LEFT JOIN (SELECT user_id, jsonb_array_length(payload) AS n FROM public.tpds_sync WHERE data_key='lessons')       lc ON LOWER(lc.user_id) = LOWER(t.username)
LEFT JOIN (SELECT user_id, jsonb_array_length(payload) AS n FROM public.tpds_sync WHERE data_key='ieps')          ic ON LOWER(ic.user_id) = LOWER(t.username)
LEFT JOIN (SELECT user_id, jsonb_array_length(payload) AS n FROM public.tpds_sync WHERE data_key='cal')           cc ON LOWER(cc.user_id) = LOWER(t.username)
LEFT JOIN (SELECT user_id, jsonb_array_length(payload) AS n FROM public.tpds_sync WHERE data_key='submitted_docs') dc ON LOWER(dc.user_id) = LOWER(t.username)
ORDER BY t.last_login_at DESC NULLS LAST;

-- 6b. Active teachers only
CREATE OR REPLACE VIEW public.v_tpds_active_teachers AS
SELECT * FROM public.v_tpds_teacher_directory WHERE is_active = TRUE;

-- 6c. Not logged in 14+ days
CREATE OR REPLACE VIEW public.v_tpds_inactive_logins AS
SELECT username, display_name, department, role, last_login_at,
       NOW() - last_login_at AS time_since_login
FROM public.tpds_teachers
WHERE last_login_at < NOW() - INTERVAL '14 days' OR last_login_at IS NULL
ORDER BY last_login_at ASC NULLS FIRST;

-- 6d. Registered but never synced
CREATE OR REPLACE VIEW public.v_tpds_no_sync AS
SELECT t.username, t.display_name, t.department, t.role, t.last_login_at
FROM public.tpds_teachers t
LEFT JOIN (SELECT DISTINCT LOWER(user_id) AS uid FROM public.tpds_sync) s ON s.uid = LOWER(t.username)
WHERE s.uid IS NULL ORDER BY t.display_name;

-- 6e. Active teachers not synced in 7+ days
CREATE OR REPLACE VIEW public.v_tpds_sync_lagging AS
SELECT t.username, t.display_name, t.department, t.role,
       s.last_sync, NOW() - s.last_sync AS time_behind
FROM public.tpds_teachers t
LEFT JOIN (SELECT LOWER(user_id) AS uid, MAX(updated_at) AS last_sync FROM public.tpds_sync GROUP BY LOWER(user_id)) s ON s.uid = LOWER(t.username)
WHERE t.is_active = TRUE
  AND (s.last_sync < NOW() - INTERVAL '7 days' OR s.last_sync IS NULL)
ORDER BY s.last_sync ASC NULLS FIRST;

-- 6f. By department
CREATE OR REPLACE VIEW public.v_tpds_dept_summary AS
SELECT COALESCE(department,'Unassigned') AS department,
       COUNT(*)                          AS teacher_count,
       COUNT(*) FILTER (WHERE is_active) AS active_count,
       MAX(last_login_at)                AS last_activity
FROM public.tpds_teachers GROUP BY department ORDER BY teacher_count DESC;

-- 6g. All submitted documents
CREATE OR REPLACE VIEW public.v_tpds_all_submissions AS
SELECT
  s.user_id                                                   AS teacher,
  t.display_name                                              AS teacher_name,
  doc->>'id'                                                  AS doc_id,
  doc->>'docType'                                             AS doc_type,
  doc->>'summary'                                             AS summary,
  doc->>'status'                                              AS status,
  doc->>'submitterName'                                       AS submitter_name,
  doc->>'submitterRole'                                       AS submitter_role,
  doc->>'targetRole'                                          AS target_role,
  doc->>'approvedBy'                                          AS approved_by,
  TO_TIMESTAMP(((doc->>'submittedAt')::BIGINT)/1000)          AS submitted_at,
  TO_TIMESTAMP(((doc->>'approvedAt')::BIGINT)/1000)           AS approved_at,
  s.updated_at                                                AS synced_at
FROM public.tpds_sync s
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]'::jsonb END
) AS doc
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(s.user_id)
WHERE s.data_key = 'submitted_docs'
ORDER BY submitted_at DESC NULLS LAST;

-- 6h. Pending only
CREATE OR REPLACE VIEW public.v_tpds_pending_submissions AS
SELECT * FROM public.v_tpds_all_submissions
WHERE status IN ('submitted','pending') OR status IS NULL
ORDER BY submitted_at DESC NULLS LAST;

-- 6i. All lesson plans
CREATE OR REPLACE VIEW public.v_tpds_all_lessons AS
SELECT
  s.user_id                                                   AS teacher,
  t.display_name                                              AS teacher_name,
  lesson->>'id'                                               AS lesson_id,
  lesson->>'grade'                                            AS grade,
  lesson->>'term'                                             AS term,
  lesson->>'week'                                             AS week,
  lesson->>'lno'                                              AS lesson_no,
  lesson->>'date'                                             AS lesson_date,
  lesson->>'day'                                              AS day_of_week,
  lesson->>'subject'                                          AS subject,
  lesson->>'theme'                                            AS theme,
  lesson->>'strand'                                           AS strand,
  lesson->>'substrand'                                        AS sub_strand,
  lesson->>'slo'                                              AS specific_learning_outcome,
  lesson->>'kiq'                                              AS key_inquiry_question,
  lesson->>'resources'                                        AS resources,
  lesson->>'reflect'                                          AS reflection,
  lesson->>'workdone'                                         AS work_done,
  s.updated_at                                                AS synced_at
FROM public.tpds_sync s
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]'::jsonb END
) AS lesson
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(s.user_id)
WHERE s.data_key = 'lessons'
ORDER BY s.user_id, lesson->>'grade', lesson->>'term', lesson->>'week';

-- 6j. All IEPs
CREATE OR REPLACE VIEW public.v_tpds_all_ieps AS
SELECT
  s.user_id                                                   AS teacher,
  t.display_name                                              AS teacher_name,
  iep->>'id'                                                  AS iep_id,
  iep->>'name'                                                AS learner_name,
  iep->>'adm'                                                 AS admission_no,
  iep->>'grade'                                               AS grade,
  iep->>'term'                                                AS term,
  iep->>'challenges'                                          AS challenges,
  iep->>'strengths'                                           AS strengths,
  iep->>'goals'                                               AS goals,
  iep->>'strategies'                                          AS strategies,
  iep->>'progress'                                            AS progress_notes,
  iep->>'review'                                              AS next_review_date,
  s.updated_at                                                AS synced_at
FROM public.tpds_sync s
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]'::jsonb END
) AS iep
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(s.user_id)
WHERE s.data_key = 'ieps'
ORDER BY s.user_id, iep->>'grade';

-- 6k. All CAL entries
CREATE OR REPLACE VIEW public.v_tpds_all_cal AS
SELECT
  s.user_id                                                   AS teacher,
  t.display_name                                              AS teacher_name,
  entry->>'grade'                                             AS grade,
  entry->>'term'                                              AS term,
  entry->>'learner'                                           AS learner_name,
  entry->>'level'                                             AS competency_level,
  entry->>'skill'                                             AS skill_outcome,
  entry->>'date'                                              AS observation_date,
  entry->>'notes'                                             AS notes,
  s.updated_at                                                AS synced_at
FROM public.tpds_sync s
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]'::jsonb END
) AS entry
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(s.user_id)
WHERE s.data_key = 'cal'
ORDER BY s.user_id, entry->>'date' DESC;

-- 6l. Lesson count summary
CREATE OR REPLACE VIEW public.v_tpds_lesson_summary AS
SELECT
  s.user_id AS teacher, t.display_name AS teacher_name,
  jsonb_array_length(CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]' END) AS total_lessons,
  (SELECT COUNT(*) FROM jsonb_array_elements(CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]' END) l WHERE l->>'grade'='7') AS grade_7,
  (SELECT COUNT(*) FROM jsonb_array_elements(CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]' END) l WHERE l->>'grade'='8') AS grade_8,
  (SELECT COUNT(*) FROM jsonb_array_elements(CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]' END) l WHERE l->>'grade'='9') AS grade_9,
  s.updated_at AS last_synced_at
FROM public.tpds_sync s
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(s.user_id)
WHERE s.data_key = 'lessons' ORDER BY total_lessons DESC;

-- 6m. Teacher profiles (setup data)
CREATE OR REPLACE VIEW public.v_tpds_teacher_profiles AS
SELECT
  s.user_id AS username, t.display_name AS teacher_name,
  s.payload->>'teacher'     AS profile_name,
  s.payload->>'tsc'         AS tsc_number,
  s.payload->>'school'      AS school_name,
  s.payload->>'subject'     AS primary_subject,
  s.payload->>'academicYear' AS academic_year,
  s.payload->'grades'       AS grades_json,
  s.updated_at              AS last_synced_at
FROM public.tpds_sync s
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(s.user_id)
WHERE s.data_key = 'setup' ORDER BY s.user_id;

-- 6n. Recent sync activity (7 days)
CREATE OR REPLACE VIEW public.v_tpds_recent_sync_activity AS
SELECT l.user_id, t.display_name AS teacher_name, l.data_key, l.action, l.synced_at
FROM public.tpds_sync_log l
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(l.user_id)
WHERE l.synced_at >= NOW() - INTERVAL '7 days'
ORDER BY l.synced_at DESC LIMIT 200;

-- 6o. School dashboard (one row)
CREATE OR REPLACE VIEW public.v_tpds_school_summary AS
SELECT
  (SELECT COUNT(*) FROM public.tpds_teachers WHERE is_active = TRUE)                         AS active_teachers,
  (SELECT COUNT(DISTINCT LOWER(user_id)) FROM public.tpds_sync)                              AS teachers_synced,
  (SELECT SUM(jsonb_array_length(payload)) FROM public.tpds_sync WHERE data_key='lessons')   AS total_lessons,
  (SELECT SUM(jsonb_array_length(payload)) FROM public.tpds_sync WHERE data_key='ieps')      AS total_ieps,
  (SELECT SUM(jsonb_array_length(payload)) FROM public.tpds_sync WHERE data_key='cal')       AS total_cal_entries,
  (SELECT COUNT(*) FROM public.v_tpds_pending_submissions)                                    AS pending_submissions,
  (SELECT MAX(updated_at) FROM public.tpds_sync)                                              AS most_recent_sync;


-- ════════════════════════════════════════════════════════════════════
-- STEP 7 — ADMIN FUNCTIONS
-- ════════════════════════════════════════════════════════════════════

-- Full backup for one teacher
CREATE OR REPLACE FUNCTION public.fn_export_teacher_backup(p_username TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE result JSONB := '{}'::JSONB; rec RECORD;
BEGIN
  FOR rec IN SELECT data_key, payload, updated_at FROM public.tpds_sync WHERE user_id = p_username
  LOOP
    result := result || jsonb_build_object(rec.data_key,
      jsonb_build_object('data', rec.payload, 'synced_at', rec.updated_at));
  END LOOP;
  RETURN jsonb_build_object('exported_at', NOW(), 'username', p_username, 'backup', result);
END;
$$;

-- Full backup for ALL teachers
CREATE OR REPLACE FUNCTION public.fn_export_all_teachers_backup()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE all_backups JSONB := '{}'::JSONB; teacher TEXT;
BEGIN
  FOR teacher IN SELECT DISTINCT user_id FROM public.tpds_sync ORDER BY user_id
  LOOP
    all_backups := all_backups || jsonb_build_object(teacher, public.fn_export_teacher_backup(teacher));
  END LOOP;
  RETURN jsonb_build_object('exported_at', NOW(),
    'teacher_count', (SELECT COUNT(DISTINCT user_id) FROM public.tpds_sync),
    'teachers', all_backups);
END;
$$;

-- Per-teacher counts
CREATE OR REPLACE FUNCTION public.fn_school_summary()
RETURNS TABLE(username TEXT, display_name TEXT, lesson_count INT, iep_count INT,
              cal_count INT, doc_count INT, last_synced_at TIMESTAMPTZ)
LANGUAGE SQL SECURITY DEFINER AS $$
  SELECT s.user_id, t.display_name,
    (SELECT COALESCE(jsonb_array_length(CASE jsonb_typeof(p.payload) WHEN 'array' THEN p.payload ELSE '[]' END),0)
     FROM public.tpds_sync p WHERE p.user_id=s.user_id AND p.data_key='lessons'),
    (SELECT COALESCE(jsonb_array_length(CASE jsonb_typeof(p.payload) WHEN 'array' THEN p.payload ELSE '[]' END),0)
     FROM public.tpds_sync p WHERE p.user_id=s.user_id AND p.data_key='ieps'),
    (SELECT COALESCE(jsonb_array_length(CASE jsonb_typeof(p.payload) WHEN 'array' THEN p.payload ELSE '[]' END),0)
     FROM public.tpds_sync p WHERE p.user_id=s.user_id AND p.data_key='cal'),
    (SELECT COALESCE(jsonb_array_length(CASE jsonb_typeof(p.payload) WHEN 'array' THEN p.payload ELSE '[]' END),0)
     FROM public.tpds_sync p WHERE p.user_id=s.user_id AND p.data_key='submitted_docs'),
    MAX(s.updated_at)
  FROM public.tpds_sync s
  LEFT JOIN public.tpds_teachers t ON LOWER(t.username)=LOWER(s.user_id)
  GROUP BY s.user_id, t.display_name ORDER BY s.user_id;
$$;

-- Delete all data for one teacher (IRREVERSIBLE)
CREATE OR REPLACE FUNCTION public.fn_remove_teacher_data(p_username TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE deleted_rows INT;
BEGIN
  DELETE FROM public.tpds_sync        WHERE user_id  = p_username; GET DIAGNOSTICS deleted_rows = ROW_COUNT;
  DELETE FROM public.tpds_sync_log    WHERE user_id  = p_username;
  DELETE FROM public.tpds_teachers    WHERE username  = p_username;
  DELETE FROM public.tpds_users_cloud WHERE username  = p_username;
  RETURN 'Removed '||deleted_rows||' sync rows for: '||p_username;
END;
$$;


-- ════════════════════════════════════════════════════════════════════
-- STEP 8 — VERIFICATION
-- Expected: 27 rows, every one showing ✅
-- If any row is missing, re-run only the relevant STEP above.
-- ════════════════════════════════════════════════════════════════════

SELECT object_name, type, '✅' AS status FROM (
  VALUES
    -- Tables (4)
    ('tpds_sync',                      'TABLE'),
    ('tpds_teachers',                  'TABLE'),
    ('tpds_users_cloud',               'TABLE'),
    ('tpds_sync_log',                  'TABLE'),
    -- RPC Functions (4)
    ('tpds_upsert',                    'RPC FUNCTION'),
    ('tpds_fetch',                     'RPC FUNCTION'),
    ('tpds_upsert_teacher',            'RPC FUNCTION'),
    ('tpds_fetch_cloud_user',          'RPC FUNCTION'),
    -- Admin Functions (4)
    ('fn_export_teacher_backup',       'ADMIN FUNCTION'),
    ('fn_export_all_teachers_backup',  'ADMIN FUNCTION'),
    ('fn_school_summary',              'ADMIN FUNCTION'),
    ('fn_remove_teacher_data',         'ADMIN FUNCTION'),
    -- Views (15)
    ('v_tpds_teacher_directory',       'VIEW'),
    ('v_tpds_active_teachers',         'VIEW'),
    ('v_tpds_inactive_logins',         'VIEW'),
    ('v_tpds_no_sync',                 'VIEW'),
    ('v_tpds_sync_lagging',            'VIEW'),
    ('v_tpds_dept_summary',            'VIEW'),
    ('v_tpds_all_submissions',         'VIEW'),
    ('v_tpds_pending_submissions',     'VIEW'),
    ('v_tpds_all_lessons',             'VIEW'),
    ('v_tpds_all_ieps',                'VIEW'),
    ('v_tpds_all_cal',                 'VIEW'),
    ('v_tpds_lesson_summary',          'VIEW'),
    ('v_tpds_teacher_profiles',        'VIEW'),
    ('v_tpds_recent_sync_activity',    'VIEW'),
    ('v_tpds_school_summary',          'VIEW')
) AS t(object_name, type)
WHERE EXISTS (
  SELECT 1 FROM information_schema.tables    WHERE table_name   = t.object_name
  UNION ALL
  SELECT 1 FROM information_schema.routines  WHERE routine_name = t.object_name
  UNION ALL
  SELECT 1 FROM information_schema.views     WHERE table_name   = t.object_name
)
ORDER BY type, object_name;

-- Quick check: constraint covers all 12 data_key values
SELECT pg_get_constraintdef(oid) AS constraint_definition
FROM   pg_constraint
WHERE  conrelid = 'public.tpds_sync'::regclass
  AND  conname  = 'tpds_sync_key_check';

-- ════════════════════════════════════════════════════════════════════
-- QUICK REFERENCE QUERIES (copy-paste individually as needed)
-- ════════════════════════════════════════════════════════════════════
/*
SELECT * FROM v_tpds_school_summary;
SELECT * FROM v_tpds_teacher_directory;
SELECT * FROM v_tpds_sync_lagging;
SELECT * FROM v_tpds_all_lessons WHERE teacher = 'sobe';
SELECT * FROM v_tpds_all_ieps;
SELECT * FROM v_tpds_pending_submissions;
SELECT * FROM fn_school_summary();
SELECT fn_export_teacher_backup('sobe');
SELECT fn_export_all_teachers_backup();
SELECT user_id, data_key, updated_at FROM tpds_sync ORDER BY user_id, data_key;

-- Revoke cross-device access:
UPDATE tpds_users_cloud SET is_active = false WHERE username = 'username_here';

-- Mark teacher inactive:
UPDATE tpds_teachers SET is_active = false WHERE username = 'username_here';

-- Remove teacher completely (IRREVERSIBLE):
SELECT fn_remove_teacher_data('username_here');
*/
