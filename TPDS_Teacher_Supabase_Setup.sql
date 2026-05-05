-- ============================================================
--  TPDS PORTAL — PERSONAL SUPABASE SETUP (Individual Teacher)
--  Atiaket Junior Secondary School
-- ============================================================
--  This is YOUR personal cloud backup project.
--  Only YOUR data lives here. No other teacher can see it.
--
--  HOW TO SET UP (one-time):
--  ─────────────────────────────────────────────────────────
--  1. Go to supabase.com → create a FREE account
--  2. Click "New Project" → give it a name (e.g. "My TPDS")
--  3. Wait for the project to finish building (~2 min)
--  4. Go to: Project Settings → API
--     • Copy "Project URL"   → paste into TPDS Profile → Cloud Sync → URL
--     • Copy "anon / public" → paste into TPDS Profile → Cloud Sync → Key
--  5. Go to: SQL Editor → paste THIS entire script → click RUN
--  6. Go back to TPDS → Profile → Cloud Sync → Save & Connect
--
--  That's it. Your data will now sync automatically every
--  time you save a lesson, IEP, CAL entry, or document.
-- ============================================================


-- ============================================================
-- SECTION 1 ── MAIN SYNC TABLE
--   The app writes one row per data category:
--   setup · lessons · ieps · cal · deleted ·
--   submitted_docs · iep_logs · admin_config
-- ============================================================

CREATE TABLE IF NOT EXISTS public.tpds_sync (
  id           TEXT        NOT NULL,         -- "{your_username}__{data_key}"
  user_id      TEXT        NOT NULL,         -- your username in the TPDS app
  data_key     TEXT        NOT NULL,         -- which data category this row holds
  payload      JSONB       NOT NULL DEFAULT '{}',
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT tpds_sync_pkey PRIMARY KEY (id),
  CONSTRAINT tpds_sync_key_check CHECK (
    data_key IN ('setup','lessons','ieps','cal','deleted',
                 'submitted_docs','iep_logs','admin_config')
  )
);

CREATE INDEX IF NOT EXISTS idx_tpds_sync_user_id    ON public.tpds_sync (user_id);
CREATE INDEX IF NOT EXISTS idx_tpds_sync_data_key   ON public.tpds_sync (data_key);
CREATE INDEX IF NOT EXISTS idx_tpds_sync_updated_at ON public.tpds_sync (updated_at DESC);

COMMENT ON TABLE  public.tpds_sync IS 'Personal TPDS sync store. One row per data category.';
COMMENT ON COLUMN public.tpds_sync.id IS 'Format: username__data_key  e.g. "jdoe__lessons"';


-- ============================================================
-- SECTION 2 ── SYNC LOG
--   Every sync is recorded here automatically.
--   Useful if you ever want to check when data last saved.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.tpds_sync_log (
  id          BIGSERIAL   PRIMARY KEY,
  user_id     TEXT        NOT NULL,
  data_key    TEXT,
  action      TEXT        NOT NULL DEFAULT 'upsert',
  synced_at   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_synclog_synced_at ON public.tpds_sync_log (synced_at DESC);

COMMENT ON TABLE public.tpds_sync_log IS 'Auto-filled record of every sync. Read-only — written by trigger.';


-- ── Auto-log trigger ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_log_sync()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.tpds_sync_log (user_id, data_key, action)
  VALUES (NEW.user_id, NEW.data_key, 'upsert');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tpds_sync_log ON public.tpds_sync;
CREATE TRIGGER trg_tpds_sync_log
  AFTER INSERT OR UPDATE ON public.tpds_sync
  FOR EACH ROW EXECUTE FUNCTION public.fn_log_sync();


-- ============================================================
-- SECTION 3 ── ROW LEVEL SECURITY
--   Since this is your private project and you use the
--   anon key from TPDS, anon gets full access.
--   No one else has your project URL + key, so your
--   data is safe.
-- ============================================================

ALTER TABLE public.tpds_sync     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tpds_sync_log ENABLE ROW LEVEL SECURITY;

-- anon key (from your TPDS app) gets full CRUD
CREATE POLICY "anon_full_access"
  ON public.tpds_sync FOR ALL TO anon
  USING (true) WITH CHECK (true);

CREATE POLICY "anon_read_log"
  ON public.tpds_sync_log FOR SELECT TO anon
  USING (true);


-- ============================================================
-- SECTION 4 ── YOUR PERSONAL VIEWS
--   Open these in the Supabase Table Editor to browse
--   your own data without needing the app.
-- ============================================================

-- ── 4a. Your lesson plans ───────────────────────────────────
CREATE OR REPLACE VIEW public.v_my_lessons AS
SELECT
  lesson->>'id'          AS lesson_id,
  lesson->>'grade'       AS grade,
  lesson->>'term'        AS term,
  lesson->>'week'        AS week,
  lesson->>'lno'         AS lesson_no,
  lesson->>'date'        AS lesson_date,
  lesson->>'strand'      AS strand,
  lesson->>'subStrand'   AS sub_strand,
  lesson->>'theme'       AS theme,
  lesson->>'subject'     AS subject,
  lesson->>'slo'         AS specific_learning_outcome,
  lesson->>'kiq'         AS key_inquiry_question,
  lesson->>'sle'         AS suggested_learning_experience,
  lesson->>'resources'   AS resources,
  lesson->>'assessment'  AS assessment,
  lesson->>'timeFrom'    AS time_from,
  lesson->>'timeTo'      AS time_to,
  TO_TIMESTAMP(((lesson->>'updatedAt')::BIGINT)/1000) AS last_edited
FROM public.tpds_sync
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(payload) WHEN 'array' THEN payload ELSE '[]' END
) AS lesson
WHERE data_key = 'lessons'
ORDER BY grade, term::INT, week::INT, lesson_no;

