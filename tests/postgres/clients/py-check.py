# psycopg 3 through keydillo's local Postgres endpoint, including cancelling a running query.
import os, threading, time, psycopg
with psycopg.connect(os.environ["DATABASE_URL"]) as c:
    print("psycopg query", c.execute("select current_user, %s::int + 1", (41,)).fetchone())
    threading.Timer(1.0, c.cancel).start()
    t = time.time()
    try:
        c.execute("select pg_sleep(10)")
        print("psycopg cancel FAILED")
    except psycopg.errors.QueryCanceled:
        print("psycopg cancel ok in %.1fs" % (time.time() - t))
