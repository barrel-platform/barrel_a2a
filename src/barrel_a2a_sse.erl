%%%-------------------------------------------------------------------
%%% @doc Server-Sent Events encoding and an incremental parser.
%%%
%%% The JSON-RPC and REST bindings stream task events as SSE: each
%%% event is one `data: <json>' block terminated by a blank line,
%%% optionally preceded by `event:', `id:' and `retry:' lines.
%%% {@link encode/1} builds such a block and {@link comment/1} builds a
%%% keep-alive comment.
%%%
%%% The parser follows the WHATWG EventSource algorithm. Feed it
%%% chunks as they arrive with {@link feed/2}; every call returns the
%%% events completed so far and keeps the partial tail, so chunk
%%% boundaries may fall anywhere, including between the CR and LF of
%%% one line ending. {@link finish/1} flushes an event that the stream
%%% ended without a blank line. A parser refuses to buffer more than
%%% `max_event_bytes' (default 16 MiB) for one event.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_a2a_sse).

-export([encode/1, encode/2, comment/1]).
-export([new/0, new/1, feed/2, finish/1, last_event_id/1]).

-define(DEFAULT_MAX_EVENT_BYTES, 16 * 1024 * 1024).

-type event() :: #{
    data := binary(),
    event => binary(),
    id => binary(),
    retry => non_neg_integer()
}.

-type opts() :: #{max_event_bytes => pos_integer()}.

-record(parser, {
    %% Partial line not yet terminated.
    buf = <<>> :: binary(),
    %% True when the previous chunk ended with a CR: a leading LF in
    %% the next chunk belongs to that same line break.
    pending_cr = false :: boolean(),
    %% Data lines of the current event, reversed, and their byte total.
    data = [] :: [binary()],
    data_size = 0 :: non_neg_integer(),
    event :: binary() | undefined,
    retry :: non_neg_integer() | undefined,
    last_event_id :: binary() | undefined,
    max :: pos_integer()
}).

-opaque parser() :: #parser{}.

-export_type([event/0, opts/0, parser/0]).

%%--------------------------------------------------------------------
%% Encoding
%%--------------------------------------------------------------------

