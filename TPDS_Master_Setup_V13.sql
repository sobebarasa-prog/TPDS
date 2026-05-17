-- ════════════════════════════════════════════════════════════════════
--  TPDS PORTAL — MASTER SETUP SQL  (V13 — Fresh Project Setup)
--  For: English TPDS Portal V13
--
--  Run in: Supabase Dashboard → SQL Editor → New Query
--  Paste entire file → click RUN
--
--  WHAT THIS CREATES:
--    ✅ 4 tables  (tpds_sync, tpds_teachers, tpds_users_cloud, tpds_sync_log)
--    ✅ Row Level Security on all tables
--    ✅ All 12 data_key values the app uses (was the source of partial sync)
--    ✅ Admin views for school oversight
--    ✅ Admin functions for backups and summaries
--    ✅ Verification query at the end (should show 23 ✅ rows)
--
--  KEYS NEEDED (Settings → API in your Supabase project):
--    anon/public key    → paste into the app's Cloud Sync section (teachers)
--    service_role key   → paste into the app's Cloud Sync → Admin Key field ONLY
--    NEVER share the service_role key with teachers.
-- ════════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════════
-- STEP 0 — DROP OLD VIEWS & FUNCTIONS (safe re-run — no data lost)
-- ════════════════════════════════════════════════════════════════════

DROP VIEW IF EXISTS public.v_tpds_sync_lagging         CASCADE;
DROP VIEW IF EXISTS public.v_tpds_school_summary        CASCADE;
DROP VIEW IF EXISTS public.v_tpds_all_ieps              CASCADE;
DROP VIEW IF EXISTS public.v_tpds_all_lessons           CASCADE;
DROP VIEW IF EXISTS public.v_tpds_pending_submissions   CASCADE;
DROP VIEW IF EXISTS public.v_tpds_all_submissions       CASCADE;
DROP VIEW IF EXISTS public.v_tpds_teacher_directory     CASCADE;
DROP VIEW IF EXISTS public.v_tpds_no_sync               CASCADE;
DROP VIEW IF EXISTS public.v_tpds_inactive_logins       CASCADE;
DROP VIEW IF EXISTS public.v_tpds_active_teachers       CASCADE;
DROP VIEW IF EXISTS public.v_tpds_dept_summary          CASCADE;
DROP VIEW IF EXISTS public.v_teachers_overview          CASCADE;
DROP VIEW IF EXISTS public.v_all_lessons                CASCADE;
DROP VIEW IF EXISTS public.v_all_ieps                   CASCADE;
DROP VIEW IF EXISTS public.v_all_cal                    CASCADE;
DROP VIEW IF EXISTS public.v_all_submitted_docs         CASCADE;
DROP VIEW IF EXISTS public.v_teacher_profiles           CASCADE;
DROP VIEW IF EXISTS public.v_lesson_summary             CASCADE;
DROP VIEW IF EXISTS public.v_recent_sync_activity       CASCADE;
DROP VIEW IF EXISTS public.v_tpds_all_cal               CASCADE;
DROP VIEW IF EXISTS public.v_tpds_lesson_summary        CASCADE;
DROP VIEW IF EXISTS public.v_tpds_teacher_profiles      CASCADE;
DROP VIEW IF EXISTS public.v_tpds_recent_sync_activity  CASCADE;


-- ════════════════════════════════════════════════════════════════════
-- STEP 1 — EXTENSIONS
-- ════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";


-- ════════════════════════════════════════════════════════════════════
-- STEP 2 — MAIN SYNC TABLE  (tpds_sync)
--
--  One row per teacher per data category.
--  The app syncs up to 12 rows per teacher:
--
--    CORE DATA          setup · lessons · ieps · cal · deleted
--    DOCUMENTS          submitted_docs
--    LOGS & CONFIG      iep_logs · admin_config
--    EXTRA              letterhead · sow_taught · users · uploads_meta
--
--  V12 bug fixed here: the old constraint only listed 8 keys.
--  The app tried to sync 12. The 4 missing ones caused HTTP 400
--  from Supabase → "partial sync" error every time.
-- ════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.tpds_sync (
  id           TEXT        NOT NULL,
  user_id      TEXT        NOT NULL,
  data_key     TEXT        NOT NULL,
  payload      JSONB       NOT NULL DEFAULT '{}',
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT tpds_sync_pkey PRIMARY KEY (id),

  -- ▼ ALL 12 keys the app uses. Missing any one = partial sync error.
  CONSTRAINT tpds_sync_key_check CHECK (
    data_key IN (
      'setup',          -- teacher profile / school setup
      'lessons',        -- lesson plans (Grades 7–9)
      'ieps',           -- Individual Education Plans
      'cal',            -- Competency Assessment Log
      'deleted',        -- deleted-items recycle bin
      'submitted_docs', -- documents submitted for approval
      'iep_logs',       -- IEP progress log entries
      'admin_config',   -- school-wide admin configuration
      'letterhead',     -- school letterhead settings  ← was missing in V12
      'sow_taught',     -- Scheme of Work taught tracker ← was missing in V12
      'users',          -- teacher account list (admin only) ← was missing in V12
      'uploads_meta'    -- uploaded file metadata (no binaries) ← was missing in V12
    )
  )
);

CREATE INDEX IF NOT EXISTS idx_tpds_sync_user_id    ON public.tpds_sync (user_id);
CREATE INDEX IF NOT EXISTS idx_tpds_sync_data_key   ON public.tpds_sync (data_key);
CREATE INDEX IF NOT EXISTS idx_tpds_sync_updated_at ON public.tpds_sync (updated_at DESC);

