// Touchline backend: serves index.html and a JSON API over the "pl" schema in PostgreSQL.
//   GET    /api/site              everything the public pages show (current season)
//   GET    /api/meta              tables + columns (types, enums, foreign keys) for the Manage page
//   GET    /api/options/:table    id + label pairs for foreign-key dropdowns
//   GET    /api/t/:table          list rows            POST   /api/t/:table       create
//   GET    /api/t/:table/:id      one row              PATCH  /api/t/:table/:id   update
//                                                      DELETE /api/t/:table/:id   delete
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import pg from 'pg';

pg.types.setTypeParser(1082, v => v); // keep DATE columns as 'YYYY-MM-DD' (no timezone shift)
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
const PORT = +(process.env.PORT || 3000);

// label shown for a row wherever another table points at it
const LABEL = {
  seasons: 'name', stadiums: 'name', clubs: 'short_name', referees: 'name',
  players: "coalesce(known_as, concat_ws(' ', first_name, last_name))",
  staff: "concat_ws(' ', first_name, last_name)",
  matches: "(select short_name from pl.clubs where id = home_club_id) || ' v ' || (select short_name from pl.clubs where id = away_club_id) || coalesce(' · MW' || matchweek, '')",
};
const READ_ONLY = new Set(['id', 'created_at', 'updated_at']);

let meta = null; // { table: { columns: [{ name, type, udt, nullable, hasDefault, enum, ref }] } }
async function loadMeta() {
  const [{ rows: cols }, { rows: fks }, { rows: enums }] = await Promise.all([
    pool.query(`select c.table_name, c.column_name, c.data_type, c.udt_name, c.is_nullable = 'YES' as nullable, c.column_default is not null as has_default
                from information_schema.columns c join information_schema.tables t using (table_schema, table_name)
                where c.table_schema = 'pl' and t.table_type = 'BASE TABLE' order by c.table_name, c.ordinal_position`),
    pool.query(`select cl.relname as tbl, a.attname as col, fr.relname as ref
                from pg_constraint co join pg_class cl on cl.oid = co.conrelid join pg_namespace n on n.oid = cl.relnamespace
                join pg_class fr on fr.oid = co.confrelid join pg_attribute a on a.attrelid = co.conrelid and a.attnum = co.conkey[1]
                where co.contype = 'f' and n.nspname = 'pl'`),
    pool.query(`select t.typname, array_agg(e.enumlabel::text order by e.enumsortorder) as vals
                from pg_enum e join pg_type t on t.oid = e.enumtypid join pg_namespace n on n.oid = t.typnamespace
                where n.nspname = 'pl' group by t.typname`),
  ]);
  const ref = Object.fromEntries(fks.map(f => [`${f.tbl}.${f.col}`, f.ref]));
  const en = Object.fromEntries(enums.map(e => [e.typname, e.vals]));
  meta = {};
  for (const c of cols) (meta[c.table_name] ??= { columns: [] }).columns.push({
    name: c.column_name, type: c.data_type, udt: c.udt_name, nullable: c.nullable, hasDefault: c.has_default,
    enum: en[c.udt_name] ?? null, ref: ref[`${c.table_name}.${c.column_name}`] ?? null,
  });
}

const table = name => { if (!meta[name]) throw Object.assign(new Error(`Unknown table "${name}"`), { status: 404 }); return meta[name]; };
const id = (s, raw) => { if (!/^\d+$/.test(raw)) throw Object.assign(new Error('Bad id'), { status: 400 }); return +raw; };
// keep only real, writable columns; '' means "no value"
function values(t, body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw Object.assign(new Error('Send a JSON object'), { status: 400 });
  const cols = t.columns.filter(c => !READ_ONLY.has(c.name) && c.name in body);
  return [cols.map(c => c.name), cols.map(c => body[c.name] === '' ? null : body[c.name])];
}