%% @doc Encode a data-only event or an {@link event()} map.
%%
%% Multi-line data is split into one `data:' line per line so the
%% receiver joins it back with `\n'. The `id', `event' and `retry'
%% lines come first, then the data lines, then the blank line.
-spec encode(iodata() | event()) -> iodata().
encode(Event) -> encode(Event, #{}).

%% @doc Same as {@link encode/1}; the options map is reserved.
-spec encode(iodata() | event(), #{}) -> iodata().
encode(#{data := Data} = Event, _Opts) ->
    [
        field(<<"id">>, maps:get(id, Event, undefined)),
        field(<<"event">>, maps:get(event, Event, undefined)),
        retry_field(maps:get(retry, Event, undefined)),
        data_lines(Data),
        $\n
    ];
encode(Data, _Opts) ->
    [data_lines(Data), $\n].

field(_Name, undefined) -> [];
field(Name, Value) -> [Name, <<": ">>, Value, $\n].

retry_field(undefined) -> [];
retry_field(Ms) when is_integer(Ms), Ms >= 0 -> [<<"retry: ">>, integer_to_binary(Ms), $\n].

data_lines(Data) ->
    Lines = binary:split(iolist_to_binary(Data), [<<"\r\n">>, <<"\n">>, <<"\r">>], [global]),
    [[<<"data: ">>, Line, $\n] || Line <- Lines].

%% @doc A comment block, `:<text>\n\n'.
%%
%% A single `:<text>\n' line would be a valid comment, but the extra
%% blank line makes it a block of its own so a receiver that buffers
%% until the next blank line sees it immediately. Comments are used
%% as keep-alives; the parser drops them. Line breaks in `Text' are
%% replaced by spaces so the comment stays one line.
-spec comment(iodata()) -> iodata().
comment(Text) ->
    Bin = iolist_to_binary(Text),
    Flat = binary:replace(Bin, [<<"\r\n">>, <<"\n">>, <<"\r">>], <<" ">>, [global]),
    [$:, Flat, <<"\n\n">>].

%%--------------------------------------------------------------------
%% Parsing
%%--------------------------------------------------------------------

-spec new() -> parser().
new() -> new(#{}).

-spec new(opts()) -> parser().
new(Opts) ->
    #parser{max = maps:get(max_event_bytes, Opts, ?DEFAULT_MAX_EVENT_BYTES)}.

%% @doc The last `id' seen, whether or not its event carried data.
-spec last_event_id(parser()) -> binary() | undefined.
last_event_id(#parser{last_event_id = Id}) -> Id.

%% @doc Parse a chunk. Returns the events completed by this chunk, in
%% order, and the parser holding whatever is still incomplete.
-spec feed(binary(), parser()) -> {[event()], parser()} | {error, event_too_large}.
feed(Chunk, #parser{buf = Buf, pending_cr = PendingCr} = P) when is_binary(Chunk) ->
    Rest =
        case {PendingCr, Chunk} of
            {true, <<$\n, Tail/binary>>} -> Tail;
            _ -> Chunk
        end,
    lines(<<Buf/binary, Rest/binary>>, P#parser{buf = <<>>, pending_cr = false}, []).

lines(Buf, P, Acc) ->
    case binary:match(Buf, [<<"\r\n">>, <<"\n">>, <<"\r">>]) of
        nomatch ->
            check_size(P#parser{buf = Buf}, lists:reverse(Acc));
        {Pos, Len} ->
            <<Line:Pos/binary, _:Len/binary, Tail/binary>> = Buf,
            PendingCr = Len =:= 1 andalso Tail =:= <<>> andalso binary:at(Buf, Pos) =:= $\r,
            case line(Line, P#parser{pending_cr = PendingCr}) of
                {ok, P1} -> lines(Tail, P1, Acc);
                {event, Event, P1} -> lines(Tail, P1, [Event | Acc]);
                {error, _} = Error -> Error
            end
    end.

check_size(#parser{buf = Buf, data_size = Size, max = Max}, _) when byte_size(Buf) + Size > Max ->
    {error, event_too_large};
check_size(P, Events) ->
    {Events, P}.

%% @doc End of stream. Per WHATWG an event is dispatched at end of
%% stream only when its data buffer is not empty; a partial line is
%% processed first.
-spec finish(parser()) -> [event()].
finish(#parser{buf = <<>>} = P) ->
    case dispatch(P) of
        {event, Event, _} -> [Event];
        {ok, _} -> []
    end;
finish(#parser{buf = Buf} = P) ->
    case line(Buf, P#parser{buf = <<>>}) of
        {event, Event, _} -> [Event];
        {ok, P1} -> finish(P1);
        {error, _} -> []
    end.

line(<<>>, P) ->
    dispatch(P);
line(<<$:, _/binary>>, P) ->
    {ok, P};
line(Line, P) ->
    {Name, Value} =
        case binary:split(Line, <<":">>) of
            [N, <<$\s, V/binary>>] -> {N, V};
            [N, V] -> {N, V};
            [N] -> {N, <<>>}
        end,
    field_line(Name, Value, P).

field_line(<<"data">>, Value, #parser{data = Data, data_size = Size, max = Max} = P) ->
    NewSize = Size + byte_size(Value) + 1,
    case NewSize > Max of
        true -> {error, event_too_large};
        false -> {ok, P#parser{data = [Value | Data], data_size = NewSize}}
    end;
field_line(<<"event">>, Value, P) ->
    {ok, P#parser{event = Value}};
field_line(<<"id">>, Value, P) ->
    case binary:match(Value, <<0>>) of
        nomatch -> {ok, P#parser{last_event_id = Value}};
        _ -> {ok, P}
    end;
field_line(<<"retry">>, Value, P) ->
    case Value =/= <<>> andalso all_digits(Value) of
        true -> {ok, P#parser{retry = binary_to_integer(Value)}};
        false -> {ok, P}
    end;
field_line(_, _, P) ->
    {ok, P}.

all_digits(Bin) ->
    lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Bin)).

dispatch(#parser{data = []} = P) ->
    {ok, reset(P)};
dispatch(#parser{data = Data, event = Name, retry = Retry, last_event_id = Id} = P) ->
    Event0 = #{data => iolist_to_binary(lists:join($\n, lists:reverse(Data)))},
    Event1 = put_if(event, Name, Event0),
    Event2 = put_if(id, Id, Event1),
    Event = put_if(retry, Retry, Event2),
    {event, Event, reset(P)}.

put_if(_Key, undefined, Event) -> Event;
put_if(event, <<>>, Event) -> Event;
put_if(Key, Value, Event) -> Event#{Key => Value}.

reset(P) ->
    P#parser{data = [], data_size = 0, event = undefined, retry = undefined}.
