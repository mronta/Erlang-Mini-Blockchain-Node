-module(cotaro_node).
-export([initializeNode/0, test_nodes/0]).

%definisce il numero di amici che ogni nodo deve cercare di mantenere
-define(NumberOfFriendsRequired, 3).
%definisce la struttura dello stato di un nodo
% - numberOfNotEnoughFriendRequest: il nodo si memorizza il numero di richieste di nuovi amici fatte che non gli hanno permesso di tornare al
%                                   numero di amici richiesto. Quando questo valore raggiunge il numero di amici che abbiamo passiamo a chiedere
%                                   al nodo professore perchè nessuno dei nostri amici è riuscito ad aiutarci.
-record(state, {numberOfNotEnoughFriendRequest}).

%utilizzata per lanciare un nuovo nodo
launchNode() -> spawn(?MODULE, initializeNode, []).

%utilizzata per inizializzare un nuovo nodo, in particolare:
% - initializza lo stato del nuovo nodo
% - richiede degli amici al nodo professore
% - avvia il behaviour del nodo
initializeNode() -> State = #state{numberOfNotEnoughFriendRequest = 0},
                    askFriendsToTeacher(),
                    loop([], State).

loop(MyFriends, State) ->
    receive

        {ping, Mittente, Nonce} ->  %io:format("~p has received ping request, sending pong~n", [self()]),
                                    Mittente ! {pong, Nonce},
                                    loop(MyFriends, State) ;


        {dead, Node} -> %un amico è morto quindi il nodo aggiorna la sua lista di amici e ne cerca uno nuovo
                        MyFriendsUpdated = MyFriends -- [Node],
                        io:format("For ~p the node ~p is dead, friend list updated = ~w~n",[self(), Node, MyFriendsUpdated]),
                        askFriends(MyFriendsUpdated),
                        loop(MyFriendsUpdated, State);


        {friends, _, OtherFriends} ->   %una lista di nuovi possibili amici è stata ricevuta
                                        %selezioniamo solo i nuovi possibili amici rimuovendo noi stessi e nodi che già conosciamo
                                        NewFriends = OtherFriends -- (MyFriends ++ [self()]),
                                        %estriamo dallo stato il numero di richieste di amici che non sono state sufficienti
                                        ActualNumberOfNotEnoughFriendRequest = State#state.numberOfNotEnoughFriendRequest,
                                        io:format("~p receive friend list, possible new friends = ~w~n", [self(), NewFriends]),
                                        case NewFriends of
                                            [] when  ActualNumberOfNotEnoughFriendRequest+1 < length(MyFriends) ->  %non riusciamo ad agiungere amici ma abbiamo ancora amici a cui chiedere
                                                                                                                    NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest+1 },
                                                                                                                    askFriends(MyFriends),
                                                                                                                    loop(MyFriends, NewState);

                                            [] when  ActualNumberOfNotEnoughFriendRequest+1 == length(MyFriends) -> %non riusciamo ad agiungere amici e abbiamo già chiesto a tutti i nostri amici quindi chiediamo al nodo professore
                                                                                                                    NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest+1 },
                                                                                                                    askFriendsToTeacher(),
                                                                                                                    loop(MyFriends, NewState);

                                            [] when  ActualNumberOfNotEnoughFriendRequest+1 > length(MyFriends) ->  %non riusciamo ad agiungere amici e abbiamo già chiesto anche al nodo professore quindi aspettiamo un pò e poi richiediamo a lui
                                                                                                                    NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest+1 },
                                                                                                                    launchTimerToAskFriendToTeacher(),
                                                                                                                    loop(MyFriends, NewState);

                                            _ ->    %abbiamo dei nuovi potenziali amici da aggiungere
                                                    MyNewListOfFriends = addFriends(MyFriends, NewFriends),
                                                    %se anche con i nuovi amici non riusciamo a raggiungere il numero necessario, applichiamo lo stesso comportamento visto sopra,
                                                    %altrimenti azzeriamo il numero di chiamate che non sono state sufficienti perchè abbiamo raggiunto il numero di amici richiesto
                                                    case length(MyNewListOfFriends) < ?NumberOfFriendsRequired of
                                                        true -> case ActualNumberOfNotEnoughFriendRequest of
                                                                    X when X+1 < length(MyNewListOfFriends) ->  NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest+1 },
                                                                                                                askFriends(MyNewListOfFriends);
                                                                    X when X+1 == length(MyNewListOfFriends) -> NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest+1 },
                                                                                                                askFriendsToTeacher();
                                                                    X when X+1 > length(MyNewListOfFriends) ->  NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest+1 },
                                                                                                                launchTimerToAskFriendToTeacher()
                                                                end;
                                                        false -> NewState = State#state{numberOfNotEnoughFriendRequest = 0 }
                                                    end,
                                                    loop(MyNewListOfFriends, NewState)
                                        end;


        {timer_askFriendsToTeacher} ->  %controlliamo se nel frattempo è successo qualcosa che ci ha fatto raggiungere il numero necessario di amicizie,
                                        %se non è così chiediamo al professore
                                        case length(MyFriends) < ?NumberOfFriendsRequired of
                                            true -> askFriendsToTeacher();
                                            false -> nothingToDo
                                        end,
                                        loop(MyFriends, State);


        {get_friends, Sender, Nonce} -> %ci arriva una richiesta di trasmissione dei nostri amici, quindi inviamo la nostra lista al mittente
                                        %io:format("~p send friend list to ~p ~n", [self(), Sender]),
                                        Sender ! {friends, Nonce, MyFriends},
                                        loop(MyFriends, State);

        {'DOWN', MonitorReference, process, _, Reason} ->   %monitoriamo tutti gli attori che spawniamo, se questi terminano normalmente non facciamo nulla,
                                                            %altrimenti li ri-lanciamo con le informazioni memorizzate nel dizionario di processo
                                                            case Reason of
                                                                normal ->   loop(MyFriends, State);
                                                                _ ->        ProcessData = get(MonitorReference),
                                                                            case ProcessData of
                                                                                launchTimerToAskFriendToTeacher -> launchTimerToAskFriendToTeacher();
                                                                                {watcher, PID} -> launchWatcher(PID)
                                                                            end,
                                                                            loop(MyFriends, State)
                                                            end

    end.


