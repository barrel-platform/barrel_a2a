# 0001. Protocol objects are wire JSON maps

## Context

A2A defines its objects in Protocol Buffers and serializes them as
ProtoJSON: camelCase keys, enums as their proto names, timestamps as
ISO 8601 strings. Every implementation has to choose an internal
representation. The obvious candidates were Erlang records with a
codec at the edges, gpb-generated maps from the official `a2a.proto`,
or the wire JSON maps themselves.

## Decision

Protocol objects are the wire JSON maps, exactly as `json:decode/1`
returns them: binary camelCase keys, enum values as binaries,
timestamps as text, `metadata` and `data` as plain JSON terms. Modules
such as `barrel_a2a_message` and `barrel_a2a_task` are accessors and
constructors over that shape, not a separate representation.

## Consequences

There is no codec and no conversion layer, so no class of bug where
the internal and external shapes disagree, and an object that arrives
unrecognized survives a round trip intact (the specification requires
ignoring unknown fields, and this gets it for free).

Erlang code reads `maps:get(<<"contextId">>, Task)` rather than a
record field, which is uglier and unchecked by the compiler. The
accessor modules exist to keep that out of application code, and
`barrel_a2a_validate` plus the published JSON Schema do the checking
the compiler cannot.

gpb was rejected because it would have pulled a code generation step
and a protobuf dependency into a library whose only mandatory bindings
are JSON, and because ProtoJSON is what actually crosses the wire. The
gRPC binding, which does need gpb, converts between gpb maps and these
maps at its edge; see [0005](0005-grpc-in-a-separate-package.md).