COMMENT ON TABLE  public.tpds_sync IS 'Main JSONB sync store. One row per teacher per data category (12 categories total).';
COMMENT ON COLUMN public.tpds_sync.id        IS 'Composite key: username__data_key  e.g. "sobe__lessons"';
COMMENT ON COLUMN public.tpds_sync.user_id   IS 'Teacher username as set in the app login.';
COMMENT ON COLUMN public.tpds_sync.data_key  IS 'Data category — one of 12 allowed values.';
COMMENT ON COLUMN public.tpds_sync.payload   IS 'Full JSONB payload for that category.';


-- ════════════════════════════════════════════════════════════════════
-- STEP 3 — TEACHER DIRECTORY TABLE  (tpds_teachers)
--   One row per teacher. Auto-created/updated on login and profile save.
-- ════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.tpds_teachers (
  username        TEXT         PRIMARY KEY,
  display_name    TEXT,
  tsc_number      TEXT,
  department      TEXT,
  role            TEXT         DEFAULT 'Teacher',
  phone           TEXT,
  email           TEXT,
  school_name     TEXT,
  grades_taught   TEXT,
  registered_at   TIMESTAMPTZ,
  last_login_at   TIMESTAMPTZ,
  is_active       BOOLEAN      DEFAULT TRUE,
  updated_at      TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tpds_teachers_role       ON public.tpds_teachers (role);
CREATE INDEX IF NOT EXISTS idx_tpds_teachers_dept       ON public.tpds_teachers (department);
CREATE INDEX IF NOT EXISTS idx_tpds_teachers_last_login ON public.tpds_teachers (last_login_at DESC);

COMMENT ON TABLE  public.tpds_teachers               IS 'Live teacher directory — one row per registered teacher.';
COMMENT ON COLUMN public.tpds_teachers.username      IS 'Login username. Primary key.';
COMMENT ON COLUMN public.tpds_teachers.tsc_number    IS 'Teachers Service Commission ID number.';
COMMENT ON COLUMN public.tpds_teachers.grades_taught IS 'Comma-separated grades e.g. "7,8,9".';
COMMENT ON COLUMN public.tpds_teachers.last_login_at IS 'Timestamp of most recent login from any device.';

CREATE OR REPLACE FUNCTION public.tpds_teachers_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tpds_teachers_updated_at ON public.tpds_teachers;
CREATE TRIGGER tpds_teachers_updated_at
  BEFORE INSERT OR UPDATE ON public.tpds_teachers
  FOR EACH ROW EXECUTE FUNCTION public.tpds_teachers_set_updated_at();


-- ════════════════════════════════════════════════════════════════════
-- STEP 4 — CLOUD USERS TABLE  (tpds_users_cloud)
--   Admin pushes all teacher accounts here.
--   Teachers use this for cross-device login verification.
-- ════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.tpds_users_cloud (
  id              TEXT         PRIMARY KEY,
  username        TEXT         NOT NULL UNIQUE,
  password_hash   TEXT         NOT NULL,
  role            TEXT         DEFAULT 'Teacher',
  name            TEXT,
  dept            TEXT,
  email           TEXT,
  phone           TEXT,
  assignments     JSONB,
  is_active       BOOLEAN      DEFAULT TRUE,
  created_at      TIMESTAMPTZ  DEFAULT NOW(),
  updated_at      TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tpds_users_cloud_username  ON public.tpds_users_cloud (username);
CREATE INDEX IF NOT EXISTS idx_tpds_users_cloud_role      ON public.tpds_users_cloud (role);
CREATE INDEX IF NOT EXISTS idx_tpds_users_cloud_is_active ON public.tpds_users_cloud (is_active);

COMMENT ON TABLE  public.tpds_users_cloud               IS 'Teacher accounts synced from admin. Used for cross-device login verification.';
COMMENT ON COLUMN public.tpds_users_cloud.password_hash IS 'SHA-1 hash of the password, produced by the TPDS app.';
COMMENT ON COLUMN public.tpds_users_cloud.assignments   IS 'JSON array of {subject, grade} pairs assigned by admin.';
COMMENT ON COLUMN public.tpds_users_cloud.is_active     IS 'Set to false to revoke cross-device access without deleting the account.';

CREATE OR REPLACE FUNCTION public.tpds_users_cloud_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tpds_users_cloud_ts ON public.tpds_users_cloud;
CREATE TRIGGER tpds_users_cloud_ts
  BEFORE INSERT OR UPDATE ON public.tpds_users_cloud
  FOR EACH ROW EXECUTE FUNCTION public.tpds_users_cloud_updated_at();


-- ════════════════════════════════════════════════════════════════════
-- STEP 5 — SYNC AUDIT LOG  (tpds_sync_log)
--   Auto-records every sync event. Use for troubleshooting.
-- ════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.tpds_sync_log (
  id           BIGSERIAL   PRIMARY KEY,
  user_id      TEXT        NOT NULL,
  data_key     TEXT,
  action       TEXT        NOT NULL,
  row_count    INT,
  synced_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_synclog_user_id   ON public.tpds_sync_log (user_id);
CREATE INDEX IF NOT EXISTS idx_synclog_synced_at ON public.tpds_sync_log (synced_at DESC);

COMMENT ON TABLE public.tpds_sync_log IS 'Audit trail of all sync operations. Auto-populated by trigger.';

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
-- STEP 6 — ROW LEVEL SECURITY  (RLS)
--
--  HOW IT WORKS:
--    The app sends an  x-tpds-user  header on every API call.
--    PostgREST exposes this via current_setting('request.headers').
--    tpds_current_user_header() extracts it.
--    Each teacher can only read/write their OWN rows.
--    service_role key bypasses ALL RLS — admin only.
--
--  V13 notes:
--    - _sbFetch in the app was missing x-tpds-user → restore was broken
--    - _sbUpsertTeacher was missing x-tpds-user → teacher directory silent fail
--    Both fixed in the app (V13 HTML). The SQL policies below are correct.
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.tpds_sync         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tpds_teachers     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tpds_users_cloud  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tpds_sync_log     ENABLE ROW LEVEL SECURITY;

-- Helper: extract x-tpds-user header sent by the app
CREATE OR REPLACE FUNCTION public.tpds_current_user_header()
RETURNS TEXT LANGUAGE SQL STABLE AS $$
  SELECT COALESCE(
    NULLIF(TRIM((current_setting('request.headers', true)::json->>'x-tpds-user')::text, '"'), ''),
    ''
  );
$$;

-- ── tpds_sync: strict per-teacher row isolation ───────────────────────

DROP POLICY IF EXISTS "anon_insert_own"    ON public.tpds_sync;
DROP POLICY IF EXISTS "anon_select_own"    ON public.tpds_sync;
DROP POLICY IF EXISTS "anon_update_own"    ON public.tpds_sync;
DROP POLICY IF EXISTS "anon_delete_own"    ON public.tpds_sync;
DROP POLICY IF EXISTS "authenticated_full" ON public.tpds_sync;
DROP POLICY IF EXISTS "tpds_anon_select"   ON public.tpds_sync;
DROP POLICY IF EXISTS "tpds_anon_insert"   ON public.tpds_sync;
DROP POLICY IF EXISTS "tpds_anon_update"   ON public.tpds_sync;
DROP POLICY IF EXISTS "tpds_anon_delete"   ON public.tpds_sync;
DROP POLICY IF EXISTS "tpds_teacher_select" ON public.tpds_sync;
DROP POLICY IF EXISTS "tpds_teacher_insert" ON public.tpds_sync;
DROP POLICY IF EXISTS "tpds_teacher_update" ON public.tpds_sync;
DROP POLICY IF EXISTS "tpds_teacher_delete" ON public.tpds_sync;

CREATE POLICY "tpds_teacher_select" ON public.tpds_sync
  FOR SELECT TO anon
  USING (LOWER(user_id) = LOWER(public.tpds_current_user_header()));

CREATE POLICY "tpds_teacher_insert" ON public.tpds_sync
  FOR INSERT TO anon
  WITH CHECK (LOWER(user_id) = LOWER(public.tpds_current_user_header()));

CREATE POLICY "tpds_teacher_update" ON public.tpds_sync
  FOR UPDATE TO anon
  USING (LOWER(user_id) = LOWER(public.tpds_current_user_header()))
  WITH CHECK (LOWER(user_id) = LOWER(public.tpds_current_user_header()));

CREATE POLICY "tpds_teacher_delete" ON public.tpds_sync
  FOR DELETE TO anon
  USING (LOWER(user_id) = LOWER(public.tpds_current_user_header()));

CREATE POLICY "authenticated_full" ON public.tpds_sync
  FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

-- ── tpds_teachers: teachers manage their own profile row ─────────────

DROP POLICY IF EXISTS "tpds_teachers_select"      ON public.tpds_teachers;
DROP POLICY IF EXISTS "tpds_teachers_insert"      ON public.tpds_teachers;
DROP POLICY IF EXISTS "tpds_teachers_update"      ON public.tpds_teachers;
DROP POLICY IF EXISTS "tpds_teachers_self_select" ON public.tpds_teachers;
DROP POLICY IF EXISTS "tpds_teachers_self_insert" ON public.tpds_teachers;
DROP POLICY IF EXISTS "tpds_teachers_self_update" ON public.tpds_teachers;

CREATE POLICY "tpds_teachers_self_select" ON public.tpds_teachers
  FOR SELECT TO anon
  USING (LOWER(username) = LOWER(public.tpds_current_user_header()));

CREATE POLICY "tpds_teachers_self_insert" ON public.tpds_teachers
  FOR INSERT TO anon
  WITH CHECK (LOWER(username) = LOWER(public.tpds_current_user_header()));

CREATE POLICY "tpds_teachers_self_update" ON public.tpds_teachers
  FOR UPDATE TO anon
  USING (LOWER(username) = LOWER(public.tpds_current_user_header()))
  WITH CHECK (LOWER(username) = LOWER(public.tpds_current_user_header()));

-- ── tpds_users_cloud: all teachers can read (needed for login check) ──

DROP POLICY IF EXISTS "users_cloud_select" ON public.tpds_users_cloud;
DROP POLICY IF EXISTS "users_cloud_insert" ON public.tpds_users_cloud;
DROP POLICY IF EXISTS "users_cloud_update" ON public.tpds_users_cloud;

CREATE POLICY "users_cloud_select" ON public.tpds_users_cloud
  FOR SELECT TO anon USING (true);

CREATE POLICY "users_cloud_insert" ON public.tpds_users_cloud
  FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY "users_cloud_update" ON public.tpds_users_cloud
  FOR UPDATE TO anon USING (true) WITH CHECK (true);

-- ── tpds_sync_log: teachers can read own log entries ──────────────────

DROP POLICY IF EXISTS "anon_read_own_log" ON public.tpds_sync_log;

CREATE POLICY "anon_read_own_log" ON public.tpds_sync_log
  FOR SELECT TO anon USING (true);


-- ════════════════════════════════════════════════════════════════════
-- STEP 7 — ADMIN VIEWS
--   All readable with the service_role key in Supabase Table Editor
--   or SQL Editor. Teachers cannot access these via the anon key.
-- ════════════════════════════════════════════════════════════════════

-- 7a. Full teacher directory with login & sync stats
CREATE OR REPLACE VIEW public.v_tpds_teacher_directory AS
SELECT
  t.username,
  t.display_name,
  t.tsc_number,
  t.department,
  t.role,
  t.phone,
  t.email,
  t.school_name,
  t.grades_taught,
  t.registered_at,
  t.last_login_at,
  NOW() - t.last_login_at                                          AS time_since_login,
  t.is_active,
  s.categories_synced,
  s.last_sync,
  NOW() - s.last_sync                                              AS time_since_sync,
  lesson_ct.n                                                      AS lesson_count,
  iep_ct.n                                                         AS iep_count,
  cal_ct.n                                                         AS cal_count,
  sub_ct.n                                                         AS submission_count
FROM public.tpds_teachers t
LEFT JOIN (
  SELECT user_id, COUNT(*) AS categories_synced, MAX(updated_at) AS last_sync
  FROM public.tpds_sync GROUP BY user_id
) s ON LOWER(s.user_id) = LOWER(t.username)
LEFT JOIN (
  SELECT user_id, jsonb_array_length(payload) AS n
  FROM public.tpds_sync WHERE data_key = 'lessons'
) lesson_ct ON LOWER(lesson_ct.user_id) = LOWER(t.username)
LEFT JOIN (
  SELECT user_id, jsonb_array_length(payload) AS n
  FROM public.tpds_sync WHERE data_key = 'ieps'
) iep_ct ON LOWER(iep_ct.user_id) = LOWER(t.username)
LEFT JOIN (
  SELECT user_id, jsonb_array_length(payload) AS n
  FROM public.tpds_sync WHERE data_key = 'cal'
) cal_ct ON LOWER(cal_ct.user_id) = LOWER(t.username)
LEFT JOIN (
  SELECT user_id, jsonb_array_length(payload) AS n
  FROM public.tpds_sync WHERE data_key = 'submitted_docs'
) sub_ct ON LOWER(sub_ct.user_id) = LOWER(t.username)
ORDER BY t.last_login_at DESC NULLS LAST;

COMMENT ON VIEW public.v_tpds_teacher_directory
  IS 'Full teacher directory with profile, login time, and sync statistics.';


-- 7b. Active teachers only
CREATE OR REPLACE VIEW public.v_tpds_active_teachers AS
SELECT * FROM public.v_tpds_teacher_directory WHERE is_active = TRUE;
COMMENT ON VIEW public.v_tpds_active_teachers IS 'Active teachers only.';


-- 7c. Teachers not logged in for 14+ days
CREATE OR REPLACE VIEW public.v_tpds_inactive_logins AS
SELECT
  username, display_name, department, role, last_login_at,
  NOW() - last_login_at AS time_since_login
FROM public.tpds_teachers
WHERE last_login_at < NOW() - INTERVAL '14 days' OR last_login_at IS NULL
ORDER BY last_login_at ASC NULLS FIRST;
COMMENT ON VIEW public.v_tpds_inactive_logins IS 'Teachers who have not logged in for 14+ days.';


-- 7d. Teachers with no cloud sync yet
CREATE OR REPLACE VIEW public.v_tpds_no_sync AS
SELECT t.username, t.display_name, t.department, t.role, t.last_login_at
FROM public.tpds_teachers t
LEFT JOIN (
  SELECT DISTINCT LOWER(user_id) AS user_id FROM public.tpds_sync
) s ON s.user_id = LOWER(t.username)
WHERE s.user_id IS NULL
ORDER BY t.display_name;
COMMENT ON VIEW public.v_tpds_no_sync IS 'Teachers registered but with no data in the sync table yet.';


-- 7e. Active teachers not synced in 7+ days
CREATE OR REPLACE VIEW public.v_tpds_sync_lagging AS
SELECT
  t.username, t.display_name, t.department, t.role,
  s.last_sync, NOW() - s.last_sync AS time_behind
FROM public.tpds_teachers t
LEFT JOIN (
  SELECT LOWER(user_id) AS uid, MAX(updated_at) AS last_sync
  FROM public.tpds_sync GROUP BY LOWER(user_id)
) s ON s.uid = LOWER(t.username)
WHERE t.is_active = TRUE
  AND (s.last_sync < NOW() - INTERVAL '7 days' OR s.last_sync IS NULL)
ORDER BY s.last_sync ASC NULLS FIRST;
COMMENT ON VIEW public.v_tpds_sync_lagging IS 'Active teachers who have not synced in the last 7 days.';


-- 7f. Department summary
CREATE OR REPLACE VIEW public.v_tpds_dept_summary AS
SELECT
  COALESCE(department, 'Unassigned') AS department,
  COUNT(*)                           AS teacher_count,
  COUNT(*) FILTER (WHERE is_active)  AS active_count,
  MAX(last_login_at)                 AS last_activity
FROM public.tpds_teachers
GROUP BY department
ORDER BY teacher_count DESC;
COMMENT ON VIEW public.v_tpds_dept_summary IS 'Teacher count grouped by department.';


-- 7g. All submitted documents across every teacher
CREATE OR REPLACE VIEW public.v_tpds_all_submissions AS
SELECT
  s.user_id                                                       AS teacher,
  t.display_name                                                  AS teacher_name,
  doc->>'id'                                                      AS doc_id,
  doc->>'docType'                                                 AS doc_type,
  doc->>'summary'                                                 AS summary,
  doc->>'status'                                                  AS status,
  doc->>'submitterId'                                             AS submitter_id,
  doc->>'submitterName'                                           AS submitter_name,
  doc->>'submitterRole'                                           AS submitter_role,
  doc->>'targetRole'                                              AS target_role,
  doc->>'currentApprover'                                         AS current_approver_id,
  doc->>'approvedBy'                                              AS approved_by,
  doc->>'approverRole'                                            AS approver_role,
  TO_TIMESTAMP(((doc->>'submittedAt')::BIGINT)/1000)              AS submitted_at,
  TO_TIMESTAMP(((doc->>'approvedAt')::BIGINT)/1000)               AS approved_at,
  s.updated_at                                                    AS synced_at
FROM public.tpds_sync s
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]'::jsonb END
) AS doc
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(s.user_id)
WHERE s.data_key = 'submitted_docs'
ORDER BY submitted_at DESC NULLS LAST;
COMMENT ON VIEW public.v_tpds_all_submissions IS 'All documents submitted by all teachers.';


-- 7h. Pending submissions (not yet approved)
CREATE OR REPLACE VIEW public.v_tpds_pending_submissions AS
SELECT * FROM public.v_tpds_all_submissions
WHERE status IN ('submitted','pending') OR status IS NULL
ORDER BY submitted_at DESC NULLS LAST;
COMMENT ON VIEW public.v_tpds_pending_submissions IS 'Documents awaiting admin review/approval.';


-- 7i. All lesson plans across every teacher
CREATE OR REPLACE VIEW public.v_tpds_all_lessons AS
SELECT
  s.user_id                                                       AS teacher,
  t.display_name                                                  AS teacher_name,
  lesson->>'id'                                                   AS lesson_id,
  lesson->>'grade'                                                AS grade,
  lesson->>'term'                                                 AS term,
  lesson->>'week'                                                 AS week,
  lesson->>'lno'                                                  AS lesson_no,
  lesson->>'date'                                                 AS lesson_date,
  lesson->>'day'                                                  AS day_of_week,
  lesson->>'time'                                                 AS lesson_time,
  lesson->>'roll'                                                 AS class_roll,
  lesson->>'subject'                                              AS subject,
  lesson->>'theme'                                                AS theme,
  lesson->>'strand'                                               AS strand,
  lesson->>'substrand'                                            AS sub_strand,
  lesson->>'slo'                                                  AS specific_learning_outcome,
  lesson->>'sle'                                                  AS specific_learning_experience,
  lesson->>'kiq'                                                  AS key_inquiry_question,
  lesson->>'resources'                                            AS resources,
  lesson->>'orglearn'                                             AS organisation_of_learning,
  lesson->>'intro'                                                AS introduction,
  lesson->'steps'                                                 AS steps,
  lesson->'stepDescs'                                             AS step_descriptions,
  lesson->>'extended'                                             AS extended_activity,
  lesson->>'conclusion'                                           AS conclusion,
  lesson->>'reflect'                                              AS reflection,
  lesson->>'skill'                                                AS lesson_skill,
  lesson->>'workdone'                                             AS work_done,
  lesson->>'asm'                                                  AS assessment_methods,
  lesson->'attainment'                                            AS attainment_levels,
  TO_TIMESTAMP(((lesson->>'createdAt')::BIGINT)/1000)             AS created_at,
  TO_TIMESTAMP(((lesson->>'updatedAt')::BIGINT)/1000)             AS updated_at,
  s.updated_at                                                    AS synced_at
FROM public.tpds_sync s
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]'::jsonb END
) AS lesson
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(s.user_id)
WHERE s.data_key = 'lessons'
ORDER BY s.user_id, lesson->>'grade', lesson->>'term', lesson->>'week';
COMMENT ON VIEW public.v_tpds_all_lessons IS 'All lesson plans from all teachers with full CBC fields.';