sleep(N) -> receive after N*1000 -> ok end.


launchWatcher(PID) ->   Self = self(),
                        WatcherPID = spawn(fun () -> watch(Self,PID) end),
                        %inseriamo le informazioni sull'attore watcher lanciato nel dizionario di processo così che
                        %se questo muore per qualche ragione, venga rilanciato
                        put(monitor(process, WatcherPID), {watcher, PID}).
watch(Main,Node) ->   sleep(10),
                      Ref = make_ref(),
                      Node ! {ping, self(), Ref},
                      receive
                        {pong, Ref} -> watch(Main,Node)
                      after 2000 -> Main ! {dead, Node}
                      end.


launchTimerToAskFriendToTeacher() ->    Creator = self(),
                                        TimerPID =  spawn(fun () -> io:format("~p launch timer to ask friends to teacher~n", [Creator]),
                                                        sleep(10),
                                                        Creator ! {timer_askFriendsToTeacher}
                                                    end),
                                        %inseriamo le informazioni sull'attore timer lanciato nel dizionario di processo così che
                                        %se questo muore per qualche ragione, venga rilanciato
                                        put(monitor(process, TimerPID), launchTimerToAskFriendToTeacher).

askFriendsToTeacher() -> askFriends([]).
askFriends([]) ->   io:format("~p require friends to teacher node~n", [self()]),
                    global:send(teacher_node, {get_friends, self(), make_ref()});
askFriends(MyFriends) ->    %selezioniamo casualmente uno dei nostri amici e gli inviamo una richiesta per ottenere la sua lista di amici
                            SelectedFriend = lists:nth(rand:uniform(length(MyFriends)), MyFriends),
                            io:format("~p require friends to ~p~n", [self(), SelectedFriend]),
                            Nonce = make_ref(),
                            SelectedFriend ! {get_friends, self(), Nonce}.


addFriends(MyFriends, []) ->    io:format("~p updated friend list = ~w ~n", [self(), MyFriends]),
                                MyFriends;
addFriends(MyFriends, OtherFriends) ->  %aggiungiamo amici finchè non raggiungiamo il numero necessario o finiscono i potenziali nuovi amicizi
                                        %la scelta di un nuovo amico, tra i potenziali a disposizione è casuale e su questo viene lanciato un watcher
                                        %per controllare che rimanga in vita
                                        case length(MyFriends) < ?NumberOfFriendsRequired of
                                            true -> NewFriend = lists:nth(rand:uniform(length(OtherFriends)), OtherFriends),
                                                    io:format("~p add a new friend ~p~n",[self(), NewFriend]),
                                                    launchWatcher(NewFriend),
                                                    addFriends( MyFriends ++ [NewFriend], OtherFriends -- [NewFriend]);
                                            false -> io:format("~p updated friend list = ~w ~n", [self(), MyFriends]),
                                                     MyFriends
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
	sleep(1),
	M1 = launchNode(),
	M2 = launchNode(),
	M3 = launchNode(),
	M4 = launchNode(),
    sleep(3),
    M5 = launchNode(),
    sleep(3),
    exit(M2, manually_kill),
	%sleep(15),
	%Ref = make_ref(),
	%M1 ! {get_friends, self(), Ref},
	%receive
	%	{friends, Ref, Lista_amici} -> io:fwrite("Amici di M1 ~w~n",[Lista_amici])
	%end.
    test_launched.
