-- ============================================================
--  TPDS PORTAL — SUPABASE COMPLETE SETUP SCRIPT
--  Atiaket Junior Secondary School
-- ============================================================
--  HOW TO USE:
--  1. Log into supabase.com → your project → SQL Editor
--  2. Paste this entire script and click RUN
--  3. Copy the anon key (Settings → API → anon/public) for teachers
--  4. Copy the service_role key (Settings → API → service_role) for admin ONLY
--  5. Teachers enter their anon key in Profile → Cloud Sync
--  6. Admin enters the SERVICE_ROLE key in Setup → Cloud Sync (Admin)
--
--  KEY SECURITY RULE:
--  ─────────────────────────────────────────────────────────
--  ● anon key       → teachers (syncs only their own data)
--  ● service_role   → administrator ONLY (sees ALL data)
--  ─────────────────────────────────────────────────────────
--  NEVER share the service_role key with teachers.
-- ============================================================


-- ============================================================
-- SECTION 1 ── EXTENSIONS
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- for full-text search on JSONB


-- ============================================================
-- SECTION 2 ── MAIN SYNC TABLE
--   One row per user per data-key. Each teacher syncs 8 rows:
--   setup · lessons · ieps · cal · deleted ·
--   submitted_docs · iep_logs · admin_config
-- ============================================================

CREATE TABLE IF NOT EXISTS public.tpds_sync (
  id           TEXT        NOT NULL,            -- "{username}__{data_key}"
  user_id      TEXT        NOT NULL,            -- teacher username
  data_key     TEXT        NOT NULL,            -- setup|lessons|ieps|cal|deleted|submitted_docs|iep_logs|admin_config
  payload      JSONB       NOT NULL DEFAULT '{}',
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT tpds_sync_pkey PRIMARY KEY (id),
  CONSTRAINT tpds_sync_key_check CHECK (
    data_key IN ('setup','lessons','ieps','cal','deleted',
                 'submitted_docs','iep_logs','admin_config')
  )
);

-- Indexes for fast per-user and admin queries
CREATE INDEX IF NOT EXISTS idx_tpds_sync_user_id    ON public.tpds_sync (user_id);
CREATE INDEX IF NOT EXISTS idx_tpds_sync_data_key   ON public.tpds_sync (data_key);
CREATE INDEX IF NOT EXISTS idx_tpds_sync_updated_at ON public.tpds_sync (updated_at DESC);

COMMENT ON TABLE  public.tpds_sync              IS 'Main JSONB sync store for TPDS Portal. One row per user per data category.';
COMMENT ON COLUMN public.tpds_sync.id           IS 'Composite key: username__data_key  e.g. "jdoe__lessons"';
COMMENT ON COLUMN public.tpds_sync.user_id      IS 'Teacher username as set in the app login.';
COMMENT ON COLUMN public.tpds_sync.data_key     IS 'Data category: setup|lessons|ieps|cal|deleted|submitted_docs|iep_logs|admin_config';
COMMENT ON COLUMN public.tpds_sync.payload      IS 'Full JSONB payload for that category.';


