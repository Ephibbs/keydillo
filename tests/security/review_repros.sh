#!/bin/sh
# Reruns the security review's proxy repros (2026-11-16) against kd-testproxy with dummy keys.
# Needs the breakers harness running: (cd ~/Desktop/keydillo-breakers && python3 harness/up.py &)
P=http://127.0.0.1:19787
c() { curl -s --noproxy '*' "$@"; }
check() { if echo "$2" | grep -q "$3"; then echo "PASS  $1"; else echo "FAIL  $1"; echo "      got: $(echo "$2" | head -c 200)"; fi; }

check "1  placeholder in body refused" "$(c -X POST $P/echo/post -H 'Host: localhost:7787' -d 'secret=keydillo:echo')" placeholder_misplaced
check "1  placeholder in query refused" "$(c "$P/echo/get?k=keydillo:echo" -H 'Host: localhost:7787')" placeholder_misplaced
check "1  placeholder in other header refused" "$(c $P/echo/get -H 'Host: localhost:7787' -H 'X-Other: keydillo:echo')" placeholder_misplaced
check "1  placeholder in path refused" "$(c $P/echo/keydillo:echo/x -H 'Host: localhost:7787')" placeholder_misplaced
check "4  Upgrade: websocket on a non-101 reply stays redacted" "$(c $P/echo/get -H 'Host: localhost:7787' -H 'Upgrade: websocket' -H 'Connection: Upgrade' --max-time 5)" 'redacted by keydillo'
check "5  echoed key redacted" "$(c $P/echo/get -H 'Host: localhost:7787')" 'redacted by keydillo'
for p in '/public/.%2e/secret' '/public/%2e./secret' '/public/%2e%2E/secret' '/public/..%2fsecret' '/public/%5c..%5csecret'; do
  check "8  dot/encoded segment refused: $p" "$(c -o /dev/null -w '%{http_code}' "$P/echo$p" -H 'Host: localhost:7787' --path-as-is)" '^400$'
done
check "9  Origin prefix trick refused" "$(c -o /dev/null -w '%{http_code}' $P/echo/get -H 'Host: localhost:7787' -H 'Origin: http://localhost.evil.example')" '^403$'
check "9  missing Host refused" "$(printf 'GET /echo/get HTTP/1.1\r\nConnection: close\r\n\r\n' | nc -w 3 127.0.0.1 19787 | head -1)" ' 400 \| 403 '
check "9  DNS-rebinding Host refused" "$(c -o /dev/null -w '%{http_code}' $P/echo/get -H 'Host: evil.example:7787')" '^403$'
echo "Findings 2, 3, 5 (Basic/base64/percent forms) and 6 are covered by swift test (testStrictHosts, testRedactionForms, testCallerScope)."
