# Python interop tests

Checks that `barrel_a2a` and the official A2A Python SDK (`a2a-sdk`,
pinned in `requirements.txt`) understand each other on the wire, in
both directions and over both HTTP bindings. You need this when you
change anything in the JSON-RPC or HTTP+JSON codecs, the card, the
task lifecycle or the streaming layer, and want proof against an
independent implementation rather than our own client.

The suite is `test/barrel_a2a_python_interop_SUITE.erl`. Every case
skips when `INTEROP_PYTHON` is unset or does not point at an
interpreter, so plain `rebar3 ct` never needs Python.

## Run

```sh
make interop-setup    # once: creates test/interop/.venv and installs requirements.txt
make interop-python   # runs the suite with INTEROP_PYTHON=test/interop/.venv/bin/python
```

`interop-setup` is idempotent. Remove `test/interop/.venv` to start
over; `make clean` does that too.

To run a single case:

```sh
INTEROP_PYTHON=$PWD/test/interop/.venv/bin/python \
    rebar3 ct --suite=test/barrel_a2a_python_interop_SUITE --case=python_client_rest_stream
```

## What runs

Direction A, `python_client_<binding>_<scenario>`: the suite starts an
Erlang server on a free port hosting `barrel_a2a_test_agent` and runs
`client.py <url> <jsonrpc|rest> <scenario>`. The script resolves the
card from `/.well-known/agent-card.json`, builds an SDK client bound
to the requested transport and prints one JSON object per step on
stdout; the case asserts on those lines and on the exit code.

| scenario | what it checks |
|---|---|
| `card` | name, skill count, streaming flag, both interfaces advertised |
| `send` | blocking `SendMessage`, `echo: from python` completes with that artifact |
| `stream` | `SendStreamingMessage`, event order task / working / two artifact chunks / completed |
| `multiturn` | `ask` pauses in `input_required`; a follow-up on the same task completes with `thanks: second` |
| `cancel` | `return_immediately`, then `CancelTask`, then `GetTask` reads `canceled` |
| `direct` | `direct` answers with a Message instead of a Task |
| `get` | `GetTask` after a completed send |

Direction B, `erlang_client_against_python_server_<binding>_<scenario>`:
the suite picks a free port, starts `server.py <port> both` (an SDK
`AgentExecutor` mirroring the test agent, JSON-RPC at `/a2a/jsonrpc`
and REST under `/a2a/v1`), waits for its `READY <port>` line and
drives it with `barrel_a2a_client` for the same scenarios except
`card`. The process is killed in `end_per_testcase`.

## Notes

- Both scripts exit non-zero and print a traceback on any failure;
  `client.py` also gives up after 40 s so a hang reaches the CT log.
- The SDK version is pinned for reproducibility. Bump it on purpose
  when validating against a newer release.
- Run the scripts by hand while iterating: start `server.py 9999`
  in one shell, then `client.py http://127.0.0.1:9999 jsonrpc stream`
  in another.
