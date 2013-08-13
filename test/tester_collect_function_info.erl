%  @copyright 2010-2013 Zuse Institute Berlin

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%% @author Thorsten Schuett <schuett@zib.de>
%% @doc    collection type information about a function
%% @end
%% @version $Id$
-module(tester_collect_function_info).
-author('schuett@zib.de').
-vsn('$Id$').

-export([collect_fun_info/4]).

-include("tester.hrl").
-include("unittest.hrl").

-spec collect_fun_info/4 :: (module(), atom(), non_neg_integer(),
                             tester_parse_state:state()) -> tester_parse_state:state().
collect_fun_info(Module, Func, Arity, ParseState) ->
    ParseState2 =
        case tester_parse_state:lookup_type({'fun', Module, Func, Arity}, ParseState) of
            {value, _} -> ParseState;
            none ->
                ModuleFile = code:where_is_file(atom_to_list(Module) ++ ".beam"),
                {ok, {Module, [{abstract_code, {_AbstVersion, AbstractCode}}]}}
                    = beam_lib:chunks(ModuleFile, [abstract_code]),
                lists:foldl(fun(Chunk, InnerParseState) ->
                                    parse_chunk(Chunk, Module, InnerParseState)
                            end, ParseState, AbstractCode)
        end,
    ParseState3 = case tester_parse_state:has_unknown_types(ParseState2) of
                      false -> ParseState2;
                      true  -> collect_unknown_type_infos(ParseState2, [])
                  end,
    case tester_parse_state:lookup_type({'fun', Module, Func, Arity}, ParseState3) of
        {value, _} -> tester_parse_state:finalize(ParseState3);
        none -> ?ct_fail("no '-spec' definition for function ~p:~p/~p found by tester~n", [Module, Func, Arity])
    end.

-spec collect_unknown_type_infos(tester_parse_state:state(), list()) ->
    tester_parse_state:state().
collect_unknown_type_infos(ParseState, OldUnknownTypes) ->
    {_, UnknownTypes} = tester_parse_state:get_unknown_types(ParseState),
    %ct:pal("unknown types: ~p~n", [UnknownTypes]),
    case OldUnknownTypes =:= UnknownTypes of
        true ->
            ct:pal("never found the following types: ~p~n~n", [UnknownTypes]),
            ?ct_fail("never found the following types: ~p~n~n", [UnknownTypes]),
            error;
        false ->
            ParseState2 = tester_parse_state:reset_unknown_types(ParseState),
            ParseState3 = lists:foldl(fun({type, Module, TypeName}, InnerParseState) ->
                                              collect_type_info(Module, TypeName,
                                                                InnerParseState)
                                      end, ParseState2, UnknownTypes),
            case tester_parse_state:has_unknown_types(ParseState3) of
                false -> ParseState3;
                true  -> collect_unknown_type_infos(ParseState3, UnknownTypes)
            end
    end.

-spec collect_type_info/3 :: (module(), atom(), tester_parse_state:state()) ->
    tester_parse_state:state().
collect_type_info(Module, Type, ParseState) ->
    case tester_parse_state:is_known_type(Module, Type, ParseState) of
        true ->
            ParseState;
        false ->
            {ok, {Module, [{abstract_code, {_AbstVersion, AbstractCode}}]}}
                = beam_lib:chunks(code:where_is_file(atom_to_list(Module) ++ ".beam"),
                                  [abstract_code]),
            lists:foldl(fun (Chunk, InnerParseState) ->
                                parse_chunk(Chunk, Module, InnerParseState)
                        end, ParseState, AbstractCode)
    end.


-spec parse_chunk/3 :: (any(), module(), tester_parse_state:state()) ->
    tester_parse_state:state().
parse_chunk({attribute, _Line, type, {{record, TypeName}, ATypeSpec, _List}},
            Module, ParseState) ->
    {TheTypeSpec, NewParseState} = parse_type(ATypeSpec, Module, ParseState),
    tester_parse_state:add_type_spec({record, Module, TypeName}, TheTypeSpec,
                                     NewParseState);
parse_chunk({attribute, _Line, type, {TypeName, ATypeSpec, _List}},
            Module, ParseState) ->
    {TheTypeSpec, NewParseState} = parse_type(ATypeSpec, Module, ParseState),
    tester_parse_state:add_type_spec({type, Module, TypeName}, TheTypeSpec,
                                     NewParseState);
