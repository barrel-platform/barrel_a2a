# Reference SDK interop tests

Checks that `barrel_a2a` and the official A2A SDKs understand each
other on the wire, in both directions and over both HTTP bindings. You
need this when you change anything in the JSON-RPC or HTTP+JSON codecs,
the card, the task lifecycle or the streaming layer, and want proof
against an independent implementation rather than our own client.

Three reference implementations run the same cases:

| Language | Package | Pinned in | Toolchain variable |
|---|---|---|---|
| Python | `a2a-sdk[http-server]` 1.1.4 | `requirements.txt` | `INTEROP_PYTHON` |
| JavaScript | `@a2a-js/sdk` 1.2.0 | `js/package.json` | `INTEROP_NODE` |
| Go | `github.com/a2aproject/a2a-go/v2` v2.5.0 | `go/go.mod` | `INTEROP_GO_BIN` |

The suite is `test/barrel_a2a_interop_SUITE.erl`, with one CT group per
language. A group skips when its toolchain variable is unset, so plain
`rebar3 ct` needs none of them.

## Run

```sh
make interop-python   # a2a-sdk, creates test/interop/.venv on first run
make interop-js       # @a2a-js/sdk, npm install on first run
make interop-go       # a2a-go, builds go/bin/{server,client} on first run
make interop          # all three
```

Each setup step is idempotent. `make clean` removes the venv, the
`node_modules` directory and the Go binaries.

To run a single case:

```sh
INTEROP_NODE=$(command -v node) \
    rebar3 ct --suite=test/barrel_a2a_interop_SUITE --group=js --case=ref_client_rest_stream
```

## What runs

`ref_client_<binding>_<scenario>`: the suite starts an Erlang server on
a free port hosting `barrel_a2a_test_agent` and runs that language's
client script with `<url> <jsonrpc|rest> <scenario>`. The script
resolves the card from `/.well-known/agent-card.json`, builds an SDK
client bound to the requested transport and prints one JSON object per
step on stdout; the case asserts on those lines and on the exit code.

| scenario | what it checks |
|---|---|
| `card` | name, skill count, streaming flag, both interfaces advertised |
| `send` | blocking `SendMessage`, `echo: interop` completes with that artifact |
| `stream` | `SendStreamingMessage`, event order task / working / two artifact chunks / completed |
| `multiturn` | `ask` pauses in `input_required`; a follow-up on the same task completes with `thanks: second` |
| `cancel` | return-immediately, then `CancelTask`, then `GetTask` reads `canceled` |
| `direct` | `direct` answers with a Message instead of a Task |
| `get` | `GetTask` after a completed send |

`ref_server_<binding>_<scenario>`: the suite picks a free port, starts
that language's server script as `<port> both` (an SDK agent executor
mirroring the test agent, JSON-RPC at `/a2a/jsonrpc` and REST under
`/a2a/v1`), waits for its `READY <port>` line and drives it with
`barrel_a2a_client` for the same scenarios except `card`. The process
is killed in `end_per_testcase`.

## Adding a language

1. Write `<lang>/server.<ext>` and `<lang>/client.<ext>` mirroring the
   existing pair. The contract is small: the server takes
   `<port> both` and prints `READY <port>`; the client takes
   `<url> <binding> <scenario>` and prints one JSON object per step,
   ending with `{"step":"done"}`. Step and field names are shared
   across languages, because the assertions are.
2. Add a clause to `runner/1` in the suite and the language to
   `?LANGUAGES`.
3. Add `interop-<lang>` to the Makefile and a job to CI.

## Notes

- Every script exits non-zero and prints a trace on failure; the suite
  gives up on a client after 60 s so a hang reaches the CT log.
- Versions are pinned for reproducibility. Bump them on purpose when
  validating against a newer release, and run all three groups after.
- Run the scripts by hand while iterating: start a server in one shell,
  then the client in another.
- The three reference servers must stay in step with each other and
  with `barrel_a2a_test_agent`: the suite runs the same assertions
  against all of them.
