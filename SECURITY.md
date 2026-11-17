# Security policy

keydillo exists to keep API keys away from AI agents, so security reports are the most useful kind.

## Reporting a vulnerability

Please report privately through GitHub: **Security → Report a vulnerability** on this repository
(GitHub private vulnerability reporting). Don't open a public issue for anything that could expose a key.

Helpful to include: what you did, what keydillo did, the macOS version, and the keydillo version or commit.
Please use dummy keys in reproductions.

You'll get an acknowledgement within a few days. Fixes for confirmed issues are released as soon as they're ready,
and reporters are credited unless they'd rather not be.

## Scope

In scope: anything that lets a program read a stored key, send it somewhere other than its configured host,
or use it without the approval keydillo is supposed to ask for. See "Security model and limits" in the README for
what keydillo deliberately does not cover (copies of keys made before install or after export, what an approved
program does with an API).