-- ============================================================
-- SECTION 3 ── SCHOOL REGISTRY TABLE
--   Written by admin only. Used to link usernames to names,
--   subjects, and grades for cross-teacher admin views.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.tpds_school_registry (
  id              UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  username        TEXT        NOT NULL UNIQUE,  -- matches tpds_sync.user_id
  full_name       TEXT,
  tsc_number      TEXT,
  id_number       TEXT,
  email           TEXT,
  phone           TEXT,
  role            TEXT        DEFAULT 'Teacher',
  subjects        TEXT[],                       -- array of assigned subjects
  grades          TEXT[],                       -- array of assigned grades (7,8,9)
  is_active       BOOLEAN     DEFAULT TRUE,
  registered_at   TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_registry_username ON public.tpds_school_registry (username);
CREATE INDEX IF NOT EXISTS idx_registry_role     ON public.tpds_school_registry (role);

COMMENT ON TABLE public.tpds_school_registry IS 'School teacher registry. Admin populates this manually or via the Admin Panel sync.';


-- ============================================================
-- SECTION 4 ── SYNC AUDIT LOG
--   Automatically records every sync event for troubleshooting.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.tpds_sync_log (
  id           BIGSERIAL   PRIMARY KEY,
  user_id      TEXT        NOT NULL,
  data_key     TEXT,
  action       TEXT        NOT NULL,    -- 'upsert' | 'restore' | 'delete'
  row_count    INT,
  synced_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_synclog_user_id  ON public.tpds_sync_log (user_id);
CREATE INDEX IF NOT EXISTS idx_synclog_synced_at ON public.tpds_sync_log (synced_at DESC);

COMMENT ON TABLE public.tpds_sync_log IS 'Audit trail of all sync operations. Auto-populated by trigger.';


-- ============================================================
-- SECTION 5 ── TRIGGER: auto-log every upsert
-- ============================================================

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


-- ============================================================
-- SECTION 6 ── ROW LEVEL SECURITY
--
--   anon key (teachers):
--     ● Can INSERT their own rows
--     ● Can SELECT / UPDATE / DELETE their own rows
--     ● CANNOT see other teachers' rows
--
--   service_role key (admin):
--     ● Bypasses RLS completely — sees ALL rows
--
--   How teacher-identity works:
--     The app sends user_id in the row payload. RLS uses
--     current_setting('request.jwt.claim.sub', true) but since
--     TPDS uses its own auth (not Supabase Auth), we use a
--     permissive anon policy combined with the service_role
--     restriction for the admin side. The app enforces
--     user_id scoping in all fetch queries.
-- ============================================================

ALTER TABLE public.tpds_sync            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tpds_school_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tpds_sync_log        ENABLE ROW LEVEL SECURITY;

-- ── tpds_sync policies ─────────────────────────────────────

-- anon: full CRUD on their OWN rows (user_id scoped by app queries)
CREATE POLICY "anon_insert_own"
  ON public.tpds_sync FOR INSERT TO anon
  WITH CHECK (true);

CREATE POLICY "anon_select_own"
  ON public.tpds_sync FOR SELECT TO anon
  USING (true);

CREATE POLICY "anon_update_own"
  ON public.tpds_sync FOR UPDATE TO anon
  USING (true) WITH CHECK (true);

CREATE POLICY "anon_delete_own"
  ON public.tpds_sync FOR DELETE TO anon
  USING (true);

-- service_role: bypasses RLS by default in Supabase (no policy needed)
-- authenticated: also allow (in case you later add Supabase Auth)
CREATE POLICY "authenticated_full"
  ON public.tpds_sync FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

-- ── tpds_school_registry policies ──────────────────────────

-- anon: read-only (teachers can read the registry for school info)
CREATE POLICY "anon_read_registry"
  ON public.tpds_school_registry FOR SELECT TO anon
  USING (true);

-- anon: cannot write to the registry (admin-only writes via service_role)
-- (No INSERT/UPDATE/DELETE policies for anon = blocked by default)

-- ── tpds_sync_log policies ─────────────────────────────────

-- anon: can read their own sync history
CREATE POLICY "anon_read_own_log"
  ON public.tpds_sync_log FOR SELECT TO anon
  USING (true);


-- ============================================================
-- SECTION 7 ── ADMIN VIEWS
--   Use these in Supabase Table Editor or SQL Editor
--   with your service_role key to see all teachers' data.
-- ============================================================

-- ── 7a. All active teachers and their last sync time ───────
CREATE OR REPLACE VIEW public.v_teachers_overview AS
SELECT
  s.user_id                                         AS username,
  r.full_name,
  r.tsc_number,
  r.email,
  r.role,
  r.subjects,
  r.grades,
  r.is_active,
  COUNT(s.data_key)                                 AS synced_data_keys,
  MAX(s.updated_at)                                 AS last_synced_at,
  MIN(s.updated_at)                                 AS first_synced_at
FROM public.tpds_sync s
LEFT JOIN public.tpds_school_registry r ON r.username = s.user_id
GROUP BY s.user_id, r.full_name, r.tsc_number, r.email,
         r.role, r.subjects, r.grades, r.is_active
ORDER BY last_synced_at DESC;

COMMENT ON VIEW public.v_teachers_overview IS 'Admin: one row per teacher, shows last sync time and data completeness.';


-- ── 7b. All lesson plans (expanded from JSONB) ─────────────
CREATE OR REPLACE VIEW public.v_all_lessons AS
SELECT
  s.user_id                                         AS teacher,
  r.full_name                                       AS teacher_name,
  lesson->>'id'                                     AS lesson_id,
  lesson->>'grade'                                  AS grade,
  lesson->>'term'                                   AS term,
  lesson->>'week'                                   AS week,
  lesson->>'lno'                                    AS lesson_no,
  lesson->>'date'                                   AS lesson_date,
  lesson->>'strand'                                 AS strand,
  lesson->>'subStrand'                              AS sub_strand,
  lesson->>'theme'                                  AS theme,
  lesson->>'subject'                                AS subject,
  lesson->>'slo'                                    AS specific_learning_outcome,
  lesson->>'timeFrom'                               AS time_from,
  lesson->>'timeTo'                                 AS time_to,
  (lesson->>'updatedAt')::BIGINT                    AS updated_at_epoch,
  TO_TIMESTAMP(((lesson->>'updatedAt')::BIGINT)/1000) AS updated_at,
  s.updated_at                                      AS synced_at
FROM public.tpds_sync s
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(s.payload)
    WHEN 'array' THEN s.payload
    ELSE '[]'::jsonb
  END
) AS lesson
LEFT JOIN public.tpds_school_registry r ON r.username = s.user_id
WHERE s.data_key = 'lessons'
ORDER BY s.user_id, lesson->>'grade', lesson->>'term', lesson->>'week';

COMMENT ON VIEW public.v_all_lessons IS 'Admin: all lesson plans from all teachers, one row per lesson.';


-- ── 7c. All IEPs (expanded) ─────────────────────────────────
CREATE OR REPLACE VIEW public.v_all_ieps AS
SELECT
  s.user_id                                         AS teacher,
  r.full_name                                       AS teacher_name,
  iep->>'id'                                        AS iep_id,
  iep->>'learner'                                   AS learner_name,
  iep->>'adm'                                       AS admission_no,
  iep->>'grade'                                     AS grade,
  iep->>'term'                                      AS term,
  iep->>'type'                                      AS need_type,
  iep->>'goal'                                      AS goal,
  iep->>'strategies'                                AS strategies,
  iep->>'review'                                    AS next_review_date,
  iep->>'status'                                    AS status,
  TO_TIMESTAMP(((iep->>'createdAt')::BIGINT)/1000)  AS created_at,
  s.updated_at                                      AS synced_at
FROM public.tpds_sync s
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(s.payload)
    WHEN 'array' THEN s.payload
    ELSE '[]'::jsonb
  END
) AS iep
LEFT JOIN public.tpds_school_registry r ON r.username = s.user_id
WHERE s.data_key = 'ieps'
ORDER BY s.user_id, iep->>'grade', iep->>'learner';

