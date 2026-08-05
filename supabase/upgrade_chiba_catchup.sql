-- ===========================================================================
-- ChibaLab Inventory — catch-up script
-- Brings this database up to date with everything the app's code expects:
-- comments, equipment, SOPs, chemical history, research asset versions/
-- links, chemical requests, PI oversight/console, feed, incidents, lab
-- document uploads, and developer-account protection.
--
-- This exists because the base schema.sql was never updated to include
-- ~13 incremental upgrade_*.sql files that PEARL's live database picked up
-- one at a time over months. This consolidates exactly what Chiba's fresh
-- database was still missing, in dependency order, with the PI/admin
-- bootstrap positioned before any guard trigger that would otherwise block it.
--
-- Safe to re-run — every statement checks "if not exists" first.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- lab-documents storage bucket (SDS / CoA / invoice uploads)
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('lab-documents', 'lab-documents', false)
on conflict (id) do nothing;

drop policy if exists "approved users manage lab documents" on storage.objects;
create policy "approved users manage lab documents"
  on storage.objects for all
  to authenticated
  using (bucket_id = 'lab-documents' and public.is_approved())
  with check (bucket_id = 'lab-documents' and public.is_approved());

-- ---------------------------------------------------------------------------
-- ownership_transfers — audit log for member offboarding/handover
-- ---------------------------------------------------------------------------
create table if not exists public.ownership_transfers (
  id uuid primary key default gen_random_uuid(),
  resource_type text not null check (resource_type in ('chemical', 'research_asset')),
  resource_id uuid not null,
  from_member uuid references public.profiles(id) on delete set null,
  from_member_name text,
  to_member uuid references public.profiles(id) on delete set null,
  to_member_name text,
  transferred_by uuid references public.profiles(id) on delete set null,
  transferred_by_name text,
  transferred_at timestamptz not null default now()
);

create index if not exists ownership_transfers_resource_idx
  on public.ownership_transfers (resource_type, resource_id, transferred_at desc);
create index if not exists ownership_transfers_member_idx
  on public.ownership_transfers (from_member, to_member, transferred_at desc);

alter table public.ownership_transfers enable row level security;

drop policy if exists "admins read ownership transfers" on public.ownership_transfers;
create policy "admins read ownership transfers"
  on public.ownership_transfers for select
  to authenticated
  using (public.is_approved() and public.current_user_role() = 'admin');

drop policy if exists "no direct ownership transfer writes" on public.ownership_transfers;
create policy "no direct ownership transfer writes"
  on public.ownership_transfers for all
  to authenticated
  using (false)
  with check (false);

-- ---------------------------------------------------------------------------
-- comments — shared across chemicals, research assets, equipment bookings,
-- projects, and feed posts (constraint widened to its final form directly,
-- rather than layering three narrower versions on top of each other)
-- ---------------------------------------------------------------------------
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  resource_type text not null check (resource_type in ('chemical', 'research_asset', 'equipment_booking', 'project', 'feed_post')),
  resource_id uuid not null,
  author_id uuid references public.profiles(id) on delete set null,
  author_name text,
  body text not null,
  created_at timestamptz not null default now(),
  edited_at timestamptz
);

alter table public.comments drop constraint if exists comments_resource_type_check;
alter table public.comments add constraint comments_resource_type_check
  check (resource_type in ('chemical', 'research_asset', 'equipment_booking', 'project', 'feed_post'));

create index if not exists comments_resource_idx on public.comments (resource_type, resource_id, created_at);
alter table public.comments enable row level security;

drop policy if exists "comments readable by parent visibility" on public.comments;
create policy "comments readable by parent visibility"
  on public.comments for select
  to authenticated
  using (
    public.is_approved()
    and (
      resource_type in ('chemical', 'equipment_booking', 'project', 'feed_post')
      or exists (
        select 1 from public.research_assets asset
        where asset.id = resource_id and asset.created_by = (select auth.uid())
      )
    )
  );

drop policy if exists "members add comments" on public.comments;
create policy "members add comments"
  on public.comments for insert
  to authenticated
  with check (
    public.is_approved()
    and public.current_user_role() in ('admin', 'member')
    and author_id = (select auth.uid())
  );

drop policy if exists "comment authors delete own comments" on public.comments;
create policy "comment authors delete own comments"
  on public.comments for delete
  to authenticated
  using (
    public.is_approved()
    and (author_id = (select auth.uid()) or public.current_user_role() = 'admin')
  );

