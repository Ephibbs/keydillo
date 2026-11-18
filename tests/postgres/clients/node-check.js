// node-postgres through keydillo's local Postgres endpoint (DATABASE_URL).
const { Client, Pool } = require('pg');
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  const r = await c.query('select current_user as u, $1::int + 1 as n', [41]);
  console.log('node-pg query', r.rows[0].u, r.rows[0].n);
  await c.end();
  const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
  const many = await Promise.all([...Array(10)].map((_, i) => pool.query('select $1::int as i', [i])));
  console.log('node-pg pool', many.length);
  await pool.end();
})().catch(e => { console.log('node-pg error', e.message); process.exit(1); });
