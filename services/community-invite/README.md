# Zulangue community invite service

This is a test-only community access service. One invitation grants 5 Give,
equivalent to 30 hours
of processed audio time across every supported mode. It does not expose money,
credits, Soniox, or provider pricing to invited partners.

The long-lived `SONIOX_API_KEY` belongs only in `service.env` on the server.
Never commit it. Clients receive short-lived temporary keys scoped to
transcription WebSocket access; they never receive the server key.

Run tests:

```sh
python3 -m unittest -v test_server.py
```

Create a partner invite:

```sh
python3 server.py --db data/invites.db create-invite --label partner-name --gives 5
```