-- ---------------------------------------------------------------------------
-- equipment + equipment_bookings
-- ---------------------------------------------------------------------------
create table if not exists public.equipment (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  location text,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.equipment_bookings (
  id uuid primary key default gen_random_uuid(),
  equipment_id uuid not null references public.equipment(id) on delete cascade,
  booked_by uuid references public.profiles(id) on delete set null,
  booked_by_name text,
  start_time timestamptz not null,
  end_time timestamptz not null,
  purpose text not null,
  related_research_asset_id uuid references public.research_assets(id) on delete set null,
  created_at timestamptz not null default now(),
  check (end_time > start_time)
);

create index if not exists equipment_bookings_equipment_time_idx
  on public.equipment_bookings (equipment_id, start_time, end_time);

create or replace function public.prevent_equipment_booking_overlap()
returns trigger
language plpgsql
as $$
begin
  if exists (
    select 1
    from public.equipment_bookings existing
    where existing.equipment_id = new.equipment_id
      and existing.id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid)
      and tstzrange(existing.start_time, existing.end_time, '[)') && tstzrange(new.start_time, new.end_time, '[)')
  ) then
    raise exception 'This equipment is already booked for that time.';
  end if;
  return new;
end $$;

drop trigger if exists equipment_booking_overlap_guard on public.equipment_bookings;
create trigger equipment_booking_overlap_guard
  before insert or update on public.equipment_bookings
  for each row execute function public.prevent_equipment_booking_overlap();

alter table public.equipment enable row level security;
alter table public.equipment_bookings enable row level security;

drop policy if exists "equipment readable by approved users" on public.equipment;
create policy "equipment readable by approved users"
  on public.equipment for select to authenticated
  using (public.is_approved());

drop policy if exists "members manage equipment" on public.equipment;
create policy "members manage equipment"
  on public.equipment for all to authenticated
  using (public.is_approved() and public.current_user_role() in ('admin', 'member'))
  with check (public.is_approved() and public.current_user_role() in ('admin', 'member'));

drop policy if exists "equipment bookings readable by approved users" on public.equipment_bookings;
create policy "equipment bookings readable by approved users"
  on public.equipment_bookings for select to authenticated
  using (public.is_approved());

drop policy if exists "members create equipment bookings" on public.equipment_bookings;
create policy "members create equipment bookings"
  on public.equipment_bookings for insert to authenticated
  with check (
    public.is_approved()
    and public.current_user_role() in ('admin', 'member')
    and booked_by = (select auth.uid())
  );

drop policy if exists "booking owners and admins delete bookings" on public.equipment_bookings;
create policy "booking owners and admins delete bookings"
  on public.equipment_bookings for delete to authenticated
  using (
    public.is_approved()
    and (booked_by = (select auth.uid()) or public.current_user_role() = 'admin')
  );