parse_chunk({attribute, _Line, opaque, {TypeName, ATypeSpec, _List}},
            Module, ParseState) ->
    {TheTypeSpec, NewParseState} = parse_type(ATypeSpec, Module, ParseState),
    tester_parse_state:add_type_spec({type, Module, TypeName}, TheTypeSpec,
                                     NewParseState);
parse_chunk({attribute, _Line, 'spec', {{FunName, FunArity}, AFunSpec}},
            Module, ParseState) ->
    %ct:pal("~w:~w ~w ~w", [Module, _Line, FunName, AFunSpec]),
    FunSpec = case AFunSpec of
                  [{type, _,bounded_fun, [_TypeFun, ConstraintType]}] ->
                      Substitutions = parse_constraints(ConstraintType, gb_trees:empty()),
                      try
                          substitute_constraints(AFunSpec, Substitutions)
                      catch
                          {subst_error, Description} ->
                              ct:pal("substitution error ~w in ~w:~w ~w", [Description, Module, FunName, AFunSpec]),
                              exit(foobar)
                      end;
                  _ ->
                      AFunSpec
              end,
    {TheFunSpec, NewParseState} = parse_type({union_fun, FunSpec}, Module, ParseState),
    tester_parse_state:add_type_spec({'fun', Module, FunName, FunArity},
                                     TheFunSpec, NewParseState);
parse_chunk({attribute, _Line, record, {TypeName, TypeList}}, Module, ParseState) ->
    {TheTypeSpec, NewParseState} = parse_type(TypeList, Module, ParseState),
    tester_parse_state:add_type_spec({record, Module, TypeName}, TheTypeSpec,
                                     NewParseState);
parse_chunk({attribute, _Line, _AttributeName, _AttributeValue}, _Module,
            ParseState) ->
    ParseState;
parse_chunk({function, _Line, _FunName, _FunArity, FunCode}, _Module, ParseState) ->
    tester_value_collector:parse_expression(FunCode, ParseState);
parse_chunk({eof, _Line}, _Module, ParseState) ->
    ParseState.

-spec parse_type/3 :: (any(), module(), tester_parse_state:state()) ->
    {type_spec() , tester_parse_state:state()}.
-ifdef(tid_not_builtin).
parse_type(T, M, ParseState) -> parse_type_(T, M, ParseState).
-else.
parse_type({type, _Line, tid, []}, _Module, ParseState) ->
    {tid, ParseState};
parse_type(T, M, ParseState) ->
    parse_type_(T, M, ParseState).
-endif.

-spec parse_type_/3 :: (any(), module(), tester_parse_state:state()) ->
    {type_spec() , tester_parse_state:state()}.
parse_type_({union_fun, FunSpecs}, Module, ParseState) ->
    {FunSpecs2, PS2} = lists:foldl(fun (FunType, {List, PS}) ->
                        {ParsedFunType, PS1 } = parse_type(FunType, Module, PS),
                        {[ParsedFunType | List], PS1}
                end, {[], ParseState}, FunSpecs),
    {{union_fun, FunSpecs2}, PS2};
parse_type_({type, _Line, 'fun', [Arg, Result]}, Module, ParseState) ->
    {ArgType, ParseState2} = parse_type(Arg, Module, ParseState),
    {ResultType, ParseState3} = parse_type(Result, Module, ParseState2),
    {{'fun', ArgType, ResultType}, ParseState3};
parse_type_({type, _Line, product, Types}, Module, ParseState) ->
    {TypeList, ParseState2} = parse_type_list(Types, Module, ParseState),
    {{product, TypeList}, ParseState2};
parse_type_({type, _Line, tuple, any}, _Module, ParseState) ->
    {{tuple, {typedef, tester, test_any}}, ParseState};
parse_type_({type, _Line, tuple, Types}, Module, ParseState) ->
    {TypeList, ParseState2} = parse_type_list(Types, Module, ParseState),
    {{tuple, TypeList}, ParseState2};
parse_type_({type, _Line, list, [Type]}, Module, ParseState) ->
    {ListType, ParseState2} = parse_type(Type, Module, ParseState),
    {{list, ListType}, ParseState2};
parse_type_({type, _Line, nonempty_list, [Type]}, Module, ParseState) ->
    {ListType, ParseState2} = parse_type(Type, Module, ParseState),
    {{nonempty_list, ListType}, ParseState2};
parse_type_({type, _Line, list, []}, _Module, ParseState) ->
    {{list, {typedef, tester, test_any}}, ParseState};
