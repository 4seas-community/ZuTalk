# Zulangue community invite service

This is a test-only community access service. One invitation grants 5 Give,
equivalent to 30 hours of realtime transcription and translation lane time.
Invite time covers realtime capture only: Soniox temporary keys are
WebSocket-scoped, so after-stop (async file) transcription always runs on the
invited partner's own key, and the app offers a Settings jump instead of
spending invite time on it. It does not expose money, credits, Soniox, or
provider pricing to invited partners.

The long-lived `SONIOX_API_KEY` belongs only in `service.env` on the server.
Never commit it. Clients receive short-lived temporary keys scoped to
transcription WebSocket access; they never receive the server key.

Abuse bounds enforced server-side: at most 2 open sessions per invite, and a
finite per-session key budget (16) shared by the initial key, renewals
(`POST /v1/realtime-session/renew-key`, for recordings longer than the 1-hour
key lifetime), and single-use per-connection keys
(`POST /v1/realtime-session/key`, one key = one WebSocket lane, 5-minute
expiry — the future invite client path). A multi-language capture start
passes `count` (up to 4) to fetch one key per lane in a single request;
the response carries them in `keys`. A batch is claimed against the budget in
one transaction before any key is minted, so concurrent requests cannot both
pass a headroom check and hand out keys the budget never covered; a batch
that does not fit is refused whole.

`POST /v1/realtime-session` takes `lane_count` alongside `requested_seconds`.
Reservations are counted in lane-seconds — a capture with three target
languages opens one canonical lane plus three translation lanes and spends
four seconds of quota per second of audio — while Soniox's
`max_session_duration_seconds` bounds each WebSocket in wall-clock seconds.
The server divides the reservation by the lane count to derive that bound.
Passing the raw reservation would let every lane run the full reservation on
its own, overshooting the quota by the lane count.

Set `ZULANGUE_ADMIN_TOKEN` in `service.env` to enable the admin panel at
`/admin`. Signing in exchanges the token for an HttpOnly, SameSite=Strict
session cookie (8 hours, memory-only — a restart signs you out); every
mutation carries a CSRF token bound to that session, so the token never rides
in a URL. The panel generates invitation codes, and its table follows each
invitation's quota, usage, sessions, keys, billed cost and last activity while
letting you rename it, grant or withdraw hours, and pause or resume access.

A generated code is shown once. Only its SHA-256 is stored, so a leaked
database does not leak usable invitations — and the panel cannot show a code
again. Quota grants and access changes are recorded in `invite_audit` for
accountability; the panel does not display that table. Withdrawing quota
settles at used plus reserved, so an invitation can never owe back time it has
already spent or is currently streaming on.
Settled seconds are client-reported. Pull what Soniox actually billed and
attribute it back to reservations:

```sh
SONIOX_API_KEY=... python3 server.py --db data/invites.db reconcile --hours 24
```

Entries are stored under Soniox's own uuid, so overlapping windows and repeat
runs never double-count — a cron every few hours is the intended use. Usage
whose `client_reference_id` does not carry the `zulangue-community:` prefix,
or names a session this database never issued, is kept unattributed; the
admin page shows it separately alongside billed hours and cost per invite.
A large gap between reported and billed hours means a client under-reported.

Run tests:

```sh
python3 -m unittest -v test_server.py
```

Create a partner invite:

```sh
python3 server.py --db data/invites.db create-invite --label partner-name --gives 5
```
