module Model exposing (..)

import Sha256 exposing (sha256)
import String exposing (slice)
import List exposing (head, filter, drop, indexedMap, map, length, sortWith, foldr, tail)
import Tuple exposing (first, second)
import Array exposing (fromList, get)
import Settings exposing (confirmationsRequired)
import Sha256 exposing (sha256)

type Msg
  = Next
  | PostTx
  | InputTxSender String
  | InputTxReceiver String
  | InputTxAmount String
  | SelectEraseBlock String Int
  | RandomEvent Int
  | GetNames Int
  | ProvideNames (List String)

type alias Flags = {
  initialNames : List String
}

type alias Model = {
  miners : List Miner,
  discoveredBlocks : List BlockLink,
  transactionPool : List Transaction,
  addressBook : List Address,
  randomValue : Int,
  randomNames : List String,
  txForm: TxForm
}

type BlockLink = BlockLink Block | NoBlock

type alias Miner = { blockToErase : BlockLink }

type alias Block = {
  transaction : Transaction,
  previousBlock : BlockLink,
  nextBlocks : List Int,
  nonce : String,
  hashCache : String
}

type alias Transaction = {
  sender : Address,
  receiver : Address,
  amount : Int
}

type alias Address = {
  name: String,
  hash : String,
  balance : Int
}

type alias TxForm = {
  sender : String,
  receiver : String,
  amount : Int
}

txHash : Transaction -> String
txHash tx =
  toString tx.amount ++ tx.sender.hash ++ tx.receiver.hash
  |> sha256

blockHash : Block -> String
blockHash block = block.hashCache

blockLinkHash : BlockLink -> String
blockLinkHash blocklink =
  case blocklink of
    NoBlock ->
      sha256 "0"
    BlockLink block ->
      blockHash block

newMiner : BlockLink -> Miner
newMiner blocklink = { blockToErase = blocklink }

newAddress : String -> Int -> Int -> Address
newAddress name seed balance = { name = name, hash = sha256 (toString seed), balance = balance }

newTx : (String, Int) -> (String, Int) -> Int -> Transaction
newTx (senderName, senderSeed) (receiverName, receiverSeed) amount =
  {
    sender = newAddress senderName senderSeed 10,
    receiver = newAddress receiverName receiverSeed 10,
    amount = amount
  }

nonceFor : Int -> Int -> String
nonceFor minerIndex seed = minerIndex + seed
  |> toString
  |> sha256
  |> slice 0 5

testBlockHash : Transaction -> BlockLink -> Int -> Int -> String
testBlockHash tx previousBlock minerIndex seed =
 txHash tx ++ blockLinkHash previousBlock ++ nonceFor minerIndex seed
 |> sha256

findAddress : String -> List Address -> Address
findAddress hash addresses =
  let
    matches = addresses
      |> filter (\a -> a.hash == hash)
  in
    case head matches of
      Nothing ->
        { name = "", hash = "", balance = 0 }
      Just address ->
        address

longestChain : List BlockLink -> List BlockLink
longestChain validBlocks =
  validBlocks
    |> filter (\blockLink -> isTip blockLink)
    |> map (\blocklink ->
        let
          chain = chainForBlock blocklink
        in
          (length chain, chain)
      )
    |> foldr (\(l, longest) (c, current) ->
        if c > l
          then (c, current)
        else
          (l, longest)
      ) (0, [])
    |> second

chainForBlock : BlockLink -> List BlockLink
chainForBlock blocklink =
  case blocklink of
    NoBlock ->
      [ NoBlock ]
    BlockLink block ->
      BlockLink block :: chainForBlock block.previousBlock

isTip : BlockLink -> Bool
isTip blocklink =
  case blocklink of
    NoBlock ->
      True
    BlockLink block ->
      length block.nextBlocks == 0

withUpdatedBalances : List BlockLink -> List Address -> List Address
withUpdatedBalances blockchain addresses =
  let
    confirmedBlockchain = drop confirmationsRequired blockchain
  in
    addresses
      |> map (\address -> { address | balance = balanceFor confirmedBlockchain address })

confirmedBalanceFor : List BlockLink -> Address -> Int
confirmedBalanceFor blockchain address =
  let
    confirmedBlockchain = drop confirmationsRequired blockchain
  in
    balanceFor confirmedBlockchain address

