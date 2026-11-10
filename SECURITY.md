# Security Policy

This page tells you how to report a vulnerability in barrel_a2a and
which releases get fixes. Use it when you find a way to bypass
authentication or authorization, reach an address the SSRF guard
should block, read another caller's tasks, exhaust a server past its
configured limits, or forge or tamper with protocol objects.

## Report a vulnerability

Report it privately through GitHub, not in a public issue or pull
request:

1. Open https://github.com/barrel-platform/barrel_a2a/security/advisories/new
   (or the repository's **Security** tab, then **Report a
   vulnerability**).
2. Describe the issue, the affected version, and the steps or a
   minimal program that reproduces it.
3. Say what an attacker gains and what configuration it needs (for
   example `auth`, `authorize` or `push_notifications` options).

You will get an answer in the advisory thread. Once a fix is released,
the advisory is published with credit to you unless you ask otherwise.

## Supported versions

Fixes go into the latest release only. Upgrade to the newest 0.2.x
release to get them.

## Scope

barrel_a2a implements the A2A protocol boundary. Your deployment
decides the rest: authentication and authorization policy, TLS
certificates, network exposure, where `task_store` and
`push_config_store` files live and who can read them, and the
`secret_key` used to seal webhook secrets. See
[Authentication](guides/authentication.md) and
[Push notifications](guides/push-notifications.md) for the settings
that matter.

Issues in dependencies (`h1`, `h2`, `hackney`, `quic`) belong to those
projects; report them there, and here too if barrel_a2a's use of them
is what makes the issue exploitable.
