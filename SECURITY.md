# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub: on the repository's **Security** tab choose **Report a vulnerability** (GitHub private vulnerability reporting / security advisories). Do not open a public issue for something exploitable.

Include what you found, how to reproduce it, and the macOS, Claude Code and app versions. You can expect an acknowledgement, and a fix or an explanation, as soon as the maintainer is able; this is a volunteer project without a service-level agreement.

## What the app exposes

Open Agent Deck is a local app, and its security-relevant surface is small but real:

- **A loopback HTTP server** (default `127.0.0.1:8765`, override with `OAD_HOOK_PORT`). It receives Claude Code hook events and can answer permission requests, which means a client that can reach it could influence whether a tool call is approved. It binds to `127.0.0.1` only and is not reachable from the network.
- **Edits to `~/.claude/settings.json`**, made only when the user connects (and to repair its own entries afterwards). The merge preserves everything else in the file.
- **Typing into terminal sessions** through the cmux CLI, which can submit text to a running Claude Code session.
- **Processes it runs:** `claude`, `cmux`, `/bin/ps`; `/bin/zsh -lic "command -v claude"` to locate `claude` (an interactive login shell, so it sources your shell rc files); `/usr/bin/env` as a last-resort lookup of `claude`; and, for crash recovery, a detached `/bin/sh` that calls `/usr/bin/open`.

There is no telemetry, and the only network traffic is loopback.

## In scope

- Anything that lets another local user, another local process without the user's intent, or a web page (for example via DNS rebinding or cross-origin requests to the loopback server) approve, deny or answer a request, or inject text into a session.
- Corrupting or clobbering `~/.claude/settings.json`, or failing to remove the deck's entries on disconnect.
- Command or argument injection through values taken from hook payloads, session names or terminal titles.
- Leaking prompt, command or path content into the log or diagnostics.

## Out of scope

- Attacks that already require the ability to run code as the same user (that user can edit `settings.json` directly).
- Vulnerabilities in Claude Code, cmux or macOS themselves; report those to their vendors.
- Denial of service by a local process on a loopback port.

## Supported versions

There are no releases yet. Fixes land on the main branch.
