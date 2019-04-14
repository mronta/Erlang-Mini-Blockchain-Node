-module(cotaro_node).
-export([initializeNode/0, test_nodes/0]).

%definisce il numero di amici che ogni nodo deve cercare di mantenere
-define(NumberOfFriendsRequired, 3).

%definisce la struttura dello stato di un nodo
% - numberOfNotEnoughFriendRequest: il nodo si memorizza il numero di richieste di nuovi amici fatte che non gli hanno permesso di tornare al
%                                   numero di amici richiesto. Quando questo valore raggiunge il numero di amici che abbiamo passiamo a chiedere
%                                   al nodo professore perchè nessuno dei nostri amici è riuscito ad aiutarci.
% - chain: è una tupla composta da {chain, IdHead, Dictonary}. Il primo campo è un atomo, il secondo è l'ID del blocco che si trova in testa alla catena
%         (ovvero l'ultimo che è stato inserito) ed infine l'ultimo campo è il dizionario che utilizziamo per memorizzare tutti i blocchi che compongono la nostra catena.
%         Il dizionario usa come chiavi gli ID dei blocchi e come valori gli oggetti "blocco" corrispondenti.
% - listOfTransaction: è la lista delle nuove transazioni che riceviamo e che possiamo inserire in un nuovo blocco dopo averlo minato
-record(state, {numberOfNotEnoughFriendRequest, chain, listOfTransaction}).

%utilizzata per lanciare un nuovo nodo
launchNode() -> spawn(?MODULE, initializeNode, []).

%utilizzata per inizializzare un nuovo nodo, in particolare:
% - initializza lo stato del nuovo nodo
% - richiede degli amici al nodo professore
% - avvia il behaviour del nodo
initializeNode() -> 
    State = #state{
        numberOfNotEnoughFriendRequest = 0,
        chain =  {chain, none, dict:new()},
        listOfTransaction = []
    },
    process_flag(trap_exit, true),
    askFriendsToTeacher(),
    loop([], State).

