:- module(triplestore, [
              destroy_graph/1,
              make_empty_graph/1,
              destroy_indexes/0,
              sync_from_journals/0,
              sync_from_journals/1,
              xrdf/4,
              insert/4,
              delete/4,
              update/5,
              commit/1,
              rollback/1,
              check_graph_exists/1,
              graph_checkpoint/2,
              current_checkpoint_directory/2,
              last_checkpoint_number/2,
              with_output_graph/2,
              ttl_to_hdt/2,
              with_transaction/2
          ]).

:- use_module(library(hdt)). 
:- use_module(library(file_utils)).
:- use_module(library(journaling)).
:- use_module(library(utils)).
:- use_module(library(schema), [cleanup_schema_module/1]).
:- use_module(library(prefixes)).
:- use_module(library(types)).

/** <module> Triplestore
 * 
 * This module contains the database management predicates responsible 
 * for creating collections, graphs and syncing from journals.
 * 
 * * * * * * * * * * * * * COPYRIGHT NOTICE  * * * * * * * * * * * * * * *
 *                                                                       *
 *  This file is part of TerminusDB.                                     *
 *                                                                       *
 *  TerminusDB is free software: you can redistribute it and/or modify   *
 *  it under the terms of the GNU General Public License as published by *
 *  the Free Software Foundation, either version 3 of the License, or    *
 *  (at your option) any later version.                                  *
 *                                                                       *
 *  TerminusDB is distributed in the hope that it will be useful,        *
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of       *
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the        *
 *  GNU General Public License for more details.                         *
 *                                                                       *
 *  You should have received a copy of the GNU General Public License    *
 *  along with TerminusDB.  If not, see <https://www.gnu.org/licenses/>. *
 *                                                                       *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

/** 
 * retract_graph(+G:atom) is det. 
 * 
 * Retract all dynamic elements of graph. 
 */
retract_graph(Graph_Name) :-
    forall(
        (   dependent_modules(Graph_Name, Modules),
            member(Module, Modules)), 
        schema:cleanup_schema_module(Module)
    ),
    retractall(xrdf_pos(Graph_Name,_,_,_)),
    retractall(xrdf_neg(Graph_Name,_,_,_)),
    retractall(xrdf_pos_trans(Graph_Name,_,_,_)),
    retractall(xrdf_neg_trans(Graph_Name,_,_,_)).

/** 
 * destroy_graph(+Database,+Graph_Id:graph_identifier) is det. 
 * 
 * Completely remove a graph from disk.
 */
destroy_graph(Graph_Name) :-
    retract_graph(Graph_Name),
    graph_directory(Graph_Name, GraphPath),
    delete_directory_and_contents(GraphPath).

/** 
 * destroy_indexes(+G) is det.
 * 
 * Destroy indexes for graph G in collection C. 
 */
destroy_indexes(G) :-
    current_checkpoint_directory(G,CPD),
    files(CPD,Entries),
    include(hdt_file_type,Entries,HDTEntries),
    maplist({CPD}/[H,F]>>(interpolate([CPD,'/',H],Path),
                          atom_concat(Path,'.index.v1-1',F)), HDTEntries, FileCandidates),
    include(exists_file,FileCandidates,Files),
    maplist(delete_file,Files).

destroy_indexes :-
    forall(
        (
            graphs(Gs),
            member(G,Gs)
        ),
        ignore(destroy_indexes(G))
    ).

/** 
 * sync_from_journals(+G) is det.
 * 
 * Sync journals for a graph and collection
 */
sync_from_journals(Graph_Name) :-
    % First remove everything in the dynamic predicates.
    (   retract_graph(Graph_Name),
        hdt_transform_journals(Graph_Name),
        get_truncated_queue(Graph_Name,Queue),
        sync_queue(Graph_Name, Queue)
    ->  true
    % in case anything failed, retract the graph
    ;   retract_graph(Graph_Name),
        throw(graph_sync_error(Graph_Name))
    ).

/** 
 * cut_queue_at_checkpoint(+Sorted,-RelevantQueue) is det.
 * 
 * Takes the relevant queue, and clips it at the first checkpoint. 
 */
cut_queue_at_checkpoint([H|_T],[H]) :-
    graph_file_type(H,ckp).
cut_queue_at_checkpoint([H|T],[H|R]) :-
    graph_file_type(H,Type), (Type=pos; Type=neg),
    cut_queue_at_checkpoint(T,R).

