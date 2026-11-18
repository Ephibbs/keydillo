#!/bin/zsh -f
# Starts a throwaway local Postgres 17 (TLS on, SCRAM and MD5 users) on port 15432 and PgBouncer on 16432,
# for tests/postgres/run.sh. Test passwords only. Usage: setup.sh <dir>; stop with: pg_ctl -D <dir>/data stop
set -e
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
PG=/opt/homebrew/opt/postgresql@17/bin
D=$1; rm -rf $D; mkdir -p $D
$PG/initdb -D $D/data -U postgres --auth=trust >/dev/null
openssl req -new -x509 -days 2 -nodes -subj "/CN=localhost" -keyout $D/data/server.key -out $D/data/server.crt >/dev/null 2>&1
chmod 600 $D/data/server.key
cat >> $D/data/postgresql.conf <<CONF
port = 15432
listen_addresses = '127.0.0.1'
ssl = on
password_encryption = 'scram-sha-256'
unix_socket_directories = '$D'
CONF
cat > $D/data/pg_hba.conf <<HBA
local all postgres trust
hostssl all scram_user 127.0.0.1/32 scram-sha-256
hostssl all md5_user 127.0.0.1/32 md5
host all bouncer_user 127.0.0.1/32 scram-sha-256
hostnossl all all 127.0.0.1/32 reject
HBA
$PG/pg_ctl -D $D/data -l $D/pg.log -w start >/dev/null
$PG/psql -h $D -p 15432 -U postgres -q <<SQL
create user scram_user password 'test-scram-pass';
set password_encryption = 'md5';
create user md5_user password 'test-md5-pass';
set password_encryption = 'scram-sha-256';
create user bouncer_user password 'test-bouncer-pass';
create database appdb owner scram_user;
create database otherdb owner scram_user;
grant all on database appdb to md5_user, bouncer_user;
SQL
cat > $D/pgbouncer.ini <<INI
[databases]
appdb = host=127.0.0.1 port=15432 dbname=appdb
[pgbouncer]
listen_addr = 127.0.0.1
listen_port = 16432
auth_type = scram-sha-256
auth_file = $D/userlist.txt
pool_mode = transaction
unix_socket_dir = $D
logfile = $D/pgbouncer.log
pidfile = $D/pgbouncer.pid
INI
echo '"bouncer_user" "test-bouncer-pass"' > $D/userlist.txt
/opt/homebrew/opt/pgbouncer/bin/pgbouncer -d $D/pgbouncer.ini
echo ready
