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
kill $HS 2>/dev/null
$DEV run -- sh -c 'curl -s -o /dev/null --max-time 8 https://example.com/; sleep 6' >/dev/null 2>&1 & KDP=$!; sleep 3
RUNPID=$(pgrep -f "keydillo run -- sh -c curl" | head -1)
PORTS=($(lsof -nP -a -p $RUNPID -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{split($9,a,":"); print a[2]}'))
refused=1
for p in $PORTS; do
  r=$(curl -s -k --max-time 3 --resolve example.com:$p:127.0.0.1 https://example.com:$p/ -o /dev/null -w "%{http_code}" 2>/dev/null)
  [[ $r == 200 ]] && refused=0
done
ok "kd: an outside program can't use the per-host TLS listener (${#PORTS} ports checked)" '(( ${#PORTS} >= 2 && refused ))'
wait $KDP 2>/dev/null
unset KEYDILLO_TEST_APP_PORT KEYDILLO_TEST_SERVICES

print "\n$pass passed, $fail failed"
exit $fail