/** 
 * type_compare(+Ty1,+Ty2,-Ord).
 * 
 * Ty1,Ty2 is one of {ckp,neg,pos}. This gives a total ordering.
 */ 
type_compare(X,X,(=)).
type_compare(ckp,_,(>)).
type_compare(pos,_,(<)).
type_compare(neg,ckp,(<)).
type_compare(neg,pos,(>)).

/** 
 * get_truncated_queue(+Collection,+Graph,-Queue) is semidet. 
 * 
 * Get the queue associated with a graph up to the first checkpoint if it exists. 
 */
get_truncated_queue(G,Queue) :-
    current_checkpoint_directory(G,DirPath), 
    files(DirPath,Entries),
    include(hdt_file_type,Entries,HDTEntries),
    predsort([Delta,X,Y]>>(   graph_file_timestamp_compare(X,Y,Ord),
                              (   Ord=(>)
                              ->  Delta=(<)
                              ;   Ord=(<)
                              ->  Delta=(>)
                              ;   graph_file_type(X,Tx),
                                  graph_file_type(Y,Ty),
                                  type_compare(Tx,Ty,Delta))),
             HDTEntries,Sorted),

    %format('Sorted queue: ~q~n',[Sorted]),
    
    cut_queue_at_checkpoint(Sorted,RelevantQueue),

    %format('Relevant queue: ~q~n',[Sorted]),

    findall(Elt,
            (
                member(File,RelevantQueue),
                interpolate([DirPath,'/',File],FilePath),
                hdt_open(HDT0, FilePath),
		        graph_file_type(File,Type),                
                ( Type=pos, Elt=pos(HDT0)
                ; Type=neg, Elt=neg(HDT0)
                ; Type=ckp, Elt=ckp(HDT0))
            ),
            Queue).
    
/** 
 * hdt_tranform_journals(+Collection_ID,+Graph_ID) is det.
 * 
 * Transform all oustanding journals to hdt files for graph G. 
 * 
 * TODO: This has never been tested.
 */
hdt_transform_journals(Graph_Name) :-
    graph_directory(Graph_Name,DirPath),
    subdirectories(DirPath,Entries),
    forall(member(Entry,Entries),
           (   interpolate([DirPath,'/',Entry],Directory),
               files(Directory,Files),
             
               include({Directory}/[F]>>(interpolate([Directory,'/',F],Full),
                                         turtle_file_type(Full)),
                       Files,TurtleEntries), 
             
               forall(member(TTLFile,TurtleEntries),
                      (   graph_file_base(TTLFile,Base),
                          interpolate([Directory,'/',TTLFile],TTLFilePath),
                          interpolate([Directory,'/',Base,'.hdt'],HDTFilePath),
                          (   exists_file(HDTFilePath)
                          ->  true
                          ;   ttl_to_hdt(TTLFilePath,HDTFilePath),
                              % get rid of any possible old indexes
                              interpolate([Directory,'/',Base,'.hdt.index.v1-1'],I),
                              (   exists_file(I)
                              ->  delete_file(I)
                              ;   true)
                          )
                      )
                     )
           )
          ).

/** 
 * xrdf_pos_trans(+G:atom,?X,?Y,?Z) is nondet.
 * 
 * The dynamic predicate which stores positive updates for transactions.
 * This is thread local - it only functions in a transaction
 */
:- thread_local xrdf_pos_trans/4.

/** 
 * xrdf_neg_trans(+G:atom,?X,?Y,?Z) is nondet.
 * 
 * The dynamic predicate which stores negative updates for transactions.
 */
:- thread_local xrdf_neg_trans/4.

/** 
 * xrdf_pos(+G,?X,?Y,?Z) is nondet.
 * 
 * The dynamic predicate which stores positive updates from the journal. 
 */
:- dynamic xrdf_pos/4.

/** 
 * xrdf_neg(+G:atom,?X,?Y,?Z) is nondet.
 * 
 * The dynamic predicate which stores negative updates from the journal. 
 */
:- dynamic xrdf_neg/4.

/**
 * check_graph_exists(+G:graph_identifier) is semidet.
 * 
 * checks to see is the graph id in the current graph list
 **/
check_graph_exists(G):-
    graphs(G_List),
    memberchk(G, G_List).  

/** 
 * graph_checkpoint(+G,-HDT) is semidet.
 * 
 * Returns the last checkpoint HDT associated with a given graph. 
 */
