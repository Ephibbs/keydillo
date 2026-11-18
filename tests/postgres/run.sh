#!/bin/zsh -f
# keydillo's Postgres proxy against real clients: psql, node-postgres, psycopg (with cancel), Prisma (with migrations)
# over TLS with SCRAM and MD5 logins, and through PgBouncer. Needs brew postgresql@17 and pgbouncer.
# Setup once: (cd clients && npm install pg@8 prisma@6 @prisma/client@6 && python3 -m venv .venv && .venv/bin/pip install "psycopg[binary]")
cd ${0:A:h}
export LC_ALL=en_US.UTF-8
D=$(mktemp -d); zsh setup.sh $D/pg >/dev/null || exit 1
trap '/opt/homebrew/opt/postgresql@17/bin/pg_ctl -D $D/pg/data stop -m fast >/dev/null; kill $(cat $D/pg/pgbouncer.pid) 2>/dev/null' EXIT
/opt/homebrew/opt/postgresql@17/bin/psql -h $D/pg -p 15432 -U postgres -qc "alter user scram_user createdb"
(cd ../../Packages/VaultCore && swift build -q --product kd-pgproxy-test) || exit 1
PX=../../Packages/VaultCore/.build/debug/kd-pgproxy-test
pass=0; fail=0
ok() { if eval "$2"; then print "PASS  $1"; ((pass++)); else print "FAIL  $1"; ((fail++)); fi }
proxy() { $PX $1 $2 "$3" > $D/px$1 2>&1 & sleep 1; head -1 $D/px$1 }
PSQL=/opt/homebrew/opt/postgresql@17/bin/psql
Q="select current_user || ',' || (select ssl::text from pg_stat_ssl where pid = pg_backend_pid())"
L=$(proxy 17801 db 'postgresql://scram_user:test-scram-pass@localhost:15432/appdb?sslmode=require')
ok "psql: SCRAM login over TLS" '[[ $($PSQL "$L" -Atc "$Q") == "scram_user,true" ]]'
ok "local URL has no password or real host" '[[ $L != *test-scram-pass* && $L != *15432* ]]'
L2=$(proxy 17802 db 'postgresql://md5_user:test-md5-pass@localhost:15432/appdb?sslmode=require')
ok "psql: MD5 login over TLS" '[[ $($PSQL "$L2" -Atc "$Q") == "md5_user,true" ]]'
L3=$(proxy 17803 db 'postgresql://scram_user:wrong@localhost:15432/appdb?sslmode=require')
ok "a wrong password shows the server's own error" '[[ $($PSQL "$L3" -c "select 1" 2>&1) == *"password authentication failed"* ]]'
ok "an unknown key name is refused clearly" '[[ $($PSQL "${L/db@/nope@}" -c "select 1" 2>&1) == *"no database key named nope"* ]]'
cd clients
ok "node-postgres: queries and a pool" '[[ $(DATABASE_URL=$L node node-check.js) == *"node-pg pool 10"* ]]'
ok "psycopg: query and cancel" '[[ $(DATABASE_URL=$L .venv/bin/python py-check.py) == *"cancel ok"* ]]'
rm -rf prisma/migrations
ok "Prisma: migrate dev (shadow database) leaves data alone" '[[ $(DATABASE_URL=$L npx prisma migrate dev --name init --skip-seed 2>&1) == *"in sync"* ]] && npx prisma generate >/dev/null 2>&1 && [[ $(DATABASE_URL=$L node prisma-check.js) == "prisma count 1" ]] && DATABASE_URL=$L npx prisma migrate dev --name again --skip-seed >/dev/null 2>&1 && [[ $(DATABASE_URL=$L node prisma-check.js) == "prisma count 2" ]]'
$PSQL -h $D/pg -p 15432 -U postgres -d appdb -qc 'grant all on schema public to bouncer_user; grant all on all tables in schema public to bouncer_user; grant all on all sequences in schema public to bouncer_user'
L4=$(proxy 17804 pooler 'postgresql://bouncer_user:test-bouncer-pass@127.0.0.1:16432/appdb?pgbouncer=true&connection_limit=1')
ok "PgBouncer (transaction pooling, like Supabase's pooler): node-postgres" '[[ $(DATABASE_URL=$L4 node node-check.js) == *"node-pg pool 10"* ]]'
ok "PgBouncer: Prisma with pgbouncer=true" '[[ $(DATABASE_URL=$L4 node prisma-check.js) == "prisma count 3" ]]'
kill %1 %2 %3 %4 2>/dev/null
print "\n$pass passed, $fail failed"