loop(MyFriends, State) ->
    receive

        {ping, Mittente, Nonce} ->  
            %io:format("~p has received ping request, sending pong~n", [self()]),
            Mittente ! {pong, Nonce},
            loop(MyFriends, State);


        {dead, Node} -> 
            %un amico è morto quindi il nodo aggiorna la sua lista di amici e ne cerca uno nuovo
            MyFriendsUpdated = MyFriends -- [Node],
            io:format("For ~p the node ~p is dead, friend list updated = ~w~n",[self(), Node, MyFriendsUpdated]),
            askFriends(MyFriendsUpdated),
            loop(MyFriendsUpdated, State);

        {friends, Nonce, Friends} ->
            %gestirà solo il messaggio di risposta del teacher alla get_friends (quello con esattamente il Nonce memorizzato nel dizionario di processo)
            TeacherNonce = get(friendsTeacherNonce),
            if
                TeacherNonce =:= Nonce ->   
                    %per gestire l'arrivo di una lista di possibili amici mi invio internamente il messaggio privato apposito
                    self() ! {friendsInternalMessage, Friends},
                    erase(friendsTeacherNonce);
                true -> 
                    %else
                    io:format("~p receive a friends list with a unknown nonce, so it erases the message~n", [self()])
            end,
            loop(MyFriends, State);

        {friendsInternalMessage, OtherFriends} ->   
            %una lista di nuovi possibili amici è stata ricevuta
            %selezioniamo solo i nuovi possibili amici rimuovendo noi stessi e nodi che già conosciamo
            NewFriends = OtherFriends -- (MyFriends ++ [self()]),
            %estriamo dallo stato il numero di richieste di amici che non sono state sufficienti
            ActualNumberOfNotEnoughFriendRequest = State#state.numberOfNotEnoughFriendRequest,
            %io:format("~p receive friend list, possible new friends = ~w~n", [self(), NewFriends]),
            case NewFriends of
                [] when  ActualNumberOfNotEnoughFriendRequest+1 < length(MyFriends) ->  
                    %non riusciamo ad agiungere amici ma abbiamo ancora amici a cui chiedere
                    NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest+1 },
                    askFriends(MyFriends),
                    loop(MyFriends, NewState);

                [] when  ActualNumberOfNotEnoughFriendRequest+1 == length(MyFriends) -> 
                    %non riusciamo ad agiungere amici e abbiamo già chiesto a tutti i nostri amici quindi chiediamo al nodo professore
                    NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest+1 },
                    askFriendsToTeacher(),
                    loop(MyFriends, NewState);

                [] when  ActualNumberOfNotEnoughFriendRequest+1 > length(MyFriends) ->  %non riusciamo ad agiungere amici e abbiamo già chiesto anche al nodo professore quindi aspettiamo un pò e poi richiediamo a lui
                    NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest+1 },
                    launchTimerToAskFriendToTeacher(),
                    loop(MyFriends, NewState);

                _ ->    
                    %abbiamo dei nuovi potenziali amici da aggiungere
                    MyNewListOfFriends = addFriends(MyFriends, NewFriends),
                    %se anche con i nuovi amici non riusciamo a raggiungere il numero necessario, applichiamo lo stesso comportamento visto sopra,
                    %altrimenti azzeriamo il numero di chiamate che non sono state sufficienti perchè abbiamo raggiunto il numero di amici richiesto
                    case length(MyNewListOfFriends) < ?NumberOfFriendsRequired of
                        true -> case ActualNumberOfNotEnoughFriendRequest of
                            X when X+1 < length(MyNewListOfFriends) ->  
                                NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest+1 },
                                askFriends(MyNewListOfFriends);
                            X when X+1 == length(MyNewListOfFriends) -> 
                                NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest+1 },
                                askFriendsToTeacher();
                            X when X+1 > length(MyNewListOfFriends) ->  
                                NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest+1 },
                                launchTimerToAskFriendToTeacher()
                        end;
                        false -> NewState = State#state{numberOfNotEnoughFriendRequest = 0 }
                    end,
                    loop(MyNewListOfFriends, NewState)
            end;


        {timer_askFriendsToTeacher} ->  
            %controlliamo se nel frattempo è successo qualcosa che ci ha fatto raggiungere il numero necessario di amicizie,
            %se non è così chiediamo al professore
            case length(MyFriends) < ?NumberOfFriendsRequired of
                true -> askFriendsToTeacher();
                false -> nothingToDo
            end,
            loop(MyFriends, State);


        {get_friends, Sender, Nonce} -> 
            %ci arriva una richiesta di trasmissione dei nostri amici, quindi inviamo la nostra lista al mittente
            %io:format("~p send friend list to ~p ~n", [self(), Sender]),
            Sender ! {friends, Nonce, MyFriends},
            loop(MyFriends, State);


        {push, Transaction} ->  
            %Transaction = {IDtransazione, Payload}
            {IdTransaction, _} = Transaction,
            %controlliamo se la transazione in questione è già presente nella nostra catena
            TransactionFoundInTheChain = searchTransactionInTheChain(IdTransaction, State#state.chain),
            %controlliamo se la transazione in questione è già presente nella nostra lista delle nuove transazioni che abbiamo già ricevuto
            TransactionFoundInTheList = searchTransactionInTheList(IdTransaction, State#state.listOfTransaction),
            TransactionFound = TransactionFoundInTheChain or TransactionFoundInTheList,
                case TransactionFound of
                    true -> 
                        %se conoscevamo già la transazione, non facciamo nulla
                        nothingToDo,
                        loop(MyFriends, State);
                    false ->   
                        %se non la conoscevamo, la inseriamo nella lista della transazione da provare ad inserire nei prossimi blocchi
                        %e poi la ritrasmettiamo ai nostri amici
                        io:format("~p receive a new transaction with ID ~w~n", [self(), IdTransaction]),
                        NewListOfTransaction = State#state.listOfTransaction ++ [Transaction],
                        NewState = State#state{listOfTransaction = NewListOfTransaction},
                        sendToAllFriend(MyFriends, {push, Transaction}),
                        loop(MyFriends, NewState)
                end;

		{get_head, Sender, Nonce} -> 
            launchGetHeadActor(Sender, Nonce, State#state.chain);

		{get_previous, Sender, Nonce, IDPreviousBlock} -> 
            launchPreviousActor(Sender, Nonce, State#state.chain, IDPreviousBlock);

        {update, Sender, Block} -> 
            spawn_link(?MODULE, getUpdatedChain, [self(), Sender, Block, State#state.chain, MyFriends]);

        {updated_chain, UpdatedChain} ->
            NewState = State#state{chain = UpdatedChain},
            loop(MyFriends, NewState);

        {'EXIT', ActorDeadPID, Reason} ->   
            %abbiamo linkato tutti gli attori che abbiamo spawniamo, se questi terminano normalmente non facciamo nulla,
            %altrimenti li ri-lanciamo con le informazioni memorizzate nel dizionario di processo
            case Reason of
                normal ->   nothingToDo;
                _ ->        ProcessData = get(ActorDeadPID),
                    case ProcessData of
                        launchTimerToAskFriendToTeacher -> launchTimerToAskFriendToTeacher();
                        {watcher, PID} -> launchWatcher(PID);
                        {friendsAsker, FriendPID} -> launchFriendsAsker(FriendPID);
						% Uso A, B, C, D per evitare di usare variabili già bindate
						{send_previous_actor, A, B, C, D} -> launchPreviousActor(A, B, C, D);
						{send_head_actor, A, B, C} -> launchGetHeadActor(A, B, C);
                        _ ->    
                            %se non so gestire la exit mi suicido
                            exit(Reason)
                    end
            end,
            %dove aver fatto ripartire l'attore crashato eliminiamo la entry collegata al vecchio attore ormai morto dal dizionario di processo
            erase(ActorDeadPID),
            loop(MyFriends, State)
    end.


getUpdatedChain(Father, NewBlockSender, NewBlock, CurrentChain, Friends) ->
    Father ! {updated_chain, updateChainAfterReceivedBlock(NewBlockSender, NewBlock, CurrentChain, Friends)}.

%% se non abbiamo il precedente (Id pari all'atomo none), allora non inviamo il messaggio.
%% in caso contrario, inviamo le informazioni del blocco richiesto
sendPreviousActor(Sender, Nonce, CurrentChain, IdBlock) ->
	{IdPrec, Id, ListTransaction, Solution} = getBlockFromChain(CurrentChain, IdBlock),
	case Id of
		none -> nothingToDo;
		_ -> Sender ! {previous, Nonce, {IdPrec, Id, ListTransaction, Solution}}
	end.

launchPreviousActor(Sender, Nonce, CurrentChain, IdBlock) ->
    PreviousActorPID = spawn_link(?MODULE, sendPreviousActor, [Sender, Nonce, CurrentChain, IdBlock]),
	put(PreviousActorPID, {send_previous_actor, Sender, Nonce, CurrentChain, IdBlock}).
	
sendHeadActor(Sender, Nonce, CurrentChain) ->
	Sender ! {head, Nonce, getHead(CurrentChain)}.

launchGetHeadActor(Sender, Nonce, CurrentChain) -> 
    SendHeadPID = spawn_link(?MODULE, sendHeadActor, [Sender, Nonce, CurrentChain]),
	put(SendHeadPID, {send_head_actor, Sender, Nonce, CurrentChain}).



sleep(N) -> receive after N*1000 -> ok end.


launchWatcher(PID) ->   
    Self = self(),
    WatcherPID = spawn_link(fun () -> watch(Self,PID) end),
    %inseriamo le informazioni sull'attore watcher lanciato nel dizionario di processo così che
    %se questo muore per qualche ragione, venga rilanciato
    put(WatcherPID, {watcher, PID}).

watch(Main,Node) ->   
    sleep(10),
    Ref = make_ref(),
    Node ! {ping, self(), Ref},
    receive
        {pong, Ref} -> watch(Main,Node)
    after 2000 -> Main ! {dead, Node}
    end.


launchTimerToAskFriendToTeacher() ->
    Creator = self(),
    TimerPID =  spawn_link(
        fun () -> 
            %io:format("~p launch timer to ask friends to teacher~n", [Creator]),
            sleep(10),
            Creator ! {timer_askFriendsToTeacher}
        end),
    link(TimerPID),
    %inseriamo le informazioni sull'attore timer lanciato nel dizionario di processo così che
    %se questo muore per qualche ragione, venga rilanciato
    put(TimerPID, launchTimerToAskFriendToTeacher).

launchFriendsAsker(FriendPID) ->
    Self = self(),
    FriendsAskerPID = spawn_link(fun () -> friendsAsker(FriendPID, Self) end),
    %inseriamo le informazioni sull'attore friends asker lanciato nel dizionario di processo così che
    %se questo muore per qualche ragione, venga rilanciato
    put(FriendsAskerPID, {friendsAsker, FriendPID}).

friendsAsker(FriendPID, MyPID) ->   
    Nonce = make_ref(),
    FriendPID ! {get_friends, self(), Nonce},
    receive
        {friends, Nonce, Friends} -> MyPID ! {friendsInternalMessage, Friends}
    after 10000 -> MyPID ! {friendsInternalMessage, []}
    end.

askFriendsToTeacher() -> askFriends([]).
askFriends([]) ->
    io:format("~p require friends to teacher node~n", [self()]),
    Nonce = make_ref(),
    %salvo il nonce nel dizionario di processo per dare la possibilità all'attore principale quando riceve un messaggio friends
    %di controllare che sia esattamente quello atteso dal teacher
    put(friendsTeacherNonce, Nonce),
    global:send(teacher_node, {get_friends, self(), Nonce});
askFriends(MyFriends) ->    
    %selezioniamo casualmente uno dei nostri amici e gli inviamo una richiesta per ottenere la sua lista di amici
    SelectedFriend = lists:nth(rand:uniform(length(MyFriends)), MyFriends),
    io:format("~p require friends to ~p~n", [self(), SelectedFriend]),
    launchFriendsAsker(SelectedFriend).


addFriends(MyFriends, []) ->
    io:format("~p updated friend list = ~w ~n", [self(), MyFriends]),
    MyFriends;
addFriends(MyFriends, OtherFriends) ->  
    %aggiungiamo amici finchè non raggiungiamo il numero necessario o finiscono i potenziali nuovi amici
    %la scelta di un nuovo amico, tra i potenziali a disposizione è casuale e su questo viene lanciato un watcher
    %per controllare che rimanga in vita
    case length(MyFriends) < ?NumberOfFriendsRequired of
        true -> 
            NewFriend = lists:nth(rand:uniform(length(OtherFriends)), OtherFriends),
            %io:format("~p add a new friend ~p~n",[self(), NewFriend]),
            launchWatcher(NewFriend),
            addFriends( MyFriends ++ [NewFriend], OtherFriends -- [NewFriend]);
        false -> 
            io:format("~p updated friend list = ~w ~n", [self(), MyFriends]),
            MyFriends
    end.


sendToAllFriend([], _) -> nothingToDo;
sendToAllFriend(FriendList, Message) -> 
    lists:foreach(fun(FriendPID) -> sendMessageWithDisturbance(FriendPID, Message) end, FriendList).


sendMessageWithDisturbance(DestinationPID, Message) ->  
    %ogni volta che inviate un messaggio, ci deve essere una probabilità su 10 di non inviarlo e una su 10 di inviarne due copie
    case rand:uniform(10) of
        0 ->    %non invio il messaggio
                io:format("~p not send message (~w) to ~p for disturbance ~n", [self(), Message, DestinationPID]),
                nothingToDo;
        1 ->    %invio il messaggio 2 volte
                io:format("~p send message (~w) to ~p 2 times for disturbance ~n", [self(), Message, DestinationPID]),
                DestinationPID ! Message, DestinationPID ! Message;
        _ ->    %altrimenti invio il messaggio correttamente una sola volta
                DestinationPID ! Message
    end.


searchTransactionInTheChain(IdTransaction, Chain) ->    
    try
        {chain, IdHeadBlock, _} = Chain,
        searchTransactionInTheChainAux(IdTransaction, IdHeadBlock, Chain)
    catch
        found -> true
    end.
%la searchTransactionInTheChainAux solleva un'eccezione 'found' nel momento in cui trova in un blocco della catena la transazione cercata
searchTransactionInTheChainAux(_, none, _) -> false ;
searchTransactionInTheChainAux(IdTransaction, IdBlock, Chain) ->    
    Block = getBlockFromChain(Chain,IdBlock),
    {_, IDPreviousBlock, CurrentTransactionList, _} = Block,
    %predicato che ritorna true se la transazione in input è quella cercata (stesso ID), false altrimenti
    IsTheSearchedTransaction =  fun(Trans) ->   {CurrentTransID, _} = Trans,
                                                case CurrentTransID of
                                                    IdTransaction -> true;
                                                    _ -> false
                                                end
                                end,
    case lists:search(IsTheSearchedTransaction, CurrentTransactionList) of
        {value, _} -> throw(found);
        false -> searchTransactionInTheChainAux(IdTransaction, IDPreviousBlock, Chain)
    end.
searchTransactionInTheList(IdTransaction, NewTransactionList) ->    
    %predicato che ritorna true se la transazione in input è quella cercata (stesso ID), false altrimenti
    IsTheSearchedTransaction =  fun(Trans) ->   {CurrentTransID, _} = Trans,
                                                case CurrentTransID of
                                                    IdTransaction -> true;
                                                    _ -> false
                                                end
                                end,
    case lists:search(IsTheSearchedTransaction, NewTransactionList) of
        {value, _} -> true;
        false -> false
    end.

getHead([]) -> {none, none, [], 0};
getHead(CurrentChain) ->
	{chain, IdHead, CurrentDictChain} = CurrentChain,
	case dict:find(IdHead, CurrentDictChain) of
		{ok, Head} -> Head;
		error -> nothingToDo %abbiamo già IdHead come testa, l'errore non si verificherà mai
	end.

% può essere usata per ottenere il blocco richiesto da messaggio 'get_previous'
getBlockFromChain(CurrentChain, BlockID) ->
    {chain, _, CurrentDictChain} = CurrentChain,
    case dict:find(BlockID, CurrentDictChain) of
		{ok, Block} -> Block;
		error -> {none, none, [], 0}
	end.

% ritorna la catena più lunga tra le due in input
% se la lunghezza è la stessa, viene ritornata la prima
getLongestChain(Chain1, Chain2) ->
    {chain, _, DictChain1} = Chain1,
    {chain, _, DictChain2} = Chain2,
    case length(dict:fetch_keys(DictChain1)) >= length(dict:fetch_keys(DictChain2)) of
        true -> Chain1;
        false -> Chain2
    end.

% restituisce il dizionario (catena) che va da BlockID a EndingBlockID (non incluso)
% chiamata con 'BlockID' avente l'id della testa della catena
getPartialDictChainFromBlockToBlock(OriginalDictChain, BlockID, EndingBlockID, PartialDictChain) ->
    case BlockID =:= EndingBlockID of
        true -> PartialDictChain;
        false ->
            Block = getBlockFromChain(OriginalDictChain, BlockID),
            PartialDictChain = dict:append(BlockID, Block, PartialDictChain),
            {_, PreviousBlockID, _, _} = Block,
            getPartialDictChainFromBlockToBlock(OriginalDictChain, PreviousBlockID, EndingBlockID, PartialDictChain)
    end.

% restituisce la nuova catena risultante dopo l'esecuzione dell'update (e la ricezione del blocco corrispondente),
% in particolare la catena più lunga tra quella corrente e quella derivata dal blocco ricevuto; 
% 'NewBlockID' e 'NewDictChain' mantengono durante le chiamate ricorsive l'ID del blocco originale ricevuto in
% seguito all'update e il dizionario (che viene aggiornato durante le chiamate) con il quale si costruisce la 
% catena derivata da quest'ultimo
getResultingChainFromUpdate(SenderPID, CurrentChain, Block, NewBlockID, NewDictChain) ->
    {chain, CurrentHeadBlockID, CurrentDictChain} = CurrentChain,
    {BlockID, PreviousBlockID, _, _} = Block,
    NewDictChain = dict:append(BlockID, Block, NewDictChain),
    case PreviousBlockID =:= none of
        true ->
            % nel caso in cui non vi siano nodi comuni tra la catena derivata dal blocco ricevuto e quella corrente
            % viene ritornata la più lunga tra queste
            getLongestChain(CurrentChain, {chain, NewBlockID, NewDictChain});
        false -> case dict:find(PreviousBlockID, CurrentDictChain) of
            {ok, Value} ->
                % nel caso in cui ci sia un nodo comune tra la catena derivata dal blocco ricevuto e quella corrente
                % queste dovrebbero avere una sotto-catena comune, viene quindi confrontata la lunghezza delle parti
                % rimanenti delle catene senza questa e ritornata la catena nel complesso più lunga
                PartialCurrentDictDelta = getPartialDictChainFromBlockToBlock(CurrentDictChain, CurrentHeadBlockID, PreviousBlockID, dict:new()),
                PartialNewDictDelta = NewDictChain,
                {chain, LongestDictHead, LongestDictDelta} = getLongestChain(
                    {chain, CurrentHeadBlockID, PartialCurrentDictDelta},
                    {chain, NewBlockID, PartialNewDictDelta}
                ),
                ChainsCommonDict = getPartialDictChainFromBlockToBlock(CurrentDictChain, PreviousBlockID, none, dict:new()),
                {
                    chain,
                    LongestDictHead,
                    dict:merge(fun(K, V1, V2) -> V1 end, LongestDictDelta, ChainsCommonDict)
                };
            error ->
                % nel caso in cui non si sia arrivati alla conclusione o ad un blocco comune con quella corrente per 
                % la catena derivata dal blocco ricevuto, è necessario continuare a richiedere i blocchi precedenti
                % al fine di costruire quest'ultima
                Nonce = make_ref(),
                SenderPID ! {get_previous, SenderPID, Nonce, PreviousBlockID},
                receive
                    {previous, Nonce, PreviousBlock} ->
                        {ReceivedPreviousBlockID, _, _, _} = PreviousBlock,
                        % se ReceivedPreviousBlockID == none, non catturato e gestito in after
                        case ReceivedPreviousBlockID =/= none of
                                true -> getResultingChainFromUpdate(
                                        SenderPID,
                                        CurrentChain,
                                        PreviousBlock,
                                        NewBlockID, 
                                        NewDictChain
                                    )
                        end
                after 2000 ->
                    % se previous non arriva entro timeout o nodo a cui l'ho chiesto non lo ha viene ritornata
                    % viene ritornata la catena corrente
                    CurrentChain
                end
        end
    end.

% metodo da richiamare successivamente ad update
updateChainAfterReceivedBlock(NewBlockSender, NewBlock, CurrentChain, Friends) ->
    {NewBlockID, PreviousBlockID, TransactionList, Solution} = NewBlock,
    {chain, Head, CurrentDictChain} = CurrentChain,
    case
        proof_of_work:check({NewBlockID, TransactionList}, Solution) and (dict:find(NewBlockID, CurrentDictChain) =:= error)
    of
        false -> CurrentChain;
        true ->
            [F ! {update, NewBlock} || F <- Friends],
            getResultingChainFromUpdate(NewBlockSender, CurrentChain, NewBlock, NewBlock, dict:new())
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
test_nodes() ->
    T = spawn(teacher_node, main, []),
	sleep(1),
	N1 = launchNode(),
	N2 = launchNode(),
	N3 = launchNode(),
	N4 = launchNode(),
    N5 = launchNode(),
    N6 = launchNode(),
	N7 = launchNode(),
	N8 = launchNode(),
	N9 = launchNode(),
    N10 = launchNode(),
    sleep(10),
    N1 ! {push, {1, transazione1}},
    N2 ! {push, {2, transazione2}},
    exit(N2, manually_kill),
    sleep(3),
    N3 ! {push, {3, transazione3}},
    N4 ! {push, {4, transazione4}},
    N5 ! {push, {5, transazione5}},
    N4 ! {push, {4, transazione4}},
    N6 ! {push, {6, transazione6}},
    exit(N10, kill),
    sleep(3),
    N7 ! {push, {7, transazione7}},
    N8 ! {push, {8, transazione8}},
    N9 ! {push, {9, transazione9}},
    N10 ! {push, {10, transazione10}},
    N1 ! {push, {11, transazione11}},
    N3 ! {push, {12, transazione12}},
    N5 ! {push, {13, transazione13}},
    N7 ! {push, {14, transazione14}},
    N9 ! {push, {15, transazione15}},
    N1 ! {push, {16, transazione16}},
	%sleep(15),
	%Ref = make_ref(),
	%M1 ! {get_friends, self(), Ref},
	%receive
	%	{friends, Ref, Lista_amici} -> io:fwrite("Amici di M1 ~w~n",[Lista_amici])
	%end.
    test_launched.