-- ---------------------------------------------------------------------------
-- sops — protocol library
-- ---------------------------------------------------------------------------
create table if not exists public.sops (
  id                  uuid primary key default gen_random_uuid(),
  title               text not null,
  body                text not null default '',
  related_chemical_ids uuid[] not null default '{}',
  related_equipment_id uuid references public.equipment(id) on delete set null,
  created_by          uuid references public.profiles(id) on delete set null,
  created_by_name     text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists sops_related_equipment_idx on public.sops (related_equipment_id);
alter table public.sops enable row level security;

drop policy if exists "sops readable by approved users" on public.sops;
create policy "sops readable by approved users"
  on public.sops for select
  to authenticated
  using (public.is_approved());

drop policy if exists "admins and members create sops" on public.sops;
create policy "admins and members create sops"
  on public.sops for insert
  to authenticated
  with check (public.is_approved() and public.current_user_role() in ('admin', 'member'));

drop policy if exists "admins and members edit sops" on public.sops;
create policy "admins and members edit sops"
  on public.sops for update
  to authenticated
  using (public.is_approved() and public.current_user_role() in ('admin', 'member'));

drop policy if exists "authors and admins delete sops" on public.sops;
create policy "authors and admins delete sops"
  on public.sops for delete
  to authenticated
  using (public.is_approved() and (created_by = (select auth.uid()) or public.current_user_role() = 'admin'));

-- ---------------------------------------------------------------------------
-- chemical_history — server-computed diff on every chemical update
-- ---------------------------------------------------------------------------
create table if not exists public.chemical_history (
  id              uuid primary key default gen_random_uuid(),
  chemical_id     uuid not null references public.chemicals(id) on delete cascade,
  changed_by      uuid references auth.users on delete set null,
  changed_by_name text,
  changed_at      timestamptz not null default now(),
  diff            jsonb not null
);

create index if not exists chemical_history_chemical_idx on public.chemical_history (chemical_id, changed_at desc);
alter table public.chemical_history enable row level security;

drop policy if exists "chemical history readable by approved users" on public.chemical_history;
create policy "chemical history readable by approved users"
  on public.chemical_history for select
  to authenticated
  using (public.is_approved());

create or replace function public.record_chemical_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  old_j jsonb := to_jsonb(old);
  new_j jsonb := to_jsonb(new);
  key text;
  computed_diff jsonb := '{}'::jsonb;
  ignore_cols text[] := array['updated_at'];
begin
  for key in select jsonb_object_keys(new_j) loop
    if key = any(ignore_cols) then
      continue;
    end if;
    if (old_j -> key) is distinct from (new_j -> key) then
      computed_diff := computed_diff || jsonb_build_object(key, jsonb_build_object('old', old_j -> key, 'new', new_j -> key));
    end if;
  end loop;

  if computed_diff <> '{}'::jsonb then
    insert into public.chemical_history (chemical_id, changed_by, changed_by_name, diff)
    values (
      new.id,
      auth.uid(),
      (select full_name from public.profiles where id = auth.uid()),
      computed_diff
    );
  end if;

  return new;
end;
$$;

drop trigger if exists record_chemical_history on public.chemicals;
create trigger record_chemical_history
  after update on public.chemicals
  for each row
  execute function public.record_chemical_history();

-- ---------------------------------------------------------------------------
-- research_assets: stable_id, versions, lineage links; chemical_requests
-- ---------------------------------------------------------------------------
alter table public.research_assets add column if not exists stable_id text;

create unique index if not exists research_assets_stable_id_idx
  on public.research_assets (stable_id)
  where stable_id is not null;

create or replace function public.next_research_asset_stable_id()
returns text
language sql
stable
set search_path = public
as $$
  select 'ChibaLab-RA-' || lpad((
    coalesce(max(nullif(regexp_replace(stable_id, '\D', '', 'g'), '')::bigint), 0) + 1
  )::text, 6, '0')
  from public.research_assets
  where stable_id ~ '^ChibaLab-RA-\d+$';
$$;

with existing as (
  select coalesce(max(nullif(regexp_replace(stable_id, '\D', '', 'g'), '')::bigint), 0) as max_n
  from public.research_assets
  where stable_id ~ '^ChibaLab-RA-\d+$'
),
numbered as (
  select id, row_number() over (order by created_at, id) as rn
  from public.research_assets
  where stable_id is null
)
update public.research_assets asset
set stable_id = 'ChibaLab-RA-' || lpad((existing.max_n + numbered.rn)::text, 6, '0')
from numbered, existing
where asset.id = numbered.id;

create table if not exists public.research_asset_versions (
  id                uuid primary key default gen_random_uuid(),
  research_asset_id uuid not null references public.research_assets on delete cascade,
  version_number    text not null,
  checksum          text,
  size_bytes        bigint,
  size_label        text,
  external_path     text,
  created_at        timestamptz not null default now(),
  notes             text,
  created_by        uuid references auth.users on delete set null,
  created_by_name   text
);

create index if not exists research_asset_versions_asset_idx
  on public.research_asset_versions (research_asset_id, created_at desc);
create unique index if not exists research_asset_versions_asset_version_idx
  on public.research_asset_versions (research_asset_id, version_number);

alter table public.research_asset_versions enable row level security;

drop policy if exists "research asset versions readable by owner" on public.research_asset_versions;
create policy "research asset versions readable by owner"
  on public.research_asset_versions for select
  to authenticated
  using (
    public.is_approved()
    and exists (
      select 1 from public.research_assets asset
      where asset.id = research_asset_id and asset.created_by = (select auth.uid())
    )
  );

drop policy if exists "members add research asset versions" on public.research_asset_versions;
create policy "members add research asset versions"
  on public.research_asset_versions for insert
  to authenticated
  with check (
    public.is_approved()
    and public.current_user_role() in ('admin', 'member')
    and created_by = (select auth.uid())
    and exists (
      select 1 from public.research_assets asset
      where asset.id = research_asset_id and asset.created_by = (select auth.uid())
    )
  );

drop policy if exists "members edit research asset versions" on public.research_asset_versions;
create policy "members edit research asset versions"
  on public.research_asset_versions for update
  to authenticated
  using (
    public.is_approved()
    and public.current_user_role() in ('admin', 'member')
    and created_by = (select auth.uid())
    and exists (
      select 1 from public.research_assets asset
      where asset.id = research_asset_id and asset.created_by = (select auth.uid())
    )
  )
  with check (
    public.is_approved()
    and public.current_user_role() in ('admin', 'member')
    and created_by = (select auth.uid())
    and exists (
      select 1 from public.research_assets asset
      where asset.id = research_asset_id and asset.created_by = (select auth.uid())
    )
  );

drop policy if exists "owners delete research asset versions" on public.research_asset_versions;
create policy "owners delete research asset versions"
  on public.research_asset_versions for delete
  to authenticated
  using (
    public.is_approved()
    and created_by = (select auth.uid())
    and exists (
      select 1 from public.research_assets asset
      where asset.id = research_asset_id and asset.created_by = (select auth.uid())
    )
  );

create table if not exists public.research_asset_links (
  id              uuid primary key default gen_random_uuid(),
  source_asset_id uuid not null references public.research_assets on delete cascade,
  target_asset_id uuid not null references public.research_assets on delete cascade,
  relationship    text not null check (relationship in ('derived_from', 'input_to', 'related_to')),
  created_at      timestamptz not null default now(),
  created_by      uuid references auth.users on delete set null,
  created_by_name text,
  notes           text,
  check (source_asset_id <> target_asset_id)
);

create index if not exists research_asset_links_source_idx on public.research_asset_links (source_asset_id);
create index if not exists research_asset_links_target_idx on public.research_asset_links (target_asset_id);
create unique index if not exists research_asset_links_unique_idx
  on public.research_asset_links (source_asset_id, target_asset_id, relationship);

alter table public.research_asset_links enable row level security;

drop policy if exists "research asset lineage readable by owner" on public.research_asset_links;
create policy "research asset lineage readable by owner"
  on public.research_asset_links for select
  to authenticated
  using (
    public.is_approved()
    and created_by = (select auth.uid())
    and exists (select 1 from public.research_assets source where source.id = source_asset_id and source.created_by = (select auth.uid()))
    and exists (select 1 from public.research_assets target where target.id = target_asset_id and target.created_by = (select auth.uid()))
  );

drop policy if exists "members manage research asset lineage" on public.research_asset_links;
create policy "members manage research asset lineage"
  on public.research_asset_links for all
  to authenticated
  using (
    public.is_approved()
    and public.current_user_role() in ('admin', 'member')
    and created_by = (select auth.uid())
    and exists (select 1 from public.research_assets source where source.id = source_asset_id and source.created_by = (select auth.uid()))
    and exists (select 1 from public.research_assets target where target.id = target_asset_id and target.created_by = (select auth.uid()))
  )
  with check (
    public.is_approved()
    and public.current_user_role() in ('admin', 'member')
    and created_by = (select auth.uid())
    and exists (select 1 from public.research_assets source where source.id = source_asset_id and source.created_by = (select auth.uid()))
    and exists (select 1 from public.research_assets target where target.id = target_asset_id and target.created_by = (select auth.uid()))
  );

create table if not exists public.chemical_requests (
  id                   uuid primary key default gen_random_uuid(),
  requested_by          uuid references auth.users on delete set null,
  requested_by_name     text,
  chemical_name_or_cas  text not null,
  quantity              text,
  supplier              text,
  justification_project text,
  status                text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'received')),
  requested_at          timestamptz not null default now(),
  decided_by            uuid references auth.users on delete set null,
  decided_by_name       text,
  decided_at            timestamptz,
  received_container_id uuid references public.chemicals on delete set null,
  notes                 text
);

