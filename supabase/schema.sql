-- Trigger Log: daily check-ins, one row per person per day.
-- Run this once in the Supabase SQL Editor for the project.
-- Each person can only read and write their own rows (row-level security).

create table if not exists public.checkins (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  day         date not null,
  meals       text not null default '' check (char_length(meals) <= 2000),
  note        text not null default '' check (char_length(note) <= 2000),
  symptoms    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint checkins_one_per_day unique (user_id, day)
);

-- Keep symptom scores to the 0 to 5 scale the app uses.
-- (Postgres check constraints cannot contain subqueries, so this is a trigger.)
create or replace function public.validate_symptoms()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  k text;
  v jsonb;
begin
  if jsonb_typeof(new.symptoms) <> 'object' then
    raise exception 'symptoms must be a JSON object';
  end if;
  for k, v in select * from jsonb_each(new.symptoms) loop
    if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric not between 0 and 5 then
      raise exception 'symptom % must be a number from 0 to 5', k;
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists checkins_validate_symptoms on public.checkins;
create trigger checkins_validate_symptoms
  before insert or update on public.checkins
  for each row execute function public.validate_symptoms();

-- Turn on row-level security. Without this policy set, nobody can read or write.
alter table public.checkins enable row level security;

-- Logged-in users can see only their own check-ins.
create policy "read own checkins"
  on public.checkins for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- Logged-in users can add check-ins only for themselves.
create policy "insert own checkins"
  on public.checkins for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

-- Logged-in users can change only their own check-ins.
create policy "update own checkins"
  on public.checkins for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- Logged-in users can delete only their own check-ins (supports "delete my data").
create policy "delete own checkins"
  on public.checkins for delete
  to authenticated
  using ((select auth.uid()) = user_id);

-- Anonymous visitors get nothing from this table.
revoke all on public.checkins from anon;
grant select, insert, update, delete on public.checkins to authenticated;

-- Keep updated_at current.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists checkins_touch_updated_at on public.checkins;
create trigger checkins_touch_updated_at
  before update on public.checkins
  for each row execute function public.touch_updated_at();