COMMENT ON VIEW public.v_my_lessons IS 'All your lesson plans — one row per lesson.';


-- ── 4b. Your IEPs ───────────────────────────────────────────
CREATE OR REPLACE VIEW public.v_my_ieps AS
SELECT
  iep->>'id'           AS iep_id,
  iep->>'learner'      AS learner_name,
  iep->>'adm'          AS admission_no,
  iep->>'grade'        AS grade,
  iep->>'term'         AS term,
  iep->>'type'         AS need_type,
  iep->>'goal'         AS goal,
  iep->>'strategies'   AS strategies,
  iep->>'outcome'      AS expected_outcome,
  iep->>'review'       AS next_review_date,
  iep->>'status'       AS status,
  iep->>'parent'       AS parent_guardian,
  TO_TIMESTAMP(((iep->>'createdAt')::BIGINT)/1000) AS created_at
FROM public.tpds_sync
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(payload) WHEN 'array' THEN payload ELSE '[]' END
) AS iep
WHERE data_key = 'ieps'
ORDER BY grade, learner_name;

COMMENT ON VIEW public.v_my_ieps IS 'All your IEP records — one row per learner plan.';


-- ── 4c. Your CAL entries ─────────────────────────────────────
CREATE OR REPLACE VIEW public.v_my_cal AS
SELECT
  entry->>'id'       AS entry_id,
  entry->>'grade'    AS grade,
  entry->>'term'     AS term,
  entry->>'learner'  AS learner_name,
  entry->>'level'    AS competency_level,
  entry->>'skill'    AS skill_observed,
  entry->>'date'     AS observation_date,
  entry->>'notes'    AS notes,
  TO_TIMESTAMP(((entry->>'createdAt')::BIGINT)/1000) AS recorded_at
FROM public.tpds_sync
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(payload) WHEN 'array' THEN payload ELSE '[]' END
) AS entry
WHERE data_key = 'cal'
ORDER BY grade, observation_date DESC;

COMMENT ON VIEW public.v_my_cal IS 'All your CAL entries — one row per observation.';


-- ── 4d. Your submitted documents ────────────────────────────
CREATE OR REPLACE VIEW public.v_my_submitted_docs AS
SELECT
  doc->>'id'           AS doc_id,
  doc->>'docType'      AS doc_type,
  doc->>'title'        AS title,
  doc->>'targetRole'   AS submitted_to,
  doc->>'status'       AS status,
  doc->>'approverName' AS approved_by,
  doc->>'grade'        AS grade,
  doc->>'term'         AS term,
  TO_TIMESTAMP(((doc->>'submittedAt')::BIGINT)/1000) AS submitted_at,
  TO_TIMESTAMP(((doc->>'approvedAt')::BIGINT)/1000)  AS approved_at
FROM public.tpds_sync
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(payload) WHEN 'array' THEN payload ELSE '[]' END
) AS doc
WHERE data_key = 'submitted_docs'
ORDER BY submitted_at DESC;

COMMENT ON VIEW public.v_my_submitted_docs IS 'All documents you have submitted for approval.';