create index if not exists chemical_requests_status_idx on public.chemical_requests (status, requested_at desc);
create index if not exists chemical_requests_requested_by_idx on public.chemical_requests (requested_by, requested_at desc);

alter table public.chemical_requests enable row level security;

drop policy if exists "chemical requests readable by approved users" on public.chemical_requests;
create policy "chemical requests readable by approved users"
  on public.chemical_requests for select
  to authenticated
  using (public.is_approved());

drop policy if exists "members create chemical requests" on public.chemical_requests;
create policy "members create chemical requests"
  on public.chemical_requests for insert
  to authenticated
  with check (public.is_approved() and public.current_user_role() in ('admin', 'member') and requested_by = (select auth.uid()));

drop policy if exists "requesters and admins update chemical requests" on public.chemical_requests;
create policy "requesters and admins update chemical requests"
  on public.chemical_requests for update
  to authenticated
  using (public.is_approved() and (public.current_user_role() = 'admin' or (requested_by = (select auth.uid()) and status = 'pending')))
  with check (public.is_approved() and (public.current_user_role() = 'admin' or (requested_by = (select auth.uid()) and status = 'pending')));

drop policy if exists "admins delete chemical requests" on public.chemical_requests;
create policy "admins delete chemical requests"
  on public.chemical_requests for delete
  to authenticated
  using (public.is_approved() and public.current_user_role() = 'admin');

