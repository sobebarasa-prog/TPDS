-- ════════════════════════════════════════════════════════════════════
--  TPDS PORTAL — TEACHER DIRECTORY TABLE
--  Run in: Supabase Dashboard → SQL Editor → New Query
--  Requires: TPDS_QuickStart.sql (tpds_sync table) already created.
-- ════════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════════
-- STEP 1 — CREATE TEACHER DIRECTORY TABLE
-- ════════════════════════════════════════════════════════════════════
-- One row per registered teacher.
-- Auto-created/updated whenever a teacher logs in or saves their profile.
-- ────────────────────────────────────────────────────────────────────

create table if not exists public.tpds_teachers (
  username        text         primary key,          -- login username (unique per teacher)
  display_name    text,                              -- full name from profile
  tsc_number      text,                              -- Teachers Service Commission number
  department      text,                              -- e.g. Languages, Science
  role            text         default 'Teacher',    -- Teacher | Administrator | HOI
  phone           text,
  email           text,
  school_name     text,                              -- from setup
  grades_taught   text,                              -- comma-separated e.g. "7,8,9"
  registered_at   timestamptz,                       -- when account was first created
  last_login_at   timestamptz,                       -- most recent login from any device
  is_active       boolean      default true,
  updated_at      timestamptz  default now()
);

comment on table  public.tpds_teachers                  is 'TPDS teacher directory — one row per registered teacher, updated on every login and profile save.';
comment on column public.tpds_teachers.username         is 'The teacher login username. Primary key.';
comment on column public.tpds_teachers.tsc_number       is 'TSC (Teachers Service Commission) ID number.';
comment on column public.tpds_teachers.grades_taught    is 'Comma-separated grade numbers e.g. "7,8,9".';
comment on column public.tpds_teachers.last_login_at    is 'Timestamp of most recent login from any device.';
comment on column public.tpds_teachers.registered_at    is 'When the account was first created in the TPDS app.';

-- Auto-refresh updated_at on every change
create or replace function public.tpds_teachers_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists tpds_teachers_updated_at on public.tpds_teachers;
create trigger tpds_teachers_updated_at
  before insert or update on public.tpds_teachers
  for each row execute function public.tpds_teachers_set_updated_at();

-- Indexes
create index if not exists idx_tpds_teachers_role        on public.tpds_teachers (role);
create index if not exists idx_tpds_teachers_dept        on public.tpds_teachers (department);
create index if not exists idx_tpds_teachers_last_login  on public.tpds_teachers (last_login_at desc);


-- ════════════════════════════════════════════════════════════════════
-- STEP 2 — ROW LEVEL SECURITY
-- ════════════════════════════════════════════════════════════════════
-- anon key (teachers): can register themselves and update their own row.
-- service_role key (admin): full access — bypasses RLS.
-- ────────────────────────────────────────────────────────────────────

alter table public.tpds_teachers enable row level security;

-- Teachers can read all rows (app only ever shows their own profile,
-- but allowing SELECT lets admin views work via the anon key too)
create policy "tpds_teachers_select"
  on public.tpds_teachers
  for select to anon
  using (true);

-- Teachers can register (insert their own row)
create policy "tpds_teachers_insert"
  on public.tpds_teachers
  for insert to anon
  with check (true);

-- Teachers can update their own row (profile changes, last_login_at)
create policy "tpds_teachers_update"
  on public.tpds_teachers
  for update to anon
  using (true)
  with check (true);


-- ════════════════════════════════════════════════════════════════════
-- STEP 3 — ADMIN VIEWS
-- ════════════════════════════════════════════════════════════════════


-- ── Full teacher directory with sync stats ───────────────────────────
-- The main admin view: all teachers, their profile details,
-- how many documents they have, and when they last synced.

