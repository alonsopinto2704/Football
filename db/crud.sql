-- Touchline · CRUD queries for every table (run after schema.sql + seed.sql)
-- In pgAdmin: select one block and press F5 (Execute script) to run just that block.
-- Each table: CREATE (insert) · READ (select) · UPDATE · DELETE. Values here are examples.
set search_path = pl;

-- =====================================================================
-- seasons
-- =====================================================================
insert into seasons (name, start_date, end_date, is_current) values ('2027/28', '2027-08-14', '2028-05-21', false) returning *;
select * from seasons order by start_date;
update seasons set matchweeks = 38, relegation_places = 3 where name = '2027/28' returning *;
delete from seasons where name = '2027/28';

-- =====================================================================
-- stadiums
-- =====================================================================
insert into stadiums (name, city, capacity, opened_year, surface) values ('Wembley Stadium', 'London', 90000, 2007, 'hybrid') returning *;
select * from stadiums order by capacity desc;
update stadiums set capacity = 90652 where name = 'Wembley Stadium' returning *;
delete from stadiums where name = 'Wembley Stadium';

-- =====================================================================
-- clubs
-- =====================================================================
insert into clubs (name, short_name, code, nickname, founded_year, primary_colour, stadium_id)
values ('West Ham United', 'West Ham', 'WHU', 'The Hammers', 1895, '#7a263a', null) returning *;
select c.code, c.name, c.nickname, s.name as stadium, s.capacity, c.kit_manufacturer, c.shirt_sponsor
from clubs c left join stadiums s on s.id = c.stadium_id order by c.name;
update clubs set shirt_sponsor = 'Betway', website = 'https://www.whufc.com' where code = 'WHU' returning *;
delete from clubs where code = 'WHU';

-- =====================================================================
-- season_clubs (which clubs are in which season)
-- =====================================================================
insert into season_clubs (season_id, club_id, points_deduction, notes)
values ((select id from seasons where is_current), (select id from clubs where code = 'ARS'), 0, 'example') on conflict (season_id, club_id) do nothing;
select s.name as season, c.name as club, sc.promoted, sc.points_deduction
from season_clubs sc join seasons s on s.id = sc.season_id join clubs c on c.id = sc.club_id order by c.name;
update season_clubs set points_deduction = 2, notes = 'Financial breach'
where club_id = (select id from clubs where code = 'HUL') and season_id = (select id from seasons where is_current) returning *;
update season_clubs set points_deduction = 0, notes = null where club_id = (select id from clubs where code = 'HUL');  -- undo
-- delete from season_clubs where club_id = (select id from clubs where code = 'HUL');  -- removes Hull from the season

-- =====================================================================
-- players
-- =====================================================================
insert into players (first_name, last_name, known_as, date_of_birth, nationality, position, preferred_foot, height_cm)
values ('Bukayo', 'Saka', 'Bukayo Saka', '2001-09-05', 'ENG', 'FW', 'left', 178) returning *;
select id, known_as, nationality, position, preferred_foot, height_cm, date_part('year', age(date_of_birth)) as age
from players order by last_name;
update players set height_cm = 178, position = 'MF' where known_as = 'Bukayo Saka' returning *;
delete from players where known_as = 'Bukayo Saka';

-- =====================================================================
-- squad_registrations (player ↔ club ↔ season, shirt number)
-- =====================================================================
insert into squad_registrations (season_id, club_id, player_id, shirt_number, joined_on)
values ((select id from seasons where is_current), (select id from clubs where code = 'MCI'),
        (select id from players where known_as = 'Erling Haaland'), 9, '2026-07-01')
on conflict (season_id, club_id, player_id) do update set shirt_number = excluded.shirt_number returning *;
select c.short_name as club, r.shirt_number, p.known_as, p.position, r.is_captain, r.on_loan
from squad_registrations r join clubs c on c.id = r.club_id join players p on p.id = r.player_id order by c.short_name, r.shirt_number;
update squad_registrations set on_loan = true where player_id = (select id from players where known_as = 'Erling Haaland') returning *;
update squad_registrations set on_loan = false where player_id = (select id from players where known_as = 'Erling Haaland');  -- undo
-- delete from squad_registrations where player_id = (select id from players where known_as = 'Erling Haaland');

-- =====================================================================
-- staff + club_staff (managers and their spells)
-- =====================================================================
insert into staff (first_name, last_name, nationality) values ('Thomas', 'Frank', 'DEN') returning *;
insert into club_staff (club_id, staff_id, season_id, role, appointed_on)
values ((select id from clubs where code = 'TOT'), (select id from staff where last_name = 'Frank'), (select id from seasons where is_current), 'assistant', '2026-10-20') returning *;
select c.short_name as club, s.first_name || ' ' || s.last_name as name, cs.role, cs.appointed_on, cs.left_on, cs.departure_reason
from club_staff cs join clubs c on c.id = cs.club_id join staff s on s.id = cs.staff_id order by c.short_name, cs.left_on nulls last;
update club_staff set left_on = '2026-10-21', departure_reason = 'mutual_consent'
where staff_id = (select id from staff where last_name = 'Frank') returning *;
delete from club_staff where staff_id = (select id from staff where last_name = 'Frank');
delete from staff where last_name = 'Frank';

-- =====================================================================
-- referees
-- =====================================================================
insert into referees (name, full_name) values ('T Robinson', 'Tim Robinson') on conflict (name) do nothing returning *;
select r.name, r.full_name, count(m.id) as matches from referees r left join matches m on m.referee_id = r.id group by r.id order by matches desc;
update referees set full_name = 'Michael Oliver' where name = 'M Oliver' returning *;
delete from referees where name = 'T Robinson';

