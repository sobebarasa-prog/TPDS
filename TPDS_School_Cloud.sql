-- ════════════════════════════════════════════════════════════════════
--  TPDS PORTAL — SCHOOL CLOUD SQL  (V12 — Full Multi-Teacher Model)
--  Run in: Supabase Dashboard → SQL Editor → New Query
--  Run AFTER TPDS_QuickStart.sql (tpds_sync table must already exist).
-- ════════════════════════════════════════════════════════════════════
--
--  What this creates:
--  1. tpds_users_cloud  — teacher accounts for cross-device login
--  2. Updated RLS on tpds_sync — strict per-teacher row isolation
--  3. Admin views — teacher directory, submissions, lesson stats
--
--  Key design:
--  • Admin uses service_role key  → bypasses ALL RLS, sees everyone's data
--  • Teachers use anon key        → RLS isolates their rows via x-tpds-user header
--  • x-tpds-user header           → the app sends teacher's username on every call
-- ════════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════════
-- STEP 1 — TEACHER ACCOUNTS TABLE (cross-device login)
-- ════════════════════════════════════════════════════════════════════
-- Admin pushes all teacher accounts here.
-- When a teacher opens the app on a new device, the app looks up their
-- credentials here, verifies the password hash, and logs them in.
-- ────────────────────────────────────────────────────────────────────

create table if not exists public.tpds_users_cloud (
  id              text         primary key,           -- same as app internal id
  username        text         not null unique,       -- login name (lowercase)
  password_hash   text         not null,              -- SHA-1 hash (from app)
  role            text         default 'Teacher',
  name            text,                               -- display name
  dept            text,                               -- department
  email           text,
  phone           text,
  assignments     jsonb,                              -- subject/grade assignments
  is_active       boolean      default true,
  created_at      timestamptz  default now(),
  updated_at      timestamptz  default now()
);

comment on table  public.tpds_users_cloud               is 'Teacher accounts synced from admin. Used for cross-device login verification.';
comment on column public.tpds_users_cloud.password_hash is 'SHA-1 hash of the password, produced by the TPDS app.';
comment on column public.tpds_users_cloud.assignments   is 'JSON array of {subject, grade} pairs assigned by admin.';
comment on column public.tpds_users_cloud.is_active     is 'Set to false to revoke cross-device access without deleting the account.';

create index if not exists idx_tpds_users_cloud_username   on public.tpds_users_cloud (username);
create index if not exists idx_tpds_users_cloud_role       on public.tpds_users_cloud (role);
create index if not exists idx_tpds_users_cloud_is_active  on public.tpds_users_cloud (is_active);

-- Auto-refresh updated_at
create or replace function public.tpds_users_cloud_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at=now(); return new; end;
$$;
drop trigger if exists tpds_users_cloud_ts on public.tpds_users_cloud;
create trigger tpds_users_cloud_ts
  before insert or update on public.tpds_users_cloud
  for each row execute function public.tpds_users_cloud_updated_at();

-- RLS on tpds_users_cloud:
-- anon can SELECT (needed for login verification — hashes are not reversible)
-- anon can INSERT/UPDATE (teachers update their own row on login / password change)
-- service_role (admin) bypasses all policies automatically

alter table public.tpds_users_cloud enable row level security;

create policy "users_cloud_select" on public.tpds_users_cloud
  for select to anon using (true);

create policy "users_cloud_insert" on public.tpds_users_cloud
  for insert to anon with check (true);

create policy "users_cloud_update" on public.tpds_users_cloud
  for update to anon using (true) with check (true);


-- ════════════════════════════════════════════════════════════════════
-- STEP 2 — UPDATE tpds_sync RLS: STRICT PER-TEACHER ISOLATION
-- ════════════════════════════════════════════════════════════════════
--
-- The app sends an x-tpds-user header with every API call.
-- PostgREST exposes this via current_setting('request.headers').
-- This policy ensures each teacher can only read/write their own rows.
-- Admin (service_role) bypasses all policies automatically.
--
-- IMPORTANT: Drop the old open policies first.
-- ────────────────────────────────────────────────────────────────────

-- Drop old open policies (from QuickStart.sql)
drop policy if exists "tpds_anon_select" on public.tpds_sync;
drop policy if exists "tpds_anon_insert" on public.tpds_sync;
drop policy if exists "tpds_anon_update" on public.tpds_sync;
drop policy if exists "tpds_anon_delete" on public.tpds_sync;

-- Helper function to extract x-tpds-user from request headers
create or replace function public.tpds_current_user_header()
returns text language sql stable as $$
  select coalesce(
    nullif(trim((current_setting('request.headers', true)::json->>'x-tpds-user')::text, '"'), ''),
    ''
  );
