-- Touchline · Premier League database (PostgreSQL 14+)
-- Everything lives in its own schema "pl", so re-running this file only resets Touchline's tables.
-- Run:  psql -d football -f db/schema.sql  &&  psql -d football -f db/seed.sql

drop schema if exists pl cascade;
create schema pl;
set search_path = pl;
-- make every new pgAdmin Query Tool on this database find the tables without "pl." (takes effect on reconnect)
do $$ begin execute format('alter database %I set search_path = pl, public', current_database()); end $$;

-- ---------- enums (the admin UI reads these to build dropdowns)
create type position_code   as enum ('GK', 'DF', 'MF', 'FW');
create type foot            as enum ('left', 'right', 'both');
create type match_status    as enum ('scheduled', 'live', 'finished', 'postponed', 'abandoned');
create type event_type      as enum ('goal', 'penalty_goal', 'own_goal', 'penalty_miss', 'yellow_card', 'second_yellow', 'red_card', 'sub_on', 'sub_off', 'var_overturn');
create type staff_role      as enum ('manager', 'interim_manager', 'assistant', 'goalkeeping_coach', 'fitness_coach');
create type departure       as enum ('sacked', 'resigned', 'end_of_contract', 'end_of_interim', 'mutual_consent', 'other');
create type transfer_kind   as enum ('permanent', 'loan', 'free', 'loan_return', 'end_of_loan');
create type surface_kind    as enum ('grass', 'hybrid', 'artificial');

-- ---------- shared updated_at trigger
create function touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

-- ---------- seasons
create table seasons (
  id               serial primary key,
  name             text not null unique check (name ~ '^\d{4}/\d{2}$'),     -- '2026/27'
  start_date       date not null,
  end_date         date not null,
  matchweeks       smallint not null default 38 check (matchweeks between 1 and 60),
  points_win       smallint not null default 3,
  points_draw      smallint not null default 1,
  ucl_places       smallint not null default 4,
  uel_places       smallint not null default 1,
  uecl_places      smallint not null default 1,
  relegation_places smallint not null default 3,
  is_current       boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (end_date > start_date)
);
create unique index one_current_season on seasons (is_current) where is_current;