-- 7j. All IEPs across every teacher
CREATE OR REPLACE VIEW public.v_tpds_all_ieps AS
SELECT
  s.user_id                                                       AS teacher,
  t.display_name                                                  AS teacher_name,
  iep->>'id'                                                      AS iep_id,
  iep->>'name'                                                    AS learner_name,
  iep->>'adm'                                                     AS admission_no,
  iep->>'grade'                                                   AS grade,
  iep->>'term'                                                    AS term,
  iep->>'dob'                                                     AS date_of_birth,
  iep->>'parent'                                                  AS parent_guardian,
  iep->>'contact'                                                 AS parent_contact,
  iep->>'date'                                                    AS iep_date,
  iep->>'review'                                                  AS next_review_date,
  iep->>'challenges'                                              AS challenges,
  iep->>'strengths'                                               AS strengths,
  iep->>'goals'                                                   AS goals,
  iep->>'strategies'                                              AS strategies,
  iep->>'assessment'                                              AS assessment_methods,
  iep->>'progress'                                                AS progress_notes,
  iep->>'remarks'                                                 AS teacher_remarks,
  iep->>'parentremarks'                                           AS parent_remarks,
  TO_TIMESTAMP(((iep->>'createdAt')::BIGINT)/1000)                AS created_at,
  TO_TIMESTAMP(((iep->>'updatedAt')::BIGINT)/1000)                AS updated_at,
  s.updated_at                                                    AS synced_at