const routes = {
  async 'GET /api/meta'() { return meta; },

  async 'GET /api/options/:t'(t) {
    table(t);
    const { rows } = await pool.query(`select id, ${LABEL[t] ?? 'id::text'} as label from pl.${t} order by 2`);
    return rows;
  },

  async 'GET /api/t/:t'(t) {
    table(t);
    return (await pool.query(`select * from pl.${t} order by id desc limit 1000`)).rows;
  },
  async 'GET /api/t/:t/:id'(t, i) {
    table(t);
    const { rows } = await pool.query(`select * from pl.${t} where id = $1`, [id(t, i)]);
    if (!rows.length) throw Object.assign(new Error('Not found'), { status: 404 });
    return rows[0];
  },
  async 'POST /api/t/:t'(t, body) {
    const [cols, vals] = values(table(t), body);
    const sql = cols.length
      ? `insert into pl.${t} (${cols.map(c => `"${c}"`).join(', ')}) values (${cols.map((_, n) => `$${n + 1}`).join(', ')}) returning *`
      : `insert into pl.${t} default values returning *`;
    return (await pool.query(sql, vals)).rows[0];
  },
  async 'PATCH /api/t/:t/:id'(t, i, body) {
    const [cols, vals] = values(table(t), body);
    if (!cols.length) throw Object.assign(new Error('Nothing to update'), { status: 400 });
    const { rows } = await pool.query(`update pl.${t} set ${cols.map((c, n) => `"${c}" = $${n + 1}`).join(', ')} where id = $${cols.length + 1} returning *`, [...vals, id(t, i)]);
    if (!rows.length) throw Object.assign(new Error('Not found'), { status: 404 });
    return rows[0];
  },
  async 'DELETE /api/t/:t/:id'(t, i) {
    table(t);
    const { rowCount } = await pool.query(`delete from pl.${t} where id = $1`, [id(t, i)]);
    if (!rowCount) throw Object.assign(new Error('Not found'), { status: 404 });
    return { deleted: +i };
  },

  async 'GET /api/site'() {
    const { rows: [season] } = await pool.query(`select * from pl.seasons order by is_current desc, start_date desc limit 1`);
    if (!season) return { season: null };
    const s = [season.id], q = sql => pool.query(sql, s).then(r => r.rows);
    const [clubs, standings, matches, leaders, [summary], perMw] = await Promise.all([
      q(`select c.id, c.code, c.name, c.short_name, c.nickname, c.founded_year, c.primary_colour as colour, c.kit_manufacturer, c.shirt_sponsor,
                st.name as stadium, st.city, st.capacity,
                (select concat_ws(' ', f.first_name, f.last_name) from pl.club_staff cs join pl.staff f on f.id = cs.staff_id
                  where cs.club_id = c.id and cs.role in ('manager', 'interim_manager') and cs.left_on is null order by cs.appointed_on desc nulls last limit 1) as manager
         from pl.season_clubs sc join pl.clubs c on c.id = sc.club_id left join pl.stadiums st on st.id = c.stadium_id
         where sc.season_id = $1 order by c.short_name`),
      q(`select c.code, s.*, s.position::int as position from pl.standings s join pl.clubs c on c.id = s.club_id where s.season_id = $1 order by s.position, c.short_name`),
      q(`select m.id, m.matchweek, m.kickoff_at, m.status, m.home_goals, m.away_goals, h.code as home, a.code as away, r.name as referee
         from pl.matches m join pl.clubs h on h.id = m.home_club_id join pl.clubs a on a.id = m.away_club_id left join pl.referees r on r.id = m.referee_id
         where m.season_id = $1 order by m.kickoff_at`),
      q(`select l.*, c.code from pl.player_leaders l join pl.clubs c on c.id = l.club_id where l.season_id = $1`),
      q(`select * from pl.season_summary where season_id = $1`),
      q(`select matchweek, goals, matches from pl.goals_by_matchweek where season_id = $1 order by matchweek`),
    ]);
    return { season, clubs, standings, matches, leaders, summary, perMw };
  },
};

function match(method, path) {
  for (const key in routes) {
    const [m, pattern] = key.split(' ');
    if (m !== method) continue;
    const a = pattern.split('/'), b = path.split('/');
    if (a.length !== b.length) continue;
    const params = [];
    if (a.every((part, i) => part.startsWith(':') ? (params.push(decodeURIComponent(b[i])), true) : part === b[i])) return [routes[key], params];
  }
}

const send = (res, status, body, type = 'application/json') =>
  res.writeHead(status, { 'content-type': `${type}; charset=utf-8`, 'cache-control': 'no-store' }).end(type === 'application/json' ? JSON.stringify(body) : body);

createServer(async (req, res) => {
  const path = new URL(req.url, 'http://x').pathname;
  try {
    if (req.method === 'GET' && (path === '/' || path === '/index.html'))
      return send(res, 200, await readFile(new URL('./index.html', import.meta.url)), 'text/html');
    const hit = match(req.method, path);
    if (!hit) return send(res, 404, { error: 'Not found' });
    let body;
    if (req.method === 'POST' || req.method === 'PATCH') {
      let raw = '';
      for await (const chunk of req) { raw += chunk; if (raw.length > 1e6) throw Object.assign(new Error('Body too large'), { status: 413 }); }
      try { body = JSON.parse(raw || '{}'); } catch { throw Object.assign(new Error('Invalid JSON'), { status: 400 }); }
    }
    send(res, 200, await hit[0](...hit[1], body));
  } catch (e) {
    // Postgres data/constraint errors (22xxx, 23xxx) are the user's input, not a server fault
    const status = e.status ?? (/^2[23]/.test(e.code ?? '') ? 400 : 500);
    if (status === 500) console.error(e);
    send(res, status, { error: e.message, detail: e.detail ?? null });
  }
}).listen(PORT, '127.0.0.1', async () => {
  try { await loadMeta(); } catch (e) { console.error(`\nCan't read the database: ${e.message}\nCheck DATABASE_URL in .env and that schema.sql has been run.\n`); process.exit(1); }
  console.log(`Touchline running at http://localhost:${PORT}  (${Object.keys(meta).length} tables)`);
});