$$;

-- New strict policies: teacher can only access rows where user_id = their x-tpds-user header
create policy "tpds_teacher_select" on public.tpds_sync
  for select to anon
  using (lower(user_id) = lower(public.tpds_current_user_header()));

create policy "tpds_teacher_insert" on public.tpds_sync
  for insert to anon
  with check (lower(user_id) = lower(public.tpds_current_user_header()));

create policy "tpds_teacher_update" on public.tpds_sync
  for update to anon
  using (lower(user_id) = lower(public.tpds_current_user_header()))
  with check (lower(user_id) = lower(public.tpds_current_user_header()));

create policy "tpds_teacher_delete" on public.tpds_sync
  for delete to anon
  using (lower(user_id) = lower(public.tpds_current_user_header()));

-- Also apply the same isolation to tpds_teachers directory
drop policy if exists "tpds_teachers_select" on public.tpds_teachers;
drop policy if exists "tpds_teachers_insert" on public.tpds_teachers;
drop policy if exists "tpds_teachers_update" on public.tpds_teachers;

create policy "tpds_teachers_self_select" on public.tpds_teachers
  for select to anon
  using (lower(username) = lower(public.tpds_current_user_header()));

create policy "tpds_teachers_self_insert" on public.tpds_teachers
  for insert to anon
  with check (lower(username) = lower(public.tpds_current_user_header()));

create policy "tpds_teachers_self_update" on public.tpds_teachers
  for update to anon
  using (lower(username) = lower(public.tpds_current_user_header()))
  with check (lower(username) = lower(public.tpds_current_user_header()));


-- ════════════════════════════════════════════════════════════════════
-- STEP 3 — ADMIN VIEWS (readable with service_role key)
-- ════════════════════════════════════════════════════════════════════


-- ── All registered teachers with login and sync stats ────────────────
create or replace view public.v_tpds_teacher_directory as
select
  u.username,
  u.name                                               as display_name,
  u.role,
  u.dept                                               as department,
  u.email,
  u.phone,
  u.is_active,
  u.created_at                                         as registered_at,
  u.updated_at                                         as last_seen,
  -- Sync stats
  s.last_sync,
  s.categories_synced,
  lesson_ct.n                                          as lesson_count,
  iep_ct.n                                             as iep_count,
  cal_ct.n                                             as cal_count,
  sub_ct.n                                             as submission_count
from public.tpds_users_cloud u
left join (
  select lower(user_id) as uid, max(updated_at) as last_sync, count(*) as categories_synced
  from public.tpds_sync group by lower(user_id)
) s on s.uid=lower(u.username)
left join (select lower(user_id) as uid, jsonb_array_length(payload) as n from public.tpds_sync where data_key='lessons') lesson_ct on lesson_ct.uid=lower(u.username)
left join (select lower(user_id) as uid, jsonb_array_length(payload) as n from public.tpds_sync where data_key='ieps')    iep_ct    on iep_ct.uid=lower(u.username)
left join (select lower(user_id) as uid, jsonb_array_length(payload) as n from public.tpds_sync where data_key='cal')     cal_ct    on cal_ct.uid=lower(u.username)
left join (select lower(user_id) as uid, jsonb_array_length(payload) as n from public.tpds_sync where data_key='submitted_docs') sub_ct on sub_ct.uid=lower(u.username)
order by u.name;

comment on view public.v_tpds_teacher_directory
  is 'All registered teachers with their lesson, IEP, CAL, and submission counts.';


-- ── All submitted documents across every teacher ─────────────────────
create or replace view public.v_tpds_all_submissions as
select
  s.user_id                                                        as teacher,
  doc->>'id'                                                       as doc_id,
  doc->>'name'                                                     as doc_name,
  doc->>'docType'                                                  as doc_type,
  doc->>'status'                                                   as status,
  doc->>'grade'                                                    as grade,
  doc->>'term'                                                     as term,
  doc->>'fileName'                                                 as file_name,
  to_timestamp(((doc->>'uploadedAt')::bigint)/1000)                as uploaded_at,
  to_timestamp(((doc->>'submittedAt')::bigint)/1000)               as submitted_at,
  to_timestamp(((doc->>'approvedAt')::bigint)/1000)                as approved_at,
  doc->>'approvedBy'                                               as approved_by,
  doc->>'recipientNotes'                                           as admin_notes
from public.tpds_sync s,
  jsonb_array_elements(s.payload) as doc
where s.data_key='submitted_docs'
order by submitted_at desc nulls last;

comment on view public.v_tpds_all_submissions
  is 'All documents submitted by all teachers, with approval status.';


