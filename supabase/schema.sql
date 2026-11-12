-- Chess Kids database schema for Supabase / PostgreSQL
-- Run this file in the Supabase SQL Editor for a new project.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null check (char_length(username) between 3 and 24),
  display_name text not null default 'שחקן Chess Kids',
  rating integer not null default 1200 check (rating between 100 and 4000),
  games_played integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.games (
  id uuid primary key default gen_random_uuid(),
  white_player uuid not null references public.profiles(id),
  black_player uuid references public.profiles(id),
  status text not null default 'waiting' check (status in ('waiting','active','finished','abandoned')),
  time_control text not null default '300+0',
  white_time_ms bigint not null default 300000,
  black_time_ms bigint not null default 300000,
  active_color text not null default 'w' check (active_color in ('w','b')),
  clock_started_at timestamptz,
  initial_fen text,
  current_fen text,
  pgn text,
  result text check (result is null or result in ('1-0','0-1','1/2-1/2')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz,
  constraint different_players check (black_player is null or black_player <> white_player)
);

alter table public.games add column if not exists white_time_ms bigint not null default 300000;
alter table public.games add column if not exists black_time_ms bigint not null default 300000;
alter table public.games add column if not exists active_color text not null default 'w';
alter table public.games add column if not exists clock_started_at timestamptz;

create table if not exists public.game_moves (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  ply integer not null check (ply > 0),
  player_id uuid not null references public.profiles(id),
  san text not null,
  uci text not null,
  fen_after text not null,
  created_at timestamptz not null default now(),
  unique (game_id, ply)
);

create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined','blocked')),
  created_at timestamptz not null default now(),
  unique (requester_id, addressee_id),
  check (requester_id <> addressee_id)
);

create table if not exists public.puzzles (
  id uuid primary key default gen_random_uuid(),
  fen text not null,
  solution_uci text[] not null,
  difficulty integer not null default 1 check (difficulty between 1 and 5),
  theme text,
  created_at timestamptz not null default now()
);

create index if not exists games_white_player_idx on public.games(white_player, created_at desc);
create index if not exists games_black_player_idx on public.games(black_player, created_at desc);
create index if not exists game_moves_game_ply_idx on public.game_moves(game_id, ply);
create index if not exists friendships_addressee_idx on public.friendships(addressee_id, status);

-- Create a profile automatically when a user signs up.
create or replace function public.handle_new_chess_kids_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested_username text;
begin
  requested_username := coalesce(
    nullif(new.raw_user_meta_data ->> 'username', ''),
    'player_' || substr(new.id::text, 1, 8)
  );

  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    requested_username,
    coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), 'שחקן Chess Kids')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_chess_kids_user_created on auth.users;
create trigger on_chess_kids_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_chess_kids_user();

alter table public.profiles enable row level security;
alter table public.games enable row level security;
alter table public.game_moves enable row level security;
alter table public.friendships enable row level security;
alter table public.puzzles enable row level security;

create policy "Profiles are visible to signed-in players"
  on public.profiles for select to authenticated using (true);
create policy "Players can create their own profile"
  on public.profiles for insert to authenticated with check (auth.uid() = id);
create policy "Players can update their own profile"
  on public.profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

create policy "Players can view their own games"
  on public.games for select to authenticated
  using (auth.uid() = white_player or auth.uid() = black_player);
create policy "Players can create games they participate in"
  on public.games for insert to authenticated
  with check (auth.uid() = white_player or auth.uid() = black_player);
create policy "Participants can update their games"
  on public.games for update to authenticated
  using (auth.uid() = white_player or auth.uid() = black_player)
  with check (auth.uid() = white_player or auth.uid() = black_player);

create policy "Participants can view game moves"
  on public.game_moves for select to authenticated
  using (exists (
    select 1 from public.games g
    where g.id = game_id and (g.white_player = auth.uid() or g.black_player = auth.uid())
  ));
create policy "Participants can add game moves"
  on public.game_moves for insert to authenticated
  with check (player_id = auth.uid() and exists (
    select 1 from public.games g
    where g.id = game_id and (g.white_player = auth.uid() or g.black_player = auth.uid())
  ));

create policy "Players can view their friendship requests"
  on public.friendships for select to authenticated
  using (requester_id = auth.uid() or addressee_id = auth.uid());
create policy "Players can send friendship requests"
  on public.friendships for insert to authenticated
  with check (requester_id = auth.uid());
create policy "Recipients can respond to friendship requests"
  on public.friendships for update to authenticated
  using (addressee_id = auth.uid())
  with check (addressee_id = auth.uid());

create policy "Signed-in players can view puzzles"
  on public.puzzles for select to authenticated using (true);


