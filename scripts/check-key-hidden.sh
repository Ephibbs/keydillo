#!/bin/bash
# Tries the ways an agent could read the key from a shell. All should fail.
echo "1. Environment variables:"; env | grep -i -E "eleven|xi-api" || echo "   none"
echo "2. Config files:"; grep -rIl "agent-vault" ~/Library/Application\ Support/agent-vault 2>/dev/null || echo "   none on disk (configs live in the Keychain)"
echo "3. security find-generic-password -w (a macOS prompt may appear: click Deny):"
if out=$(security find-generic-password -s agent-vault.secret -a elevenlabs -w 2>&1); then
  echo "   READ SUCCEEDED (bad): ${#out} chars"
else
  echo "   failed: $out"
fi
echo "4. Debugger attach:"
pid=$(pgrep -x agent-vault) && (lldb -p "$pid" --batch -o "detach" 2>&1 | grep -E -i "error|attached" | head -2) || echo "   app not running"