graph_checkpoint(G, HDT) :-
    graph_hdt_queue(G, Queue),
    graph_checkpoint_search(Queue, HDT).

graph_checkpoint_search([], _) :- fail.

graph_checkpoint_search([ckp(HDT)|_], HDT).
graph_checkpoint_search([pos(_)|Rest], Result) :-
    graph_checkpoint_search(Rest, Result).
graph_checkpoint_search([neg(_)|Rest], Result) :-
    graph_checkpoint_search(Rest, Result).

/**
 * graph_hdt_queue(+G, -HDTs) is semidet.
 *
 * Returns a queue of hdt files up to and including the last checkpoint.
 * This is recalculated by sync_queue/2.
 */
:- dynamic graph_hdt_queue/2.

/** 
 * sync_queue(+Collection_ID,+G,+Queue) is det. % + exception
 * 
 * Update the xrdf_pos/4 and xrdf_neg/4 predicates and the 
 * graph_checkpoint/1 predicate from the current graph. 
 */
sync_queue(G, Queue) :-
    (   check_queue(Queue)
    ->  true
    ;   throw(malformed_graph_journal_queue(G))),
    (   graph_hdt_queue(G, Old_Queue)
    ->  close_all_handles(Old_Queue)
    ;   true),
    retractall(graph_hdt_queue(G,_)),
    asserta(graph_hdt_queue(G, Queue)).

/**
 * close_all_handles(+Queue:list) is det.
 *
 * Close all hdt handles of the queue.
 */
close_all_handles([]).
close_all_handles([Head|Rest]) :-
    Head =.. [_, HDT],
    hdt_close(HDT),
    close_all_handles(Rest).

/** 
 * with_output_graph(+Template,:Goal) is det. 
 * 
 * Template is graph(Collection_ID,Graph_Id,Type,Ext) where Type is one of {ckp,neg,pos}
 * and Ext is one of {ttl,hdt,ntr}
 *
 * ckp is for new graph (initial checkpoint) or any thereafter. 
 */
:- meta_predicate with_output_graph(?, 0).
with_output_graph(graph(G,Type,Ext),Goal) :-
    with_mutex(
        G,
        (   current_checkpoint_directory(G,CPD),
            last_plane_number(CPD,M),
            N is M+1,
            %get_time(T),floor(T,N), %switch to sequence numbers
            interpolate([CPD,'/',N,'-',Type,'.',Ext],NewFile),

            catch(
                (   
                    open(NewFile,write,Stream),
                    set_graph_stream(G,Stream,Type,Ext),
                    initialise_graph(G,Stream,Type,Ext),
                    !, % Don't ever retreat!
                    (   once(call(Goal))
                    ->  true
                    ;   format(atom(Msg),'Goal (~q) in with_output_graph failed~n',[Goal]),
                        throw(transaction_error(Msg))
                    ),
                    finalise_graph(G,Stream,Type,Ext)
                ),
                E,
                (   finalise_graph(G,Stream,Type,Ext),
                    throw(E)
                )
            )
        )
    ).

/** 
 * checkpoint(+Collection_Id,+Graph_Id:graph_identifier) is det.
 * 
 * Create a new graph checkpoint from our current dynamic triple state
 */
checkpoint(Graph_Id) :-
    make_checkpoint_directory(Graph_Id, _),
    with_output_graph(
        graph(Graph_Id,ckp,ttl),
        (
            forall(
                xrdf(Graph_Id,X,Y,Z),
                write_triple(Graph_Id,ckp,X,Y,Z)
            )
        )
    ).


/** 
 * check_queue(+Queue) is det.
 * 
 * Sanity check the queue. 
 */
check_queue([pos(_HDT)|Res]) :-
        check_queue(Res). 
check_queue([neg(_HDT)|Res]) :-
        check_queue(Res). 
check_queue([ckp(_HDT)]).

/** 
 * sync_from_journals is det.  
 * 
 * This predicate updates the xrdf_pos/5 and xrdf_neg/5 predicate so that 
 * it reflects the current state of the database on file. 
 */ 
sync_from_journals :-
    forall(
        (   graphs(Graphs),
            member(Graph_Name, Graphs)
        ),
        (
            format("~n ** Syncing ~q ~n~n", [Graph_Name]),
            catch(sync_from_journals(Graph_Name),
                  graph_sync_error(Graph_Name),
                  format("~n ** ERROR: Graph ~s failed to sync.~n~n", [Graph_Name]))      
        )
    ).