parse_type_({type, _Line, range, [Begin, End]}, Module, ParseState) ->
    {BeginType, ParseState2} = parse_type(Begin, Module, ParseState),
    {EndType, ParseState3} = parse_type(End, Module, ParseState2),
    {{range, BeginType, EndType}, ParseState3};
parse_type_({type, _Line, union, Types}, Module, ParseState) ->
    {TypeList, ParseState2} = parse_type_list(Types, Module, ParseState),
    {{union, TypeList}, ParseState2};
parse_type_({type, _Line, integer, []}, _Module, ParseState) ->
    {integer, ParseState};
parse_type_({type, _Line, pos_integer, []}, _Module, ParseState) ->
    {pos_integer, ParseState};
parse_type_({type, _Line, neg_integer, []}, _Module, ParseState) ->
    {neg_integer, ParseState};
parse_type_({type, _Line, non_neg_integer, []}, _Module, ParseState) ->
    {non_neg_integer, ParseState};
parse_type_({type, _Line, byte, []}, _Module, ParseState) ->
    {{range, {integer, 0}, {integer, 255}}, ParseState};
parse_type_({type, _Line, bool, []}, _Module, ParseState) ->
    {bool, ParseState};
parse_type_({type, _Line, char, []}, _Module, ParseState) ->
    {{range, {integer, 0}, {integer, 16#10ffff}}, ParseState};
parse_type_({type, _Line, string, []}, _Module, ParseState) ->
    {{list, {range, {integer, 0}, {integer, 16#10ffff}}}, ParseState};
parse_type_({type, _Line, nonempty_string, []}, _Module, ParseState) ->
    {nonempty_string, ParseState};
parse_type_({type, _Line, number, []}, _Module, ParseState) ->
    {{union, [integer, float]}, ParseState};
parse_type_({type, _Line, boolean, []}, _Module, ParseState) ->
    {bool, ParseState};
parse_type_({type, _Line, any, []}, _Module, ParseState) ->
    {{typedef, tester, test_any}, ParseState};
parse_type_({type, _Line, atom, []}, _Module, ParseState) ->
    {atom, ParseState};
parse_type_({type, _Line, arity, []}, _Module, ParseState) ->
    {arity, ParseState};
parse_type_({type, _Line, binary, []}, _Module, ParseState) ->
    {binary, ParseState};
parse_type_({type, _Line, pid, []}, _Module, ParseState) ->
    {pid, ParseState};
parse_type_({type, _Line, port, []}, _Module, ParseState) ->
    {port, ParseState};
parse_type_({type, _Line, float, []}, _Module, ParseState) ->
    {float, ParseState};
parse_type_({type, _Line, iolist, []}, _Module, ParseState) ->
    {iolist, ParseState};
parse_type_({type, _Line, nil, []}, _Module, ParseState) ->
    {nil, ParseState};
parse_type_({type, _Line, node, []}, _Module, ParseState) ->
    {node, ParseState};
parse_type_({type, _Line, none, []}, _Module, ParseState) ->
    {none, ParseState};
parse_type_({type, _Line, no_return, []}, _Module, ParseState) ->
    {none, ParseState};
parse_type_({type, _Line, reference, []}, _Module, ParseState) ->
    {reference, ParseState};
parse_type_({type, _Line, term, []}, _Module, ParseState) ->
    {{typedef, tester, test_any}, ParseState};
parse_type_({ann_type, _Line, [{var, _Line2, _Varname}, Type]}, Module, ParseState) ->
    parse_type(Type, Module, ParseState);
parse_type_({atom, _Line, Atom}, _Module, ParseState) ->
    {{atom, Atom}, ParseState};
parse_type_({op, _Line1,'-',{integer,_Line2,Value}}, _Module, ParseState) ->
    {{integer, -Value}, ParseState};
parse_type_({integer, _Line, Value}, _Module, ParseState) ->
    {{integer, Value}, ParseState};
parse_type_({type, _Line, array, []}, _Module, ParseState) ->
    {{builtin_type, array}, ParseState};
parse_type_({type, _Line, dict, []}, _Module, ParseState) ->
    {{builtin_type, dict}, ParseState};
parse_type_({type, _Line, gb_set, []}, _Module, ParseState) ->
    {{builtin_type, gb_set}, ParseState};
parse_type_({type, _Line, gb_tree, []}, _Module, ParseState) ->
    {{builtin_type, gb_tree}, ParseState};
parse_type_({type, _Line, set, []}, _Module, ParseState) ->
    {{builtin_type, set}, ParseState};
parse_type_({type, _Line, module, []}, _Module, ParseState) ->
    {{builtin_type, module}, ParseState};
parse_type_({type, _Line, iodata, []}, _Module, ParseState) ->
    {{builtin_type, iodata}, ParseState};
parse_type_({type, _Line, mfa, []}, _Module, ParseState) ->
    {{tuple, [atom, atom, {range, {integer, 0}, {integer, 255}}]}, ParseState};
parse_type_({remote_type, _Line, [{atom, _Line2, TypeModule},
                                 {atom, _line3, TypeName}, []]},
           _Module, ParseState) ->
    case tester_parse_state:is_known_type(TypeModule, TypeName, ParseState) of
        true ->
            {{typedef, TypeModule, TypeName}, ParseState};
        false ->
            {{typedef, TypeModule, TypeName},
             tester_parse_state:add_unknown_type(TypeModule, TypeName, ParseState)}
    end;
% why is this here? function() is no official type
parse_type_({type, _Line, 'function', []}, _Module, ParseState) ->
    {{'function'}, ParseState};
parse_type_({type, _Line, 'fun', []}, _Module, ParseState) ->
    {{'function'}, ParseState};
parse_type_({type, _Line, record, [{atom, _Line2, TypeName}]}, Module, ParseState) ->
    {{record, Module, TypeName}, ParseState};
parse_type_({type, _Line, record, [{atom, _Line2, TypeName} | Fields]}, Module,
           ParseState) ->
    {RecordType, ParseState2} = parse_type_list(Fields, Module, ParseState),
    {{record, Module, TypeName, RecordType}, ParseState2};
parse_type_({typed_record_field, {record_field, _Line,
                                 {atom, _Line2, FieldName}}, Field}, Module,
           ParseState) ->
    {FieldType, ParseState2} = parse_type(Field, Module, ParseState),
    {{typed_record_field, FieldName, FieldType}, ParseState2};
parse_type_({typed_record_field, {record_field, _Line,
                                 {atom, _Line2, FieldName}, _Default}, Field},
           Module, ParseState) ->
    {FieldType, ParseState2} = parse_type(Field, Module, ParseState),
    {{typed_record_field, FieldName, FieldType}, ParseState2};
parse_type_({type, _, field_type, [{atom, _, FieldName}, Field]}, Module, ParseState) ->
    {FieldType, ParseState2} = parse_type(Field, Module, ParseState),
    {{field_type, FieldName, FieldType}, ParseState2};
parse_type_({record_field, _Line, {atom, _Line2, FieldName}}, _Module, ParseState) ->
    {{untyped_record_field, FieldName}, ParseState};
parse_type_({record_field, _Line, {atom, _Line2, FieldName}, _Default}, _Module,
           ParseState) ->
    {{untyped_record_field, FieldName}, ParseState};
parse_type_(TypeSpecs, Module, ParseState) when is_list(TypeSpecs) ->
    case hd(TypeSpecs) of
        {typed_record_field, _, _} ->
            {RecordType, ParseState2} = parse_type_list(TypeSpecs,
                                                        Module, ParseState),
            {{record, RecordType}, ParseState2};
        {record_field, _, _} ->
            {RecordType, ParseState2} = parse_type_list(TypeSpecs,
                                                        Module, ParseState),
            {{record, RecordType}, ParseState2};
        {record_field, _, _, _} ->
            {RecordType, ParseState2} = parse_type_list(TypeSpecs,
                                                        Module, ParseState),
            {{record, RecordType}, ParseState2};
        _ ->
            ct:pal("potentially unknown type2: ~p~n", [TypeSpecs]),
            unknown
    end;
parse_type_({var, _Line, Atom}, _Module, ParseState) when is_atom(Atom) ->
    {{tuple, {typedef, tester, test_any}}, ParseState};
parse_type_({type, _Line, constraint, _Constraint}, _Module, ParseState) ->
    {{constraint, nyi}, ParseState};
parse_type_({type, _, bounded_fun, [FunType, ConstraintList]}, Module, ParseState) ->
    {InternalFunType, ParseState2} = parse_type(FunType, Module, ParseState),
    Foldl = fun (Constraint, {PartialConstraintList, ParseState2a}) ->
                    {InternalConstraint, ParseState2c} = parse_type(Constraint,
                                                                    Module,
                                                                    ParseState2a),
                    {[InternalConstraint | PartialConstraintList], ParseState2c}
            end,
    {Constraints, ParseState3} = lists:foldl(Foldl, {[], ParseState2}, ConstraintList),
    {{bounded_fun, InternalFunType, Constraints}, ParseState3};
parse_type_({paren_type, _Line, [InnerType]}, Module, ParseState) ->
    parse_type(InnerType, Module, ParseState);
parse_type_({type, _Line, identifier, L}, _Module, ParseState) when is_list(L) ->
    {{builtin_type, identifier}, ParseState};
parse_type_({type, _Line, timeout, L}, _Module, ParseState) when is_list(L) ->
    {{builtin_type, timeout}, ParseState};
parse_type_({type, _Line, bitstring, L}, _Module, ParseState) when is_list(L) ->
    {{builtin_type, bitstring}, ParseState};
parse_type_({type, _Line, maybe_improper_list, L}, _Module, ParseState) when is_list(L) ->
    {{builtin_type, maybe_improper_list}, ParseState};
parse_type_({type, _Line, TypeName, L}, Module, ParseState) when is_list(L) ->
    %ct:pal("type1 ~p:~p~n", [Module, TypeName]),
    case tester_parse_state:is_known_type(Module, TypeName, ParseState) of
        true ->
            {{typedef, Module, TypeName}, ParseState};
        false ->
            {{typedef, Module, TypeName},
             tester_parse_state:add_unknown_type(Module, TypeName, ParseState)}
    end;
parse_type_({ann_type,_Line,[Left,Right]}, _Module, ParseState) ->
    {{ann_type, [Left, Right]}, ParseState};
parse_type_(TypeSpec, Module, ParseState) ->
    ct:pal("unknown type ~p in module ~p~n", [TypeSpec, Module]),
    {unkown, ParseState}.

-spec parse_type_list/3 :: (list(type_spec()), module(), tester_parse_state:state()) ->
    {list(type_spec()), tester_parse_state:state()}.
parse_type_list(List, Module, ParseState) ->
    case List of
        [] ->
            {[], ParseState};
        [Head | Tail] ->
            {Type, ParseState2} = parse_type(Head, Module, ParseState),
            {TypeList, ParseState3} = parse_type_list(Tail, Module, ParseState2),
            {[Type | TypeList], ParseState3}
    end.

parse_constraints([], Substitutions) ->
    Substitutions;
parse_constraints([ConstraintType | Rest], Substitutions) ->
    case ConstraintType of
        {type,_,constraint,[{atom,_,is_subtype},[{var,_,Variable},Type]]} ->
            NewSubstitutions = gb_trees:insert(Variable, Type, Substitutions),
            parse_constraints(Rest, NewSubstitutions);
        _ ->
            ct:pal("unknown constraint ~w", [ConstraintType]),
            parse_constraints(Rest, Substitutions)
    end.

substitute_constraints(FunSpecs, Substitutions) when is_list(FunSpecs)->
    [substitute_constraints(FunSpec, Substitutions) ||  FunSpec <- FunSpecs];
% type variable
substitute_constraints({var,_Line,VarName}, Substitutions) ->
    case gb_trees:lookup(VarName, Substitutions) of
        {value, Substitution} -> Substitution;
        none -> {var,_Line,VarName}
    end;

substitute_constraints({type, Line,bounded_fun, [FunType, _Constraints]}, Substitutions) ->
    substitute_constraints(FunType, Substitutions);

% generic types
substitute_constraints({type, Line,TypeType, Types}, Substitutions) ->
    Types2 = substitute_constraints(Types, Substitutions),
    {type,Line,TypeType,Types2};

% special types
substitute_constraints({ann_type,Line,[Left,Right]}, Substitutions) ->
    Left2 = substitute_constraints(Left, Substitutions),
    Right2 = substitute_constraints(Right, Substitutions),
    {ann_type,Line,[Left2,Right2]};
substitute_constraints({remote_type,Line,[Left,Right,[]]}, Substitutions) ->
    Left2 = substitute_constraints(Left, Substitutions),
    Right2 = substitute_constraints(Right, Substitutions),
    {remote_type,Line,[Left2,Right2,[]]};
substitute_constraints(any, _Substitutions) ->
    any;

% value types
substitute_constraints({atom,Line,Value}, _Substitutions) ->
    {atom,Line,Value};
substitute_constraints({integer,Line,Value}, _Substitutions) ->
    {integer,Line,Value};

substitute_constraints(Unknown, Substitutions) ->
    ct:pal("Unknown: ~w", [Unknown]),
    ct:pal("~w", [Substitutions]),
    throw({subst_error, unknown_expression}),
    exit(foobar).
