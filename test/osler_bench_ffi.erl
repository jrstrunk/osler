%% Benchmark-only shim around OTP's own RFC 3339 parser.
%%
%% `calendar:rfc3339_to_system_time/2` signals failure by raising, which Gleam
%% cannot catch, so this wraps it into a `Result`. The `try` costs a few ns on
%% BEAM and is on both the success and failure paths, so it does not flatter
%% the native parser.
-module(osler_bench_ffi).

-export([rfc3339_to_system_time/1]).

rfc3339_to_system_time(Bin) ->
    try calendar:rfc3339_to_system_time(Bin, [{unit, nanosecond}]) of
        Value -> {ok, Value}
    catch
        _:_ -> {error, nil}
    end.
