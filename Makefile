.PHONY: all compile check fmt lint xref dialyzer test eunit ct docs examples-setup examples-test interop-setup interop-python interop-js-setup interop-js interop-go-setup interop-go interop check-vectors clean

all: compile

compile:
	rebar3 compile

fmt:
	rebar3 fmt

lint:
	rebar3 lint

xref:
	rebar3 xref

dialyzer:
	rebar3 dialyzer

eunit:
	rebar3 eunit

ct:
	rebar3 ct

test: eunit ct

check: fmt compile lint xref dialyzer eunit ct

docs:
	rebar3 ex_doc

# Set up `_checkouts' symlinks so each example resolves `barrel_a2a'
# to the parent repo without fetching from hex/git.
examples-setup:
	@for ex in examples/*/; do \
	    mkdir -p "$$ex/_checkouts"; \
	    ln -snf ../../.. "$$ex/_checkouts/barrel_a2a"; \
	done
	@ln -snf ../../echo_server examples/echo_client/_checkouts/echo_server
	@ln -snf ../../streaming_server examples/streaming_client/_checkouts/streaming_server
	@# Local checkouts of the wire libraries, when the parent uses them.
	@for dep in _checkouts/*/; do \
	    [ -d "$$dep" ] || continue; \
	    name=$$(basename "$$dep"); \
	    for ex in examples/*/; do \
	        ln -snf "../../../_checkouts/$$name" "$$ex/_checkouts/$$name"; \
	    done; \
	done

examples-test: examples-setup
	@for ex in examples/*/; do \
	    echo "==> $$ex"; \
	    (cd "$$ex" && rebar3 ct) || exit 1; \
	done

# Python A2A SDK interop. `interop-setup' is idempotent. The CT suite
# skips when INTEROP_PYTHON is unset, so plain `rebar3 ct' remains
# independent of Python.
interop-setup:
	python3 -m venv test/interop/.venv
	./test/interop/.venv/bin/pip install --upgrade pip
	./test/interop/.venv/bin/pip install -r test/interop/requirements.txt

interop-python: interop-setup
	INTEROP_PYTHON=$(CURDIR)/test/interop/.venv/bin/python \
	    rebar3 ct --suite=test/barrel_a2a_interop_SUITE --group=python

# JavaScript SDK interop. Same shape: `interop-js-setup' is idempotent
# and the group skips when INTEROP_NODE is unset.
interop-js-setup:
	cd test/interop/js && npm install --no-audit --no-fund

interop-js: interop-js-setup
	INTEROP_NODE=$$(command -v node) \
	    rebar3 ct --suite=test/barrel_a2a_interop_SUITE --group=js

# Go SDK interop. Built ahead of time rather than run through `go run',
# which would rebuild on each client invocation.
interop-go-setup:
	cd test/interop/go && go build -o bin/server ./cmd/server && go build -o bin/client ./cmd/client

interop-go: interop-go-setup
	INTEROP_GO_BIN=$(CURDIR)/test/interop/go/bin \
	    rebar3 ct --suite=test/barrel_a2a_interop_SUITE --group=go

# Every reference implementation at once.
interop: interop-setup interop-js-setup interop-go-setup
	INTEROP_PYTHON=$(CURDIR)/test/interop/.venv/bin/python \
	INTEROP_NODE=$$(command -v node) \
	INTEROP_GO_BIN=$(CURDIR)/test/interop/go/bin \
	    rebar3 ct --suite=test/barrel_a2a_interop_SUITE

# Does the vendored spec still match what upstream publishes? Network
# dependent, so it is never part of `check' or the PR gate: a CI outage
# or an upstream edit must not turn an unrelated commit red. Run it
# deliberately, and see test/schema_vectors/1.0.1/VENDORED.md before
# acting on a difference.
A2A_TAG := v1.0.1
SCHEMA_URL := https://a2a-protocol.org/latest/spec/a2a.json
PROTO_URL := https://raw.githubusercontent.com/a2aproject/A2A/$(A2A_TAG)/specification/a2a.proto

check-vectors:
	@set -e; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	curl -sSfL "$(SCHEMA_URL)" -o "$$tmp/a2a.json"; \
	curl -sSfL "$(PROTO_URL)" -o "$$tmp/a2a.proto"; \
	fail=0; \
	for pair in "priv/schema/a2a.json:$$tmp/a2a.json" \
	            "test/schema_vectors/1.0.1/a2a.json:$$tmp/a2a.json" \
	            "docs/a2a.proto:$$tmp/a2a.proto"; do \
	    ours=$${pair%%:*}; theirs=$${pair#*:}; \
	    if cmp -s "$$ours" "$$theirs"; then \
	        echo "ok    $$ours  $$(shasum -a 256 < "$$ours" | cut -d' ' -f1)"; \
	    else \
	        echo "DRIFT $$ours"; \
	        echo "      ours   $$(shasum -a 256 < "$$ours" | cut -d' ' -f1)"; \
	        echo "      theirs $$(shasum -a 256 < "$$theirs" | cut -d' ' -f1)"; \
	        fail=1; \
	    fi; \
	done; \
	exit $$fail

clean:
	rebar3 clean
	rm -rf examples/*/_build examples/*/_checkouts test/interop/.venv \
	    test/interop/js/node_modules test/interop/go/bin