/** 
 * make_empty_graph(+Graph) is det.
 * 
 * Create a new empty graph
 */
make_empty_graph(Graph_Id) :-
    % create the graph if it doesn't exist
    graph_directory(Graph_Id,Graph_Path),
    ensure_directory(Graph_Path),
    make_checkpoint_directory(Graph_Id, CPD),
    %get_time(T),floor(T,N),
    N=1,
    interpolate([CPD,'/',N,'-ckp.ttl'],TTLFile),
    touch(TTLFile),
    interpolate([CPD,'/',N,'-ckp.hdt'],CKPFile),
    ttl_to_hdt(TTLFile,CKPFile).

/** 
 * import_graph(+File,+Graph) is det.
 * 
 * This predicate imports a given File as the latest checkpoint of Graph_Name
 * 
 * File will be in either ntriples, turtle or hdt format. 
 */
import_graph(File, Graph_Id) :-    
    graph_file_extension(File,Ext),
    (   Ext = hdt,
        hdt_open(_, File, [access(map), indexed(false)]), % make sure this is a proper HDT file
        make_checkpoint_directory(Graph_Id,CPD),
        N=1,
        %get_time(T),floor(T,N),
        interpolate([CPD,'/',N,'-ckp.hdt'],NewFile),
        copy_file(File,NewFile)
    ;   Ext = ttl,
        make_checkpoint_directory(Graph_Id,CPD),
        N=1,                
        %get_time(T),floor(T,N),
        interpolate([CPD,'/',N,'-ckp.hdt'],NewFile),
        ttl_to_hdt(File,NewFile)
    ;   Ext = ntr,
        make_checkpoint_directory(Graph_Id,CPD),
        N=1,                
        %get_time(T),floor(T,N),
        interpolate([CPD,'/',N,'-ckp.hdt'],NewFile),
        ntriples_to_hdt(File,NewFile)
    ),
    sync_from_journals(Graph_Id).

/** 
 * literal_to_canonical(+Lit,-Can) is det. 
 * 
 * Converts a literal to canonical form. Currently 
 * we are only canonicalising booleans. We may extend as necessary.
 */
literal_to_canonical(literal(type('http://www.w3.org/2001/XMLSchema#boolean',Lit)),
                     literal(type('http://www.w3.org/2001/XMLSchema#boolean',Can))) :-
    !,
    (   member(Lit, ['1',true])
    ->  Can=true
    ;   (   member(Lit, ['0',false]) 
        ->  Can=false
        ;   fail)             
    ).
literal_to_canonical(X,X).

/** 
 * canonicalise_object(+O,-C) is det. 
 * 
 * Finds the canonical form for an object
 */
canonicalise_object(O,C) :-
    (   is_literal(O)
    ->  literal_to_canonical(O,C)
    ;   O=C).

/** 
 * insert(+G:graph_identifier,+X,+Y,+Z) is det.
 * 
 * Insert quint into transaction predicates.
 */
insert(G,X,Y,O) :-
    canonicalise_object(Z,O),
    (   xrdf(G,X,Y,Z)
    ->  true
    ;   asserta(xrdf_pos_trans(G,X,Y,Z)),
        (   xrdf_neg_trans(G,X,Y,Z)
        ->  retractall(xrdf_neg_trans(G,X,Y,Z))
        ;   true)).

user:goal_expansion(insert(G,A,Y,Z),insert(G,X,Y,Z)) :-
    \+ var(A),
    global_prefix_expand(A,X).
user:goal_expansion(insert(G,X,B,Z),insert(G,X,Y,Z)) :-
    \+ var(B),
    global_prefix_expand(B,Y).
user:goal_expansion(insert(G,X,Y,C),insert(G,X,Y,Z)) :-
    \+ var(C),
    \+ C = literal(_),        
    global_prefix_expand(C,Z).
user:goal_expansion(insert(G,X,Y,literal(L)),insert(G,X,Y,Object)) :-
    \+ var(L),
    literal_expand(literal(L),Object).


/** 
 * delete(+G,+X,+Y,+Z) is det.
 * 
 * Delete quad from transaction predicates.
 */
delete(G,X,Y,O) :-
    canonicalise_object(Z,O),
    (   xrdf_pos_trans(G,X,Y,Z)
    ->  retractall(xrdf_pos_trans(G,X,Y,Z))        
    ;   true),
    (   xrdfdb(G,X,Y,Z)
    ->  asserta(xrdf_neg_trans(G,X,Y,Z))
    ;   true).