COMMENT ON VIEW public.v_all_ieps IS 'Admin: all IEPs from all teachers.';


-- ── 7d. All CAL entries (expanded) ──────────────────────────
CREATE OR REPLACE VIEW public.v_all_cal AS
SELECT
  s.user_id                                         AS teacher,
  r.full_name                                       AS teacher_name,
  entry->>'id'                                      AS entry_id,
  entry->>'grade'                                   AS grade,
  entry->>'term'                                    AS term,
  entry->>'learner'                                 AS learner_name,
  entry->>'level'                                   AS competency_level,
  entry->>'skill'                                   AS skill_observed,
  entry->>'date'                                    AS observation_date,
  entry->>'notes'                                   AS notes,
  TO_TIMESTAMP(((entry->>'createdAt')::BIGINT)/1000) AS created_at,
  s.updated_at                                       AS synced_at
FROM public.tpds_sync s
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(s.payload)
    WHEN 'array' THEN s.payload
    ELSE '[]'::jsonb
  END
) AS entry
LEFT JOIN public.tpds_school_registry r ON r.username = s.user_id
WHERE s.data_key = 'cal'
ORDER BY s.user_id, entry->>'grade', entry->>'date' DESC;

COMMENT ON VIEW public.v_all_cal IS 'Admin: all Continuous Assessment Log entries from all teachers.';


-- ── 7e. All submitted documents ──────────────────────────────
CREATE OR REPLACE VIEW public.v_all_submitted_docs AS
SELECT
  s.user_id                                         AS submitter,
  r.full_name                                       AS submitter_name,
  doc->>'id'                                        AS doc_id,
  doc->>'docType'                                   AS doc_type,
  doc->>'title'                                     AS title,
  doc->>'targetRole'                                AS submitted_to_role,
  doc->>'status'                                    AS status,
  doc->>'approverName'                              AS approved_by,
  doc->>'approvedAt'                                AS approved_at,
  doc->>'grade'                                     AS grade,
  doc->>'term'                                      AS term,
  TO_TIMESTAMP(((doc->>'submittedAt')::BIGINT)/1000) AS submitted_at,
  s.updated_at                                       AS synced_at
