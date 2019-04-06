-module(cotaro_node_rec).
-export([loop/2, test_nodes/0]).

sleep(N) -> receive after N*1000 -> ok end.

%watcher che controlla periodicamente che il nodo sia vivo
watch(Main,Node) ->
  sleep(10),
  Ref = make_ref(),
  Node ! {ping, self(), Ref},
  receive
    {pong, Ref} -> watch(Main,Node)
  after 10000 -> Main ! {dead, Node}
  end.

loop(Nodes, State) ->
  receive
		{ping, Watcher, WatcherRef} -> Watcher ! {pong, WatcherRef} ,
							   io:format("~p has received ping request, sending pong~n", [self()])
  after 2000 -> global:send(teacher_node, {get_friends, self(), make_ref()})
  end,
  receive

	%{ping, Sender, Nonce} -> Sender ! {pong, Nonce};

    {get_friends, Sender, Nonce} ->
       Sender ! {friends, Nonce, Nodes},
       loop(Nodes, State) ;
	%%se uno dei nodi muore, manda a se stesso un messaggio "get_more_friends" e torna in loop
    {dead, Node} ->
       io:format("Dead node ~p~n",[Node]),
	   Ref = make_ref(),
	   self() ! {get_more_friends, Ref, Nodes -- [Node]},
       loop(Nodes -- [Node], State);

	{get_more_friends, Ref, CurrentNodes} -> getMoreFriends(self(), Ref, CurrentNodes);

	{friends, Ref, AmiciAltrui} -> AmiciDiversi = AmiciAltrui -- [self()|Nodes], %elimino dalla lista ottenuta me stesso e gli amici che già ho
		Nuovo_Amico = case length(AmiciDiversi) > 0 of %se la lista ottenuta non è vuota, scelgo un amico a caso
			true -> io:format("~p: AmiciDiversi: ~p~n", [self(), AmiciDiversi]),
				F = lists:nth(rand:uniform(length(AmiciDiversi)), AmiciDiversi),
				io:format("L'attore ~p sta aggiungendo un amico ~p.~n", [self(), F]),
				spawn(fun () -> watch(self(),F) end), %spawno il watcher per il nuovo amico
				F;

			false -> []
		end,
		loop([Nuovo_Amico|Nodes], State)

    after 2000 ->
	   case length(Nodes) < 3 of
		   true -> Ref = make_ref(),
				   self() ! {get_more_friends, Ref, Nodes},
				   io:format("L'attore ~p sta mandando a se stesso una get_more_friends", [self()]);
		   false -> ok
	   end,
	   loop(Nodes, State)
	end.

%% se abbiamo ancora amici, chiediamo la lista di amici ad un nostro amico, altrimenti la chiediamo al teacher_node
getMoreFriends(PID, Nonce, Nodes) ->
	io:format("L'attore ~p ha fatto chiamata a getMoreFriends.~n", [PID]),
	case length(Nodes) > 0 of
		true -> lists:nth(rand:uniform(length(Nodes)), Nodes) ! {get_friends, PID, Nonce};
		false -> global:send(teacher_node, {get_friends, PID, Nonce})
	end.

% può essere usata per ottenere il blocco richiesto da messaggio 'get_previous'
getBlockFromChain(CurrentChain, BlockID) ->
    {chain, _, CurrentDictChain} = CurrentChain,
    {ok, Block} = dict:find(BlockID, CurrentDictChain),
    Block.

% crea un dizionario sulla base di quello originale considerando solo la "catena"
% che parte da BlockID
iterDictChain(OriginalDict, Dict, BlockID) ->
    %non dovrebbero essere possibili errori
    Block = getBlockFromChain(OriginalDict, BlockID),
    NewDict = dict:append(BlockID, Block, Dict),
    {_, PreviousBlockID, _, _} = Block,
    case PreviousBlockID of
        none -> NewDict;
        ExistingID -> iterDictChain(OriginalDict, NewDict, ExistingID)
    end.

% Alla chiamata della funzione NewDictChain è un dizionario vuoto
newDictChain(SenderPID, Nonce, Block, CurrentDictChain, NewDictChain) ->
    {BlockID, PreviousBlockID, _, _} = Block,
    NewDictChain = dict:append(BlockID, Block, NewDictChain),
    case PreviousBlockID =:= none of
        true -> NewDictChain;
        false -> case dict:find(PreviousBlockID, CurrentDictChain) of
            {ok, Value} ->
                RemainingDict = iterDictChain(CurrentDictChain, dict:new(), PreviousBlockID),
                dict:merge(fun(K, V1, V2) -> V1 end, NewDictChain, RemainingDict);
            error ->
                SenderPID ! {get_previous, SenderPID, Nonce, PreviousBlockID},
                receive
                    {previous, Nonce, PreviousBlock} ->
                        newDictChain(
                            SenderPID, 
                            Nonce, 
                            PreviousBlock, 
                            CurrentDictChain,
                            NewDictChain
                        )
                end
        end
    end.

% CurrentChain {chain, HeadBlock, DictChain}
newUpdateChain(SenderPID, Nonce, NewBlock, CurrentChain) ->
    {NewBlockID, _, _, _} = NewBlock,
    {chain, _, CurrentDictChain} = CurrentChain,
    {
        chain, 
        NewBlockID,
        newDictChain(SenderPID, Nonce, NewBlock, CurrentDictChain, dict:new())
    }.

% ritorna la catena più lunga tra le due in input
% se la lunghezza è la stessa, viene ritornata la prima
getLongestChain(Chain1, Chain2) ->
    {chain, _, DictChain1} = Chain1,
    {chain, _, DictChain2} = Chain2,
    case length(dict:fetch_keys(DictChain1)) >= length(dict:fetch_keys(DictChain2)) of
        true -> Chain1;
        false -> Chain2
    end.

test_nodes() ->
	T = spawn(teacher_node, main, []),
	sleep(5),
	M1 = spawn(?MODULE, loop, [[],[]]),
	M2 = spawn(?MODULE, loop, [[],[]]),
	M3 = spawn(?MODULE, loop, [[],[]]),
	M4 = spawn(?MODULE, loop, [[],[]]),
	io:format("Finito di spawnare 4 nodi + teacher_node~n"),
	sleep(2),
	Ref = make_ref(),
	M1 ! {get_friends, self(), Ref},
	receive
		{friends, Ref, Lista_amici} -> io:fwrite("Amici di M1 ~w~n",[Lista_amici])
	end.