-- Queue for finding another player with the same time control.
create table if not exists public.matchmaking_queue (
  player_id uuid primary key references public.profiles(id) on delete cascade,
  time_control text not null,
  rating integer not null default 1200,
  status text not null default 'waiting' check (status in ('waiting','matched')),
  game_id uuid references public.games(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists matchmaking_queue_search_idx
  on public.matchmaking_queue(time_control, status, created_at);

alter table public.matchmaking_queue enable row level security;

create policy "Players can view their own matchmaking entry"
  on public.matchmaking_queue for select to authenticated
  using (player_id = auth.uid());
create policy "Players can join matchmaking as themselves"
  on public.matchmaking_queue for insert to authenticated
  with check (player_id = auth.uid());
create policy "Players can update their own waiting entry"
  on public.matchmaking_queue for update to authenticated
  using (player_id = auth.uid() and status = 'waiting')
  with check (player_id = auth.uid() and status = 'waiting' and game_id is null);
create policy "Players can leave their own queue entry"
  on public.matchmaking_queue for delete to authenticated
  using (player_id = auth.uid());

create or replace function public.join_matchmaking_queue(p_time_control text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_opponent uuid;
  v_game uuid;
  v_existing uuid;
  v_base_seconds integer;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;
  if p_time_control not in ('60+0','180+0','300+0','600+0') then
    raise exception 'Unsupported time control';
  end if;

  select game_id into v_existing
  from public.matchmaking_queue
  where player_id = v_user and status = 'matched';

  if v_existing is not null then
    return v_existing;
  end if;

  insert into public.matchmaking_queue(player_id, time_control, rating, status, game_id, created_at)
  select v_user, p_time_control, coalesce(p.rating, 1200), 'waiting', null, now()
  from public.profiles p
  where p.id = v_user
  on conflict (player_id) do update
    set time_control = excluded.time_control,
        rating = excluded.rating,
        status = 'waiting',
        game_id = null,
        created_at = now();

  select player_id into v_opponent
  from public.matchmaking_queue
  where time_control = p_time_control
    and status = 'waiting'
    and player_id <> v_user
  order by created_at
  limit 1
  for update skip locked;

  if v_opponent is null then
    return null;
  end if;

  v_base_seconds := greatest(1, split_part(p_time_control, '+', 1)::integer);
  insert into public.games(white_player, black_player, status, time_control, white_time_ms, black_time_ms, active_color, clock_started_at)
  values (v_opponent, v_user, 'active', p_time_control, v_base_seconds * 1000, v_base_seconds * 1000, 'w', now())
  returning id into v_game;

  update public.matchmaking_queue
  set status = 'matched', game_id = v_game
  where player_id in (v_user, v_opponent);

  return v_game;
end;
$$;

create or replace function public.leave_matchmaking_queue()
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  delete from public.matchmaking_queue
  where player_id = auth.uid() and status = 'waiting';
$$;

create or replace function public.acknowledge_matchmaking_game()
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  delete from public.matchmaking_queue
  where player_id = auth.uid() and status = 'matched';
$$;

revoke all on function public.join_matchmaking_queue(text) from public;
revoke all on function public.leave_matchmaking_queue() from public;
revoke all on function public.acknowledge_matchmaking_game() from public;
grant execute on function public.join_matchmaking_queue(text) to authenticated;
grant execute on function public.leave_matchmaking_queue() to authenticated;
grant execute on function public.acknowledge_matchmaking_game() to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'games') then
      alter publication supabase_realtime add table public.games;
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'game_moves') then
      alter publication supabase_realtime add table public.game_moves;
    end if;
  end if;
end;
$$;


-- Store each move and update the game in one transaction.
-- The function checks whose turn it is; the client still validates chess legality.
create or replace function public.record_chess_move(
  p_game_id uuid,
  p_player_id uuid,
  p_ply integer,
  p_san text,
  p_uci text,
  p_fen_after text,
  p_pgn text,
  p_result text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_white uuid;
  v_black uuid;
  v_status text;
  v_expected_ply integer;
  v_white_rating integer;
  v_black_rating integer;
  v_white_score numeric;
  v_white_expected numeric;
  v_white_time_ms bigint;
  v_black_time_ms bigint;
  v_active_color text;
  v_clock_started_at timestamptz;
  v_elapsed_ms bigint;
begin
  if p_player_id is null then
    raise exception 'Authentication required';
  end if;

  select white_player, black_player, status, white_time_ms, black_time_ms, active_color, clock_started_at
    into v_white, v_black, v_status, v_white_time_ms, v_black_time_ms, v_active_color, v_clock_started_at
  from public.games
  where id = p_game_id
  for update;

  if not found or (p_player_id <> v_white and p_player_id <> v_black) then
    raise exception 'Game not found or access denied';
  end if;

  if v_status <> 'active' then
    raise exception 'Game is not active';
  end if;

  if (p_ply % 2 = 1 and p_player_id <> v_white)
     or (p_ply % 2 = 0 and p_player_id <> v_black) then
    raise exception 'It is not this player turn';
  end if;
  if (v_active_color = 'w' and p_player_id <> v_white)
     or (v_active_color = 'b' and p_player_id <> v_black) then
    raise exception 'Clock turn does not match player turn';
  end if;

  v_elapsed_ms := case
    when v_clock_started_at is null then 0
    else greatest(0, floor(extract(epoch from (now() - v_clock_started_at)) * 1000)::bigint)
  end;

  if v_active_color = 'w' then
    v_white_time_ms := greatest(0, v_white_time_ms - v_elapsed_ms);
    if v_white_time_ms <= 0 then raise exception 'White clock expired'; end if;
  else
    v_black_time_ms := greatest(0, v_black_time_ms - v_elapsed_ms);
    if v_black_time_ms <= 0 then raise exception 'Black clock expired'; end if;
  end if;

  if p_result is not null and p_result not in ('1-0','0-1','1/2-1/2') then
    raise exception 'Invalid game result';
  end if;

  select coalesce(max(ply), 0) + 1 into v_expected_ply
  from public.game_moves
  where game_id = p_game_id;

  if p_ply <> v_expected_ply then
    raise exception 'Move sequence conflict';
  end if;

  insert into public.game_moves(game_id, ply, player_id, san, uci, fen_after)
  values (p_game_id, p_ply, p_player_id, p_san, p_uci, p_fen_after);

  update public.games
  set current_fen = p_fen_after,
      pgn = p_pgn,
      status = case when p_result is null then 'active' else 'finished' end,
      result = p_result,
      updated_at = now(),
      finished_at = case when p_result is null then null else now() end,
      white_time_ms = v_white_time_ms,
      black_time_ms = v_black_time_ms,
      active_color = case when v_active_color = 'w' then 'b' else 'w' end,
      clock_started_at = case when p_result is null then now() else null end
  where id = p_game_id;

  if p_result is not null and v_black is not null then
    select rating into v_white_rating from public.profiles where id = v_white for update;
    select rating into v_black_rating from public.profiles where id = v_black for update;
    v_white_score := case p_result when '1-0' then 1 when '0-1' then 0 else 0.5 end;
    v_white_expected := 1 / (1 + power(10::numeric, (v_black_rating - v_white_rating)::numeric / 400));
    update public.profiles
      set rating = greatest(100, round(v_white_rating + 32 * (v_white_score - v_white_expected))::integer),
          games_played = games_played + 1
      where id = v_white;
    update public.profiles
      set rating = greatest(100, round(v_black_rating + 32 * ((1 - v_white_score) - (1 - v_white_expected)))::integer),
          games_played = games_played + 1
      where id = v_black;
  end if;
end;
$$;

create or replace function public.abandon_chess_game(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  update public.games
  set status = 'abandoned', updated_at = now()
  where id = p_game_id
    and status = 'active'
    and (white_player = auth.uid() or black_player = auth.uid());
end;
$$;

revoke all on function public.record_chess_move(uuid, uuid, integer, text, text, text, text, text) from public;
revoke all on function public.record_chess_move(uuid, uuid, integer, text, text, text, text, text) from authenticated;
grant execute on function public.record_chess_move(uuid, uuid, integer, text, text, text, text, text) to service_role;
revoke all on function public.abandon_chess_game(uuid) from public;
grant execute on function public.abandon_chess_game(uuid) to authenticated;

-- Clients may edit display names/usernames, but cannot alter ratings or game records.
revoke insert, update on public.profiles from authenticated;
grant update (username, display_name) on public.profiles to authenticated;
revoke insert, update on public.games from authenticated;
revoke insert on public.game_moves from authenticated;


-- Admin permissions are granted only through trusted app_metadata set in Supabase.
create or replace function public.is_chess_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role' = 'admin', false);
$$;

create policy "Chess admins can view all games"
  on public.games for select to authenticated
  using (public.is_chess_admin());
create policy "Chess admins can view all game moves"
  on public.game_moves for select to authenticated
  using (public.is_chess_admin());
create policy "Chess admins can manage puzzles"
  on public.puzzles for all to authenticated
  using (public.is_chess_admin())
  with check (public.is_chess_admin());

create or replace function public.admin_set_player_rating(p_player_id uuid, p_rating integer)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_chess_admin() then
    raise exception 'Administrator access required';
  end if;
  if p_rating < 100 or p_rating > 4000 then
    raise exception 'Rating must be between 100 and 4000';
  end if;
  update public.profiles set rating = p_rating where id = p_player_id;
end;
$$;

revoke all on function public.is_chess_admin() from public;
revoke all on function public.admin_set_player_rating(uuid, integer) from public;
grant execute on function public.is_chess_admin() to authenticated;
grant execute on function public.admin_set_player_rating(uuid, integer) to authenticated;


-- Private game invitations. The short code is shared directly between players.
create table if not exists public.game_invites (
  id uuid primary key default gen_random_uuid(),
  inviter_id uuid not null references public.profiles(id) on delete cascade,
  invite_code text not null unique,
  time_control text not null,
  status text not null default 'pending' check (status in ('pending','accepted','declined','expired')),
  game_id uuid references public.games(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 minutes')
);

alter table public.game_invites enable row level security;
create policy "Inviters can view their own invitations"
  on public.game_invites for select to authenticated
  using (inviter_id = auth.uid());

create or replace function public.create_game_invite(p_time_control text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_code text;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;
  if p_time_control not in ('60+0','180+0','300+0','600+0') then
    raise exception 'Unsupported time control';
  end if;
  v_code := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 8));
  insert into public.game_invites(inviter_id, invite_code, time_control)
  values (v_user, v_code, p_time_control);
  return v_code;
end;
$$;

create or replace function public.accept_game_invite(p_invite_code text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_invite public.game_invites%rowtype;
  v_game uuid;
  v_base_seconds integer;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;

  select * into v_invite
  from public.game_invites
  where invite_code = upper(trim(p_invite_code))
  for update;

  if not found or v_invite.status <> 'pending' or v_invite.expires_at < now() then
    raise exception 'Invitation is invalid or expired';
  end if;
  if v_invite.inviter_id = v_user then
    raise exception 'You cannot accept your own invitation';
  end if;

  v_base_seconds := greatest(1, split_part(v_invite.time_control, '+', 1)::integer);
  insert into public.games(white_player, black_player, status, time_control, white_time_ms, black_time_ms, active_color, clock_started_at)
  values (v_invite.inviter_id, v_user, 'active', v_invite.time_control, v_base_seconds * 1000, v_base_seconds * 1000, 'w', now())
  returning id into v_game;

  update public.game_invites
  set status = 'accepted', game_id = v_game
  where id = v_invite.id;

  return v_game;
end;
$$;

revoke all on function public.create_game_invite(text) from public;
revoke all on function public.accept_game_invite(text) from public;
grant execute on function public.create_game_invite(text) to authenticated;
grant execute on function public.accept_game_invite(text) to authenticated;


-- Server-authoritative timeout adjudication.
create or replace function public.claim_game_timeout(p_game_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_white uuid;
  v_black uuid;
  v_status text;
  v_white_time_ms bigint;
  v_black_time_ms bigint;
  v_active_color text;
  v_clock_started_at timestamptz;
  v_elapsed_ms bigint;
  v_result text;
  v_white_rating integer;
  v_black_rating integer;
  v_white_score numeric;
  v_white_expected numeric;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select white_player, black_player, status, white_time_ms, black_time_ms, active_color, clock_started_at
    into v_white, v_black, v_status, v_white_time_ms, v_black_time_ms, v_active_color, v_clock_started_at
  from public.games
  where id = p_game_id
  for update;

  if not found or (auth.uid() <> v_white and auth.uid() <> v_black) then
    raise exception 'Game not found or access denied';
  end if;
  if v_status <> 'active' or v_clock_started_at is null then
    return null;
  end if;

  v_elapsed_ms := greatest(0, floor(extract(epoch from (now() - v_clock_started_at)) * 1000)::bigint);
  if v_active_color = 'w' then
    if v_white_time_ms - v_elapsed_ms > 0 then return null; end if;
    v_white_time_ms := 0;
    v_result := '0-1';
  else
    if v_black_time_ms - v_elapsed_ms > 0 then return null; end if;
    v_black_time_ms := 0;
    v_result := '1-0';
  end if;

  update public.games
  set status = 'finished',
      result = v_result,
      white_time_ms = v_white_time_ms,
      black_time_ms = v_black_time_ms,
      clock_started_at = null,
      finished_at = now(),
      updated_at = now()
  where id = p_game_id;

  if v_black is not null then
    select rating into v_white_rating from public.profiles where id = v_white for update;
    select rating into v_black_rating from public.profiles where id = v_black for update;
    v_white_score := case v_result when '1-0' then 1 else 0 end;
    v_white_expected := 1 / (1 + power(10::numeric, (v_black_rating - v_white_rating)::numeric / 400));
    update public.profiles
      set rating = greatest(100, round(v_white_rating + 32 * (v_white_score - v_white_expected))::integer),
          games_played = games_played + 1
      where id = v_white;
    update public.profiles
      set rating = greatest(100, round(v_black_rating + 32 * ((1 - v_white_score) - (1 - v_white_expected)))::integer),
          games_played = games_played + 1
      where id = v_black;
  end if;

  return v_result;
end;
$$;

revoke all on function public.claim_game_timeout(uuid) from public;
grant execute on function public.claim_game_timeout(uuid) to authenticated;