-- ── 4e. Your profile / setup summary ────────────────────────
CREATE OR REPLACE VIEW public.v_my_profile AS
SELECT
  payload->>'teacher'      AS teacher_name,
  payload->>'tsc'          AS tsc_number,
  payload->>'contact'      AS contact,
  payload->>'school'       AS school_name,
  payload->>'subject'      AS primary_subject,
  payload->>'academicYear' AS academic_year,
  payload->'grades'        AS grades,
  updated_at               AS last_synced_at
FROM public.tpds_sync
WHERE data_key = 'setup';

COMMENT ON VIEW public.v_my_profile IS 'Your TPDS profile/setup details.';


-- ── 4f. Lessons by grade and term (quick count) ─────────────
CREATE OR REPLACE VIEW public.v_my_lesson_counts AS
SELECT
  lesson->>'grade'  AS grade,
  lesson->>'term'   AS term,
  COUNT(*)          AS lesson_count
FROM public.tpds_sync
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(payload) WHEN 'array' THEN payload ELSE '[]' END
) AS lesson
WHERE data_key = 'lessons'
GROUP BY lesson->>'grade', lesson->>'term'
ORDER BY grade, term::INT;

COMMENT ON VIEW public.v_my_lesson_counts IS 'How many lessons you have per grade per term.';


-- ── 4g. IEPs due for review this month ──────────────────────
CREATE OR REPLACE VIEW public.v_my_ieps_due_this_month AS
SELECT
  iep->>'learner'   AS learner_name,
  iep->>'grade'     AS grade,
  iep->>'type'      AS need_type,
  iep->>'review'    AS review_date,
  iep->>'status'    AS status
FROM public.tpds_sync
CROSS JOIN LATERAL jsonb_array_elements(
  CASE jsonb_typeof(payload) WHEN 'array' THEN payload ELSE '[]' END
) AS iep
WHERE data_key = 'ieps'
  AND (iep->>'review') IS NOT NULL
  AND (iep->>'review')::DATE BETWEEN
      DATE_TRUNC('month', NOW()) AND
      DATE_TRUNC('month', NOW()) + INTERVAL '1 month - 1 day'
ORDER BY (iep->>'review')::DATE;

COMMENT ON VIEW public.v_my_ieps_due_this_month IS 'IEPs whose review date falls in the current calendar month.';


-- ── 4h. Your last sync per data category ────────────────────
CREATE OR REPLACE VIEW public.v_my_sync_status AS
SELECT
  data_key,
  updated_at AS last_synced_at,
  CASE
    WHEN updated_at >= NOW() - INTERVAL '1 day'  THEN '🟢 Synced today'
    WHEN updated_at >= NOW() - INTERVAL '7 days' THEN '🟡 Synced this week'
    ELSE                                               '🔴 Not synced recently'
  END AS sync_health,
  CASE jsonb_typeof(payload)
    WHEN 'array'  THEN jsonb_array_length(payload)
    WHEN 'object' THEN (SELECT COUNT(*) FROM jsonb_object_keys(payload))::INT
    ELSE 0
  END AS record_count
FROM public.tpds_sync
ORDER BY data_key;

COMMENT ON VIEW public.v_my_sync_status IS 'Quick health check — when each data category was last synced.';


-- ============================================================
-- SECTION 5 ── PERSONAL HELPER FUNCTIONS
-- ============================================================

-- ── 5a. Full JSON backup of all your data ───────────────────
CREATE OR REPLACE FUNCTION public.fn_my_full_backup()
RETURNS JSONB
LANGUAGE SQL
SECURITY DEFINER
AS $$
  SELECT jsonb_build_object(
    'exported_at', NOW(),
    'backup', jsonb_object_agg(
      data_key,
      jsonb_build_object('data', payload, 'synced_at', updated_at)
    )
  )
  FROM public.tpds_sync;
$$;

COMMENT ON FUNCTION public.fn_my_full_backup IS
  'Returns all your synced data as a single JSON blob you can save as a backup file.
   Usage: SELECT fn_my_full_backup();';


