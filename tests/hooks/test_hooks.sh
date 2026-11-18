#!/bin/zsh -f
# Tests kd and the Claude Code hooks (pre-command steering to kd, post-command explanation).
# Needs the keydillo app running. Uses no keys: only checks routing, pass-through and cleanup.
B="$HOME/.local/bin/keydillo"
T=$(mktemp -d); trap 'rm -rf $T' EXIT
pass=0; fail=0
ok() { if eval "$2"; then print "PASS  $1"; ((pass++)); else print "FAIL  $1"; ((fail++)); fi }

mkdir -p $T/proj/sub $T/other
printf '# --- keydillo ---\n# test project\n# --- end keydillo ---\nFOO=keydillo:x\n' > $T/proj/.env
print 'print("hi")' > $T/proj/sub/run.py

ok "kd is on PATH" '[[ -x $HOME/.local/bin/kd ]]'
ok "kd runs a command" '[[ $($HOME/.local/bin/kd /bin/echo hi 2>/dev/null) == hi ]]'

# 4. Pre-command check: programs in a keydillo project need kd; other commands are left alone.
pre() { print -r -- "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"},\"cwd\":\"$2\"}" | "$B" hook 2>&1; print "exit=$?" }
ok "pre: python in a keydillo project is stopped with the kd fix" '[[ $(pre "python3 sub/run.py" $T/proj) == *"kd python3 sub/run.py"*"exit=2"* ]]'
ok "pre: with kd in front it runs" '[[ $(pre "kd python3 sub/run.py" $T/proj) == *"exit=0"* ]]'
ok "pre: npm run dev needs kd" '[[ $(pre "npm run dev" $T/proj/sub) == *"exit=2"* ]]'
ok "pre: npm install doesn't" '[[ $(pre "npm install" $T/proj) == *"exit=0"* ]]'
ok "pre: git and cat don't" '[[ $(pre "git status && cat .env" $T/proj) == *"exit=0"* ]]'
ok "pre: a path into a project counts" '[[ $(pre "python3 $T/proj/sub/run.py" $T/other) == *"exit=2"* ]]'
ok "pre: outside projects nothing is stopped" '[[ $(pre "python3 x.py" $T/other) == *"exit=0"* ]]'
# The hook command Connect writes: runs keydillo only while it's installed, and keeps its "stop" exit code.
wrapped() { print -r -- "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$1\"},\"cwd\":\"$2\"}" | sh -c "if [ -x '$3' ]; then exec '$3' hook; fi" 2>&1; print "exit=$?" }
ok "hook command: still stops a command when keydillo is installed" '[[ $(wrapped "python3 sub/run.py" $T/proj "$B") == *"exit=2"* ]]'
ok "hook command: silent and harmless once keydillo is uninstalled" '[[ $(wrapped "python3 sub/run.py" $T/proj /nonexistent/keydillo) == "exit=0" ]]'

# 5. Post-command check: real providers don't echo the key, so it looks at the command, folder and error.
postc() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2],"tool_response":{"stdout":sys.argv[3],"stderr":""}}))' "$1" "$2" "$3" | "$B" hook post }
ok "post: OpenAI 401 without kd in a project is explained" '[[ $(postc "python3 app.py" $T/proj "openai.AuthenticationError: Error code: 401 - Incorrect API key provided") == *"kd python3 app.py"* ]]'
ok "post: Anthropic invalid x-api-key explained" '[[ -n $(postc "node index.js" $T/proj "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}") ]]'
ok "post: ElevenLabs invalid_api_key explained" '[[ -n $(postc "python3 tts.py" $T/proj "{\"detail\":{\"status\":\"invalid_api_key\"}}") ]]'
ok "post: Gemini key not valid explained" '[[ -n $(postc "python3 g.py" $T/proj "API key not valid. Please pass a valid API key.") ]]'
ok "post: with kd, nothing to say" '[[ -z $(postc "kd python3 app.py" $T/proj "401 Unauthorized") ]]'
ok "post: outside projects, nothing" '[[ -z $(postc "python3 app.py" $T/other "401 Unauthorized") ]]'
ok "post: reading code that mentions 401 isn't flagged" '[[ -z $(postc "cat app.py" $T/proj "raise Exception(\"401 Unauthorized: keydillo:openai\")") ]]'