-- ── Pending submissions (not yet approved) ───────────────────────────
create or replace view public.v_tpds_pending_submissions as
select * from public.v_tpds_all_submissions
where status in ('submitted','pending') or status is null
order by submitted_at desc nulls last;

comment on view public.v_tpds_pending_submissions
  is 'Documents awaiting admin review/approval.';


-- ── All lesson plans across every teacher ────────────────────────────
create or replace view public.v_tpds_all_lessons as
select
  s.user_id                                            as teacher,
  lesson->>'id'                                        as lesson_id,
  lesson->>'title'                                     as title,
  lesson->>'grade'                                     as grade,
  lesson->>'term'                                      as term,
  lesson->>'week'                                      as week,
  lesson->>'strand'                                    as strand,
  lesson->>'subStrand'                                 as sub_strand,
  lesson->>'date'                                      as lesson_date,
  lesson->>'duration'                                  as duration_min,
  s.updated_at                                         as synced_at
from public.tpds_sync s,
  jsonb_array_elements(s.payload) as lesson
where s.data_key='lessons'
order by s.user_id, (lesson->>'grade'), (lesson->>'term'), (lesson->>'week');

comment on view public.v_tpds_all_lessons
  is 'All lesson plans from all teachers flattened — useful for compliance checking.';


-- ── All IEPs across every teacher ────────────────────────────────────
create or replace view public.v_tpds_all_ieps as
select
  s.user_id                                            as teacher,
  iep->>'id'                                           as iep_id,
  iep->>'learnerName'                                  as learner_name,
  iep->>'grade'                                        as grade,
  iep->>'term'                                         as term,
  iep->>'category'                                     as category,
  iep->>'concern'                                      as concern,
  iep->>'strategy'                                     as strategy,
  iep->>'reviewDate'                                   as review_date,
  s.updated_at                                         as synced_at
from public.tpds_sync s,
  jsonb_array_elements(s.payload) as iep
where s.data_key='ieps'
order by s.user_id, iep->>'grade';

comment on view public.v_tpds_all_ieps
  is 'All IEP entries from all teachers.';


-- ── School-wide dashboard summary ────────────────────────────────────
create or replace view public.v_tpds_school_summary as
select
  (select count(*) from public.tpds_users_cloud where is_active=true)            as active_teachers,
  (select count(distinct lower(user_id)) from public.tpds_sync)                  as teachers_synced,
  (select sum(jsonb_array_length(payload)) from public.tpds_sync where data_key='lessons')  as total_lessons,
  (select sum(jsonb_array_length(payload)) from public.tpds_sync where data_key='ieps')     as total_ieps,
  (select sum(jsonb_array_length(payload)) from public.tpds_sync where data_key='cal')      as total_cal_entries,
  (select count(*) from public.v_tpds_pending_submissions)                        as pending_submissions,
  (select max(updated_at) from public.tpds_sync)                                  as most_recent_sync;

comment on view public.v_tpds_school_summary
  is 'One-row school-wide snapshot: teacher counts, document totals, pending submissions.';


-- ── Teachers who have not synced recently ────────────────────────────
create or replace view public.v_tpds_sync_lagging as
select
  u.username,
  u.name,
  u.dept                                               as department,
  u.role,
  s.last_sync,
  now()-s.last_sync                                    as time_behind
from public.tpds_users_cloud u
left join (
  select lower(user_id) as uid, max(updated_at) as last_sync
  from public.tpds_sync group by lower(user_id)
) s on s.uid=lower(u.username)
where u.is_active=true
  and (s.last_sync < now()-interval '7 days' or s.last_sync is null)
order by s.last_sync asc nulls first;

comment on view public.v_tpds_sync_lagging
  is 'Active teachers who have not synced in the last 7 days.';


-- ════════════════════════════════════════════════════════════════════
-- ADMIN QUICK QUERIES
-- ════════════════════════════════════════════════════════════════════

-- Full school dashboard:
-- select * from v_tpds_school_summary;

-- All teachers + their document counts:
-- select * from v_tpds_teacher_directory;

-- Pending submissions to review:
-- select * from v_tpds_pending_submissions;

-- All lessons for a specific teacher:
-- select * from v_tpds_all_lessons where teacher = 'jmutua';

-- Teachers not syncing:
-- select * from v_tpds_sync_lagging;

-- Revoke a teacher's cross-device access (without deleting account):
-- update tpds_users_cloud set is_active=false where username='username_here';

-- Reset a teacher's password (hash = sha1 of new password):
-- update tpds_users_cloud set password_hash='<new_hash>' where username='username_here';

-- Delete all cloud data for a specific teacher:
-- delete from tpds_sync where lower(user_id)='username_here';
-- delete from tpds_users_cloud where username='username_here';
-- delete from tpds_teachers where username='username_here';
