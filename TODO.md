# TODO

- [ ] Check reconstruction chain and whole update algorithm
    <br>-Abort reconstruction if get_previous response not received in certain time
    <br>-Careful about 'Nonce' uses
- [x] Handle update messages, like 'get_previous' and 'get_head'
- [ ] Block mining
    <br>-Handle transactions pool and inserting of them in blocks
    <br>-Interrupt mining if original chain is not anymore the current one and save in the pool the inserted transactions from the block is going to be discharged
    <br>-When a new chain is obtained, pick from the previous chain the transaction not considered in the new one and save them in pool