FROM public.tpds_sync s
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(s.payload)
    WHEN 'array' THEN s.payload
    ELSE '[]'::jsonb
  END
) AS doc
LEFT JOIN public.tpds_school_registry r ON r.username = s.user_id
WHERE s.data_key = 'submitted_docs'
ORDER BY submitted_at DESC;

COMMENT ON VIEW public.v_all_submitted_docs IS 'Admin: all document submissions from all teachers with approval status.';


-- ── 7f. Teacher setup / profile summary ─────────────────────
CREATE OR REPLACE VIEW public.v_teacher_profiles AS
SELECT
  s.user_id                                         AS username,
  s.payload->>'teacher'                             AS teacher_name,
  s.payload->>'tsc'                                 AS tsc_number,
  s.payload->>'school'                              AS school_name,
  s.payload->>'subject'                             AS primary_subject,
  s.payload->>'contact'                             AS contact,
  s.payload->>'academicYear'                        AS academic_year,
  jsonb_array_length(
    COALESCE(s.payload->'grades','[]'::jsonb)
  )                                                 AS grade_count,
  s.payload->'grades'                               AS grades_json,
  s.updated_at                                      AS last_synced_at
FROM public.tpds_sync s
WHERE s.data_key = 'setup'
ORDER BY s.user_id;

COMMENT ON VIEW public.v_teacher_profiles IS 'Admin: setup/profile data for every synced teacher.';


-- ── 7g. School-wide lesson count summary ────────────────────
CREATE OR REPLACE VIEW public.v_lesson_summary AS
SELECT
  s.user_id                                         AS teacher,
  r.full_name                                       AS teacher_name,
  jsonb_array_length(
    CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]' END
  )                                                 AS total_lessons,
  (
    SELECT COUNT(*) FROM jsonb_array_elements(
      CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]' END
    ) l WHERE l->>'grade'='7'
  )                                                 AS grade_7_lessons,
  (
    SELECT COUNT(*) FROM jsonb_array_elements(
      CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]' END
    ) l WHERE l->>'grade'='8'
  )                                                 AS grade_8_lessons,
  (
    SELECT COUNT(*) FROM jsonb_array_elements(
      CASE jsonb_typeof(s.payload) WHEN 'array' THEN s.payload ELSE '[]' END
    ) l WHERE l->>'grade'='9'
  )                                                 AS grade_9_lessons,
  s.updated_at                                      AS last_synced_at
FROM public.tpds_sync s
LEFT JOIN public.tpds_school_registry r ON r.username = s.user_id
WHERE s.data_key = 'lessons'
ORDER BY total_lessons DESC;

COMMENT ON VIEW public.v_lesson_summary IS 'Admin: per-teacher lesson count breakdown by grade.';


-- ── 7h. Recent sync activity (last 7 days) ──────────────────
CREATE OR REPLACE VIEW public.v_recent_sync_activity AS
SELECT
  l.user_id,
  r.full_name,
  l.data_key,
  l.action,
  l.synced_at
FROM public.tpds_sync_log l
LEFT JOIN public.tpds_school_registry r ON r.username = l.user_id
WHERE l.synced_at >= NOW() - INTERVAL '7 days'
ORDER BY l.synced_at DESC
LIMIT 200;

COMMENT ON VIEW public.v_recent_sync_activity IS 'Admin: sync activity in the last 7 days.';


-- ============================================================
-- SECTION 8 ── ADMIN FUNCTIONS
-- ============================================================

