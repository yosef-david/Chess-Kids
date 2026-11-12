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
  initial_fen text,
  current_fen text,
  pgn text,
  result text check (result is null or result in ('1-0','0-1','1/2-1/2')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz,
  constraint different_players check (black_player is null or black_player <> white_player)
);

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