-- ---------------------------------------------------------------------------
-- PI oversight: is_pi, projects, project_updates, notifications
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists is_pi boolean not null default false;

create or replace function public.is_pi()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select is_pi from public.profiles where id = (select auth.uid())), false);
$$;

revoke execute on function public.is_pi() from public;
grant execute on function public.is_pi() to authenticated;

create table if not exists public.projects (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  workspace   text not null default 'both' check (workspace in ('experimental', 'computational', 'both')),
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  archived    boolean not null default false
);

create unique index if not exists projects_name_idx on public.projects (lower(name));
alter table public.projects enable row level security;

drop policy if exists "projects readable by approved users" on public.projects;
create policy "projects readable by approved users"
  on public.projects for select
  to authenticated
  using (public.is_approved());

drop policy if exists "members create projects" on public.projects;
create policy "members create projects"
  on public.projects for insert
  to authenticated
  with check (public.is_approved() and (public.current_user_role() in ('admin', 'member') or public.is_pi()));

drop policy if exists "owners and admins manage projects" on public.projects;
create policy "owners and admins manage projects"
  on public.projects for update
  to authenticated
  using (public.is_approved() and (created_by = (select auth.uid()) or public.current_user_role() = 'admin' or public.is_pi()));

drop policy if exists "owners and admins delete projects" on public.projects;
create policy "owners and admins delete projects"
  on public.projects for delete
  to authenticated
  using (public.is_approved() and (created_by = (select auth.uid()) or public.current_user_role() = 'admin' or public.is_pi()));

create table if not exists public.project_updates (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid not null references public.projects(id) on delete cascade,
  author_id   uuid references public.profiles(id) on delete set null,
  author_name text,
  status      text not null default 'on_track' check (status in ('on_track', 'blocked', 'done', 'paused')),
  summary     text not null,
  created_at  timestamptz not null default now()
);

create index if not exists project_updates_project_idx on public.project_updates (project_id, created_at desc);
alter table public.project_updates enable row level security;

drop policy if exists "project updates readable by approved users" on public.project_updates;
create policy "project updates readable by approved users"
  on public.project_updates for select
  to authenticated
  using (public.is_approved());

drop policy if exists "members post project updates" on public.project_updates;
create policy "members post project updates"
  on public.project_updates for insert
  to authenticated
  with check (public.is_approved() and public.current_user_role() in ('admin', 'member') and author_id = (select auth.uid()));

drop policy if exists "authors and admins manage project updates" on public.project_updates;
create policy "authors and admins manage project updates"
  on public.project_updates for update
  to authenticated
  using (public.is_approved() and (author_id = (select auth.uid()) or public.current_user_role() = 'admin' or public.is_pi()));

drop policy if exists "authors and admins delete project updates" on public.project_updates;
create policy "authors and admins delete project updates"
  on public.project_updates for delete
  to authenticated
  using (public.is_approved() and (author_id = (select auth.uid()) or public.current_user_role() = 'admin' or public.is_pi()));

create table if not exists public.notifications (
  id           uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  actor_id     uuid references public.profiles(id) on delete set null,
  actor_name   text,
  project_id   uuid references public.projects(id) on delete cascade,
  message      text not null,
  created_at   timestamptz not null default now(),
  read_at      timestamptz
);

create index if not exists notifications_recipient_idx on public.notifications (recipient_id, created_at desc);
alter table public.notifications enable row level security;

drop policy if exists "recipients read own notifications" on public.notifications;
create policy "recipients read own notifications"
  on public.notifications for select
  to authenticated
  using (recipient_id = (select auth.uid()));

drop policy if exists "approved users send notifications" on public.notifications;
create policy "approved users send notifications"
  on public.notifications for insert
  to authenticated
  with check (public.is_approved() and (actor_id = (select auth.uid()) or actor_id is null));

drop policy if exists "recipients update own notifications" on public.notifications;
create policy "recipients update own notifications"
  on public.notifications for update
  to authenticated
  using (recipient_id = (select auth.uid()))
  with check (recipient_id = (select auth.uid()));

