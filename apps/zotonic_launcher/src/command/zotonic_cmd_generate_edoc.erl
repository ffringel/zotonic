%%%-------------------------------------------------------------------
%%% @author Blaise
%%% @doc
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%	 http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%% @end
%%% Created : 18. Dec 2017 11:36 AM
%%%-------------------------------------------------------------------
-module(zotonic_cmd_generate_edoc).
-author("Blaise").

%% API
-export([run/1]).

files(Path) ->
    filelib:fold_files(Path, ".erl$", true, fun(F, Acc) -> [F|Acc] end, []).

run(_) ->
    generate("src", "core"),
    io:format("Generated core edoc files in ~p~n", [outpath("core")]),
    Zotonic = os:getenv("ZOTONIC"),
    Modules = [string:substr(L, length(Zotonic ++ "/modules/") + 1) || L <- filelib:wildcard(filename:join([os:getenv("ZOTONIC"), "modules/mod_*"]))],
    [generate("modules/" ++ M, "modules/" ++ M) || M <- Modules],
    io:format("Generated modules edoc files in ~p~n", [outpath("modules")]).

generate(InputDir, OutputDir) ->
    SrcPath = filename:join(os:getenv("ZOTONIC"), InputDir),
    Files = files(SrcPath),
    edoc:files(Files, [{dir, outpath(OutputDir)}]).

outpath(Component) ->
    Path = filename:join([os:getenv("ZOTONIC"), "doc", "_build", "edoc", Component]),
    filelib:ensure_dir(filename:join([Path, ".empty"])),
    Path.