# 6. kd proxy: plain http:// works; nobody but the proxy can use its per-host TLS listeners.
DEV=~/Desktop/keydillo/App/build/Build/Products/Release/keydillo
export KEYDILLO_TEST_APP_PORT=1 KEYDILLO_TEST_SERVICES='[{"name":"ex","displayName":"ex","project":"t","host":"example.com","baseURL":"x","envVarName":"EX_KEY","baseURLEnvName":"EX_BASE_URL"}]'
python3 -m http.server 18734 --bind 127.0.0.1 >/dev/null 2>&1 & HS=$!; sleep 1
ok "kd: plain http:// to a non-local address works" '[[ $($DEV run -- curl -s -o /dev/null -w "%{http_code}" --max-time 8 http://0.0.0.0:18734/ 2>/dev/null) == 200 ]]'

# 6b. A program the command leaves running in the background (nohup, pm2) keeps kd's proxy, and kd returns at once.
start=$EPOCHSECONDS
$DEV run -- sh -c "nohup sh -c 'sleep 3; curl -s -o /dev/null -w %{http_code} --max-time 8 http://0.0.0.0:18734/ > $T/bg.out' >/dev/null 2>&1 &" 2>$T/bg.err
took=$(( EPOCHSECONDS - start ))
ok "background: kd returns right away instead of waiting for the background program" '[[ $took -lt 3 ]]'
ok "background: kd says the background program keeps its keys" '[[ $(cat $T/bg.err) == *"in the background"* ]]'
for i in {1..20}; do [[ -s $T/bg.out ]] && break; sleep 0.5; done
ok "background: after kd returned, the program still gets through kd's proxy" '[[ $(cat $T/bg.out 2>/dev/null) == 200 ]]'
for i in {1..10}; do pgrep -f "__run-core" >/dev/null || break; sleep 0.5; done
ok "background: the proxy process ends once the program exits" '! pgrep -f "__run-core" >/dev/null'
kill $HS 2>/dev/null
$DEV run -- sh -c 'curl -s -o /dev/null --max-time 8 https://example.com/; sleep 6' >/dev/null 2>&1 & KDP=$!; sleep 3
RUNPID=$(pgrep -f "__run-core .* sh -c curl" | head -1)
PORTS=($(lsof -nP -a -p $RUNPID -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{split($9,a,":"); print a[2]}'))
refused=1
for p in $PORTS; do
  r=$(curl -s -k --max-time 3 --resolve example.com:$p:127.0.0.1 https://example.com:$p/ -o /dev/null -w "%{http_code}" 2>/dev/null)
  [[ $r == 200 ]] && refused=0
done
ok "kd: an outside program can't use the per-host TLS listener (${#PORTS} ports checked)" '(( ${#PORTS} >= 2 && refused ))'
wait $KDP 2>/dev/null
unset KEYDILLO_TEST_APP_PORT KEYDILLO_TEST_SERVICES

# 7. Other env file names, cd, Go/Rust, the app going away mid-run.
mkdir -p $T/next/web $T/worker
printf '# --- keydillo ---\n# test\n# --- end keydillo ---\nOPENAI_API_KEY=keydillo:x\n' > $T/next/web/.env.local
printf '# --- keydillo ---\n# test\n# --- end keydillo ---\nKEY=keydillo:x\n' > $T/worker/.dev.vars
ok "pre: a Next.js project (.env.local) needs kd" '[[ $(pre "npm run dev" $T/next/web) == *"exit=2"* ]]'
ok "pre: a Workers project (.dev.vars) needs kd" '[[ $(pre "npx wrangler dev" $T/worker) == *"exit=2"* ]]'
ok "pre: cd into a project counts" '[[ $(pre "cd web && npm run dev" $T/next) == *"kd"*"exit=2"* ]]'
ok "pre: go run isn't told to use kd" '[[ $(pre "go run ." $T/proj) == *"exit=0"* ]]'
ok "post: Go auth failure gets the base-URL advice" '[[ $(postc "go run ." $T/proj "401 Unauthorized: invalid api key") == *"BASE_URL"* ]]'
ok "post: certificate error under kd gets the base-URL advice" '[[ $(postc "kd ./server" $T/proj "x509: certificate signed by unknown authority") == *"BASE_URL"* ]]'
export KEYDILLO_TEST_APP_PORT=1 KEYDILLO_TEST_SERVICES='[{"name":"ex","displayName":"ex","project":"t","host":"example.com","baseURL":"x","envVarName":"EX_KEY","baseURLEnvName":"EX_BASE_URL"}]'
start=$(date +%s)
out=$($DEV run -- curl -s --max-time 20 https://example.com/x -H "x-api-key: keydillo:ex" 2>/dev/null)
took=$(( $(date +%s) - start ))
ok "kd: with the app gone, a keyed call fails at once with a clear message (${took}s)" '[[ $out == *"keydillo_not_running"* && $took -lt 5 ]]'
unset KEYDILLO_TEST_APP_PORT KEYDILLO_TEST_SERVICES

# 8. Names in the Touch ID prompt can't be borrowed.
"$B" run --serve-for $$ >/dev/null 2>&1 & SF=$!; sleep 0.5
ok "names: a leftover --serve-for argument doesn't borrow a session's name" '! "$B" whois $SF 2>/dev/null | grep -q "shown as: Claude Code$"'
kill $SF 2>/dev/null

# 9. A key without a host: kd never guesses sites from its name.
cat > $T/app.py <<'PYEOF'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(sys.argv[2], "w").write(self.headers.get("X-Keydillo-Target-Host", "none") + " " + self.path)
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).handle_request()
PYEOF
python3 $T/app.py 18736 $T/seen & APPP=$!; sleep 0.5
export KEYDILLO_TEST_APP_PORT=18736 KEYDILLO_TEST_SERVICES='[{"name":"example","displayName":"Example","project":"t","host":"","baseURL":"x","envVarName":"EXAMPLE_API_KEY","baseURLEnvName":"EXAMPLE_BASE_URL","hostTokens":["example"]}]'
$DEV run -- curl -s --max-time 8 https://api.example.com/v1/x -H "x-api-key: keydillo:example" >/dev/null 2>&1
ok "kd: a key with no site doesn't make kd intercept sites guessed from its name" '[[ ! -s $T/seen ]]'
export KEYDILLO_TEST_SERVICES='[{"name":"github","displayName":"GitHub","project":"t","host":"","baseURL":"x","envVarName":"GITHUB_TOKEN","baseURLEnvName":"X","hostTokens":["github"]}]'
ok "kd: a key named after a developer platform never takes over that platform's site" '[[ $($DEV run -- curl -s -o /dev/null -w "%{http_code}" --max-time 8 https://github.com/ 2>/dev/null) == 200 ]]'
kill $APPP 2>/dev/null
unset KEYDILLO_TEST_APP_PORT KEYDILLO_TEST_SERVICES

# 10. Launch-time keys: kd puts the real value in the program's environment; .env loaders keep it.
mkdir -p $T/web/src
printf '# --- keydillo ---\n# test\n# --- end keydillo ---\nJWT_SECRET=keydillo:jwt-secret:run-with-kd\nPORT=3000\n' > $T/web/.env
export KEYDILLO_TEST_SERVICES='[{"name":"jwt-secret","displayName":"JWT secret","project":"t","host":"","baseURL":"x","envVarName":"JWT_SECRET","baseURLEnvName":"X","launchTime":true}]'
export KEYDILLO_TEST_LAUNCH_VALUES='{"jwt-secret":"s3cret-from-keychain"}' KEYDILLO_TEST_APP_PORT=1
ok "launch-time: kd gives the program the real value" '[[ $(cd $T/web/src && $DEV run -- sh -c "echo \$JWT_SECRET" 2>/dev/null) == "s3cret-from-keychain" ]]'
PY=$HOME/Desktop/keydillo-breakers/.venv/bin/python
if [[ -x $PY ]]; then
  ok "launch-time: python-dotenv keeps kd's value instead of the placeholder" '[[ $(cd $T/web && $DEV run -- $PY -c "from dotenv import load_dotenv; load_dotenv(); import os; print(os.environ[\"JWT_SECRET\"])" 2>/dev/null) == "s3cret-from-keychain" ]]'
fi
export KEYDILLO_TEST_LAUNCH_VALUES='{}'
ok "launch-time: if it isn't approved, kd says so" '[[ $(cd $T/web && $DEV run -- true 2>&1) == *"JWT_SECRET wasn"* ]]'
unset KEYDILLO_TEST_SERVICES KEYDILLO_TEST_LAUNCH_VALUES KEYDILLO_TEST_APP_PORT

# 11. After you quit keydillo yourself, kd doesn't reopen it. (Stops the running app for a moment, then restarts it.)
QM="$HOME/Library/Application Support/keydillo/quit-by-user"
launchctl kill TERM gui/$(id -u)/com.studiokillswitch.keydillo.agent 2>/dev/null; sleep 2
touch "$QM"
out=$("$B" run -- true 2>&1); running=$(pgrep -f "MacOS/keydillo$")
ok "quit: kd says keydillo was quit and doesn't reopen it" '[[ $out == *"keydillo was quit"* && -z $running ]]'
rm -f "$QM"; launchctl kickstart gui/$(id -u)/com.studiokillswitch.keydillo.agent 2>/dev/null; sleep 3
ok "quit: once keydillo is open again, kd works" '"$B" run -- true 2>/dev/null'

# 12. Launch-time keys in a monorepo, and the check for a program that ended up with the placeholder.
mkdir -p $T/mono/packages/web
printf '# --- keydillo ---\n# t\n# --- end keydillo ---\nDATABASE_URL=keydillo:db-url:0123456789abcdef0123456789abcdef0123456789abcdef\n' > $T/mono/.env
printf '# --- keydillo ---\n# t\n# --- end keydillo ---\nPORT=3000\n' > $T/mono/packages/web/.env
export KEYDILLO_TEST_SERVICES='[{"name":"db-url","displayName":"DB","project":"t","host":"","baseURL":"x","envVarName":"DATABASE_URL","baseURLEnvName":"X","launchTime":true}]'
export KEYDILLO_TEST_LAUNCH_VALUES='{"db-url":"postgres://real"}' KEYDILLO_TEST_APP_PORT=1
ok "launch-time: a monorepo root's .env counts when kd runs in a package" '[[ $(cd $T/mono/packages/web && $DEV run -- sh -c "echo \$DATABASE_URL" 2>/dev/null) == "postgres://real" ]]'
unset KEYDILLO_TEST_SERVICES KEYDILLO_TEST_LAUNCH_VALUES KEYDILLO_TEST_APP_PORT
ok "post: a launch-time placeholder in the output is explained" '[[ $(postc "kd node worker.js" $T/proj "connect failed: password keydillo:db-url:0123456789abcdef0123456789abcdef0123456789abcdef") == *"got the placeholder for db-url"* ]]'

# 13. kd warns about launch-time keys in .env files below where it runs (monorepo root).
mkdir -p $T/root2/apps/web
printf '# --- keydillo ---\n# t\n# --- end keydillo ---\nJWT_SECRET=keydillo:jwt-secret:0123456789abcdef0123456789abcdef0123456789abcdef\n' > $T/root2/apps/web/.env
export KEYDILLO_TEST_SERVICES='[{"name":"jwt-secret","displayName":"JWT","project":"t","host":"","baseURL":"x","envVarName":"JWT_SECRET","baseURLEnvName":"X","launchTime":true}]' KEYDILLO_TEST_APP_PORT=1
ok "launch-time: kd run from a monorepo root says which package .env it can't fill" '[[ $(cd $T/root2 && $DEV run -- true 2>&1) == *"apps/web/.env has launch-time key JWT_SECRET"* ]]'
unset KEYDILLO_TEST_SERVICES KEYDILLO_TEST_APP_PORT

# 15. kd behaves like the command in a terminal: Ctrl-C stops it and it can read the keyboard.
cat > $T/ctrlc.exp <<'EXP'
set timeout 10
set env(KEYDILLO_TEST_APP_PORT) 1
set env(KEYDILLO_TEST_SERVICES) {[]}
set start [clock seconds]
spawn [lindex $argv 0] run -- sleep 30
sleep 1
send "\003"
expect eof
puts "took [expr [clock seconds] - $start]"
EXP
cat > $T/stdin.exp <<'EXP'
set timeout 8
set env(KEYDILLO_TEST_APP_PORT) 1
set env(KEYDILLO_TEST_SERVICES) {[]}
spawn [lindex $argv 0] run -- sh -c "read x; echo got:\$x"
sleep 1
send "hello\r"
expect eof
EXP
ok "terminal: Ctrl-C stops the command kd runs" '[[ $(expect $T/ctrlc.exp $DEV 2>&1 | tail -1) == *"took "[1-3] ]]'
ok "terminal: the command kd runs can read the keyboard" '[[ $(expect $T/stdin.exp $DEV 2>&1) == *"got:hello"* ]]'

# 17. A signal sent to kd itself reaches the command, and kd exits with the command's status.
export KEYDILLO_TEST_APP_PORT=1 KEYDILLO_TEST_SERVICES='[]'
$DEV run -- sh -c 'trap "exit 42" TERM; sleep 30 & wait' & K=$!; sleep 2; kill -TERM $K; wait $K; st=$?
ok "signals: SIGTERM to kd stops the command and kd returns its status" '[[ $st == 42 ]] && ! pgrep -f "sleep 30" >/dev/null'
$DEV run -- sh -c 'sleep 31' & K=$!; sleep 2; kill -HUP $K; wait $K; st=$?
ok "signals: SIGHUP to kd (terminal closed) stops the command" '[[ $st == 129 ]] && ! pgrep -f "sleep 31" >/dev/null'

# 18. kd sets the project's base-URL and key variables for programs that don't read .env (Go, Rust), never over the user's own.
mkdir -p $T/goproj $T/gwproj
printf '# --- keydillo ---\n# t\n# --- end keydillo ---\nEX_KEY=keydillo:ex:run-with-kd\n' > $T/goproj/.env
printf '# --- keydillo ---\n# t\n# --- end keydillo ---\nEX_KEY=keydillo:ex:run-with-kd\nEX_BASE_URL=https://my-gateway.example\n' > $T/gwproj/.env
export KEYDILLO_TEST_APP_PORT=1 KEYDILLO_TEST_SERVICES='[{"name":"ex","displayName":"ex","project":"t","host":"example.com","baseURL":"http://localhost:7787/ex","envVarName":"EX_KEY","baseURLEnvName":"EX_BASE_URL"}]'
ok "base URL: kd sets the provider's base-URL variable for this project's key" '[[ $(cd $T/goproj && $DEV run -- printenv EX_BASE_URL 2>/dev/null) == "http://localhost:7787/ex" ]]'
ok "base URL: and the key variable to its placeholder" '[[ $(cd $T/goproj && $DEV run -- printenv EX_KEY 2>/dev/null) == "keydillo:ex:run-with-kd" ]]'
ok "base URL: a base URL the user set in .env is left alone" '[[ -z $(cd $T/gwproj && $DEV run -- printenv EX_BASE_URL 2>/dev/null) ]]'
ok "base URL: one set in the environment is left alone" '[[ $(cd $T/goproj && EX_BASE_URL=https://mine.example $DEV run -- printenv EX_BASE_URL 2>/dev/null) == "https://mine.example" ]]'
ok "base URL: outside the project nothing is set" '[[ -z $(cd $T/other && $DEV run -- printenv EX_BASE_URL 2>/dev/null) ]]'
ok "nested: kd inside kd doesn't call the outer kd 'your proxy'" '[[ $($DEV run -- $DEV run -- true 2>&1) != *"your proxy"* ]]'
unset KEYDILLO_TEST_SERVICES KEYDILLO_TEST_APP_PORT

print "\n$pass passed, $fail failed"
exit $fail
