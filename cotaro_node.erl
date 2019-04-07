-module(cotaro_node).
-export([loop/2, test_nodes/0]).

-define(NumberOfFriendsRequired, 3).

sleep(N) -> receive after N*1000 -> ok end.

loop(MyFriends, State) ->
    case MyFriends of
        [] ->   io:format("~p require to teacher_node new friends ~n", [self()]),
                global:send(teacher_node, {get_friends, self(), make_ref()});
        _ ->    io:format("~p has at least one friend ~n", [self()])
    end,
    receive

        {ping, Mittente, Nonce} ->  Mittente ! {pong, Nonce},
                                    io:format("~p has received ping request, sending pong~n", [self()]),
                                    loop(MyFriends, State) ;


        {dead, Node} -> io:format("For ~p the node ~p is dead~n",[self(), Node]),
                        MyFriendsUpdated = MyFriends -- [Node],
                        askFriends(MyFriendsUpdated),
                        loop(MyFriendsUpdated, State);


        {friends, _, OtherFriends} ->   io:format("~p receive friend list ~n", [self()]),
                                        NewFriends = OtherFriends -- (MyFriends ++ [self()]),
                                        MyNewListOfFriends = addFriends(MyFriends, NewFriends),
                                        loop(MyNewListOfFriends, State);


        {get_friends, Sender, Nonce} -> io:format("~p send friend list to ~p ~n", [self(), Sender]),
                                        Sender ! {friends, Nonce, MyFriends},
                                        loop(MyFriends, State)

    end.



askFriends([]) ->   io:format("~p require friends to teacher node~n", [self()]),
                    global:send(teacher_node, {get_friends, self(), make_ref()});
askFriends(MyFriends) ->    io:format("~p require friends to another node~n", [self()]),
                            Nonce = make_ref(),
                            lists:nth(rand:uniform(length(MyFriends)), MyFriends) ! {get_friends, self(), Nonce}.


addFriends(MyFriends, []) -> MyFriends;
addFriends([], OtherFriends) ->
    NewFriend = lists:nth(rand:uniform(length(OtherFriends)), OtherFriends),
    io:format("~p add a new friend ~p~n",[self(), NewFriend]),
    Self = self(),
    spawn(fun () -> watch(Self,NewFriend) end),
    addFriends([NewFriend], OtherFriends -- [NewFriend]);
addFriends(MyFriends, OtherFriends) ->
    case length(MyFriends) < ?NumberOfFriendsRequired of
        true -> NewFriend = lists:nth(rand:uniform(length(OtherFriends)), OtherFriends),
                io:format("~p add a new friend ~p~n",[self(), NewFriend]),
                Self = self(),
                spawn(fun () -> watch(Self,NewFriend) end),
                addFriends( MyFriends ++ [NewFriend], OtherFriends -- [NewFriend]);
        false -> io:format("~p friend list = ~w ~n", [self(), MyFriends]),
                 MyFriends
    end.


watch(Main,Node) ->
  sleep(10),
  Ref = make_ref(),
  Node ! {ping, self(), Ref},
  receive
    {pong, Ref} -> watch(Main,Node)
  after 2000 -> Main ! {dead, Node}
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

%Controllo se la soluzione per il proof of work sia corretta, in caso negativo la nostra chain resta immutata,
%altrimenti faccio le seguenti operazioni: se abbiamo già il blocco nel nostro dizionario, non aggiungo nulla e non faccio gossiping,
%altrimenti aggiungo il blocco nel dizionario e faccio gossiping dell'update
updateBlock(Block, OurCurrentChain, Friends) -> 
    {IDnuovo_blocco, ID_bloccoprecedente, Lista_transazioni, Soluzione} = Block,
	{chain, Head, CurrChain} = OurCurrentChain,
	Chain = case proof_of_work:check(ID_bloccoprecedente, Lista_transazioni) of
		true -> case dict:find(IDnuovo_blocco, CurrChain) of
			{ok, Value} -> OurCurrentChain;
			error -> 
                NewChain = dict:store(IDnuovo_blocco, Block, OurCurrentChain),
				[F ! {update, Block} || F <- Friends],
				{chain, Block, NewChain}
			end;   
		false -> OurCurrentChain 
		end,
		%cerchiamo sempre di determinare la catena più lunga fra la nostra e quella degli amici
		%in modo da risolvere i casi di fork o qualora ci siamo appena connessi alla rete
		ChainList = getChainsFromFriends(Chain, Friends, Block),
		getLongestChainFromList(ChainList, Chain).

getChainsFromFriends(ChainTupla, Friends, Block) -> [newUpdateChain(F, make_ref(), Block, ChainTupla) || F <- Friends]. 

getLongestChainFromList([], CurrChain) -> CurrChain; 
getLongestChainFromList(ChainList, CurrChain) -> [H|Tail] = ChainList,
													LongestChain = getLongestChain(H, CurrChain),
													getLongestChainFromList(Tail, LongestChain).

updateChainAfterReceivedBlock(NewBlockSender, NewBlock, CurrentChain, Friends) ->
    {NewBlockID, PreviousBlockID, TransactionList, Solution} = NewBlock,
    {chain, Head, CurrentDictChain} = CurrentChain,
    case 
        % non mi è chiaro quale sia uso e input della check (id blocco o lista transazioni?)
        proof_of_work:check(NewBlockID, Solution) and (dict:find(NewBlockID, CurrentDictChain) =:= error)
    of
        false -> CurrentChain;
        true ->
            [F ! {update, NewBlock} || F <- Friends],
            getLongestChain(
                CurrentChain, 
                newUpdateChain(NewBlockSender, make_ref(), NewBlock, CurrentChain)
            )
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
test_nodes() ->
	T = spawn(teacher_node, main, []),
	sleep(5),
	M1 = spawn(?MODULE, loop, [[],[]]),
	M2 = spawn(?MODULE, loop, [[],[]]),
	M3 = spawn(?MODULE, loop, [[],[]]),
	M4 = spawn(?MODULE, loop, [[],[]]),
	io:format("Finito di spawnare 4 nodi + teacher_node~n"),
    sleep(15),
    exit(M2, manually_kill),
	sleep(15),
	Ref = make_ref(),
	M1 ! {get_friends, self(), Ref},
	receive
		{friends, Ref, Lista_amici} -> io:fwrite("Amici di M1 ~w~n",[Lista_amici])
	end.
