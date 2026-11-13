#!/usr/bin/env python3
"""Runs the city's server from a checkout for an end-to-end check on this machine.

    CITY_SRC=<city checkout> python3 -B tools/city-interop/local-city.py <state dir> <port>

It differs from the city's own launcher in three ways, all of them to keep a
test contained: it listens on 127.0.0.1 only, every byte of state goes under
the directory given, and none of the background jobs that talk to other
hosts are started. Run it with -B (or PYTHONDONTWRITEBYTECODE=1) so that
importing the checkout writes nothing into it.
"""
import functools
import http.server
import os
import sys

src = os.environ.get("CITY_SRC")
if not src or not os.path.isfile(os.path.join(src, "server", "hub.py")) or len(sys.argv) != 3:
    sys.exit(__doc__)
sys.path.insert(0, src)

from server import state  # noqa: E402

state.KEEP = os.path.abspath(sys.argv[1])
os.makedirs(state.KEEP, exist_ok=True)

from server.record import CAN_VERIFY  # noqa: E402

if not CAN_VERIFY:
    sys.exit("The city's server needs the Python 'cryptography' package to keep records.")

from server.citydid import key_open  # noqa: E402
from server.did import witness_open  # noqa: E402
from server.drop import load as drop_load  # noqa: E402
from server.handler import Handler  # noqa: E402
from server.hub import after_load, load  # noqa: E402
from server.tlog import tlog_open  # noqa: E402

load()
drop_load()
witness_open()
key_open()
after_load()
tlog_open()

# An empty directory stands in for the built pages: only the interfaces are used.
site = os.path.join(state.KEEP, "site")
os.makedirs(site, exist_ok=True)
state.ROOT = site
server = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), functools.partial(Handler, directory=site))
print("ready", flush=True)
server.serve_forever()
