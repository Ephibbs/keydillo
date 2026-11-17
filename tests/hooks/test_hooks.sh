#!/bin/zsh -f
# Tests the automatic routing hooks (zsh shell hook, Claude Code session-start and post hooks).
# Needs the keydillo app running. Uses no keys: only checks routing, pass-through and cleanup.
B="$HOME/Library/Application Support/keydillo/bin/keydillo"
T=$(mktemp -d); trap 'rm -rf $T' EXIT
pass=0; fail=0
ok() { if eval "$2"; then print "PASS  $1"; ((pass++)); else print "FAIL  $1"; ((fail++)); fi }

mkdir -p $T/proj/sub $T/other
printf '# --- keydillo ---\n# test project\n# --- end keydillo ---\nFOO=keydillo:x\n' > $T/proj/.env
print 'print("hi")' > $T/proj/sub/run.py

# 1. Shell hook
cat > $T/shell.zsh <<ZEOF
eval "\$("$B" shell-init)"
export NODE_OPTIONS=--max-old-space-size=100
cd $T/other
_kd_preexec "" "ls -la"; print "outside=\$_kd_on"; _kd_precmd
_kd_preexec "" "python3 $T/proj/sub/run.py"; print "pathinto=\$_kd_on run=\${KEYDILLO_RUN-}"
print "code=\$(curl --max-time 8 -s -o /dev/null -w '%{http_code}' https://example.com/)"
_kd_precmd; print "after_run=\${KEYDILLO_RUN-none} after_proxy=\${HTTPS_PROXY-none} node_opts=\$NODE_OPTIONS"
cd $T/proj/sub; _kd_preexec "" "npm test"; print "inside=\$_kd_on"; _kd_precmd
cd $T/other; _kd_preexec "" "cat ~/nonexistent/x"; print "tilde_miss=\$_kd_on"; _kd_precmd
print "kd=\$(whence -p kd)"
ZEOF
out=$(zsh -f $T/shell.zsh 2>&1)
ok "shell: commands outside projects untouched" '[[ $out == *"outside=0"* ]]'
ok "shell: a path into a project is routed" '[[ $out == *"pathinto=1 run=1"* ]]'
ok "shell: other sites pass through the proxy" '[[ $out == *"code=200"* ]]'
ok "shell: settings removed and user values restored after the command" '[[ $out == *"after_run=none after_proxy=none node_opts=--max-old-space-size=100"* ]]'
ok "shell: commands inside a project are routed" '[[ $out == *"inside=1"* ]]'
ok "shell: unrelated paths aren't routed" '[[ $out == *"tilde_miss=0"* ]]'
ok "shell: kd is on PATH" '[[ $out == *"kd="*"/keydillo/bin/kd"* ]]'

# 2. Claude Code session-start: routes everything a (fake) Claude session runs, and stops when it exits.
cp /bin/zsh $T/claude
: > $T/envfile
$T/claude -fc "CLAUDE_ENV_FILE=$T/envfile '$B' hook session-start < /dev/null > $T/ctx; source $T/envfile; curl --max-time 8 -s -o /dev/null -w '%{http_code}' https://example.com/ > $T/code; print \$\$ > $T/owner"
ok "claude: session env file gets the proxy settings" 'grep -q "export HTTPS_PROXY=" $T/envfile'
ok "claude: Claude is told commands are routed" 'grep -q "routes this session" $T/ctx'
ok "claude: other sites pass through" '[[ $(<$T/code) == 200 ]]'
sleep 4
ok "claude: the session proxy stops when the session ends" '! pgrep -f "serve-for $(<$T/owner)" >/dev/null'

# 3. Post hook: explains a rejected placeholder, stays quiet otherwise.
post() { print -r -- "$1" | "$B" hook post }
ok "post: rejected placeholder explained" '[[ $(post "{\"tool_name\":\"Bash\",\"tool_response\":{\"stdout\":\"401 Incorrect API key provided: keydillo:openai:start-with-keydillo-run\",\"stderr\":\"\"}}") == *"kd <command>"* ]]'
ok "post: ordinary 401 ignored" '[[ -z $(post "{\"tool_name\":\"Bash\",\"tool_response\":{\"stdout\":\"401 Unauthorized\",\"stderr\":\"\"}}") ]]'
ok "post: placeholder without an error ignored" '[[ -z $(post "{\"tool_name\":\"Bash\",\"tool_response\":{\"stdout\":\"FOO=keydillo:x\",\"stderr\":\"\"}}") ]]'

print "\n$pass passed, $fail failed"
exit $fail
