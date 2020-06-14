:- module(woql_predicates,[
              t//3,
              t//4,
              insert//3,
              insert//4,
              read_object//3,
              query_term_properties/1
          ]).

:- discontiguous query_term_properties/1.

query_term_properties(
    properties{
        name : t,
        arity : 3,
        implementation : t,
        mode : [any,any,any],
        types : [node,node,obj],
        resource : true,
        stream : false
    }).

t(n(Subject), n(Predicate), o(Object), Resource) :-
    % What do we need to be passed in? Should there be two arguments?
    % Resource and Files?
    inferredEdge(Subject,Predicate,Object,Resource).

query_term_properties(insert/3,insert//3,[any,any,any],[node,node,obj]).
query_term_properties(insert/4,insert//4,[any,any,any,ground],[node,node,obj,resource]).
query_term_properties(read_object/3,read_object//3,[node,number,dict]).