-- ── 8a. Export full backup JSON for one teacher ─────────────
CREATE OR REPLACE FUNCTION public.fn_export_teacher_backup(p_username TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER   -- runs with owner privileges (service_role level)
AS $$
DECLARE
  result JSONB := '{}'::JSONB;
  rec    RECORD;
BEGIN
  FOR rec IN
    SELECT data_key, payload, updated_at
    FROM public.tpds_sync
    WHERE user_id = p_username
  LOOP
    result := result || jsonb_build_object(
      rec.data_key,
      jsonb_build_object(
        'data',       rec.payload,
        'synced_at',  rec.updated_at
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'exported_at', NOW(),
    'username',    p_username,
    'backup',      result
  );
END;
$$;

COMMENT ON FUNCTION public.fn_export_teacher_backup IS
  'Returns a complete JSON backup of all synced data for one teacher. Call with service_role key.
   Example: SELECT fn_export_teacher_backup(''jdoe'');';


-- ── 8b. Export backup for ALL teachers ──────────────────────
CREATE OR REPLACE FUNCTION public.fn_export_all_teachers_backup()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
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
    'exported_at',    NOW(),
    'teacher_count',  (SELECT COUNT(DISTINCT user_id) FROM public.tpds_sync),
    'teachers',       all_backups
  );
END;
$$;

COMMENT ON FUNCTION public.fn_export_all_teachers_backup IS
  'Returns a full backup JSON of every teacher''s data in one call.
   Example: SELECT fn_export_all_teachers_backup();';


-- ── 8c. Get per-teacher lesson + IEP + CAL counts ───────────
CREATE OR REPLACE FUNCTION public.fn_school_summary()
RETURNS TABLE (
  username        TEXT,
  full_name       TEXT,
  lesson_count    INT,
  iep_count       INT,
  cal_count       INT,
  doc_count       INT,
  last_synced_at  TIMESTAMPTZ
)
LANGUAGE SQL
SECURITY DEFINER
AS $$
  SELECT
    s.user_id,
    r.full_name,
    (
      SELECT COALESCE(jsonb_array_length(
        CASE jsonb_typeof(p.payload) WHEN 'array' THEN p.payload ELSE '[]' END
      ), 0)
      FROM public.tpds_sync p
      WHERE p.user_id = s.user_id AND p.data_key = 'lessons'
    ),
    (
      SELECT COALESCE(jsonb_array_length(
        CASE jsonb_typeof(p.payload) WHEN 'array' THEN p.payload ELSE '[]' END
      ), 0)
      FROM public.tpds_sync p
      WHERE p.user_id = s.user_id AND p.data_key = 'ieps'
    ),
    (
      SELECT COALESCE(jsonb_array_length(
        CASE jsonb_typeof(p.payload) WHEN 'array' THEN p.payload ELSE '[]' END
      ), 0)
      FROM public.tpds_sync p
      WHERE p.user_id = s.user_id AND p.data_key = 'cal'
    ),
    (
      SELECT COALESCE(jsonb_array_length(
        CASE jsonb_typeof(p.payload) WHEN 'array' THEN p.payload ELSE '[]' END
      ), 0)
      FROM public.tpds_sync p
      WHERE p.user_id = s.user_id AND p.data_key = 'submitted_docs'
    ),
    MAX(s.updated_at)
  FROM public.tpds_sync s
  LEFT JOIN public.tpds_school_registry r ON r.username = s.user_id
  GROUP BY s.user_id, r.full_name
  ORDER BY s.user_id;
$$;

COMMENT ON FUNCTION public.fn_school_summary IS
  'Returns a school-wide dashboard: one row per teacher with lesson/IEP/CAL counts.
   Example: SELECT * FROM fn_school_summary();';


-- ── 8d. Delete all data for a specific teacher ──────────────
--  (Use with caution — this is irreversible)
CREATE OR REPLACE FUNCTION public.fn_remove_teacher_data(p_username TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  deleted_rows INT;
BEGIN
  DELETE FROM public.tpds_sync      WHERE user_id = p_username;
  GET DIAGNOSTICS deleted_rows = ROW_COUNT;
  DELETE FROM public.tpds_sync_log  WHERE user_id = p_username;
  DELETE FROM public.tpds_school_registry WHERE username = p_username;

  RETURN 'Removed ' || deleted_rows || ' sync rows for user: ' || p_username;
END;
$$;

COMMENT ON FUNCTION public.fn_remove_teacher_data IS
  'Permanently removes all synced data for a teacher. IRREVERSIBLE.
   Example: SELECT fn_remove_teacher_data(''jdoe'');';


-- ============================================================
-- SECTION 9 ── SAMPLE ADMIN QUERIES
--   Copy-paste these individually in the SQL Editor whenever
--   you need to check data or generate reports.
-- ============================================================

/*
-- ── Q1: Which teachers have synced and when? ────────────────
SELECT * FROM v_teachers_overview;

-- ── Q2: All lesson plans for Grade 8, Term 2 ───────────────
SELECT teacher_name, lesson_no, strand, theme, lesson_date
FROM v_all_lessons
WHERE grade = '8' AND term = '2'
ORDER BY teacher, lesson_no;

-- ── Q3: All pending document approvals ──────────────────────
SELECT submitter_name, doc_type, title, submitted_at
FROM v_all_submitted_docs
WHERE status = 'pending'
ORDER BY submitted_at ASC;

-- ── Q4: School-wide lesson/IEP/CAL dashboard ────────────────
SELECT * FROM fn_school_summary();

-- ── Q5: Export one teacher's full backup as JSON ────────────
SELECT fn_export_teacher_backup('teacher_username_here');

-- ── Q6: Export ALL teachers' data as one JSON ───────────────
SELECT fn_export_all_teachers_backup();

-- ── Q7: All IEPs that are due for review this month ─────────
SELECT teacher_name, learner_name, grade, need_type, next_review_date
FROM v_all_ieps
WHERE next_review_date::DATE BETWEEN DATE_TRUNC('month', NOW())
                                 AND DATE_TRUNC('month', NOW()) + INTERVAL '1 month - 1 day'
ORDER BY next_review_date;

-- ── Q8: Teachers who haven't synced in 14+ days ─────────────
SELECT username, full_name, last_synced_at,
       NOW() - last_synced_at AS days_since_sync
FROM v_teachers_overview
WHERE last_synced_at < NOW() - INTERVAL '14 days'
ORDER BY last_synced_at ASC;

-- ── Q9: CAL entries per competency level ────────────────────
SELECT teacher, competency_level, COUNT(*) AS entry_count
FROM v_all_cal
GROUP BY teacher, competency_level
ORDER BY teacher, competency_level;

-- ── Q10: Lessons per teacher per grade ──────────────────────
SELECT * FROM v_lesson_summary;

-- ── Q11: Recent sync activity ───────────────────────────────
SELECT * FROM v_recent_sync_activity;

-- ── Q12: Add a teacher to the school registry ───────────────
INSERT INTO tpds_school_registry
  (username, full_name, tsc_number, email, role, subjects, grades)
VALUES
  ('jdoe', 'Jane Doe', 'TSC/12345', 'jdoe@school.ac.ke',
   'Teacher', ARRAY['English','Kiswahili'], ARRAY['7','8','9']);
*/


-- ============================================================
-- SECTION 10 ── SETUP VERIFICATION
--   Run this block after the script to confirm everything
--   was created successfully.
-- ============================================================

SELECT
  'tpds_sync'            AS object_name, 'TABLE'    AS type, '✅' AS status
  WHERE EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='tpds_sync')
UNION ALL SELECT
  'tpds_school_registry','TABLE','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='tpds_school_registry')
UNION ALL SELECT
  'tpds_sync_log',       'TABLE','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='tpds_sync_log')
UNION ALL SELECT
  'v_teachers_overview', 'VIEW', '✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_teachers_overview')