balanceFor : List BlockLink -> Address -> Int
balanceFor blockchain address =
  case head blockchain of
    Nothing ->
      address.balance
    Just blocklink ->
      case blocklink of
        NoBlock ->
          address.balance
        BlockLink block ->
          let
            difference =
              if block.transaction.sender.hash == address.hash
                then negate block.transaction.amount
              else if block.transaction.receiver.hash == address.hash
                then block.transaction.amount
              else
                0
          in
            case tail blockchain of
              Nothing ->
                0
              Just remainingBlockchain ->
                difference + balanceFor remainingBlockchain address

isValidTx : List BlockLink -> Transaction -> Bool
isValidTx blockchain transaction =
  let
    senderHasFunds = (balanceFor blockchain transaction.sender) >= transaction.amount
    senderIsNotReceiver = transaction.sender /= transaction.receiver
    amountIsPositive = transaction.amount > 0
  in
    senderHasFunds && senderIsNotReceiver && amountIsPositive

nextTx : List BlockLink -> List Transaction -> Maybe Transaction
nextTx blockchain transactionPool =
  case head transactionPool of
    Nothing ->
      Nothing
    Just transaction ->
      if isValidTx blockchain transaction
        then Just transaction
      else
        case tail transactionPool of
          Nothing ->
            Nothing
          Just remainingTransactions ->
            nextTx blockchain remainingTransactions

isBlockInChain : BlockLink -> List BlockLink -> Bool
isBlockInChain target chain =
  chain
    |> foldr (\blocklink hasBeenFound ->
        (blockLinkHash blocklink == blockLinkHash target) || hasBeenFound
      ) False

maliciousBlockToMine : List BlockLink -> Block -> BlockLink
maliciousBlockToMine blocklinks blockToErase =
  let
    startBlock = blockToErase.previousBlock
    chains = blocklinks
      |> filter ( \blocklink -> isTip blocklink)
      |> map ( \blocklink -> chainForBlock blocklink )
      |> filter ( \chain -> (isBlockInChain startBlock chain) && not (isBlockInChain (BlockLink blockToErase) chain) )
      |> map ( \chain -> (chain, distanceToBlock chain startBlock) )
      |> sortWith ( \(chain1, distance1) (chain2, distance2) ->
          case compare distance1 distance2 of
            LT -> GT
            EQ -> EQ
            GT -> LT
        )
    longestChain = get 0 (fromList chains)
  in
    case longestChain of
      Nothing ->
        startBlock
      Just chain ->
        case head (first chain) of
          Nothing ->
            NoBlock
          Just blocklink ->
            blocklink

distanceToBlock : List BlockLink -> BlockLink -> Int
distanceToBlock blocklinks target =
  case head blocklinks of
    Nothing ->
      0
    Just current ->
      if current == target
        then 0
      else
        case tail blocklinks of
          Nothing ->
            1 -- not reached unless target is not in blocklinks
          Just remainingBlocks ->
            1 + distanceToBlock remainingBlocks target

erasableBlocks : List BlockLink -> List BlockLink
erasableBlocks blocks =
  blocks
    |> longestChain
    |> filter ( \blocklink ->
        case blocklink of
          NoBlock ->
            False
          BlockLink block ->
            True
      )

blockToMine : Model -> Miner -> BlockLink
blockToMine model miner =
  case head (longestChain model.discoveredBlocks) of
    Nothing -> NoBlock
    Just longestChainBlock ->
      case miner.blockToErase of
        NoBlock -> longestChainBlock
        BlockLink blockToErase ->
          case (maliciousBlockToMine model.discoveredBlocks blockToErase) of
            NoBlock -> NoBlock
            BlockLink block -> BlockLink block

minedBlocksFor : Model -> Transaction -> List (String, String, BlockLink)
minedBlocksFor model transaction = model.miners
  |> indexedMap ( \m miner ->
      let
        parentBlock = blockToMine model miner
      in
        (
          (nonceFor m model.randomValue),
          (testBlockHash transaction parentBlock m model.randomValue),
          parentBlock
        )
    )
  |> filter (\(nonce, hash, block) -> isValidHash hash)

isValidHash : String -> Bool
isValidHash hash =
  slice 0 1 hash == "0"