user:goal_expansion(delete(G,A,Y,Z),delete(G,X,Y,Z)) :-
    \+ var(A),
    global_prefix_expand(A,X).
user:goal_expansion(delete(G,X,B,Z),delete(G,X,Y,Z)) :-
    \+ var(B),
    global_prefix_expand(B,Y).
user:goal_expansion(delete(G,X,Y,C),delete(G,X,Y,Z)) :-
    \+ var(C),
    \+ C = literal(_),                
    global_prefix_expand(C,Z).
user:goal_expansion(delete(G,X,Y,literal(L)),delete(G,X,Y,Object)) :-
    \+ var(L),
    literal_expand(literal(L),Object).

new_triple(_,Y,Z,subject(X2),X2,Y,Z).
new_triple(X,_,Z,predicate(Y2),X,Y2,Z).
new_triple(X,Y,_,object(Z2),X,Y,Z2).

/** 
 * update(+G,+X,+Y,+Z,+G,+Action) is det.
 * 
 * Update transaction graphs
 */ 
update(G,X,Y,Z,Action) :-
    delete(G,X,Y,Z),
    new_triple(X,Y,Z,Action,X1,Y1,Z1),
    insert(G,X1,Y1,Z1).

user:goal_expansion(update(G,A,Y,Z,Act),update(G,X,Y,Z,Act)) :-
    \+ var(A),
    global_prefix_expand(A,X).
user:goal_expansion(update(G,X,B,Z,Act),update(G,X,Y,Z,Act)) :-
    \+ var(B),
    global_prefix_expand(B,Y).
user:goal_expansion(update(G,X,Y,C,Act),update(G,X,Y,Z,Act)) :-
    \+ var(C),
    \+ C = literal(_),
    global_prefix_expand(C,Z).
user:goal_expansion(update(G,X,Y,literal(L),Act),update(G,X,Y,Object,Act)) :-
    \+ var(L),
    literal_expand(literal(L),Object).

/** 
 * commit(+G:graph_id) is det.
 * 
 * Commits the current transaction state to backing store and dynamic predicate
 * for a given collection and graph.
 */
commit(GName) :-
    % Time order here is critical as we actually have a time stamp for ordering.
    % negative before positive
    % graph_id_name(G,GName),
    with_output_graph(
            graph(GName,neg,ttl),
            (   forall(
                     xrdf_neg_trans(GName,X,Y,Z),
                     (   % journal
                         write_triple(GName,neg,X,Y,Z),
                         % dynamic 
                         retractall(xrdf_pos(GName,X,Y,Z)),
                         retractall(xrdf_neg(GName,X,Y,Z)),
                         asserta(xrdf_neg(GName,X,Y,Z))
                     ))
            )
    ),
    retractall(xrdf_neg_trans(GName,X,Y,Z)),
    
    with_output_graph(
            graph(GName,pos,ttl),
            (   forall(
                    xrdf_pos_trans(GName,X,Y,Z),
                     
                    (% journal
                        write_triple(GName,pos,X,Y,Z),
                        % dynamic
                        retractall(xrdf_pos(GName,X,Y,Z)),
                        retractall(xrdf_neg(GName,X,Y,Z)),
                        asserta(xrdf_pos(GName,X,Y,Z))
                    ))
            )
    ),
    retractall(xrdf_pos_trans(GName,X,Y,Z)).

/** 
 * rollback(+Collection_Id,+Graph_Id:graph_identifier) is det.
 * 
 * Rollback the current transaction state.
 */
rollback(GName) :-
    % graph_id_name(Graph_Id, GName),
    retractall(xrdf_pos_trans(GName,X,Y,Z)),
    retractall(xrdf_neg_trans(GName,X,Y,Z)). 

/** 
 * xrdf(+Graph_Id,?Subject,?Predicate,?Object) is nondet.
 * 
 * The basic predicate implementing the the RDF database.
 * This layer has the transaction updates included.
 *
 * Graph is either an atom or a list of atoms, referring to the name(s) of the graph(s).
 */
% temporarily remove id behaviour.
xrdf(Gs,X,Y,Z) :-
    member(G,Gs),
    xrdfid(G,X,Y,Z).

user:goal_expansion(xrdf(G,A,Y,Z),xrdf(G,X,Y,Z)) :-
    \+ var(A),
    global_prefix_expand(A,X).
