#!/bin/bash
# Calls ElevenLabs through agent-vault. No key anywhere in this script or its environment.
# Usage: scripts/tts-test.sh [port] [voice_id]
PORT=${1:-$(defaults read com.studiokillswitch.agentvault port 2>/dev/null || echo 8787)}
VOICE=${2:-21m00Tcm4TlvDq8ikWAM}
OUT=/tmp/agent-vault-test.mp3
echo "POST localhost:$PORT/elevenlabs/v1/text-to-speech/$VOICE (approve with Touch ID)"
code=$(curl -s -o "$OUT" -w "%{http_code}" -X POST "http://127.0.0.1:$PORT/elevenlabs/v1/text-to-speech/$VOICE" \
  -H "Content-Type: application/json" -H "Accept: audio/mpeg" \
  -d '{"text":"The key never left the vault.","model_id":"eleven_multilingual_v2"}')
echo "HTTP $code"
if [ "$code" = "200" ]; then file "$OUT"; afplay "$OUT"; else cat "$OUT"; echo; fi