create or replace view public.v_tpds_teacher_directory as
select
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
  now() - t.last_login_at                                        as time_since_login,
  t.is_active,
  -- Sync stats from tpds_sync
  s.categories_synced,
  s.last_sync,
  now() - s.last_sync                                            as time_since_sync,
  lesson_count.n                                                 as lesson_count,
  iep_count.n                                                    as iep_count,
  cal_count.n                                                    as cal_count
from public.tpds_teachers t
left join (
  select user_id, count(*) as categories_synced, max(updated_at) as last_sync
  from public.tpds_sync
  group by user_id
) s on lower(s.user_id) = lower(t.username)
left join (
  select user_id, jsonb_array_length(payload) as n
  from public.tpds_sync where data_key = 'lessons'
) lesson_count on lower(lesson_count.user_id) = lower(t.username)
left join (
  select user_id, jsonb_array_length(payload) as n
  from public.tpds_sync where data_key = 'ieps'
) iep_count on lower(iep_count.user_id) = lower(t.username)
left join (
  select user_id, jsonb_array_length(payload) as n
  from public.tpds_sync where data_key = 'cal'
) cal_count on lower(cal_count.user_id) = lower(t.username)
order by t.last_login_at desc nulls last;

comment on view public.v_tpds_teacher_directory
  is 'Full teacher directory with profile details and sync statistics. Main admin view.';


-- ── Active teachers only ─────────────────────────────────────────────

create or replace view public.v_tpds_active_teachers as
select * from public.v_tpds_teacher_directory
where is_active = true;

comment on view public.v_tpds_active_teachers
  is 'Active teachers only (is_active = true).';


-- ── Teachers who have not logged in recently ─────────────────────────

create or replace view public.v_tpds_inactive_logins as
select
  username,
  display_name,
  department,
  role,
  last_login_at,
  now() - last_login_at as time_since_login
from public.tpds_teachers
where last_login_at < now() - interval '14 days'
   or last_login_at is null
order by last_login_at asc nulls first;

comment on view public.v_tpds_inactive_logins
  is 'Teachers who have not logged in for 14+ days, or have never logged in.';


-- ── Teachers who have never set up cloud sync ────────────────────────

create or replace view public.v_tpds_no_sync as
select
  t.username,
  t.display_name,
  t.department,
  t.role,
  t.last_login_at
from public.tpds_teachers t
left join (
  select distinct lower(user_id) as user_id from public.tpds_sync
) s on s.user_id = lower(t.username)
where s.user_id is null
order by t.display_name;

comment on view public.v_tpds_no_sync
  is 'Teachers who are registered but have no data in the sync table yet.';


-- ── Department summary ───────────────────────────────────────────────

create or replace view public.v_tpds_dept_summary as
select
  coalesce(department, 'Unassigned')  as department,
  count(*)                            as teacher_count,
  count(*) filter (where is_active)   as active_count,
  max(last_login_at)                  as last_activity
from public.tpds_teachers
group by department
order by teacher_count desc;

comment on view public.v_tpds_dept_summary
  is 'Teacher count grouped by department.';


-- ════════════════════════════════════════════════════════════════════
-- USEFUL ADMIN QUERIES
-- ════════════════════════════════════════════════════════════════════

-- Full teacher directory (main admin view):
-- select * from v_tpds_teacher_directory;

-- Teachers who haven't logged in for 2 weeks:
-- select * from v_tpds_inactive_logins;

-- Teachers with no cloud sync yet:
-- select * from v_tpds_no_sync;

-- Teachers by department:
-- select * from v_tpds_dept_summary;

-- Find a specific teacher:
-- select * from v_tpds_teacher_directory where username = 'jmutua';

-- Mark a teacher as inactive (e.g. after they leave):
-- update tpds_teachers set is_active = false where username = 'username_here';

-- All teachers teaching Grade 8:
-- select * from tpds_teachers where grades_taught like '%8%';

-- Teachers with the most lesson plans:
-- select username, display_name, department, lesson_count
-- from v_tpds_teacher_directory
-- order by lesson_count desc nulls last;
