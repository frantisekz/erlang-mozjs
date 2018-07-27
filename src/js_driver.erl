%% @author Kevin Smith <ksmith@basho.com>
%% @copyright 2009-2010 Basho Technologies
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.

%% @doc This module manages all of the low-level details surrounding the
%% linked-in driver. It is reponsible for loading and unloading the driver
%% as needed. This module is also reponsible for creating and destroying
%% instances of Javascript VMs.

-module(js_driver).

-define(DEFAULT_HEAP_SIZE, 8). %% MB
-define(DEFAULT_THREAD_STACK, 16). %% MB

-export([new/0, new/2, new/3, destroy/1]).
-export([define_js/2, define_js/3, eval_js/2]).

%% @spec new() -> {ok, port()} | {error, atom()} | {error, any()}
%% @doc Create a new Javascript VM instance and preload Douglas Crockford's
%% json2 converter (http://www.json.org/js.html). Uses a default heap
%% size of 8MB and a default thread stack size of 8KB.
new() ->
    new(?DEFAULT_THREAD_STACK, ?DEFAULT_HEAP_SIZE).

%% @spec new(ThreadStackSize::int(), HeapSize::int()) -> {ok, port()} | {error, atom()} | {error, any()}
%% @doc Create a new Javascript VM instance and preload Douglas Crockford's
%% json2 converter (http://www.json.org/js.html)
new(ThreadStackSize, HeapSize) ->
    {ok, Port} = new(ThreadStackSize, HeapSize, no_json),
    %% Load json converter for use later
    case define_js(Port, <<"json2.js">>, json_converter()) of
        ok ->
            {ok, Port};
        {error, Reason} ->
            port_close(Port),
            {error, Reason}
    end.

%% @type init_fun() = function(port()).
%% @spec new(int(), int(), no_json | init_fun() | {ModName::atom(), FunName::atom()}) -> {ok, port()} | {error, atom()} | {error, any()}
%% @doc Create a new Javascript VM instance. The function arguments control how the VM instance is initialized.
%% User supplied initializers must return true or false.
new(ThreadStackSize, HeapSize, no_json) ->
    {ok, Port} = mozjs_nif:sm_init(ThreadStackSize, HeapSize),
    {ok, Port};
new(ThreadStackSize, HeapSize, Initializer) when is_function(Initializer) ->
    {ok, Port} = new(ThreadStackSize, HeapSize),
    case Initializer(Port) of
        ok ->
            {ok, Port};
        {error, Error} ->
            js_driver:destroy(Port),
            error_logger:error_report(Error),
            throw({error, init_failed})
    end;
new(ThreadStackSize, HeapSize, {InitMod, InitFun}) ->
    {ok, Port} = new(ThreadStackSize, HeapSize),
    case InitMod:InitFun(Port) of
        ok ->
            {ok, Port};
        {error, Error} ->
            js_driver:destroy(Port),
            error_logger:error_report(Error),
            throw({error, init_failed})
    end.

%% @spec destroy(port()) -> ok
%% @doc Destroys a Javascript VM instance
destroy(Ctx) ->
    mozjs_nif:sm_stop(Ctx).

%% @spec define_js(port(), binary()) -> ok | {error, any()}
%% @doc Define a Javascript expression:
%% js_driver:define(Port, &lt;&lt;"var x = 100;"&gt;&gt;).
define_js(Ctx, {file, FileName}) ->
    {ok, File} = file:read_file(FileName),
    define_js(Ctx, list_to_binary(FileName), File);
define_js(Ctx, Js) when is_binary(Js) ->
    define_js(Ctx, <<"unnamed">>, Js).

%% @spec define_js(port(), binary(), binary(), integer()) -> {ok, binary()} | {error, any()}
%% @doc Define a Javascript expression:
%% js_driver:define(Port, &lt;&lt;var blah = new Wubba();"&gt;&gt;).
%% Note: Filename is used only as a label for error reporting.
define_js(Ctx, FileName, Js) when is_binary(FileName),
                                           is_binary(Js) ->
    case mozjs_nif:sm_eval(Ctx, FileName, Js, 0) of
        {error, ErrorJson} when is_binary(ErrorJson) ->
            {struct, Error} = mochijson2:decode(ErrorJson),
            {error, Error};
        {error, Error} ->
            {error, Error};
        ok ->
            ok
    end.

%% @spec eval_js(port(), binary()) -> {ok, any()} | {error, any()}
%% @doc Evaluate a Javascript expression and return the result
eval_js(Ctx, {file, FileName}) ->
    {ok, File} = file:read_file(FileName),
    eval_js(Ctx, File);
eval_js(Ctx, Js) when is_binary(Js) ->
    case mozjs_nif:sm_eval(Ctx, <<"<unnamed>">>, jsonify(Js), 1) of
        {ok, Result} ->
            {ok, mochijson2:decode(Result)};
        {error, ErrorJson} when is_binary(ErrorJson) ->
            case mochijson2:decode(ErrorJson) of
                {struct, Error} ->
                    {error, Error};
                _ ->
                    {error, ErrorJson}
            end;
        {error, Error} ->
            {error, Error}
    end.

%% Internal functions
%% @private
jsonify(Code) when is_binary(Code) ->
    {Body, <<LastChar:8>>} = split_binary(Code, size(Code) - 1),
    C = case LastChar of
            $; ->
                Body;
            _ ->
                Code
        end,
    list_to_binary([<<"JSON.stringify(">>, C, <<");">>]).

%% @private
priv_dir() ->
    %% Hacky workaround to handle running from a standard app directory
    %% and .ez package
    case code:priv_dir('erlang-mozjs') of
        {error, bad_name} ->
            filename:join([filename:dirname(code:which(?MODULE)), "..", "priv"]);
        Dir ->
            Dir
    end.

%% @private
json_converter() ->
    is_pid(erlang:whereis(js_cache)) orelse js_cache:start_link(),
    FileName = filename:join([priv_dir(), "json2.js"]),
    case js_cache:fetch(FileName) of
        error ->
            {ok, Contents} = file:read_file(FileName),
            js_cache:store(FileName, Contents),
            Contents;
        Contents ->
            Contents
    end.
