%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2010-2011 Marc Worrell
%%
%% @doc Model for accessing survey information.

%% Copyright 2010-2011 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% 
%%     http://www.apache.org/licenses/LICENSE-2.0
%% 
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(m_survey).
-author("Marc Worrell <marc@worrell.nl").

-behaviour(gen_model).

%% interface functions
-export(
   [
    m_find_value/3,
    m_to_list/2,
    m_value/2,

    is_allowed_results_download/2,
    get_handlers/1,
    insert_survey_submission/3,
    insert_survey_submission/5,
    replace_survey_submission/4,
    survey_stats/2,
    survey_results/2,
    survey_results_prompts/2,
    survey_results_sorted/3,
    prepare_results/2,
    single_result/3,
    single_result/4,
    delete_result/3,
    delete_result/4,
    get_questions/2
   ]).

-include_lib("zotonic.hrl").
-include("../survey.hrl").

%% @doc Fetch the value for the key from a model source
%% @spec m_find_value(Key, Source, Context) -> term()
m_find_value(questions, #m{value=undefined} = M, _Context) ->
    M#m{value=questions};
m_find_value(results, #m{value=undefined} = M, _Context) ->
    M#m{value=results};
m_find_value(all_results, #m{value=undefined} = M, _Context) ->
    M#m{value=all_results};
m_find_value(captions, #m{value=undefined} = M, _Context) ->
    M#m{value=captions};
m_find_value(totals, #m{value=undefined} = M, _Context) ->
    M#m{value=totals};
m_find_value(did_survey, #m{value=undefined} = M, _Context) ->
    M#m{value=did_survey};
m_find_value(did_survey_results, #m{value=undefined} = M, _Context) ->
    M#m{value=did_survey_results};
m_find_value(did_survey_results_readable, #m{value=undefined} = M, _Context) ->
    M#m{value=did_survey_results_readable};
m_find_value(is_allowed_results_download, #m{value=undefined} = M, _Context) ->
    M#m{value=is_allowed_results_download};
m_find_value(handlers, #m{value=undefined}, Context) ->
    get_handlers(Context);

m_find_value(Id, #m{value=results}, Context) ->
    prepare_results(m_rsc:rid(Id, Context), Context);
m_find_value([Id, SortColumn], #m{value=all_results}, Context) ->
    survey_results_sorted(m_rsc:rid(Id, Context), SortColumn, Context);
m_find_value(Id, #m{value=all_results}, Context) ->
    survey_results(m_rsc:rid(Id, Context), Context);
m_find_value(Id, #m{value=captions}, Context) ->
    survey_captions(m_rsc:rid(Id, Context), Context);
m_find_value(Id, #m{value=totals}, Context) ->
    survey_totals(m_rsc:rid(Id, Context), Context);
m_find_value(Id, #m{value=did_survey}, Context) ->
    did_survey(m_rsc:rid(Id, Context), Context);
m_find_value(Id, #m{value=did_survey_results}, Context) ->
    {UserId, PersistentId} = case z_acl:user(Context) of
                                undefined ->
                                    {undefined, persistent_id(Context)};
                                UId ->
                                    {UId, undefined}
                            end,
    m_survey:single_result(m_rsc:rid(Id, Context), UserId, PersistentId, Context);
m_find_value(Id, #m{value=did_survey_results_readable}, Context) ->
    {UserId, PersistentId} = case z_acl:user(Context) of
                                undefined ->
                                    {undefined, persistent_id(Context)};
                                UId ->
                                    {UId, undefined}
                            end,
    SurveyAnswer = m_survey:single_result(m_rsc:rid(Id, Context), UserId, PersistentId, Context),
    survey_answer_prep:readable_stored_result(Id, SurveyAnswer, Context);
m_find_value(Id, #m{value=is_allowed_results_download}, Context) ->
    is_allowed_results_download(m_rsc:rid(Id, Context), Context).


%% @doc Transform a m_config value to a list, used for template loops
%% @spec m_to_list(Source, Context) -> list()
m_to_list(#m{value=undefined}, _Context) ->
	[].

%% @doc Transform a model value so that it can be formatted or piped through filters
%% @spec m_value(Source, Context) -> term()
m_value(#m{value=undefined}, _Context) ->
	undefined.


is_allowed_results_download(Id, Context) ->
    z_acl:rsc_editable(Id, Context)
    orelse z_notifier:first(#survey_is_allowed_results_download{id=Id}, Context) == true.

%% @doc Return the list of known survey handlers
-spec get_handlers(#context{}) -> list({atom(), binary()}).
get_handlers(Context) ->
    z_notifier:foldr(#survey_get_handlers{}, [], Context).


%% @doc Check if the current user/browser did the survey
%% @private
did_survey(SurveyId, Context) ->
    find_answer_id(SurveyId, z_acl:user(Context), persistent_id(Context), Context) /= undefined.


persistent_id(#context{session_id = undefined}) -> undefined;
persistent_id(Context) -> z_context:persistent_id(Context).

%% @doc Replace a survey answer
replace_survey_submission(SurveyId, AnswerId, Answers, Context) ->
    {Points, AnswersPoints} = survey_test_results:calc_test_results(SurveyId, Answers, Context),
    case z_db:q("
        update survey_answers
        set props = $1,
            points = $2
            modifier_id = $3,
            modified = now()
        where id = $4
          and survey_id = $5
        ",
        [
            ?DB_PROPS([{answers, AnswersPoints}]),
            Points,
            z_acl:user(Context),
            AnswerId,
            SurveyId
        ],
        Context)
    of
        1 -> ok;
        0 -> {error, enoent}
    end.


%% @doc Save a survey, connect to the current user (if any)
-spec insert_survey_submission(integer(), list(), #context{}) -> {ok, integer()} | {error, term()}.
insert_survey_submission(SurveyId, Answers, Context) ->
    case z_acl:user(Context) of
        undefined ->
            insert_survey_submission(SurveyId, undefined, persistent_id(Context), Answers, Context);
        UserId ->
            insert_survey_submission(SurveyId, UserId, undefined, Answers, Context)
    end.

%% @doc Save or replace a survey, resetting the created if needed.
insert_survey_submission(SurveyId, UserId, PersistentId, Answers, Context) ->
    case z_convert:to_bool(m_rsc:p_no_acl(SurveyId, survey_multiple, Context)) of
        true ->
            insert_survey_submission_1(SurveyId, UserId, PersistentId, Answers, Context);
        false ->
            % Check if answer exists, if so update the answer
            case find_answer_id(SurveyId, UserId, PersistentId, Context) of
                undefined ->
                    insert_survey_submission_1(SurveyId, UserId, PersistentId, Answers, Context);
                AnsId ->
                    replace_survey_submission(SurveyId, AnsId, Answers, Context)
            end
    end.

find_answer_id(SurveyId, undefined, PersistentId, Context) ->
    z_db:q1("select id 
             from survey_answers
             where survey_id = $1
               and persistent = $2",
            [SurveyId, PersistentId],
            Context);
find_answer_id(SurveyId, UserId, _PersistendId, Context) ->
    z_db:q1("select id 
             from survey_answers
             where survey_id = $1
               and user_id = $2",
            [SurveyId, UserId],
            Context).

insert_survey_submission_1(SurveyId, undefined, PersistentId, Answers, Context) ->
    {Points, AnswersPoints} = survey_test_results:calc_test_results(SurveyId, Answers, Context),
    z_db:insert(
        survey_answers,
        [
            {survey_id, SurveyId},
            {user_id, undefined},
            {persistent, PersistentId},
            {is_anonymous, z_convert:to_bool(m_rsc:p_no_acl(SurveyId, survey_anonymous, Context))},
            {points, Points},
            {answers, AnswersPoints}
        ],
        Context);
insert_survey_submission_1(SurveyId, UserId, _PersistentId, Answers, Context) ->
    {Points, AnswersPoints} = survey_test_results:calc_test_results(SurveyId, Answers, Context),
    z_db:insert(
        survey_answers,
        [
            {survey_id, SurveyId},
            {user_id, UserId},
            {persistent, undefined},
            {is_anonymous, z_convert:to_bool(m_rsc:p_no_acl(SurveyId, survey_anonymous, Context))},
            {points, Points},
            {answers, AnswersPoints}
        ],
        Context).


%% @private
prepare_results(SurveyId, Context) ->
    case m_rsc:p(SurveyId, blocks, Context) of
        [] ->
            undefined;
        <<>> ->
            undefined;
        undefined -> 
            undefined;
        Blocks ->
            Stats = survey_stats(SurveyId, Context),
            [
                begin
                    Name = proplists:get_value(name, Block),
                    prepare_result(Block, proplists:get_value(Name, Stats), Context)
                end
                || Block <- Blocks
            ]
    end.

%% @private
prepare_result(_Block, undefined, _Context) ->
    {undefined, undefined, undefined};
prepare_result(Block, Stats, Context) ->
    Type = proplists:get_value(type, Block),
    {
      Stats,
      prep_chart(Type, Block, Stats, Context),
      [] % mod_survey:question_to_props(Question)
    }.

%% @private
prep_chart(_Type, _Block, undefined, _Context) ->
    undefined;
prep_chart(Type, Block, Stats, Context) ->
    M = mod_survey:module_name(Type),
    M:prep_chart(Block, Stats, Context).


%% @doc Fetch the aggregate answers of a survey. 
-spec survey_stats(integer(), #context{}) -> 
    list({Block::binary(), [{QName::binary(),[{Answer::binary(),Count::integer()}]}]}).
survey_stats(SurveyId, Context) ->
    Rows = z_db:q("
            select props
            from survey_answers
            where survey_id = $1",
            [SurveyId],
            Context),
    QDict = count_answers(Rows, dict:new()),
    BDict = dict:fold(
        fun({Block,QName,Ans}, Count, Acc) ->
            dict:append({Block,QName}, {Ans,Count}, Acc)
        end,
        dict:new(),
        QDict),
    FinalDict = dict:fold(
        fun({Block,QName}, AnsCt, Acc) ->
            dict:append(Block, {QName,AnsCt}, Acc)
        end,
        dict:new(),
        BDict),
    dict:to_list(FinalDict).

count_answers([], Dict) -> Dict;
count_answers([{Row}|Rows], Dict) ->
    {answers, Answers} = proplists:lookup(answers, Row),
    Dict1 = lists:foldl(
        fun({QName, QAnswer}, Acc) ->
            As = proplists:get_value(answer, QAnswer),
            Block = proplists:get_value(block, QAnswer),
            lists:foldl(
                fun(Ans, QAcc) ->
                    dict:update_counter({Block, QName, Ans}, 1, QAcc)
                end,
                Acc,
                As)
        end,
        Dict,
        Answers),
    count_answers(Rows, Dict1).

%% @doc Get survey results, sorted by the given sort column.
survey_results_sorted(SurveyId, SortColumn, Context) ->
    [Headers|Data] = survey_results(SurveyId, Context),
    case string:str(Headers, [z_convert:to_binary(SortColumn)]) of
        0 ->
            %% column not found, do not sort
            [Headers|Data];
        N ->
            %% Sort on nth row
            Data1 = [{z_string:to_lower(z_convert:to_list(lists:nth(N, Row))), Row} || Row <- Data],
            Data2 = [Row1 || {_, Row1} <- lists:sort(Data1)],
            [Headers|Data2]
    end.



%% @doc get prepared questions from the blocks
-spec get_questions(integer(), #context{}) -> [{BlockName::binary(),list()}] | undefined.
get_questions(SurveyId, Context) ->
    case m_rsc:p(SurveyId, blocks, Context) of
        Blocks when is_list(Blocks) ->
            [ {proplists:get_value(name, B), question_prepare(B, Context)} || B <- Blocks];
        _ ->
            undefined
    end.

%% @doc Return all results of a survey
survey_results(SurveyId, Context) ->
    {Hs, _Prompts, Data} = survey_results_prompts(SurveyId, Context),
    [ Hs | Data ].

%% @doc Return all results of a survey with separate names, prompts and data
survey_results_prompts(undefined, _Context) ->
    {[], [], []};
survey_results_prompts(SurveyId, Context) when is_integer(SurveyId) ->
    case get_questions(SurveyId, Context) of
        NQs when is_list(NQs) ->
            IsAnonymous = z_convert:to_bool(m_rsc:p_no_acl(SurveyId, survey_anonymous, Context)),
            Rows = z_db:assoc_props("
                        select *
                        from survey_answers
                        where survey_id = $1
                        order by created asc",
                        [SurveyId],
                        Context),
            Rows1 = anonymize(IsAnonymous, Rows),
            Answers = [ user_answer_row(Row, NQs, Context) || Row <- Rows1 ],
            Hs = lists:flatten([ answer_header(B, Context) || {_,B} <- NQs ]),
            Prompts = lists:flatten([ z_trans:lookup_fallback(answer_prompt(B), Context) || {_,B} <- NQs ]),
            {Hs, Prompts, Answers};
        undefined ->
            {[], [], []}
    end;
survey_results_prompts(SurveyId, Context) ->
    survey_results_prompts(m_rsc:rid(SurveyId, Context), Context).

anonymize(IsAnonymous, Rows) ->
    lists:map(
        fun(Row) ->
            case IsAnonymous
                orelse proplists:get_value(is_anonymous, Row)
            of
                true ->
                    Row1 = proplists:delete(user_id,
                        proplists:delete(persistent, Row)),
                    [
                        {user_id, undefined},
                        {persistent, undefined}
                        | Row1
                    ];
                false ->
                    Row
            end
        end,
        Rows).

user_answer_row(Row, Questions, Context) ->
    Answers = proplists:get_value(answers, Row),
    % TODO: change this for the points
    %       also need to change all prep_answer functions in the questions.
    ByBlock = [
        {proplists:get_value(block, Vs), {Name, proplists:get_value(answer, Vs)}}
        || {Name, Vs} <- Answers
    ],
    {proplists:get_value(id, Row),
     lists:flatten([
        answer_row_question(proplists:get_all_values(QId, ByBlock),
                               Question,
                               Context)
        || {QId, Question} <- Questions
     ])}.

%% @doc private
answer_row_question(_Answer, undefined, _Context) ->
    [];
answer_row_question(Answer, Q, Context) ->
    Type = proplists:get_value(type, Q),
    case mod_survey:module_name(Type) of
        undefined -> [];
        M -> M:prep_answer(Q, Answer, Context)
    end.

%% @doc private
question_prepare(B, Context) ->
    case mod_survey:module_name(proplists:get_value(type, B)) of
        undefined -> B;
        M -> M:prep_block(B, Context)
    end.

%% @doc private
answer_header(Block, Context) ->
    Type = proplists:get_value(type, Block),
    case mod_survey:module_name(Type) of
        undefined -> [];
        M -> M:prep_answer_header(Block, Context)
    end.

answer_prompt(Block) ->
    Type = proplists:get_value(type, Block),
    case mod_survey:module_name(Type) of
        undefined -> [];
        _M -> proplists:get_value(prompt, Block, <<>>)
    end.


-spec single_result(integer(), integer(), #context{}) -> list().
single_result(SurveyId, AnswerId, Context) when is_integer(SurveyId), is_integer(AnswerId) ->
    case z_db:assoc_props_row("
            select *
            from survey_answers
            where survey_id = $1 and id = $2",
            [SurveyId, AnswerId],
            Context)
    of
        undefined -> [];
        Row -> Row
    end.

%% @doc Retrieve the latest survey result for a user or persistent id.
single_result(SurveyId, UserId, PersistentId, Context) ->
    {Clause, Arg} = case z_utils:is_empty(UserId) of
                        true -> {"persistent = $2", PersistentId};
                        false -> {"user_id = $2", UserId}
                    end,
    case z_db:assoc_props_row("
            select *
            from survey_answers
            where survey_id = $1
              and "++Clause++"
            order by id desc
            limit 1",
            [ SurveyId, Arg ],
            Context)
    of
        undefined -> [];
        Row -> Row
    end.

%% @doc Delete a specific survey results
delete_result(SurveyId, ResultId, Context) ->
    z_db:q("
        DELETE FROM survey_answers
        WHERE id = $2
          AND survey_id = $1",
        [SurveyId, ResultId],
        Context).

%% @doc Delete all survey results for a user or persistent id.
delete_result(SurveyId, UserId, PersistentId, Context) ->
    {Clause, Arg} = case z_utils:is_empty(UserId) of
                        true -> {"persistent = $2", PersistentId};
                        false -> {"user_id = $2", UserId}
                    end,
    z_db:q("
        DELETE FROM survey_answers
        WHERE " ++ Clause ++ "
          AND survey_id = $1",
        [SurveyId, Arg],
        Context).


%% @private
survey_captions(Id, Context) ->
    case m_rsc:p(Id, blocks, Context) of
        Blocks when is_list(Blocks) ->
            [
                {<<"created">>, ?__("Created", Context)} |
                [ {proplists:get_value(name, Block), proplists:get_value(prompt, Block)} || Block <- Blocks ]
            ];
        _ ->
            []
    end.


%% @private
survey_totals(Id, Context) ->
    Stats = survey_stats(Id, Context),
    case m_rsc:p(Id, blocks, Context) of
        Blocks when is_list(Blocks) ->
            All = lists:map(fun(Block) ->
                    Name = proplists:get_value(name, Block),
                    Type = proplists:get_value(type, Block),
                    M = mod_survey:module_name(Type),
                    Value = case proplists:get_value(prep_totals, erlang:get_module_info(M, exports)) of
                                3 ->
                                    % lager:warning("Name: ~p", [Name]),
                                    Vals = proplists:get_value(Name, Stats),
                                    M:prep_totals(Block, Vals, Context);
                                undefined ->
                                    undefined
                            end,
                    {Name, Value}
            end,
            Blocks),
            AllEmpty = lists:foldl(
                fun(Total, Acc) ->
                    Acc andalso z_utils:is_empty(Total)
                end,
                true,
                All),
            case AllEmpty of
                true -> undefined;
                false -> All
            end;
        _ ->
            []
    end.

                
