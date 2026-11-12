-- Chess Kids community modules: clubs, moderated articles/blogs, and tournaments.
-- Run once in Supabase SQL Editor after schema.sql.

create table if not exists public.clubs (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 3 and 48),
  description text not null default '' check (char_length(description) <= 500),
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.club_members (
  club_id uuid not null references public.clubs(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  primary key (club_id,user_id)
);
create table if not exists public.community_posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  club_id uuid references public.clubs(id) on delete set null,
  kind text not null check (kind in ('article','blog')),
  title text not null check (char_length(title) between 5 and 100),
  body text not null check (char_length(body) between 30 and 8000),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create table if not exists public.content_reports (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts(id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null check (char_length(reason) between 5 and 300),
  created_at timestamptz not null default now(),
  unique(post_id,reporter_id)
);
create table if not exists public.tournaments (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 5 and 100),
  description text not null default '',
  time_control text not null default '300+0' check (time_control in ('60+0','180+0','300+0','600+0')),
  starts_at timestamptz not null,
  status text not null default 'scheduled' check (status in ('scheduled','live','finished','cancelled')),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create table if not exists public.tournament_entries (
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  player_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (tournament_id,player_id)
);

create index if not exists community_posts_status_date_idx on public.community_posts(status,created_at desc);
create index if not exists club_members_user_idx on public.club_members(user_id);
create index if not exists tournaments_date_idx on public.tournaments(starts_at);

alter table public.clubs enable row level security;
alter table public.club_members enable row level security;
alter table public.community_posts enable row level security;
alter table public.content_reports enable row level security;
alter table public.tournaments enable row level security;
alter table public.tournament_entries enable row level security;

drop policy if exists "Public can view clubs" on public.clubs;
create policy "Public can view clubs" on public.clubs for select using (true);
drop policy if exists "Signed in players can create clubs" on public.clubs;
create policy "Signed in players can create clubs" on public.clubs for insert to authenticated with check (created_by = auth.uid());
drop policy if exists "Club owners can update clubs" on public.clubs;
create policy "Club owners can update clubs" on public.clubs for update to authenticated using (created_by = auth.uid()) with check (created_by = auth.uid());
drop policy if exists "Club owners can delete clubs" on public.clubs;
create policy "Club owners can delete clubs" on public.clubs for delete to authenticated using (created_by = auth.uid());

drop policy if exists "Signed in players can view club memberships" on public.club_members;
create policy "Signed in players can view club memberships" on public.club_members for select to authenticated using (true);
drop policy if exists "Players can join clubs as themselves" on public.club_members;
create policy "Players can join clubs as themselves" on public.club_members for insert to authenticated with check (user_id = auth.uid() and role = 'member');
drop policy if exists "Players can leave clubs" on public.club_members;
create policy "Players can leave clubs" on public.club_members for delete to authenticated using (user_id = auth.uid());

drop policy if exists "Approved posts are public and authors see their drafts" on public.community_posts;
create policy "Approved posts are public and authors see their drafts" on public.community_posts for select using (status = 'approved' or author_id = auth.uid() or public.is_chess_admin());
drop policy if exists "Players can submit posts for review" on public.community_posts;
create policy "Players can submit posts for review" on public.community_posts for insert to authenticated with check (author_id = auth.uid() and status = 'pending');
drop policy if exists "Authors can edit pending posts" on public.community_posts;
create policy "Authors can edit pending posts" on public.community_posts for update to authenticated using (author_id = auth.uid() and status = 'pending') with check (author_id = auth.uid() and status = 'pending');
drop policy if exists "Admins can review community posts" on public.community_posts;
create policy "Admins can review community posts" on public.community_posts for update to authenticated using (public.is_chess_admin()) with check (public.is_chess_admin());
drop policy if exists "Authors and admins can delete posts" on public.community_posts;
create policy "Authors and admins can delete posts" on public.community_posts for delete to authenticated using ((author_id = auth.uid() and status = 'pending') or public.is_chess_admin());

drop policy if exists "Players can report content" on public.content_reports;
create policy "Players can report content" on public.content_reports for insert to authenticated with check (reporter_id = auth.uid());
drop policy if exists "Reporters and admins can view reports" on public.content_reports;
create policy "Reporters and admins can view reports" on public.content_reports for select to authenticated using (reporter_id = auth.uid() or public.is_chess_admin());

drop policy if exists "Public can view tournaments" on public.tournaments;
create policy "Public can view tournaments" on public.tournaments for select using (true);
drop policy if exists "Admins can manage tournaments" on public.tournaments;
create policy "Admins can manage tournaments" on public.tournaments for all to authenticated using (public.is_chess_admin()) with check (public.is_chess_admin());

drop policy if exists "Players can view tournament entries" on public.tournament_entries;
create policy "Players can view tournament entries" on public.tournament_entries for select to authenticated using (true);
drop policy if exists "Players can register themselves" on public.tournament_entries;
create policy "Players can register themselves" on public.tournament_entries for insert to authenticated with check (player_id = auth.uid());
drop policy if exists "Players can withdraw themselves" on public.tournament_entries;
create policy "Players can withdraw themselves" on public.tournament_entries for delete to authenticated using (player_id = auth.uid());