-- =====================================================================
-- matches
-- =====================================================================
-- schedule a fixture (matchweek 8)
insert into matches (season_id, matchweek, kickoff_at, home_club_id, away_club_id, status)
values ((select id from seasons where is_current), 8, '2026-10-24 15:00 Europe/London',
        (select id from clubs where code = 'ARS'), (select id from clubs where code = 'AVL'), 'scheduled') returning *;
-- results & fixtures, newest first
select m.id, m.matchweek, m.kickoff_at at time zone 'Europe/London' as kickoff, h.short_name as home,
       coalesce(m.home_goals || '–' || m.away_goals, 'v') as score, a.short_name as away, m.status, r.name as referee
from matches m join clubs h on h.id = m.home_club_id join clubs a on a.id = m.away_club_id left join referees r on r.id = m.referee_id
order by m.kickoff_at desc;
-- enter a result
update matches set status = 'finished', home_goals = 2, away_goals = 0, home_ht_goals = 1, away_ht_goals = 0, attendance = 60150
where home_club_id = (select id from clubs where code = 'ARS') and away_club_id = (select id from clubs where code = 'AVL') returning *;
delete from matches where home_club_id = (select id from clubs where code = 'ARS') and away_club_id = (select id from clubs where code = 'AVL');

-- =====================================================================
-- match_team_stats
-- =====================================================================
insert into match_team_stats (match_id, club_id, possession_pct, shots, shots_on_target, corners, fouls)
select m.id, m.home_club_id, 58.5, 14, 6, 7, 9 from matches m where m.status = 'scheduled' order by m.kickoff_at limit 1 returning *;
select h.short_name as club, t.possession_pct, t.expected_goals, t.shots, t.shots_on_target, t.corners, t.fouls, t.yellow_cards, t.red_cards
from match_team_stats t join clubs h on h.id = t.club_id order by t.match_id desc, t.club_id;
update match_team_stats set offsides = 2 where possession_pct = 58.5 returning *;
delete from match_team_stats where possession_pct = 58.5;

-- =====================================================================
-- match_events (goals, cards, subs)
-- =====================================================================
insert into match_events (match_id, club_id, player_id, related_player_id, event, minute, added_time)
select m.id, m.away_club_id, (select id from players where known_as = 'Erling Haaland'), null, 'goal', 90, 3
from matches m where m.home_club_id = (select id from clubs where code = 'LIV') and m.away_club_id = (select id from clubs where code = 'MCI') returning *;
select e.minute || coalesce('+' || nullif(e.added_time, 0), '') as min, c.short_name as club, e.event, p.known_as as player, rp.known_as as assist_or_off
from match_events e join clubs c on c.id = e.club_id left join players p on p.id = e.player_id left join players rp on rp.id = e.related_player_id
order by e.match_id, e.minute, e.added_time;
update match_events set minute = 88, added_time = 0 where event = 'goal' and minute = 90 returning *;
delete from match_events where event = 'goal' and minute = 88;

-- =====================================================================
-- player_season_stats
-- =====================================================================
insert into player_season_stats (season_id, player_id, club_id, appearances, goals, assists)
values ((select id from seasons where is_current), (select id from players where known_as = 'Bruno Fernandes'), (select id from clubs where code = 'MUN'), 6, 3, 4)
on conflict (season_id, player_id, club_id) do update set appearances = excluded.appearances, assists = excluded.assists returning *;
select * from player_leaders order by goals desc, player limit 10;
update player_season_stats set goals = goals + 1 where player_id = (select id from players where known_as = 'Erling Haaland') returning *;
update player_season_stats set goals = goals - 1 where player_id = (select id from players where known_as = 'Erling Haaland');  -- undo
-- delete from player_season_stats where player_id = (select id from players where known_as = 'Bruno Fernandes');

-- =====================================================================
-- transfers
-- =====================================================================
insert into transfers (player_id, from_club_id, to_club_id, season_id, kind, transfer_date, fee_gbp)
values ((select id from players where known_as = 'Alexander Isak'), (select id from clubs where code = 'NEW'), (select id from clubs where code = 'LIV'),
        null, 'permanent', '2025-09-01', 125000000) returning *;
select p.known_as, f.short_name as from_club, t.short_name as to_club, tr.kind, tr.transfer_date, to_char(tr.fee_gbp, 'FM£999,999,999') as fee
from transfers tr join players p on p.id = tr.player_id left join clubs f on f.id = tr.from_club_id left join clubs t on t.id = tr.to_club_id
order by tr.transfer_date desc;
update transfers set notes = 'British record fee' where fee_gbp = 125000000 returning *;
delete from transfers where fee_gbp = 125000000;

-- =====================================================================
-- reports (views) — what the website shows
-- =====================================================================
-- league table
select st.position, c.short_name as club, st.played as p, st.won as w, st.drawn as d, st.lost as l,
       st.goals_for as gf, st.goals_against as ga, st.goal_difference as gd, st.points as pts, st.form
from standings st join clubs c on c.id = st.club_id
where st.season_id = (select id from seasons where is_current) order by st.position, c.short_name;
-- season so far
select * from season_summary where season_id = (select id from seasons where is_current);
-- goals per matchweek
select matchweek, matches, goals, round(goals::numeric / matches, 2) as per_match from goals_by_matchweek order by matchweek;
-- golden glove race
select player, c.short_name as club, clean_sheets from player_leaders pl join clubs c on c.id = pl.club_id where clean_sheets > 0 order by clean_sheets desc;
-- home vs away record for one club
select home, count(*) filter (where result = 'W') as w, count(*) filter (where result = 'D') as d, count(*) filter (where result = 'L') as l, sum(gf) as gf, sum(ga) as ga
from team_results where club_id = (select id from clubs where code = 'ARS') group by home;