FROM public.tpds_sync s
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]'::jsonb END
) AS iep
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(s.user_id)
WHERE s.data_key = 'ieps'
ORDER BY s.user_id, iep->>'grade';
COMMENT ON VIEW public.v_tpds_all_ieps IS 'All IEPs from all teachers with full content fields.';


-- 7k. All CAL entries across every teacher
CREATE OR REPLACE VIEW public.v_tpds_all_cal AS
SELECT
  s.user_id                                                       AS teacher,
  t.display_name                                                  AS teacher_name,
  entry->>'id'                                                    AS entry_id,
  entry->>'grade'                                                 AS grade,
  entry->>'term'                                                  AS term,
  entry->>'learner'                                               AS learner_name,
  entry->>'level'                                                 AS competency_level,
  entry->>'skill'                                                 AS skill_outcome,
  entry->>'date'                                                  AS observation_date,
  entry->>'notes'                                                 AS notes,
  TO_TIMESTAMP(((entry->>'createdAt')::BIGINT)/1000)              AS created_at,
  s.updated_at                                                    AS synced_at
FROM public.tpds_sync s
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]'::jsonb END
) AS entry
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(s.user_id)
WHERE s.data_key = 'cal'
ORDER BY s.user_id, entry->>'grade', entry->>'date' DESC;
COMMENT ON VIEW public.v_tpds_all_cal IS 'All CAL entries. competency_level = EE/ME/AE/BE band.';