-- ── 5b. Lessons for a specific grade and term ───────────────
CREATE OR REPLACE FUNCTION public.fn_my_lessons_by_term(
  p_grade TEXT,
  p_term  TEXT
)
RETURNS TABLE (
  lesson_no   TEXT,
  lesson_date TEXT,
  strand      TEXT,
  sub_strand  TEXT,
  theme       TEXT,
  slo         TEXT,
  time_from   TEXT,
  time_to     TEXT
)
LANGUAGE SQL AS $$
  SELECT
    lesson->>'lno',
    lesson->>'date',
    lesson->>'strand',
    lesson->>'subStrand',
    lesson->>'theme',
    lesson->>'slo',
    lesson->>'timeFrom',
    lesson->>'timeTo'
  FROM public.tpds_sync
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE jsonb_typeof(payload) WHEN 'array' THEN payload ELSE '[]' END
  ) AS lesson
  WHERE data_key = 'lessons'
    AND lesson->>'grade' = p_grade
    AND lesson->>'term'  = p_term
  ORDER BY (lesson->>'week')::INT, lesson->>'lno';
$$;

COMMENT ON FUNCTION public.fn_my_lessons_by_term IS
  'Returns your lessons for one grade and term, sorted by week.
   Usage: SELECT * FROM fn_my_lessons_by_term(''8'', ''2'');';


-- ── 5c. CAL entries for a specific learner ──────────────────
CREATE OR REPLACE FUNCTION public.fn_my_cal_for_learner(p_learner TEXT)
RETURNS TABLE (
  grade            TEXT,
  term             TEXT,
  competency_level TEXT,
  skill_observed   TEXT,
  observation_date TEXT,
  notes            TEXT
)
LANGUAGE SQL AS $$
  SELECT
    entry->>'grade',
    entry->>'term',
    entry->>'level',
    entry->>'skill',
    entry->>'date',
    entry->>'notes'
  FROM public.tpds_sync
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE jsonb_typeof(payload) WHEN 'array' THEN payload ELSE '[]' END
  ) AS entry
  WHERE data_key = 'cal'
    AND LOWER(entry->>'learner') LIKE '%' || LOWER(p_learner) || '%'
  ORDER BY entry->>'date' DESC;
$$;

COMMENT ON FUNCTION public.fn_my_cal_for_learner IS
  'Returns all CAL entries for a learner (partial name match).
   Usage: SELECT * FROM fn_my_cal_for_learner(''Auma'');';


-- ── 5d. Count your documents by status ──────────────────────
CREATE OR REPLACE FUNCTION public.fn_my_doc_summary()
RETURNS TABLE (
  status        TEXT,
  doc_count     BIGINT
)
LANGUAGE SQL AS $$
  SELECT
    COALESCE(doc->>'status', 'unknown') AS status,
    COUNT(*) AS doc_count
  FROM public.tpds_sync
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE jsonb_typeof(payload) WHEN 'array' THEN payload ELSE '[]' END
  ) AS doc
  WHERE data_key = 'submitted_docs'
  GROUP BY doc->>'status'
  ORDER BY doc_count DESC;
$$;

COMMENT ON FUNCTION public.fn_my_doc_summary IS
  'How many documents you have by approval status.
   Usage: SELECT * FROM fn_my_doc_summary();';


-- ── 5e. Clear all data (full reset) ─────────────────────────
--  Only use this if you want to wipe the cloud and re-sync
--  fresh from your device.
CREATE OR REPLACE FUNCTION public.fn_clear_my_data()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER AS $$
DECLARE
  deleted_rows INT;
BEGIN
  DELETE FROM public.tpds_sync;
  GET DIAGNOSTICS deleted_rows = ROW_COUNT;
  DELETE FROM public.tpds_sync_log;
  RETURN 'Cleared ' || deleted_rows || ' rows. Re-sync from TPDS app to restore.';
END;
$$;

COMMENT ON FUNCTION public.fn_clear_my_data IS
  'Wipes all synced data from Supabase. Your device data is untouched.
   Run a fresh Sync Now in the app afterward to re-populate.
   Usage: SELECT fn_clear_my_data();';


-- ============================================================
-- SECTION 6 ── USEFUL QUERIES TO RUN ANYTIME
--   Paste any of these into SQL Editor whenever you need them.
-- ============================================================

