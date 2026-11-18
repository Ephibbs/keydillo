#!/bin/zsh -f
# Which Go and Rust SDKs follow a base-URL variable (what kd sets for this project's keys). Needs go and cargo.
# Uses a local mock server and placeholder keys; nothing is sent to a provider when the SDK follows the variable.
cd ${0:A:h}
L=$(mktemp); python3 mock.py 18801 $L & M=$!; trap 'kill $M' EXIT; sleep 1
export OPENAI_API_KEY=placeholder ANTHROPIC_API_KEY=placeholder
export OPENAI_BASE_URL=http://127.0.0.1:18801/openai/v1 ANTHROPIC_BASE_URL=http://127.0.0.1:18801/anthropic
go build -o /tmp/kd-sdkcheck-go . || exit 1
(cd ../sdk-rust && cargo build -q) || exit 1
check() { : > $L; "$@" >/dev/null 2>&1; [[ -s $L ]] && print "follows base URL   $2" || print "ignores base URL   $2" }
check /tmp/kd-sdkcheck-go openai-go
check /tmp/kd-sdkcheck-go anthropic-sdk-go
check /tmp/kd-sdkcheck-go go-openai
check ../sdk-rust/target/debug/kdsdkcheck async-openai
