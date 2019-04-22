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
% - transactionPool: è la lista delle nuove transazioni che riceviamo e che possiamo inserire in un nuovo blocco dopo averlo minato
-record(state, {numberOfNotEnoughFriendRequest, chain, transactionPool, currentChainLength}).

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
        transactionPool = [],
        currentChainLength = 0
    },
    process_flag(trap_exit, true),
    askFriendsToTeacher(),
    loop([], State).

loop(MyFriends, State) ->
	launchTimerToMine(),
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
            %estriamo dallo stato il numero di richieste di amici che non sono state sufficienti
            PreviousNumberOfNotEnoughFriendRequest = State#state.numberOfNotEnoughFriendRequest,
            %selezioniamo solo i nuovi possibili amici rimuovendo noi stessi e nodi che già conosciamo
            NewFriends = OtherFriends -- (MyFriends ++ [self()]),
            %io:format("~p receive friend list, possible new friends = ~w~n", [self(), NewFriends]),
            case NewFriends of
                [] ->
                    %non riusciamo ad aggiungere amici
                    ActualNumberOfNotEnoughFriendRequest = PreviousNumberOfNotEnoughFriendRequest + 1,
                    NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest},
                    if
                        ActualNumberOfNotEnoughFriendRequest < length(MyFriends) ->
                            %non riusciamo ad aggiungere amici ma abbiamo ancora amici a cui chiedere
                            askFriends(MyFriends);
                        ActualNumberOfNotEnoughFriendRequest == length(MyFriends) ->
                            %non riusciamo ad aggiungere amici e abbiamo già chiesto a tutti i nostri amici quindi chiediamo al nodo professore
                            askFriendsToTeacher();
                        ActualNumberOfNotEnoughFriendRequest > length(MyFriends) ->
                            %non riusciamo ad aggiungere amici e abbiamo già chiesto anche al nodo professore quindi aspettiamo un pò e poi richiediamo a lui
                            launchTimerToAskFriendToTeacher()
                    end;
                _ ->
                    %abbiamo dei nuovi potenziali amici da aggiungere
                    NewState = State,
                    launchFriendsAdder(MyFriends, NewFriends)
            end,
            loop(MyFriends, NewState);

        {friendsAdded, MyNewListOfFriends} ->
            io:format("~p updated friend list = ~w ~n", [self(), MyNewListOfFriends]),
            %estriamo dallo stato il numero di richieste di amici che non sono state sufficienti
            PreviousNumberOfNotEnoughFriendRequest = State#state.numberOfNotEnoughFriendRequest,
            %se anche con i nuovi amici non riusciamo a raggiungere il numero necessario chiediamo nuovi amici,
            %altrimenti azzeriamo il numero di chiamate che non sono state sufficienti perchè abbiamo raggiunto il numero di amici richiesto
            case length(MyNewListOfFriends) < ?NumberOfFriendsRequired of
                true ->
                    ActualNumberOfNotEnoughFriendRequest = PreviousNumberOfNotEnoughFriendRequest + 1,
                    NewState = State#state{numberOfNotEnoughFriendRequest = ActualNumberOfNotEnoughFriendRequest},
                    if
                        ActualNumberOfNotEnoughFriendRequest < length(MyNewListOfFriends) ->
                            askFriends(MyNewListOfFriends);
                        ActualNumberOfNotEnoughFriendRequest == length(MyNewListOfFriends) ->
                            askFriendsToTeacher();
                        ActualNumberOfNotEnoughFriendRequest > length(MyNewListOfFriends) ->
                            launchTimerToAskFriendToTeacher()
                    end;
                false ->
                    NewState = State#state{numberOfNotEnoughFriendRequest = 0 }
            end,
            loop(MyNewListOfFriends, NewState);

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
            launchTransactionIsInTheChain(Transaction, State#state.chain),
            loop(MyFriends, State);

        {transactionNotInTheChain, Transaction} ->
            %Transaction = {IDtransazione, Payload}
            {IdTransaction, _} = Transaction,
            %controlliamo se la transazione in questione è già presente nella nostra lista delle nuove transazioni che abbiamo già ricevuto
            TransactionFoundInTheList = searchTransactionInTheList(IdTransaction, State#state.transactionPool),
            case TransactionFoundInTheList of
                true ->
                    %se la transazione è già nella catena, non facciamo nulla
                    nothingToDo,
                    loop(MyFriends, State);
                false ->
                    %se non conoscevamo la transazione, la inseriamo nella lista della transazione da provare ad inserire nei prossimi blocchi
                    %e poi la ritrasmettiamo ai nostri amici
                    io:format("~p receive a new transaction with ID ~w~n", [self(), IdTransaction]),
                    NewTransactionPool = State#state.transactionPool ++ [Transaction],
                    NewState = State#state{transactionPool = NewTransactionPool},
                    launchSenderToAllFriend(MyFriends, {push, Transaction}),
                    loop(MyFriends, NewState)
            end;

		{timer_toMine} -> 
			TransactionsToMine = lists:sublist(State#state.transactionPool, 10),
			{chain, IDHead, _} = State#state.chain,
			launchMinerActor(IDHead, self(), TransactionsToMine);

		{mine_successful, NewBlock} ->
			nothingToDo; %TODO: definire le operazioni da fare qui

		{get_head, Sender, Nonce} ->
            launchGetHeadActor(Sender, Nonce, State#state.chain);

		{get_previous, Sender, Nonce, IDPreviousBlock} ->
            launchPreviousActor(Sender, Nonce, State#state.chain, IDPreviousBlock);

        {update, Sender, Block} ->
            launchUpdateActor(self(), Sender, MyFriends, Block, State#state.chain, State#state.currentChainLength);

        {update_response, UpdateResponse} ->
            CurrentChainLength = State#state.currentChainLength,
            CurrentTransactionPool = State#state.transactionPool,
            case UpdateResponse of
                {new_chain, NewChain, NewChainLength, TransactionToRemove} ->
                    case NewChainLength > CurrentChainLength of
                        true ->
                            NewState = State#state{
                                chain = NewChain,
                                transactionPool = CurrentTransactionPool -- TransactionToRemove,
                                currentChainLength = NewChainLength
                            },
                            loop(MyFriends, NewState)
                    end
            end;

        {'EXIT', ActorDeadPID, Reason} ->
            %abbiamo linkato tutti gli attori che abbiamo spawniamo, se questi terminano normalmente non facciamo nulla,
            %altrimenti li ri-lanciamo con le informazioni memorizzate nel dizionario di processo
            case Reason of
                normal -> nothingToDo;
				killed -> nothingToDo; %abbiamo appositamente killato l'attore
                _ ->
                    ProcessData = get(ActorDeadPID),
                    case ProcessData of
						launchTimerToMine ->
							launchTimerToMine();
                        launchTimerToAskFriendToTeacher ->
                            launchTimerToAskFriendToTeacher();
                        {watcher, PID} ->
                            launchWatcher(PID, self());
                        {friendsAsker} ->
                            askFriends(MyFriends);
                        {friendsAdder, NewFriends} ->
                            launchFriendsAdder(MyFriends, NewFriends--MyFriends);
                        {messageSender, FriendList, Message} ->
                            launchSenderToAllFriend(FriendList, Message);
                        {transcationIsInTheChainController, Transaction} ->
                            launchTransactionIsInTheChain(Transaction, State#state.chain);
						% Uso A, B, C, D per evitare di usare variabili già bindate
						{send_previous_actor, A, B, C, D} ->
                            launchPreviousActor(A, B, C, D);
						{send_head_actor, E, F, G} ->
                            launchGetHeadActor(E, F, G);
						{miner_actor, IdPreviousBlock, PIDMiner, TransactionsMiner} ->
                            launchMinerActor(IdPreviousBlock, PIDMiner, TransactionsMiner);
                        {launch_update, Father, Sender, NewBlock} ->
                            launchUpdateActor(Father, Sender, MyFriends, NewBlock, State#state.chain, State#state.currentChainLength);
                        _ ->
                            %se non so gestire la exit mi suicido
                            exit(Reason)
                    end
            end,
            %dove aver fatto ripartire l'attore crashato eliminiamo la entry collegata al vecchio attore ormai morto dal dizionario di processo
            erase(ActorDeadPID),
            loop(MyFriends, State)
    end.

% lancia un sotto-attore per gestire un'update ricevuta
launchUpdateActor(FatherPID, Sender, Friends, NewBlock, CurrentChain, CurrentChainLength) ->
    UpdateActorPID = spawn_link(?MODULE, handleUpdate, [FatherPID, Sender, Friends, NewBlock, CurrentChain, CurrentChainLength]),
    put(UpdateActorPID, {launch_update, FatherPID, Sender, NewBlock}).

% gestione in seguito ad arrivo update delegata a sotto-attore
handleUpdate(FatherPID, NewBlockSenderPID, Friends, NewBlock, CurrentChain, CurrentChainLength) ->
    FatherPID ! updateHandling(NewBlockSenderPID, Friends, NewBlock, CurrentChain, CurrentChainLength).

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


watch(Node, Main) ->
    sleep(10),
    Ref = make_ref(),
    Node ! {ping, self(), Ref},
    receive
        {pong, Ref} -> watch(Node, Main)
    after 2000 -> Main ! {dead, Node}
    end.
launchWatcher(PID, LoopPID) ->
    WatcherPID = spawn_link(fun () -> watch(PID, LoopPID) end),
    %inseriamo le informazioni sull'attore watcher lanciato nel dizionario di processo così che
    %se questo muore per qualche ragione, venga rilanciato
    put(WatcherPID, {watcher, PID}).


launchTimerToAskFriendToTeacher() ->
    Creator = self(),
    TimerPID =  spawn_link(
        fun () ->
            %io:format("~p launch timer to ask friends to teacher~n", [Creator]),
            sleep(10),
            Creator ! {timer_askFriendsToTeacher}
        end),
    %inseriamo le informazioni sull'attore timer lanciato nel dizionario di processo così che
    %se questo muore per qualche ragione, venga rilanciato
    put(TimerPID, launchTimerToAskFriendToTeacher).

launchTimerToMine() ->
	Creator = self(),
	TimerPID = spawn_link(
		fun() ->
			sleep(10),
			Creator ! {timer_toMine}
		end),
	put(TimerPID, launchTimerToMine).


friendsAsker(MyFriends, LoopPID) ->
    %selezioniamo casualmente uno dei nostri amici e gli inviamo una richiesta per ottenere la sua lista di amici
    SelectedFriend = lists:nth(rand:uniform(length(MyFriends)), MyFriends),
    io:format("~p require friends to ~p~n", [LoopPID, SelectedFriend]),
    Nonce = make_ref(),
    SelectedFriend ! {get_friends, self(), Nonce},
    receive
        {friends, Nonce, Friends} -> LoopPID ! {friendsInternalMessage, Friends}
    after 10000 -> LoopPID ! {friendsInternalMessage, []}
    end.
askFriendsToTeacher() ->
    askFriends([]).
askFriends([]) ->
    io:format("~p require friends to teacher node~n", [self()]),
    Nonce = make_ref(),
    %salvo il nonce nel dizionario di processo per dare la possibilità all'attore principale quando riceve un messaggio friends
    %di controllare che sia esattamente quello atteso dal teacher
    put(friendsTeacherNonce, Nonce),
    global:send(teacher_node, {get_friends, self(), Nonce});
askFriends(MyFriends) ->
    Self = self(),
    FriendsAskerPID = spawn_link(fun () -> friendsAsker(MyFriends, Self) end),
    %inseriamo le informazioni sull'attore friends asker lanciato nel dizionario di processo così che
    %se questo muore per qualche ragione, venga rilanciato
    put(FriendsAskerPID, {friendsAsker}).


addFriends(MyFriends, [], LoopPID) ->
    LoopPID ! {friendsAdded, MyFriends};
addFriends(MyFriends, OtherFriends, LoopPID) ->
    %aggiungiamo amici finchè non raggiungiamo il numero necessario o finiscono i potenziali nuovi amici
    %la scelta di un nuovo amico, tra i potenziali a disposizione è casuale e su questo viene lanciato un watcher
    %per controllare che rimanga in vita
    case length(MyFriends) < ?NumberOfFriendsRequired of
        true ->
            NewFriend = lists:nth(rand:uniform(length(OtherFriends)), OtherFriends),
            %io:format("~p add a new friend ~p~n",[self(), NewFriend]),
            launchWatcher(NewFriend, LoopPID),
            addFriends( MyFriends ++ [NewFriend], OtherFriends -- [NewFriend], LoopPID);
        false ->
            LoopPID ! {friendsAdded, MyFriends}
    end.
launchFriendsAdder(MyFriends, OtherFriends) ->
    Self = self(),
    FriendsAdderPID = spawn_link(fun () -> addFriends(MyFriends, OtherFriends, Self) end),
    %inseriamo le informazioni sull'attore friends adder lanciato nel dizionario di processo così che
    %se questo muore per qualche ragione, venga rilanciato
    put(FriendsAdderPID, {friendsAdder, OtherFriends}).


sendMessageWithDisturbance(DestinationPID, Message) ->
    %ogni volta che inviate un messaggio, ci deve essere una probabilità su 10 di non inviarlo e una su 10 di inviarne due copie
    case rand:uniform(10) of
        0 ->    %non invio il messaggio
                io:format("Not send message (~w) to ~p for disturbance ~n", [Message, DestinationPID]),
                nothingToDo;
        1 ->    %invio il messaggio 2 volte
                io:format("Send message (~w) to ~p 2 times for disturbance ~n", [Message, DestinationPID]),
                DestinationPID ! Message, DestinationPID ! Message;
        _ ->    %altrimenti invio il messaggio correttamente una sola volta
                DestinationPID ! Message
    end.
sendToAllFriend([], _) -> nothingToDo;
sendToAllFriend(FriendList, Message) ->
    lists:foreach(fun(FriendPID) -> sendMessageWithDisturbance(FriendPID, Message) end, FriendList).
launchSenderToAllFriend(FriendList, Message) ->
    MessageSenderPID = spawn_link(fun () -> sendToAllFriend(FriendList, Message) end),
    %inseriamo le informazioni sull'attore message sender lanciato nel dizionario di processo così che
    %se questo muore per qualche ragione, venga rilanciato
    put(MessageSenderPID, {messageSender, FriendList, Message}).


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
    IsTheSearchedTransaction =
        fun(Trans) ->   {CurrentTransID, _} = Trans,
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
    IsTheSearchedTransaction =
        fun(Trans) ->   {CurrentTransID, _} = Trans,
            case CurrentTransID of
                IdTransaction -> true;
                _ -> false
            end
        end,
    case lists:search(IsTheSearchedTransaction, NewTransactionList) of
        {value, _} -> true;
        false -> false
    end.


transactionIsInTheChain(Transaction, Chain, LoopPID) ->
    %Transaction = {IDtransazione, Payload}
    {IdTransaction, _} = Transaction,
    %controlliamo se la transazione in questione è già presente nella nostra catena
    TransactionFoundInTheChain = searchTransactionInTheChain(IdTransaction, Chain),
    case TransactionFoundInTheChain of
        true ->
            %se la transazione è già nella catena, non facciamo nulla
            nothingToDo;
        false ->
            %se non la conoscevamo
            LoopPID ! {transactionNotInTheChain, Transaction}
    end.
launchTransactionIsInTheChain(Transaction, Chain) ->
    Self = self(),
    TransactionControllerPID = spawn_link(fun () -> transactionIsInTheChain(Transaction, Chain, Self) end),
    %inseriamo le informazioni sull'attore transaction controller lanciato nel dizionario di processo così che
    %se questo muore per qualche ragione, venga rilanciato
    put(TransactionControllerPID, {transcationIsInTheChainController, Transaction}).


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

% scandisce la catena (dizionario) per ottenere le transazioni
scanChainForTransactionList(DictChain, BlockID, List) ->
    case dict:find(BlockID, DictChain) of
        error -> List;
        {ok, Block} ->
            {_, PreviousBlockID, TransactionList, _} = Block,
            scanChainForTransactionList(DictChain, PreviousBlockID, List ++ TransactionList)
    end.

% ritorna la lista complessiva di transazioni per la catena considerata
getChainTransactions(Chain) ->
    {chain, HeadID, DictChain} = Chain,
    scanChainForTransactionList(DictChain, HeadID, []).

% ritorna la lunghezza della catena (dizionario) considerato
getDictChainLength(DictChain) ->
    length(dict:fetch_keys(DictChain)).

% restituisce la catena risultante dal blocco ricevuto in fase di update, lunghezza per questa e il pool di transazioni
% da rimuovere nel caso in cui essa diventi la nuova catena;
% 'NewBlockID' e 'NewDictChain' mantengono durante le chiamate ricorsive l'ID del blocco originale ricevuto in
% seguito all'update e il dizionario (che viene aggiornato durante le chiamate) con il quale si costruisce la
% catena derivata da quest'ultimo
getResultingChainFromUpdate(SenderPID, Friends, CurrentChain, CurrentChainLength, Block, NewBlockID, NewDictChain) ->
    {chain, CurrentHeadBlockID, CurrentDictChain} = CurrentChain,
    {BlockID, PreviousBlockID, _, _} = Block,
    NewDictChain = dict:append(BlockID, Block, NewDictChain),
    case PreviousBlockID =:= none of
        true ->
            % caso in cui non vi siano nodi comuni tra la catena derivata dal blocco ricevuto e quella corrente
            NewChain = {chain, NewBlockID, NewDictChain},
            {update_response, {new_chain, NewChain, getDictChainLength(NewDictChain), getChainTransactions(NewChain)}};
        false -> case dict:find(PreviousBlockID, CurrentDictChain) of
            {ok, Value} ->
                % caso in cui ci sia un nodo comune tra la catena derivata dal blocco ricevuto e quella corrente;
                % queste dovrebbero avere una sotto-catena comune che può essere sfruttata per il calcolo
                % della lunghezza in maniera maggiormente efficiente
                PartialNewDictDelta = NewDictChain,
                ChainsCommonSubChain = getPartialDictChainFromBlockToBlock(CurrentDictChain, PreviousBlockID, none, dict:new()),
                NewChain = {
                    chain,
                    NewBlockID,
                    dict:merge(
                        fun(K, V1, V2) -> V1 end,
                        PartialNewDictDelta,
                        ChainsCommonSubChain
                    )
                },
                {update_response, {
                    new_chain,
                    NewChain,
                    % per calcolare la lunghezza della nuova catena aggiungo la lunghezza della catena fino al nodo comune
                    % con quella corrente alla lunghezza totale della catena corrente alla quale viene sottratto il numero
                    % di blocchi che non sono considerati nella nuova
                    getDictChainLength(PartialNewDictDelta)
                        +CurrentChainLength
                        -getDictChainLength(getPartialDictChainFromBlockToBlock(CurrentDictChain, CurrentHeadBlockID, PreviousBlockID, dict:new())),
                    getChainTransactions(NewChain)
                }};
            error ->
                % nel caso in cui non si sia arrivati alla conclusione o ad un blocco comune con quella corrente per
                % la catena derivata dal blocco ricevuto, è necessario continuare a richiedere i blocchi precedenti
                % al fine di costruire quest'ultima
                Nonce = make_ref(),
                [A ! {get_previous, self(), Nonce, PreviousBlockID} || A <- [SenderPID] ++ Friends],
                receive
                    {previous, Nonce, PreviousBlock} ->
                        {ReceivedPreviousBlockID, _, _, _} = PreviousBlock,
                        % se ReceivedPreviousBlockID == none, non catturato e gestito in after
                        case ReceivedPreviousBlockID =/= none of
                                true -> getResultingChainFromUpdate(
                                        SenderPID,
                                        Friends,
                                        CurrentChain,
                                        CurrentChainLength,
                                        PreviousBlock,
                                        NewBlockID,
                                        NewDictChain
                                    )
                        end
                after 2000 ->
                    % se previous non arriva entro timeout o nodo a cui l'ho chiesto non lo ha, viene ritornato
                    % un atomo che indica che la nuova catena non deve essere considerata
                    {update_response, discharged_chain}
                end
        end
    end.

% metodo da richiamare successivamente ad update
updateHandling(NewBlockSender, Friends, NewBlock, CurrentChain, CurrentChainLength) ->
    {NewBlockID, PreviousBlockID, TransactionList, Solution} = NewBlock,
    {chain, Head, CurrentDictChain} = CurrentChain,
    case
        proof_of_work:check({NewBlockID, TransactionList}, Solution) and (dict:find(NewBlockID, CurrentDictChain) =:= error)
    of
        false -> CurrentChain;
        true ->
            [F ! {update, NewBlock} || F <- Friends],
            getResultingChainFromUpdate(NewBlockSender, Friends, CurrentChain, CurrentChainLength, NewBlock, NewBlock, dict:new())
    end.

mine(ID_previousBlock, TransactionList) ->
    BlockID = make_ref(),
    Solution = proof_of_work:solve(ID_previousBlock, TransactionList),
    {ID_previousBlock, BlockID, TransactionList, Solution}.

%% registra se stesso con l'atomo miner_process, in modo da essere killato in caso di updateBlock sulle stesse transazioni su cui stiamo minando.
%% Nel caso in cui il mining sia avvenuto con successo, manda a PID un messaggio contenente il nuovo stato (quindi la nuova catena).
miner(IdPreviousBlock, PID, TransactionsToMine) ->
    register(miner_process, self()),
    %TransactionsToMine = lists:sublist(State#state.transactionPool, 10),
    NewBlock = mine(IdPreviousBlock, TransactionsToMine),
    PID ! {mine_successful, NewBlock}.

launchMinerActor(IdPreviousBlock, PID, TransactionsToMine) ->
    MinerActorPID = spawn_link(?MODULE, miner, [IdPreviousBlock, PID, TransactionsToMine]),
	put(MinerActorPID, {miner_actor, IdPreviousBlock, PID, TransactionsToMine}).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
test_nodes() ->
    T = spawn(teacher_node, main, []),
	sleep(1),
    NodeList = launchNNode(10, []),
    sleep(2),
    spawn(fun () -> sendTransactions(NodeList, 0) end),
    sleep(5),


    %TODO: manca codice per leggere la catena da un nodo random e vedere come evolve


    %exit(lists:nth(rand:uniform(length(NodeList)), NodeList), manually_kill),
    %exit(lists:nth(rand:uniform(length(NodeList)), NodeList), kill),
    sleep(3),
    test_launched.

launchNNode(0, NodeList) ->
    NodeList;
launchNNode(N, NodeList) ->
    launchNNode(N-1, NodeList ++ [launchNode()]).

sendTransactions(NodeList, 5) ->
    nothingToDo;
sendTransactions(NodeList, I) ->
    lists:nth(rand:uniform(length(NodeList)), NodeList) ! {push, {make_ref(), list_to_atom("Transazione" ++ integer_to_list(I))}},
    sendTransactions(NodeList, I+1).
