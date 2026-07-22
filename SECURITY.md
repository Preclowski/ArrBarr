# Security Policy

## Reporting a vulnerability

Please report security issues **privately**, through GitHub's
[private vulnerability reporting](https://github.com/Preclowski/ArrBarr/security/advisories/new)
form, rather than opening a public issue.

Include what you did, what happened, and the ArrBarr version (Settings →
About). A proof of concept helps, but a clear description is enough.

This is a small, single-maintainer project. Expect a first reply within about a
week. There is no bug-bounty program.

## Supported versions

Only the latest released version is supported. Fixes ship in a new release
rather than as patches to older tags.

## Why this matters more than for a typical menu-bar app

ArrBarr holds credentials that grant full control of your media stack, and it
can open a local HTTP listener:

- **\*arr API keys** — a Sonarr/Radarr/Lidarr/Whisparr API key is not read-only.
  It can add, delete and reconfigure everything in that instance.
- **Download-client credentials** — qBittorrent, Transmission, rTorrent, Deluge,
  SABnzbd and NZBGet passwords, which usually reach a web UI that can write to
  disk.
- **Third-party API keys** — your OpenAI-compatible and TMDB keys, which are
  billable.
- **The MCP server** — an HTTP server bound on your machine that exposes those
  same *arr capabilities as callable tools.

## Where secrets are stored

ArrBarr picks its secret store at runtime, based on what the running binary's
**code signature** actually provisions:

| Build | Store |
| --- | --- |
| Signed with a team identity that provisions the shared Keychain access group (the App Store build) | the system **Keychain**, data-protection class |
| Everything else — local Debug builds, the self-signed DMG from Releases, forks signed by another team | a plist inside the app's **sandboxed container** |

The fallback is not a shortcut: `keychain-access-groups` is a restricted
entitlement that requires a provisioning profile issued by Apple, which an
ad-hoc signature can never carry. A build that later gains such a profile
migrates its secrets into the Keychain on first launch.

**Practical consequence:** in the OSS/Homebrew build, your API keys sit in a
plist inside the app container. That is protected by the macOS sandbox and by
FileVault, but not encrypted independently. Anything running as your user can
read it. If that is not acceptable in your threat model, use FileVault and do
not run untrusted code as your own user.

The MCP bearer token is always device-only and is never synced to iCloud, even
in App Store builds.

## MCP server exposure

The MCP server is **off by default**. When enabled, the defaults are:

- binds `127.0.0.1:8080` — loopback only
- bearer-token authentication **on**
- the server **refuses to start** on a non-loopback address if authentication is
  disabled
- the `Origin` header is validated, so a page in your browser cannot drive it
- every tool can be individually disabled

If you change the bind address to reach ArrBarr from another machine, you are
publishing *arr control to your network. Keep the bearer token on, put it behind
a reverse proxy with TLS, and do not expose it to the internet. There is no rate
limiting and no per-tool authorization beyond the on/off switch.

## What leaves your machine

- **\*arr and download-client traffic** goes only to the URLs you configure.
  There is no ArrBarr backend, no telemetry, no analytics and no account.
- **Apple Intelligence** chat runs on-device.
- **OpenAI-compatible chat** sends your messages, the tool catalog and tool
  results — which include your library and queue contents — to whatever endpoint
  you configured. Choose that endpoint accordingly.
- **TMDB** receives the search and discovery queries you make in Search and Quiz.
- **iCloud sync**, in App Store builds only and only when you enable it, mirrors
  settings through iCloud key-value storage and secrets through iCloud Keychain.

## Distribution caveat

Releases here are signed with a self-signed certificate and are **not
notarized** — there is no paid Apple Developer account behind the OSS build.
Gatekeeper will warn on first launch. Verify the DMG's SHA-256 against the
checksum in the Homebrew cask, or build from source, if that matters to you.

## Out of scope

- Vulnerabilities in Sonarr, Radarr, Lidarr, Whisparr or any download client —
  report those upstream.
- Anything requiring an attacker who already has code execution as your user.
- Gatekeeper warnings caused by the lack of notarization (see above).
