%% Self-signed certificate material for TLS tests, written as PEM files
%% into a temporary directory.
-module(barrel_a2a_test_tls).

-include_lib("public_key/include/public_key.hrl").

-export([make_certs/0]).

%% Returns `#{certfile, keyfile, cacertfile, dir}'.
-spec make_certs() -> map().
make_certs() ->
    Root = public_key:pkix_test_root_cert("barrel_a2a test root", [{key, {rsa, 2048, 65537}}]),
    Server = public_key:pkix_test_data(#{
        root => Root,
        peer => [{key, {rsa, 2048, 65537}}, {extensions, [localhost_san()]}]
    }),
    CertDer = proplists:get_value(cert, Server),
    {KeyType, KeyDer} = proplists:get_value(key, Server),
    [CaDer | _] = proplists:get_value(cacerts, Server),
    Dir = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "barrel_a2a_tls_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    CertFile = filename:join(Dir, "server.pem"),
    KeyFile = filename:join(Dir, "server-key.pem"),
    CaFile = filename:join(Dir, "ca.pem"),
    ok = file:write_file(
        CertFile, public_key:pem_encode([{'Certificate', CertDer, not_encrypted}])
    ),
    ok = file:write_file(KeyFile, public_key:pem_encode([{KeyType, KeyDer, not_encrypted}])),
    ok = file:write_file(CaFile, public_key:pem_encode([{'Certificate', CaDer, not_encrypted}])),
    #{certfile => CertFile, keyfile => KeyFile, cacertfile => CaFile, dir => Dir}.

%% The server certificate must name `localhost' for clients that verify.
localhost_san() ->
    #'Extension'{
        extnID = ?'id-ce-subjectAltName',
        extnValue = [{dNSName, "localhost"}, {iPAddress, <<127, 0, 0, 1>>}],
        critical = false
    }.
