.PHONY: all compile check fmt lint xref dialyzer test eunit ct docs examples-setup examples-test interop-setup interop-python clean

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
	    rebar3 ct --suite=test/barrel_a2a_python_interop_SUITE

clean:
	rebar3 clean
	rm -rf examples/*/_build examples/*/_checkouts test/interop/.venv