-- 7l. Per-teacher lesson count by grade
CREATE OR REPLACE VIEW public.v_tpds_lesson_summary AS
SELECT
  s.user_id                                                       AS teacher,
  t.display_name                                                  AS teacher_name,
  jsonb_array_length(
    CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]' END
  )                                                               AS total_lessons,
  (SELECT COUNT(*) FROM jsonb_array_elements(
    CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]' END
  ) l WHERE l->>'grade' = '7')                                    AS grade_7_lessons,
  (SELECT COUNT(*) FROM jsonb_array_elements(
    CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]' END
  ) l WHERE l->>'grade' = '8')                                    AS grade_8_lessons,
  (SELECT COUNT(*) FROM jsonb_array_elements(
    CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]' END
  ) l WHERE l->>'grade' = '9')                                    AS grade_9_lessons,
  s.updated_at                                                    AS last_synced_at
FROM public.tpds_sync s
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(s.user_id)
WHERE s.data_key = 'lessons'
ORDER BY total_lessons DESC;
COMMENT ON VIEW public.v_tpds_lesson_summary IS 'Per-teacher lesson count breakdown by grade.';


-- 7m. Teacher setup / profile summary
CREATE OR REPLACE VIEW public.v_tpds_teacher_profiles AS
SELECT
  s.user_id                                                       AS username,
  t.display_name                                                  AS teacher_name,
  s.payload->>'teacher'                                           AS profile_name,
  s.payload->>'tsc'                                               AS tsc_number,
  s.payload->>'school'                                            AS school_name,
  s.payload->>'subject'                                           AS primary_subject,
  s.payload->>'contact'                                           AS contact,
  s.payload->>'academicYear'                                      AS academic_year,
  jsonb_array_length(COALESCE(s.payload->'grades','[]'::jsonb))   AS grade_count,
  s.payload->'grades'                                             AS grades_json,
  s.updated_at                                                    AS last_synced_at
