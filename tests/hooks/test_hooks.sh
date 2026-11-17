#!/bin/zsh -f
# Tests the Claude Code routing hooks (session-start and post) and kd.
# Needs the keydillo app running. Uses no keys: only checks routing, pass-through and cleanup.
B="$HOME/.local/bin/keydillo"
T=$(mktemp -d); trap 'rm -rf $T' EXIT
pass=0; fail=0
ok() { if eval "$2"; then print "PASS  $1"; ((pass++)); else print "FAIL  $1"; ((fail++)); fi }

mkdir -p $T/proj/sub $T/other
printf '# --- keydillo ---\n# test project\n# --- end keydillo ---\nFOO=keydillo:x\n' > $T/proj/.env
print 'print("hi")' > $T/proj/sub/run.py

# 2. Claude Code session-start: routes everything a (fake) Claude session runs, and stops when it exits.
ln -s /bin/zsh $T/claude
: > $T/envfile
$T/claude -fc "CLAUDE_ENV_FILE=$T/envfile '$B' hook session-start < /dev/null > $T/ctx; source $T/envfile; curl --max-time 8 -s -o /dev/null -w '%{http_code}' https://example.com/ > $T/code; print \$\$ > $T/owner"
ok "claude: session env file gets the proxy settings" 'grep -q "export HTTPS_PROXY=" $T/envfile'
ok "claude: Claude is told commands are routed" 'grep -q "routes this session" $T/ctx'
ok "claude: other sites pass through" '[[ $(<$T/code) == 200 ]]'
sleep 4
ok "claude: the session proxy stops when the session ends" '! pgrep -f "serve-for $(<$T/owner)" >/dev/null'

ok "kd is on PATH" '[[ -x $HOME/.local/bin/kd ]]'
ok "kd runs a command" '[[ $($HOME/.local/bin/kd /bin/echo hi 2>/dev/null) == hi ]]'

# 3. Post hook: explains a rejected placeholder, stays quiet otherwise.
post() { print -r -- "$1" | "$B" hook post }
ok "post: rejected placeholder explained" '[[ $(post "{\"tool_name\":\"Bash\",\"tool_response\":{\"stdout\":\"401 Incorrect API key provided: keydillo:openai:start-with-keydillo-run\",\"stderr\":\"\"}}") == *"kd <command>"* ]]'
ok "post: ordinary 401 ignored" '[[ -z $(post "{\"tool_name\":\"Bash\",\"tool_response\":{\"stdout\":\"401 Unauthorized\",\"stderr\":\"\"}}") ]]'
ok "post: placeholder without an error ignored" '[[ -z $(post "{\"tool_name\":\"Bash\",\"tool_response\":{\"stdout\":\"FOO=keydillo:x\",\"stderr\":\"\"}}") ]]'

print "\n$pass passed, $fail failed"
exit $fail
