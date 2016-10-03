-module(pipeline).

-export([parse_transform/2]).

%% parse_transform entry point
parse_transform(AST, Options) ->
    ShowAST = lists:member({pipeline_verbose, true}, Options),
    ShowAST andalso io:format("~p~n", [AST]),
    Pipelined = parse_trans:plain_transform(fun replace_cons_calls/1, AST),
    ShowAST andalso io:format("~p~n", [Pipelined]),
    Pipelined.

replace_cons_calls({call, CallLine, {cons, _ConsLine, Function, Tail}, Arguments}) ->
    AppliedFunction = trans_apply(Function, Arguments),
    replace_cons_calls({call, CallLine, Tail, [AppliedFunction]});
replace_cons_calls({call, _CallLine, {nil, _NilLine}, [Argument]}) ->
    Argument;
replace_cons_calls(_) ->
    continue.

trans_apply({atom, Line, _} = Function, Arguments) ->
    {call, Line, Function, Arguments};
trans_apply({remote, Line, _, _} = Function, Arguments) ->
    {call, Line, Function, Arguments};
trans_apply({call, Line, Fun, ArgPattern}, [Argument]) ->
    Substituted = parse_trans:plain_transform(make_substitutor(Argument), ArgPattern),
    {call, Line, Fun, Substituted};
trans_apply({match, Line, Left, Right}, Arguments) ->
    AppliedRight = trans_apply(Right, Arguments),
    Name__ = erlang:list_to_atom("__@" ++ erlang:integer_to_list(Line)),
    [Left__Renamed] = parse_trans:plain_transform(make_renamer(Name__), [Left]),
    {block, Line, [
                   {match, Line, Left__Renamed, AppliedRight},
                   {var, Line, Name__}
                  ]}.

make_substitutor(Arg) ->
    fun(Forms) ->
            substitute_arg(Arg, Forms)
    end.

substitute_arg(Arg, {var, _, '__'}) ->
    Arg;
substitute_arg(_Arg, _Forms) ->
    continue.

make_renamer(Name__) ->
    fun(Forms) ->
            rename__(Name__, Forms)
    end.

rename__(Name__, {var, Line, '__'}) ->
    {var, Line, Name__};
rename__(_Name, _Forms) ->
    continue.