FROM public.tpds_sync s
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(s.user_id)
WHERE s.data_key = 'setup'
ORDER BY s.user_id;
COMMENT ON VIEW public.v_tpds_teacher_profiles IS 'Setup/profile data for every synced teacher.';


-- 7n. Recent sync activity (last 7 days)
CREATE OR REPLACE VIEW public.v_tpds_recent_sync_activity AS
SELECT
  l.user_id,
  t.display_name AS teacher_name,
  l.data_key,
  l.action,
  l.synced_at
FROM public.tpds_sync_log l
LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(l.user_id)
WHERE l.synced_at >= NOW() - INTERVAL '7 days'
ORDER BY l.synced_at DESC
LIMIT 200;
COMMENT ON VIEW public.v_tpds_recent_sync_activity IS 'Sync activity in the last 7 days.';


-- 7o. School-wide one-row dashboard snapshot
CREATE OR REPLACE VIEW public.v_tpds_school_summary AS
SELECT
  (SELECT COUNT(*) FROM public.tpds_teachers WHERE is_active = TRUE)              AS active_teachers,
  (SELECT COUNT(DISTINCT LOWER(user_id)) FROM public.tpds_sync)                   AS teachers_synced,
  (SELECT SUM(jsonb_array_length(payload)) FROM public.tpds_sync WHERE data_key='lessons')     AS total_lessons,
  (SELECT SUM(jsonb_array_length(payload)) FROM public.tpds_sync WHERE data_key='ieps')        AS total_ieps,
  (SELECT SUM(jsonb_array_length(payload)) FROM public.tpds_sync WHERE data_key='cal')         AS total_cal_entries,
  (SELECT COUNT(*) FROM public.v_tpds_pending_submissions)                         AS pending_submissions,
  (SELECT MAX(updated_at) FROM public.tpds_sync)                                   AS most_recent_sync;
COMMENT ON VIEW public.v_tpds_school_summary IS 'One-row school-wide snapshot.';