user:goal_expansion(xrdf(G,X,B,Z),xrdf(G,X,Y,Z)) :-
    \+ var(B),
    global_prefix_expand(B,Y).
user:goal_expansion(xrdf(G,X,Y,C),xrdf(G,X,Y,Z)) :-
    \+ var(C),
    \+ C = literal(_),
    global_prefix_expand(C,Z).
user:goal_expansion(xrdf(G,X,Y,literal(L)),xrdf(G,X,Y,Object)) :-
    \+ var(L),
    literal_expand(literal(L),Object).

xrdfid(G,X0,Y0,Z0) :-
    !,
    (   xrdf_pos_trans(G,X0,Y0,Z0)      % If in positive graph, return results
    ;   xrdfdb(G,X0,Y0,Z0),             % or a lower plane
        \+ xrdf_neg_trans(G,X0,Y0,Z0)   % but only if it's not negative
    ). 
        
/** 
 * xrdfdb(+Collection_Id,+Graph_Id,?X,?Y,?Z) is nondet.
 * 
 * This layer has only those predicates with backing store.
 */ 
xrdfdb(G,X,Y,Z) :-
    graph_hdt_queue(G,Queue),
    xrdf_search_queue(Queue,X,Y,Z).

/* 
 * xrdf_search_queue(Queue,X,Y,Z) is nondet.
 * 
 * Underlying planar access to hdts
 */
xrdf_search_queue([ckp(HDT)|_],X,Y,Z) :-
    hdt_search_safe(HDT,X,Y,Z).
xrdf_search_queue([pos(HDT)|Rest],X,Y,Z) :-
    (   hdt_search_safe(HDT,X,Y,Z)
    ;   xrdf_search_queue(Rest,X,Y,Z)).
xrdf_search_queue([neg(HDT)|Rest],X,Y,Z) :-
    xrdf_search_queue(Rest,X,Y,Z),
    \+ hdt_search_safe(HDT,X,Y,Z).

/* 
 * hdt_search_safe(HDT,X,P,Y) is nondet.
 * 
 * Add some marshalling.
 */ 
hdt_search_safe(HDT,X,Y,literal(type(T,Z))) :-
	hdt_search(HDT,X,Y,Z^^T).
hdt_search_safe(HDT,X,Y,literal(lang(L,Z))) :-
	hdt_search(HDT,X,Y,Z@L).
hdt_search_safe(HDT,X,Y,Z) :-
	atom(Z),
	hdt_search(HDT,X,Y,Z).
hdt_search_safe(HDT,X,Y,Z) :-
	var(Z),
	hdt_search(HDT,X,Y,Z),
	atom(Z).


/** 
 * with_transaction(+Options,:Goal) is semidet.
 * 
 * Executes goal, commits if successful, and rolls back if not.
 * 
 * Options is a list which contains any of:
 * 
 *  graphs([Graph0,Graph1,...,Graphn])
 * 
 *  Specifying each of the graphs which is in the transaction
 * 
 *  success(SuccessFlag)
 *  
 *  which gives a way to make the transaction fail, even if goal succeeds 
 * 
 * TODO: We should perhaps have an additional structure witness(Witness) which 
 *       returns the witnesses of failure
 *
 */
with_transaction(Options,Goal) :-
    % some crazy heavy locking here!
    with_mutex(transaction,
               (   member(graphs(Graph_Id_Bag),Options),
                   !,
                   sort(Graph_Id_Bag,Graph_Ids),
                   !,
                   % if we can't get graphs, there is nothing interesting to do anyhow. 
                   (
                       % select success flag from
                       ignore(
                           member(success(SuccessFlag),Options)
                       ),
                       % Call the goal
                       call(Goal),
                       
                       (   (   
                               (   var(SuccessFlag)
                               % If the goal succeeds but there is no success flag, set to true
                               ->  SuccessFlag = true
                               ;   true)
                           ->  true
                           % If the goal fails, we want to signal failure and rollback
                           ;   SuccessFlag = false
                           ),
                           SuccessFlag = true
                       ->  forall(member(G,Graph_Ids),
                                  (   commit(G),
                                      sync_from_journals(G)))
                       % We have succeeded in running the goal but Success is false
                       ;   forall(member(G,Graph_Ids),rollback(G))
                       )
                   ->  true
                   % We have not succeeded in running goal, so we need to cleanup
                   ;   forall(member(G,Graph_Ids),rollback(G)),
                       fail
                   )
               )
              ).