-- ---------- stadiums
create table stadiums (
  id           serial primary key,
  name         text not null unique,
  city         text not null,
  district     text,
  capacity     integer check (capacity > 0),
  opened_year  smallint check (opened_year between 1850 and 2100),
  surface      surface_kind not null default 'hybrid',
  latitude     numeric(9,6) check (latitude between -90 and 90),
  longitude    numeric(9,6) check (longitude between -180 and 180),
  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ---------- clubs
create table clubs (
  id               serial primary key,
  name             text not null unique,           -- 'Manchester City'
  short_name       text not null unique,           -- 'Man City'
  code             char(3) not null unique check (code ~ '^[A-Z]{3}$'),
  nickname         text,
  founded_year     smallint check (founded_year between 1850 and 2100),
  stadium_id       integer references stadiums on delete set null,
  primary_colour   char(7) not null default '#0a7d3e' check (primary_colour ~ '^#[0-9a-fA-F]{6}$'),
  secondary_colour char(7) check (secondary_colour ~ '^#[0-9a-fA-F]{6}$'),
  kit_manufacturer text,
  shirt_sponsor    text,
  sleeve_sponsor   text,
  website          text check (website ~ '^https?://'),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- which clubs play in which season (promotion/relegation), with any points deduction
create table season_clubs (
  id                serial primary key,
  season_id         integer not null references seasons on delete cascade,
  club_id           integer not null references clubs on delete cascade,
  points_deduction  smallint not null default 0 check (points_deduction >= 0),
  promoted          boolean not null default false,
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (season_id, club_id)
);

-- ---------- people
create table players (
  id             serial primary key,
  first_name     text,
  last_name      text not null,
  known_as       text,                                   -- 'Alisson', 'João Pedro'
  date_of_birth  date check (date_of_birth > '1950-01-01'),
  nationality    char(3),                                -- FIFA code, e.g. NOR
  position       position_code,
  preferred_foot foot,
  height_cm      smallint check (height_cm between 140 and 220),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- a player's time at a club in a season (handles mid-season moves and loans)
create table squad_registrations (
  id            serial primary key,
  season_id     integer not null references seasons on delete cascade,
  club_id       integer not null references clubs on delete cascade,
  player_id     integer not null references players on delete cascade,
  shirt_number  smallint check (shirt_number between 1 and 99),
  is_captain    boolean not null default false,
  on_loan       boolean not null default false,
  joined_on     date,
  left_on       date,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (season_id, club_id, player_id),
  check (left_on is null or joined_on is null or left_on >= joined_on)
);
create unique index one_shirt_per_number on squad_registrations (season_id, club_id, shirt_number) where left_on is null;

create table staff (
  id             serial primary key,
  first_name     text,
  last_name      text not null,
  nationality    char(3),
  date_of_birth  date,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- managerial spells: who ran which club and when, and how it ended
create table club_staff (
  id               serial primary key,
  club_id          integer not null references clubs on delete cascade,
  staff_id         integer not null references staff on delete cascade,
  season_id        integer references seasons on delete set null,
  role             staff_role not null default 'manager',
  appointed_on     date,
  left_on          date,
  departure_reason departure,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (left_on is null or appointed_on is null or left_on >= appointed_on)
);

create table referees (
  id           serial primary key,
  name         text not null unique,                   -- as published: 'M Oliver'
  full_name    text,
  nationality  char(3) default 'ENG',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ---------- matches
create table matches (
  id             serial primary key,
  season_id      integer not null references seasons on delete cascade,
  matchweek      smallint check (matchweek between 1 and 60),
  kickoff_at     timestamptz not null,
  home_club_id   integer not null references clubs on delete restrict,
  away_club_id   integer not null references clubs on delete restrict,
  stadium_id     integer references stadiums on delete set null,    -- null = home club's ground
  referee_id     integer references referees on delete set null,
  status         match_status not null default 'scheduled',
  home_goals     smallint check (home_goals >= 0),
  away_goals     smallint check (away_goals >= 0),
  home_ht_goals  smallint check (home_ht_goals >= 0),
  away_ht_goals  smallint check (away_ht_goals >= 0),
  attendance     integer check (attendance >= 0),
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (home_club_id <> away_club_id),
  check (status <> 'finished' or (home_goals is not null and away_goals is not null)),
  check (home_ht_goals is null or home_ht_goals <= home_goals),
  check (away_ht_goals is null or away_ht_goals <= away_goals),
  unique (season_id, home_club_id, away_club_id)       -- each pairing once per season
);
create index on matches (season_id, kickoff_at);

-- per-team numbers for one match
create table match_team_stats (
  id               serial primary key,
  match_id         integer not null references matches on delete cascade,
  club_id          integer not null references clubs on delete cascade,
  possession_pct   numeric(4,1) check (possession_pct between 0 and 100),
  expected_goals   numeric(4,2) check (expected_goals >= 0),
  shots            smallint check (shots >= 0),
  shots_on_target  smallint check (shots_on_target >= 0),
  corners          smallint check (corners >= 0),
  fouls            smallint check (fouls >= 0),
  offsides         smallint check (offsides >= 0),
  yellow_cards     smallint check (yellow_cards >= 0),
  red_cards        smallint check (red_cards >= 0),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (match_id, club_id),
  check (shots_on_target is null or shots is null or shots_on_target <= shots)
);

-- goals, cards and subs, minute by minute
create table match_events (
  id                serial primary key,
  match_id          integer not null references matches on delete cascade,
  club_id           integer not null references clubs on delete cascade,
  player_id         integer references players on delete set null,
  related_player_id integer references players on delete set null,  -- assist, or the player subbed off
  event             event_type not null,
  minute            smallint not null check (minute between 1 and 130),
  added_time        smallint not null default 0 check (added_time between 0 and 30),
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index on match_events (match_id);

-- season totals per player (kept directly for leaders the event log doesn't cover yet)
create table player_season_stats (
  id              serial primary key,
  season_id       integer not null references seasons on delete cascade,
  player_id       integer not null references players on delete cascade,
  club_id         integer not null references clubs on delete cascade,
  appearances     smallint not null default 0 check (appearances >= 0),
  minutes         integer not null default 0 check (minutes >= 0),
  goals           smallint not null default 0 check (goals >= 0),
  assists         smallint not null default 0 check (assists >= 0),
  clean_sheets    smallint not null default 0 check (clean_sheets >= 0),
  yellow_cards    smallint not null default 0 check (yellow_cards >= 0),
  red_cards       smallint not null default 0 check (red_cards >= 0),
  hat_tricks      smallint not null default 0 check (hat_tricks >= 0),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (season_id, player_id, club_id)
);

create table transfers (
  id            serial primary key,
  player_id     integer not null references players on delete cascade,
  from_club_id  integer references clubs on delete set null,   -- null = from outside the league
  to_club_id    integer references clubs on delete set null,
  season_id     integer references seasons on delete set null,
  kind          transfer_kind not null default 'permanent',
  transfer_date date not null,
  fee_gbp       numeric(12,0) check (fee_gbp >= 0),
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (from_club_id is distinct from to_club_id)
);

-- updated_at on every table
do $$ declare t text; begin
  for t in select table_name from information_schema.tables where table_schema = 'pl' and table_type = 'BASE TABLE' loop
    execute format('create trigger touch before update on pl.%I for each row execute function pl.touch()', t);
  end loop;
end $$;

-- ---------- read models (views) — the website reads these, never raw sums
-- one row per club per finished match, from that club's point of view
create view team_results as
select m.season_id, m.id as match_id, m.kickoff_at, m.matchweek, c.club_id, c.opponent_id, c.home,
       c.gf, c.ga, case when c.gf > c.ga then 'W' when c.gf = c.ga then 'D' else 'L' end as result
from matches m
cross join lateral (values (m.home_club_id, m.away_club_id, true,  m.home_goals, m.away_goals),
                           (m.away_club_id, m.home_club_id, false, m.away_goals, m.home_goals)) as c(club_id, opponent_id, home, gf, ga)
where m.status = 'finished';

create view standings as
with agg as (
  select sc.season_id, sc.club_id, sc.points_deduction,
         count(r.match_id)::int as played,
         count(*) filter (where r.result = 'W')::int as won,
         count(*) filter (where r.result = 'D')::int as drawn,
         count(*) filter (where r.result = 'L')::int as lost,
         coalesce(sum(r.gf), 0)::int as goals_for,
         coalesce(sum(r.ga), 0)::int as goals_against,
         count(*) filter (where r.ga = 0)::int as clean_sheets,
         (select string_agg(x.result, '' order by x.kickoff_at) from
            (select result, kickoff_at from team_results t where t.season_id = sc.season_id and t.club_id = sc.club_id order by kickoff_at desc limit 5) x) as form
  from season_clubs sc
  left join team_results r on r.season_id = sc.season_id and r.club_id = sc.club_id
  group by sc.season_id, sc.club_id, sc.points_deduction
)
select a.*, a.goals_for - a.goals_against as goal_difference,
       a.won * s.points_win + a.drawn * s.points_draw - a.points_deduction as points,
       rank() over (partition by a.season_id order by a.won * s.points_win + a.drawn * s.points_draw - a.points_deduction desc,
                    a.goals_for - a.goals_against desc, a.goals_for desc) as position
from agg a join seasons s on s.id = a.season_id;

-- leaders: season totals plus anything logged in match_events
create view player_leaders as
select ps.season_id, ps.player_id, ps.club_id,
       coalesce(p.known_as, concat_ws(' ', p.first_name, p.last_name)) as player,
       ps.appearances, ps.goals, ps.assists, ps.clean_sheets, ps.yellow_cards, ps.red_cards, ps.hat_tricks
from player_season_stats ps join players p on p.id = ps.player_id;

create view season_summary as
select s.id as season_id, s.name,
       count(m.id) filter (where m.status = 'finished')::int as played,
       count(m.id)::int as scheduled,
       coalesce(sum(m.home_goals + m.away_goals) filter (where m.status = 'finished'), 0)::int as goals,
       count(*) filter (where m.home_goals > m.away_goals)::int as home_wins,
       count(*) filter (where m.home_goals = m.away_goals)::int as draws,
       count(*) filter (where m.home_goals < m.away_goals)::int as away_wins,
       count(*) filter (where m.home_goals = 0 or m.away_goals = 0)::int
         + count(*) filter (where m.home_goals = 0 and m.away_goals = 0)::int as clean_sheets,
       (select coalesce(sum(t.yellow_cards), 0)::int from match_team_stats t join matches x on x.id = t.match_id where x.season_id = s.id) as yellow_cards,
       (select coalesce(sum(t.red_cards), 0)::int    from match_team_stats t join matches x on x.id = t.match_id where x.season_id = s.id) as red_cards
from seasons s left join matches m on m.season_id = s.id
group by s.id, s.name;

create view goals_by_matchweek as
select season_id, matchweek, count(*)::int as matches, sum(home_goals + away_goals)::int as goals
from matches where status = 'finished' and matchweek is not null
group by season_id, matchweek;