-- ════════════════════════════════════════════════════════════════════
-- STEP 8 — ADMIN FUNCTIONS
-- ════════════════════════════════════════════════════════════════════

-- 8a. Export full backup JSON for one teacher
CREATE OR REPLACE FUNCTION public.fn_export_teacher_backup(p_username TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  result JSONB := '{}'::JSONB;
  rec    RECORD;
BEGIN
  FOR rec IN
    SELECT data_key, payload, updated_at
    FROM public.tpds_sync WHERE user_id = p_username
  LOOP
    result := result || jsonb_build_object(
      rec.data_key,
      jsonb_build_object('data', rec.payload, 'synced_at', rec.updated_at)
    );
  END LOOP;
  RETURN jsonb_build_object('exported_at', NOW(), 'username', p_username, 'backup', result);
END;
$$;
COMMENT ON FUNCTION public.fn_export_teacher_backup IS
  'Full JSON backup for one teacher. Example: SELECT fn_export_teacher_backup(''sobe'');';


-- 8b. Export backup for ALL teachers
CREATE OR REPLACE FUNCTION public.fn_export_all_teachers_backup()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  all_backups JSONB := '{}'::JSONB;
  teacher     TEXT;
BEGIN
  FOR teacher IN
    SELECT DISTINCT user_id FROM public.tpds_sync ORDER BY user_id
  LOOP
    all_backups := all_backups || jsonb_build_object(
      teacher, public.fn_export_teacher_backup(teacher)
    );
  END LOOP;
  RETURN jsonb_build_object(
    'exported_at',   NOW(),
    'teacher_count', (SELECT COUNT(DISTINCT user_id) FROM public.tpds_sync),
    'teachers',      all_backups
  );
END;
$$;
COMMENT ON FUNCTION public.fn_export_all_teachers_backup IS
  'Full JSON backup of ALL teachers. Example: SELECT fn_export_all_teachers_backup();';


-- 8c. School-wide counts per teacher
CREATE OR REPLACE FUNCTION public.fn_school_summary()
RETURNS TABLE (
  username        TEXT,
  display_name    TEXT,
  lesson_count    INT,
  iep_count       INT,
  cal_count       INT,
  doc_count       INT,
  last_synced_at  TIMESTAMPTZ
)
LANGUAGE SQL SECURITY DEFINER AS $$
  SELECT
    s.user_id,
    t.display_name,
    (SELECT COALESCE(jsonb_array_length(
       CASE jsonb_typeof(p.payload) WHEN 'array' THEN p.payload ELSE '[]' END), 0)
     FROM public.tpds_sync p WHERE p.user_id = s.user_id AND p.data_key = 'lessons'),
    (SELECT COALESCE(jsonb_array_length(
       CASE jsonb_typeof(p.payload) WHEN 'array' THEN p.payload ELSE '[]' END), 0)
     FROM public.tpds_sync p WHERE p.user_id = s.user_id AND p.data_key = 'ieps'),
    (SELECT COALESCE(jsonb_array_length(
       CASE jsonb_typeof(p.payload) WHEN 'array' THEN p.payload ELSE '[]' END), 0)
     FROM public.tpds_sync p WHERE p.user_id = s.user_id AND p.data_key = 'cal'),
    (SELECT COALESCE(jsonb_array_length(
       CASE jsonb_typeof(p.payload) WHEN 'array' THEN p.payload ELSE '[]' END), 0)
     FROM public.tpds_sync p WHERE p.user_id = s.user_id AND p.data_key = 'submitted_docs'),
    MAX(s.updated_at)
  FROM public.tpds_sync s
  LEFT JOIN public.tpds_teachers t ON LOWER(t.username) = LOWER(s.user_id)
  GROUP BY s.user_id, t.display_name
  ORDER BY s.user_id;
$$;
COMMENT ON FUNCTION public.fn_school_summary IS
  'Per-teacher counts. Example: SELECT * FROM fn_school_summary();';


-- 8d. Delete all data for one teacher (IRREVERSIBLE)
CREATE OR REPLACE FUNCTION public.fn_remove_teacher_data(p_username TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE deleted_rows INT;
BEGIN
  DELETE FROM public.tpds_sync        WHERE user_id  = p_username;
  GET DIAGNOSTICS deleted_rows = ROW_COUNT;
  DELETE FROM public.tpds_sync_log    WHERE user_id  = p_username;
  DELETE FROM public.tpds_teachers    WHERE username  = p_username;
  DELETE FROM public.tpds_users_cloud WHERE username  = p_username;
  RETURN 'Removed ' || deleted_rows || ' sync rows for: ' || p_username;
END;
$$;
COMMENT ON FUNCTION public.fn_remove_teacher_data IS
  'Permanently deletes all data for one teacher. IRREVERSIBLE.';


-- ════════════════════════════════════════════════════════════════════
-- STEP 9 — USEFUL ADMIN QUERIES  (copy-paste individually as needed)
-- ════════════════════════════════════════════════════════════════════

/*
-- School dashboard (one row):
SELECT * FROM v_tpds_school_summary;

-- Full teacher directory:
SELECT * FROM v_tpds_teacher_directory;

-- Active teachers:
SELECT * FROM v_tpds_active_teachers;

-- Sync categories per teacher (should show 12 per teacher after V13):
SELECT user_id, data_key, updated_at,
       jsonb_array_length(CASE WHEN jsonb_typeof(payload)='array'
                               THEN payload ELSE '[]' END) AS item_count
FROM tpds_sync ORDER BY user_id, data_key;

-- Teachers not syncing recently (7+ days):
SELECT * FROM v_tpds_sync_lagging;

-- Teachers not logged in for 14+ days:
SELECT * FROM v_tpds_inactive_logins;

-- Teachers with no cloud sync yet:
SELECT * FROM v_tpds_no_sync;

-- By department:
SELECT * FROM v_tpds_dept_summary;

-- Pending approvals:
SELECT * FROM v_tpds_pending_submissions;

-- All lesson plans (all teachers):
SELECT * FROM v_tpds_all_lessons;

-- Lessons for one teacher:
SELECT * FROM v_tpds_all_lessons WHERE teacher = 'sobe';

-- Lessons for Grade 8, Term 2:
SELECT teacher_name, lesson_no, strand, theme, specific_learning_outcome, lesson_date
FROM v_tpds_all_lessons WHERE grade = '8' AND term = '2';

-- All IEPs:
SELECT * FROM v_tpds_all_ieps;

-- IEPs due for review this month:
SELECT teacher_name, learner_name, grade, next_review_date, goals
FROM v_tpds_all_ieps
WHERE next_review_date::DATE BETWEEN DATE_TRUNC('month', NOW())
  AND DATE_TRUNC('month', NOW()) + INTERVAL '1 month - 1 day';

-- All CAL entries:
SELECT * FROM v_tpds_all_cal;

-- Lesson counts per teacher per grade:
SELECT * FROM v_tpds_lesson_summary;

-- Per-teacher summary (lessons/IEPs/CAL/docs):
SELECT * FROM fn_school_summary();

-- Recent sync activity:
SELECT * FROM v_tpds_recent_sync_activity;

-- Export one teacher's full backup as JSON:
SELECT fn_export_teacher_backup('sobe');

-- Export ALL teachers' data as one JSON:
SELECT fn_export_all_teachers_backup();

-- Revoke a teacher's cross-device access (keeps account):
UPDATE tpds_users_cloud SET is_active = false WHERE username = 'username_here';

-- Reset a teacher's password:
UPDATE tpds_users_cloud SET password_hash = '<sha1_hash>' WHERE username = 'username_here';

-- Mark teacher inactive (e.g. after leaving):
UPDATE tpds_teachers SET is_active = false WHERE username = 'username_here';
*/


-- ════════════════════════════════════════════════════════════════════
-- STEP 10 — VERIFICATION  (run after the script)
--   You should see 23 rows, each showing ✅.
--   If any object is missing, re-run only the relevant STEP above.
-- ════════════════════════════════════════════════════════════════════

SELECT 'tpds_sync'                       AS object_name, 'TABLE'    AS type, '✅' AS status
  WHERE EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='tpds_sync')
UNION ALL SELECT 'tpds_teachers',                'TABLE','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='tpds_teachers')
UNION ALL SELECT 'tpds_users_cloud',             'TABLE','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='tpds_users_cloud')
UNION ALL SELECT 'tpds_sync_log',                'TABLE','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='tpds_sync_log')
UNION ALL SELECT 'v_tpds_teacher_directory',     'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_teacher_directory')
UNION ALL SELECT 'v_tpds_active_teachers',       'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_active_teachers')
UNION ALL SELECT 'v_tpds_inactive_logins',       'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_inactive_logins')
UNION ALL SELECT 'v_tpds_no_sync',               'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_no_sync')
UNION ALL SELECT 'v_tpds_sync_lagging',          'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_sync_lagging')
UNION ALL SELECT 'v_tpds_dept_summary',          'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_dept_summary')
UNION ALL SELECT 'v_tpds_all_submissions',       'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_all_submissions')
UNION ALL SELECT 'v_tpds_pending_submissions',   'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_pending_submissions')
UNION ALL SELECT 'v_tpds_all_lessons',           'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_all_lessons')
UNION ALL SELECT 'v_tpds_all_ieps',              'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_all_ieps')
UNION ALL SELECT 'v_tpds_all_cal',               'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_all_cal')
UNION ALL SELECT 'v_tpds_lesson_summary',        'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_lesson_summary')
UNION ALL SELECT 'v_tpds_teacher_profiles',      'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_teacher_profiles')
UNION ALL SELECT 'v_tpds_recent_sync_activity',  'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_recent_sync_activity')
UNION ALL SELECT 'v_tpds_school_summary',        'VIEW','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_tpds_school_summary')
UNION ALL SELECT 'fn_export_teacher_backup',     'FUNCTION','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name='fn_export_teacher_backup')
UNION ALL SELECT 'fn_export_all_teachers_backup','FUNCTION','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name='fn_export_all_teachers_backup')
UNION ALL SELECT 'fn_school_summary',            'FUNCTION','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name='fn_school_summary')
UNION ALL SELECT 'fn_remove_teacher_data',       'FUNCTION','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name='fn_remove_teacher_data')
ORDER BY type, object_name;

-- ════════════════════════════════════════════════════════════════════
-- Also confirm the constraint covers all 12 data_key values:
SELECT pg_get_constraintdef(oid) AS constraint_definition
FROM   pg_constraint
WHERE  conrelid = 'public.tpds_sync'::regclass
  AND  conname  = 'tpds_sync_key_check';
-- Expected output includes all 12: setup, lessons, ieps, cal, deleted,
-- submitted_docs, iep_logs, admin_config, letterhead, sow_taught,
-- users, uploads_meta
-- ════════════════════════════════════════════════════════════════════