drop policy if exists "recipients delete own notifications" on public.notifications;
create policy "recipients delete own notifications"
  on public.notifications for delete
  to authenticated
  using (recipient_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- BOOTSTRAP — set the developer and the PI *before* any guard trigger exists
-- below. This must stay right here in the script, not moved to the end.
-- ---------------------------------------------------------------------------
update public.profiles set role = 'admin'
  where email = 'abedisyedaliabbas@gmail.com';

update public.profiles set role = 'admin', is_pi = true
  where email = 'chibaresearchgroup@gmail.com';

-- ---------------------------------------------------------------------------
-- project_members + PI-change guard (final version, single-PI enforced)
-- ---------------------------------------------------------------------------
create table if not exists public.project_members (
  project_id  uuid not null references public.projects(id) on delete cascade,
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  assigned_by uuid references public.profiles(id) on delete set null,
  assigned_at timestamptz not null default now(),
  primary key (project_id, profile_id)
);

alter table public.project_members enable row level security;

drop policy if exists "project members readable by approved users" on public.project_members;
create policy "project members readable by approved users"
  on public.project_members for select
  to authenticated
  using (public.is_approved());

drop policy if exists "pi and admins assign project members" on public.project_members;
create policy "pi and admins assign project members"
  on public.project_members for insert
  to authenticated
  with check (public.is_approved() and (public.is_pi() or public.current_user_role() = 'admin'));

drop policy if exists "pi and admins remove project members" on public.project_members;
create policy "pi and admins remove project members"
  on public.project_members for delete
  to authenticated
  using (public.is_approved() and (public.is_pi() or public.current_user_role() = 'admin'));

create unique index if not exists profiles_single_pi_idx on public.profiles ((is_pi)) where is_pi;

create or replace function public.guard_is_pi_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_is_pi boolean := public.is_pi();
begin
  if old.is_pi
     and not actor_is_pi
     and (
       new.role is distinct from old.role
       or new.approved is distinct from old.approved
       or new.is_pi is distinct from old.is_pi
     )
  then
    raise exception 'Only the PI can change or revoke the PI account''s access.'
      using errcode = '42501';
  end if;

  if new.is_pi is distinct from old.is_pi and not actor_is_pi then
    raise exception 'Only an existing PI can grant or revoke PI access.'
      using errcode = '42501';
  end if;

  if new.is_pi and not old.is_pi then
    update public.profiles set is_pi = false where id <> new.id and is_pi;
  end if;

  return new;
end;
$$;

drop trigger if exists guard_is_pi_change on public.profiles;
create trigger guard_is_pi_change
  before update on public.profiles
  for each row
  execute function public.guard_is_pi_change();

create or replace function public.guard_pi_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.is_pi and not public.is_pi() then
    raise exception 'Only the PI can delete the PI account.'
      using errcode = '42501';
  end if;
  return old;
end;
$$;

drop trigger if exists guard_pi_delete on public.profiles;
create trigger guard_pi_delete
  before delete on public.profiles
  for each row
  execute function public.guard_pi_delete();

-- ---------------------------------------------------------------------------
-- PI console: project fields, milestones, private supervision notes
-- ---------------------------------------------------------------------------
alter table public.projects add column if not exists description text;
alter table public.projects add column if not exists status text not null default 'active'
  check (status in ('active', 'on_hold', 'completed', 'archived'));
alter table public.projects add column if not exists target_date date;
alter table public.projects add column if not exists budget_amount numeric;

create or replace function public.sync_project_archived_status()
returns trigger
language plpgsql
as $$
begin
  if new.archived and new.status <> 'archived' then
    new.status := 'archived';
  elsif not new.archived and new.status = 'archived' then
    new.status := 'active';
  end if;
  return new;
end;
$$;

drop trigger if exists sync_project_archived_status on public.projects;
create trigger sync_project_archived_status
  before insert or update on public.projects
  for each row
  execute function public.sync_project_archived_status();

create table if not exists public.project_milestones (
  id                 uuid primary key default gen_random_uuid(),
  project_id         uuid not null references public.projects(id) on delete cascade,
  title              text not null,
  status             text not null default 'todo' check (status in ('todo', 'in_progress', 'done')),
  assignee_member_id uuid references public.profiles(id) on delete set null,
  due_date           date,
  created_at         timestamptz not null default now()
);

create index if not exists project_milestones_project_idx on public.project_milestones (project_id);
alter table public.project_milestones enable row level security;

drop policy if exists "milestones readable by approved users" on public.project_milestones;
create policy "milestones readable by approved users"
  on public.project_milestones for select
  to authenticated
  using (public.is_approved());

drop policy if exists "admins and pi create milestones" on public.project_milestones;
create policy "admins and pi create milestones"
  on public.project_milestones for insert
  to authenticated
  with check (public.is_approved() and (public.current_user_role() = 'admin' or public.is_pi()));

drop policy if exists "admins pi and assignee update milestones" on public.project_milestones;
create policy "admins pi and assignee update milestones"
  on public.project_milestones for update
  to authenticated
  using (public.is_approved() and (public.current_user_role() = 'admin' or public.is_pi() or assignee_member_id = (select auth.uid())));

drop policy if exists "admins and pi delete milestones" on public.project_milestones;
create policy "admins and pi delete milestones"
  on public.project_milestones for delete
  to authenticated
  using (public.is_approved() and (public.current_user_role() = 'admin' or public.is_pi()));

create table if not exists public.pi_notes (
  id         uuid primary key default gen_random_uuid(),
  member_id  uuid not null references public.profiles(id) on delete cascade,
  author_id  uuid references public.profiles(id) on delete set null,
  author_name text,
  body       text not null,
  created_at timestamptz not null default now()
);

create index if not exists pi_notes_member_idx on public.pi_notes (member_id, created_at desc);
alter table public.pi_notes enable row level security;

drop policy if exists "admins read notes not about themselves" on public.pi_notes;
create policy "admins read notes not about themselves"
  on public.pi_notes for select
  to authenticated
  using (public.is_approved() and public.current_user_role() = 'admin' and member_id <> (select auth.uid()));

drop policy if exists "admins write notes not about themselves" on public.pi_notes;
create policy "admins write notes not about themselves"
  on public.pi_notes for insert
  to authenticated
  with check (public.is_approved() and public.current_user_role() = 'admin' and author_id = (select auth.uid()) and member_id <> (select auth.uid()));

drop policy if exists "authors delete their own notes" on public.pi_notes;
create policy "authors delete their own notes"
  on public.pi_notes for delete
  to authenticated
  using (public.is_approved() and public.current_user_role() = 'admin' and author_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- feed_posts + feed_post_likes + feed-images bucket
-- ---------------------------------------------------------------------------
create table if not exists public.feed_posts (
  id                   uuid primary key default gen_random_uuid(),
  author_id            uuid references public.profiles(id) on delete set null,
  author_name          text,
  body                 text not null,
  image_url            text,
  linked_resource_type text check (linked_resource_type in ('chemical', 'research_asset', 'project')),
  linked_resource_id   uuid,
  cross_post_to_teams  boolean not null default false,
  created_at           timestamptz not null default now()
);

create index if not exists feed_posts_created_idx on public.feed_posts (created_at desc);
alter table public.feed_posts enable row level security;

drop policy if exists "feed posts readable by approved users" on public.feed_posts;
create policy "feed posts readable by approved users"
  on public.feed_posts for select
  to authenticated
  using (public.is_approved());

drop policy if exists "any approved member can post to the feed" on public.feed_posts;
create policy "any approved member can post to the feed"
  on public.feed_posts for insert
  to authenticated
  with check (public.is_approved() and author_id = (select auth.uid()));

drop policy if exists "authors and admins delete feed posts" on public.feed_posts;
create policy "authors and admins delete feed posts"
  on public.feed_posts for delete
  to authenticated
  using (public.is_approved() and (author_id = (select auth.uid()) or public.current_user_role() = 'admin'));

create table if not exists public.feed_post_likes (
  post_id    uuid not null references public.feed_posts(id) on delete cascade,
  member_id  uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, member_id)
);

alter table public.feed_post_likes enable row level security;

drop policy if exists "likes readable by approved users" on public.feed_post_likes;
create policy "likes readable by approved users"
  on public.feed_post_likes for select
  to authenticated
  using (public.is_approved());

drop policy if exists "approved members can like" on public.feed_post_likes;
create policy "approved members can like"
  on public.feed_post_likes for insert
  to authenticated
  with check (public.is_approved() and member_id = (select auth.uid()));

drop policy if exists "members can unlike their own like" on public.feed_post_likes;
create policy "members can unlike their own like"
  on public.feed_post_likes for delete
  to authenticated
  using (member_id = (select auth.uid()));

create or replace function public.teams_on_feed_post()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.cross_post_to_teams and exists (select 1 from pg_proc where proname = 'notify_teams_async') then
    perform public.notify_teams_async(format('%s posted to the feed: %s', coalesce(new.author_name, 'Someone'), left(new.body, 200)));
  end if;
  return new;
end;
$$;

drop trigger if exists teams_on_feed_post on public.feed_posts;
create trigger teams_on_feed_post
  after insert on public.feed_posts
  for each row
  execute function public.teams_on_feed_post();

insert into storage.buckets (id, name, public)
values ('feed-images', 'feed-images', false)
on conflict (id) do nothing;

drop policy if exists "approved users manage feed images" on storage.objects;
create policy "approved users manage feed images"
  on storage.objects for all
  to authenticated
  using (bucket_id = 'feed-images' and public.is_approved())
  with check (bucket_id = 'feed-images' and public.is_approved());

-- ---------------------------------------------------------------------------
-- incident_reports (needs notifications + is_pi, both created above)
-- ---------------------------------------------------------------------------
create table if not exists public.incident_reports (
  id            uuid primary key default gen_random_uuid(),
  reported_by   uuid references public.profiles(id) on delete set null,
  reported_by_name text,
  resource_type text check (resource_type in ('chemical', 'equipment', 'other')),
  resource_id   uuid,
  severity      text not null default 'near_miss' check (severity in ('near_miss', 'minor', 'major')),
  description   text not null,
  occurred_at   timestamptz not null default now(),
  actions_taken text,
  created_at    timestamptz not null default now()
);

create index if not exists incident_reports_created_idx on public.incident_reports (created_at desc);
alter table public.incident_reports enable row level security;

drop policy if exists "incident reports readable by approved users" on public.incident_reports;
create policy "incident reports readable by approved users"
  on public.incident_reports for select
  to authenticated
  using (public.is_approved());

drop policy if exists "any approved member can file an incident report" on public.incident_reports;
create policy "any approved member can file an incident report"
  on public.incident_reports for insert
  to authenticated
  with check (public.is_approved() and reported_by = (select auth.uid()));

drop policy if exists "authors and admins edit incident reports" on public.incident_reports;
create policy "authors and admins edit incident reports"
  on public.incident_reports for update
  to authenticated
  using (public.is_approved() and (reported_by = (select auth.uid()) or public.current_user_role() = 'admin'));

drop policy if exists "authors and admins delete incident reports" on public.incident_reports;
create policy "authors and admins delete incident reports"
  on public.incident_reports for delete
  to authenticated
  using (public.is_approved() and (reported_by = (select auth.uid()) or public.current_user_role() = 'admin'));

create or replace function public.notify_on_incident_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notifications (recipient_id, actor_id, actor_name, message)
  select p.id, new.reported_by, new.reported_by_name,
         format('New %s incident report: %s', new.severity, left(new.description, 140))
  from public.profiles p
  where p.approved and (p.role = 'admin' or p.is_pi);
  return new;
end;
$$;

drop trigger if exists notify_on_incident_report on public.incident_reports;
create trigger notify_on_incident_report
  after insert on public.incident_reports
  for each row
  execute function public.notify_on_incident_report();

-- ---------------------------------------------------------------------------
-- Protect the developer account (abedisyedaliabbas@gmail.com) — must run
-- after the bootstrap UPDATE above, not before.
-- ---------------------------------------------------------------------------
create or replace function public.guard_developer_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  developer_email constant text := 'abedisyedaliabbas@gmail.com';
begin
  if tg_op = 'DELETE' and lower(old.email) = developer_email then
    raise exception 'The ChibaLab developer account cannot be deleted.';
  end if;

  if tg_op = 'UPDATE' and lower(old.email) = developer_email then
    if auth.uid() is distinct from old.id and (
      new.email is distinct from old.email or
      new.role is distinct from old.role or
      new.approved is distinct from old.approved or
      new.is_pi is distinct from old.is_pi
    ) then
      raise exception 'The ChibaLab developer account cannot be changed by another account.';
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists guard_developer_profile_update on public.profiles;
create trigger guard_developer_profile_update
  before update on public.profiles
  for each row
  execute function public.guard_developer_profile();

drop trigger if exists guard_developer_profile_delete on public.profiles;
create trigger guard_developer_profile_delete
  before delete on public.profiles
  for each row
  execute function public.guard_developer_profile();

-- ---------------------------------------------------------------------------
-- Repaired handle_new_user (defensive null-email handling)
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  is_first boolean;
begin
  select count(*) = 0 into is_first from public.profiles;

  insert into public.profiles (id, email, full_name, role, approved, has_password)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), split_part(coalesce(new.email, ''), '@', 1)),
    case when is_first then 'admin' else 'viewer' end,
    is_first,
    new.encrypted_password is not null and new.encrypted_password <> ''
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_user();

notify pgrst, 'reload schema';
