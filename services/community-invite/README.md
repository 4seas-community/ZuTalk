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

Set `ZULANGUE_ADMIN_TOKEN` in `service.env` to enable `GET /admin` (Bearer
token or `?token=`): per-invite used/reserved lane-hours, open sessions,
keys issued, and an estimated cost at the Soniox realtime list price.
Settled seconds are client-reported; reconcile against Soniox
`GET /v1/usage-logs` by `client_reference_id` prefix `zulangue-community:`
for ground truth.

Run tests:

```sh
python3 -m unittest -v test_server.py
```

Create a partner invite:

```sh
python3 server.py --db data/invites.db create-invite --label partner-name --gives 5
```