/*
-- ── Check sync health ──────────────────────────────────────
SELECT * FROM v_my_sync_status;

-- ── Browse all your lessons ────────────────────────────────
SELECT * FROM v_my_lessons;

-- ── Lessons for Grade 8 Term 2 ────────────────────────────
SELECT * FROM fn_my_lessons_by_term('8', '2');

-- ── Lessons for Grade 7 Term 1 ────────────────────────────
SELECT * FROM fn_my_lessons_by_term('7', '1');

-- ── Browse your IEPs ──────────────────────────────────────
SELECT * FROM v_my_ieps;

-- ── IEPs due for review this month ────────────────────────
SELECT * FROM v_my_ieps_due_this_month;

-- ── All CAL entries for a learner ─────────────────────────
SELECT * FROM fn_my_cal_for_learner('learner name here');

-- ── Browse all CAL entries ─────────────────────────────────
SELECT * FROM v_my_cal;

-- ── Lesson count per grade per term ───────────────────────
SELECT * FROM v_my_lesson_counts;

-- ── Your document submissions ─────────────────────────────
SELECT * FROM v_my_submitted_docs;

-- ── Document count by approval status ─────────────────────
SELECT * FROM fn_my_doc_summary();

-- ── Your profile/setup info ───────────────────────────────
SELECT * FROM v_my_profile;

-- ── Full JSON backup (save the output as .json file) ──────
SELECT fn_my_full_backup();

-- ── When did each category last sync? ─────────────────────
SELECT data_key, last_synced_at, sync_health, record_count
FROM v_my_sync_status;

-- ── Raw sync history (last 50 events) ─────────────────────
SELECT * FROM tpds_sync_log ORDER BY synced_at DESC LIMIT 50;

-- ── DANGER: wipe cloud data and re-sync fresh ─────────────
-- SELECT fn_clear_my_data();
*/


-- ============================================================
-- SECTION 7 ── VERIFICATION
--   After running, all rows should appear below.
-- ============================================================

SELECT
  'tpds_sync'                  AS object_name, 'TABLE'    AS type
  WHERE EXISTS (SELECT 1 FROM information_schema.tables   WHERE table_name='tpds_sync')
UNION ALL SELECT 'tpds_sync_log',               'TABLE'
  WHERE EXISTS (SELECT 1 FROM information_schema.tables   WHERE table_name='tpds_sync_log')
UNION ALL SELECT 'v_my_lessons',                'VIEW'
  WHERE EXISTS (SELECT 1 FROM information_schema.views    WHERE table_name='v_my_lessons')
UNION ALL SELECT 'v_my_ieps',                   'VIEW'
  WHERE EXISTS (SELECT 1 FROM information_schema.views    WHERE table_name='v_my_ieps')
UNION ALL SELECT 'v_my_cal',                    'VIEW'
  WHERE EXISTS (SELECT 1 FROM information_schema.views    WHERE table_name='v_my_cal')
UNION ALL SELECT 'v_my_submitted_docs',         'VIEW'
  WHERE EXISTS (SELECT 1 FROM information_schema.views    WHERE table_name='v_my_submitted_docs')
UNION ALL SELECT 'v_my_profile',                'VIEW'
  WHERE EXISTS (SELECT 1 FROM information_schema.views    WHERE table_name='v_my_profile')
UNION ALL SELECT 'v_my_lesson_counts',          'VIEW'
  WHERE EXISTS (SELECT 1 FROM information_schema.views    WHERE table_name='v_my_lesson_counts')
UNION ALL SELECT 'v_my_ieps_due_this_month',    'VIEW'
  WHERE EXISTS (SELECT 1 FROM information_schema.views    WHERE table_name='v_my_ieps_due_this_month')
UNION ALL SELECT 'v_my_sync_status',            'VIEW'
  WHERE EXISTS (SELECT 1 FROM information_schema.views    WHERE table_name='v_my_sync_status')
UNION ALL SELECT 'fn_my_full_backup',           'FUNCTION'
  WHERE EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name='fn_my_full_backup')
UNION ALL SELECT 'fn_my_lessons_by_term',       'FUNCTION'
  WHERE EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name='fn_my_lessons_by_term')
UNION ALL SELECT 'fn_my_cal_for_learner',       'FUNCTION'
  WHERE EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name='fn_my_cal_for_learner')
UNION ALL SELECT 'fn_my_doc_summary',           'FUNCTION'
  WHERE EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name='fn_my_doc_summary')
UNION ALL SELECT 'fn_clear_my_data',            'FUNCTION'
  WHERE EXISTS (SELECT 1 FROM information_schema.routines WHERE routine_name='fn_clear_my_data')
ORDER BY type, object_name;

-- ============================================================
--  If you see 15 rows above, setup is complete!
--  Go to TPDS → Profile → ☁️ My Personal Cloud Sync
--  → Save & Connect → 🔄 Sync Now
-- ============================================================
