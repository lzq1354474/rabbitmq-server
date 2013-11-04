%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2013 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_binary_parser).

-include("rabbit.hrl").

-export([parse_table/1]).
-export([ensure_content_decoded/1, clear_decoded_content/1]).
-export([validate_utf8/1, assert_utf8/1]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-spec(parse_table/1 :: (binary()) -> rabbit_framing:amqp_table()).
-spec(ensure_content_decoded/1 ::
        (rabbit_types:content()) -> rabbit_types:decoded_content()).
-spec(clear_decoded_content/1 ::
        (rabbit_types:content()) -> rabbit_types:undecoded_content()).
-spec(validate_utf8/1 :: (binary()) -> 'ok' | 'error').
-spec(assert_utf8/1 :: (binary()) -> 'ok').

-endif.

%%----------------------------------------------------------------------------

%% parse_table supports the AMQP 0-8/0-9 standard types, S, I, D, T
%% and F, as well as the QPid extensions b, d, f, l, s, t, x, and V.

parse_table(<<>>) ->
    [];
parse_table(<<NLen:8/unsigned, NameString:NLen/binary, ValueAndRest/binary>>) ->
    {Type, Value, Rest} = parse_field_value(ValueAndRest),
    [{NameString, Type, Value} | parse_table(Rest)].

parse_array(<<>>) ->
    [];
parse_array(<<ValueAndRest/binary>>) ->
    {Type, Value, Rest} = parse_field_value(ValueAndRest),
    [{Type, Value} | parse_array(Rest)].

parse_field_value(<<"S", VLen:32/unsigned, V:VLen/binary, R/binary>>) ->
    {longstr, V, R};

parse_field_value(<<"I", V:32/signed, R/binary>>) ->
    {signedint, V, R};

parse_field_value(<<"D", Before:8/unsigned, After:32/unsigned, R/binary>>) ->
    {decimal, {Before, After}, R};

parse_field_value(<<"T", V:64/unsigned, R/binary>>) ->
    {timestamp, V, R};

parse_field_value(<<"F", VLen:32/unsigned, Table:VLen/binary, R/binary>>) ->
    {table, parse_table(Table), R};

parse_field_value(<<"A", VLen:32/unsigned, Array:VLen/binary, R/binary>>) ->
    {array, parse_array(Array), R};

parse_field_value(<<"b", V:8/unsigned, R/binary>>) -> {byte,        V, R};
parse_field_value(<<"d", V:64/float,   R/binary>>) -> {double,      V, R};
parse_field_value(<<"f", V:32/float,   R/binary>>) -> {float,       V, R};
parse_field_value(<<"l", V:64/signed,  R/binary>>) -> {long,        V, R};
parse_field_value(<<"s", V:16/signed,  R/binary>>) -> {short,       V, R};
parse_field_value(<<"t", V:8/unsigned, R/binary>>) -> {bool, (V /= 0), R};

parse_field_value(<<"x", VLen:32/unsigned, V:VLen/binary, R/binary>>) ->
    {binary, V, R};

parse_field_value(<<"V", R/binary>>) ->
    {void, undefined, R}.

ensure_content_decoded(Content = #content{properties = Props})
  when Props =/= none ->
    Content;
ensure_content_decoded(Content = #content{properties_bin = PropBin,
                                          protocol = Protocol})
  when PropBin =/= none ->
    Content#content{properties = Protocol:decode_properties(
                                   Content#content.class_id, PropBin)}.

clear_decoded_content(Content = #content{properties = none}) ->
    Content;
clear_decoded_content(Content = #content{properties_bin = none}) ->
    %% Only clear when we can rebuild the properties later in
    %% accordance to the content record definition comment - maximum
    %% one of properties and properties_bin can be 'none'
    Content;
clear_decoded_content(Content = #content{}) ->
    Content#content{properties = none}.

assert_utf8(B) ->
    case validate_utf8(B) of
        ok    -> ok;
        error -> rabbit_misc:protocol_error(
                   frame_error, "Malformed UTF-8 in shortstr", [])
    end.

validate_utf8(<<C, Cs/binary>>) when C < 16#80 ->
    %% Plain Ascii character.
    validate_utf8(Cs);
validate_utf8(<<C1, C2, Cs/binary>>) when C1 band 16#E0 =:= 16#C0,
                                          C2 band 16#C0 =:= 16#80 ->
    case ((C1 band 16#1F) bsl 6) bor (C2 band 16#3F) of
	C when 16#80 =< C ->
	    validate_utf8(Cs);
	_ ->
            %% Bad range.
	    exit(bad)
    end;
validate_utf8(<<C1, C2, C3, Cs/binary>>) when C1 band 16#F0 =:= 16#E0,
                                              C2 band 16#C0 =:= 16#80,
                                              C3 band 16#C0 =:= 16#80 ->
    case ((((C1 band 16#0F) bsl 6) bor (C2 band 16#3F)) bsl 6) bor
	(C3 band 16#3F) of
	C when 16#800 =< C -> validate_utf8(Cs);
	_                  -> error
    end;
validate_utf8(<<C1, C2, C3, C4, Cs/binary>>) when C1 band 16#F8 =:= 16#F0,
                                                  C2 band 16#C0 =:= 16#80,
                                                  C3 band 16#C0 =:= 16#80,
                                                  C4 band 16#C0 =:= 16#80 ->
    case ((((((C1 band 16#0F) bsl 6) bor (C2 band 16#3F)) bsl 6) bor
               (C3 band 16#3F)) bsl 6) bor (C4 band 16#3F) of
	C when 16#10000 =< C -> validate_utf8(Cs);
	_                    -> error
    end;
validate_utf8(<<>>) ->
    ok;
validate_utf8(_) ->
    error.
