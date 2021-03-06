%%%-------------------------------------------------------------------
%%% @author Blaise
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
%%% @doc
%%%
%%% @end
%%% Created : 13. Dec 2017 7:55 PM
%%%-------------------------------------------------------------------
-module(zotonic_cmd_debug).
-author("Blaise").

%% API
-export([run/1]).

-include("zotonic_command.hrl").

run(_) ->
    ZotonicApp = string:concat(?ZOTONIC, "/_build/default/lib/zotonic_core/ebin/zotonic_core.app"),
    Target = list_to_atom(?NODENAME ++ "@" ++ ?NODEHOST),
    case filelib:is_file(ZotonicApp) of
        true ->
            io:format("Starting Zotonic ~s..", [Target]),
            Shell = user_drv:start(),
            true = erlang:link(Shell),
            net_kernel:start([Target, shortnames]),
            zotonic_launcher_config:load_configs(),
            zotonic:start(),

            receive
                {'EXIT', Shell, _} ->
                    ok
            end;
        false ->
            io:format("Building Zotonic for the first time. ~n"),
            make:all()
    end.