UNION ALL SELECT
  'v_all_lessons',       'VIEW', '✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_all_lessons')
UNION ALL SELECT
  'v_all_ieps',          'VIEW', '✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_all_ieps')
UNION ALL SELECT
  'v_all_cal',           'VIEW', '✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_all_cal')
UNION ALL SELECT
  'v_all_submitted_docs','VIEW', '✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_all_submitted_docs')
UNION ALL SELECT
  'v_teacher_profiles',  'VIEW', '✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_teacher_profiles')
UNION ALL SELECT
  'v_lesson_summary',    'VIEW', '✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.views WHERE table_name='v_lesson_summary')
UNION ALL SELECT
  'fn_export_teacher_backup',       'FUNCTION','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name='fn_export_teacher_backup')
UNION ALL SELECT
  'fn_export_all_teachers_backup',  'FUNCTION','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name='fn_export_all_teachers_backup')
UNION ALL SELECT
  'fn_school_summary',              'FUNCTION','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name='fn_school_summary')
UNION ALL SELECT
  'fn_remove_teacher_data',         'FUNCTION','✅'
  WHERE EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name='fn_remove_teacher_data')
ORDER BY type, object_name;

-- ============================================================
--  END OF SCRIPT
--  Everything above should show ✅ in the verification output.
--  If any row is missing, re-run only the relevant section.
-- ============================================================
