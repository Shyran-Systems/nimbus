import
  db/[db_chain, state_db, capturedb], eth_common, utils, json,
  constants, vm_state, vm_types, transaction, p2p/executor,
  eth_trie/db, nimcrypto, strutils, ranges, ./utils/addresses,
  sets

proc getParentHeader(self: BaseChainDB, header: BlockHeader): BlockHeader =
  self.getBlockHeader(header.parentHash)

proc prefixHex(x: openArray[byte]): string =
  "0x" & toHex(x, true)

proc getSender(tx: Transaction): EthAddress =
  if not tx.getSender(result):
    raise newException(ValueError, "Could not get sender")

proc getRecipient(tx: Transaction): EthAddress =
  if tx.isContractCreation:
    let sender = tx.getSender()
    result = generateAddress(sender, tx.accountNonce)
  else:
    result = tx.to

proc captureAccount(n: JsonNode, db: AccountStateDB, address: EthAddress, name: string) =
  var jaccount = newJObject()
  jaccount["name"] = %name
  jaccount["address"] = %($address)
  let account = db.getAccount(address)
  jaccount["nonce"] = %(account.nonce.toHex)
  jaccount["balance"] = %(account.balance.toHex)

  let code = db.getCode(address)
  jaccount["codeHash"] = %($account.codeHash)
  jaccount["code"] = %(toHex(code.toOpenArray, true))
  jaccount["storageRoot"] = %($account.storageRoot)

  var storage = newJObject()
  for key, value in db.storage(address):
    storage[key.dumpHex] = %(value.dumpHex)
  jaccount["storage"] = storage

  n.add jaccount

const
  senderName = "sender"
  recipientName = "recipient"
  minerName = "miner"
  uncleName = "uncle"

proc traceTransaction*(db: BaseChainDB, header: BlockHeader,
                       body: BlockBody, txIndex: int, tracerFlags: set[TracerFlags] = {}): JsonNode =
  let
    parent = db.getParentHeader(header)
    # we add a memory layer between backend/lower layer db
    # and capture state db snapshot during transaction execution
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(db.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureChainDB = newBaseChainDB(captureTrieDB, false) # prune or not prune?
    vmState = newBaseVMState(parent, captureChainDB, tracerFlags)

  var stateDb = newAccountStateDB(captureTrieDB, parent.stateRoot, db.pruneTrie)
  if header.txRoot == BLANK_ROOT_HASH: return
  assert(body.transactions.calcTxRoot == header.txRoot)
  assert(body.transactions.len != 0)

  var
    gasUsed: GasInt
    before = newJObject()
    after = newJObject()
    stateDiff = %{"before": before, "after": after}

  for idx, tx in body.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient

    if idx == txIndex:
      vmState.enableTracing()
      before.captureAccount(stateDb, sender, senderName)
      before.captureAccount(stateDb, recipient, recipientName)
      before.captureAccount(stateDb, header.coinbase, minerName)

    let txFee = processTransaction(stateDb, tx, sender, vmState)

    if idx == txIndex:
      gasUsed = (txFee div tx.gasPrice.u256).truncate(GasInt)
      vmState.disableTracing()
      after.captureAccount(stateDb, sender, senderName)
      after.captureAccount(stateDb, recipient, recipientName)
      after.captureAccount(stateDb, header.coinbase, minerName)
      break

  result = vmState.getTracingResult()
  result["gas"] = %gasUsed
  result["statediff"] = stateDiff

  # now we dump captured state db
  if TracerFlags.DisableState notin tracerFlags:
    var n = newJObject()
    for k, v in pairsInMemoryDB(memoryDB):
      n[k.prefixHex] = %v.prefixHex
    result["state"] = n

proc dumpBlockState*(db: BaseChainDB, header: BlockHeader, body: BlockBody): JsonNode =
  # TODO: scan tracing result and find internal transaction address
  # then do account dump as usual, before and after
  # cons: unreliable and prone to error.
  # pros: no need to map account secure key back to address.

  # alternative: capture state trie using captureDB, and then dump every
  # account for this block.
  # cons: we need to map account secure key back to account address.
  # pros: no account will be missed, we will get all account touched by this block
  # we can turn this address capture/mapping only during dumping block state and
  # disable it during normal operation.
  # also the order of capture needs to be reversed, collecting addresses *after*
  # processing block then using that addresses to collect accounts from parent block

  let
    parent = db.getParentHeader(header)
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(db.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureChainDB = newBaseChainDB(captureTrieDB, false)
    # we only need stack dump if we want to scan for internal transaction address
    vmState = newBaseVMState(parent, captureChainDB, {EnableTracing, DisableMemory, DisableStorage})

  var
    before = newJObject()
    after = newJObject()
    stateBefore = newAccountStateDB(captureTrieDB, parent.stateRoot, db.pruneTrie)
    stateAfter = newAccountStateDB(captureTrieDB, header.stateRoot, db.pruneTrie)
    accountSet = initSet[EthAddress]()

  for tx in body.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient
    if sender notin accountSet:
      before.captureAccount(stateBefore, sender, senderName)
      accountSet.incl sender
    if recipient notin accountSet:
      before.captureAccount(stateBefore, recipient, recipientName)
      accountSet.incl recipient

  before.captureAccount(stateBefore, header.coinbase, minerName)

  for idx, uncle in body.uncles:
    before.captureAccount(stateBefore, uncle.coinbase, uncleName & $idx)

  discard captureChainDB.processBlock(parent, header, body, vmState)

  for tx in body.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient
    if sender notin accountSet:
      after.captureAccount(stateAfter, sender, senderName)
      accountSet.incl sender
    if recipient notin accountSet:
      after.captureAccount(stateAfter, recipient, recipientName)
      accountSet.incl recipient

  after.captureAccount(stateAfter, header.coinbase, minerName)

  for idx, uncle in body.uncles:
    after.captureAccount(stateAfter, uncle.coinbase, uncleName & $idx)

  result = %{"before": before, "after": after}