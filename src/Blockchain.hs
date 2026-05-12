module Blockchain
  ( Block(..)
  , Blockchain
  , ChainConfig(..)
  , defaultConfig
  , mkBlockchain
  , chainToList
  , chainTip
  , chainConfig
  , calculateHash
  , mineBlockAsync
  , createGenesisBlock
  , addBlock
  , isValidHash
  , isValidChain
  ) where

import Data.Time.Clock (UTCTime, getCurrentTime, diffUTCTime, NominalDiffTime)
import Crypto.Hash.SHA256 (hash)
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Base16 as B16
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Control.Concurrent.STM (TVar, newTVarIO, readTVarIO)

type Hash = String

-- | Runtime-tunable chain parameters.
data ChainConfig = ChainConfig
  { cfgDifficulty      :: Int              -- ^ current leading-zero target
  , cfgTargetBlockTime :: NominalDiffTime  -- ^ desired seconds per block
  , cfgRetargetEvery   :: Int              -- ^ retarget after this many blocks
  } deriving (Show, Eq)

-- | Sensible defaults: difficulty 1, 10-second target, retarget every 5 blocks.
defaultConfig :: ChainConfig
defaultConfig = ChainConfig
  { cfgDifficulty      = 1
  , cfgTargetBlockTime = 10
  , cfgRetargetEvery   = 5
  }

data Block = Block
  { blockIndex     :: Int
  , blockTimestamp :: UTCTime
  , blockData      :: String
  , blockPrevHash  :: Hash
  , blockNonce     :: Int
  , blockHash      :: Hash
  } deriving (Show, Eq)

-- | O(1) tip access; O(log n) append via Seq.
-- Config travels with the chain so every caller gets consistent parameters.
data Blockchain = Blockchain
  { chainBlocks :: Seq Block
  , chainTip    :: Block
  , chainConfig :: ChainConfig
  }

-- | Build a chain from a genesis block with an initial config.
mkBlockchain :: Block -> ChainConfig -> Blockchain
mkBlockchain genesis cfg = Blockchain (Seq.singleton genesis) genesis cfg

-- | Convert to a plain list when needed (e.g. printing or validation).
chainToList :: Blockchain -> [Block]
chainToList = foldr (:) [] . chainBlocks

-- ---------------------------------------------------------------------------
-- Difficulty retargeting
-- ---------------------------------------------------------------------------

-- | Recompute difficulty based on how long the last window of blocks took.
--
-- Bitcoin-style clamped retarget:
--   new_diff = old_diff * (target_time * window) / actual_time
-- clamped to [old_diff / 4, old_diff * 4] so a single slow window
-- can't crash or spike the difficulty.
retargetDifficulty :: ChainConfig -> [Block] -> ChainConfig
retargetDifficulty cfg window =
  case (safeHead window, safeLast window) of
    (Just first, Just lst) ->
      let actual  = diffUTCTime (blockTimestamp lst) (blockTimestamp first)
          target  = cfgTargetBlockTime cfg
                      * fromIntegral (cfgRetargetEvery cfg)
          actual' = max actual 1          -- guard against zero
          ratio   = toRational target / toRational actual'
          oldDiff = cfgDifficulty cfg
          newDiff = max 1
                  . min (oldDiff * 4)
                  . max (max 1 (oldDiff `div` 4))
                  $ round (fromIntegral oldDiff * (fromRational ratio :: Double))
      in cfg { cfgDifficulty = newDiff }
    _ -> cfg    -- not enough blocks; keep unchanged
  where
    safeHead []    = Nothing
    safeHead (x:_) = Just x
    safeLast []    = Nothing
    safeLast xs    = Just (last xs)

-- ---------------------------------------------------------------------------
-- Hashing and mining
-- ---------------------------------------------------------------------------

calculateHash :: Int -> String -> String -> String -> Int -> Hash
calculateHash index timestamp dat prevHash nonce =
  let content = show index ++ timestamp ++ dat ++ prevHash ++ show nonce
      bytes   = BC.pack content
      hashed  = hash bytes
  in BC.unpack (B16.encode hashed)

-- | Mine in a tight loop, checking the cancellation token every 1 000 nonces.
-- Returns Nothing if cancelled (e.g. a peer found the block first),
-- or Just (hash, nonce) on success.
mineBlockAsync
  :: Int          -- ^ difficulty (leading zeros required)
  -> Int          -- ^ block index
  -> String       -- ^ timestamp
  -> String       -- ^ data payload
  -> String       -- ^ previous hash
  -> TVar Bool    -- ^ cancellation flag: set True from another thread to abort
  -> IO (Maybe (Hash, Int))
mineBlockAsync diff index timestamp dat prevHash cancelVar =
  go 0
  where
    go nonce = do
      let (found, h, nextNonce) = searchBatch nonce 1000
      if found
        then return (Just (h, nextNonce - 1))
        else do
          cancelled <- readTVarIO cancelVar
          if cancelled then return Nothing
                       else go nextNonce

    searchBatch :: Int -> Int -> (Bool, Hash, Int)
    searchBatch nonce 0 = (False, "", nonce)
    searchBatch nonce n =
      let h = calculateHash index timestamp dat prevHash nonce
      in if take diff h == replicate diff '0'
           then (True, h, nonce + 1)
           else searchBatch (nonce + 1) (n - 1)

-- ---------------------------------------------------------------------------
-- Chain operations
-- ---------------------------------------------------------------------------

-- | Mine the genesis block using the supplied config.
createGenesisBlock :: ChainConfig -> IO Block
createGenesisBlock cfg = do
  now <- getCurrentTime
  let diff      = cfgDifficulty cfg
      timestamp = show now
      prevHash  = "0"
      dat       = "Genesis Block"
  cancelVar <- newTVarIO False
  result    <- mineBlockAsync diff 0 timestamp dat prevHash cancelVar
  case result of
    Nothing         -> fail "Genesis mining cancelled — should never happen"
    Just (h, nonce) -> return Block
      { blockIndex     = 0
      , blockTimestamp = now
      , blockData      = dat
      , blockPrevHash  = prevHash
      , blockNonce     = nonce
      , blockHash      = h
      }

-- | Mine and append a new block.
-- Retargets difficulty automatically every cfgRetargetEvery blocks.
-- Returns Nothing if mining was cancelled via the TVar.
addBlock :: Blockchain -> String -> TVar Bool -> IO (Maybe Blockchain)
addBlock bc dat cancelVar = do
  now <- getCurrentTime
  let cfg       = chainConfig bc
      prev      = chainTip bc
      newIndex  = blockIndex prev + 1
      prevHash  = blockHash prev
      timestamp = show now

      -- Retarget when we have just completed a full window
      cfg' = if newIndex `mod` cfgRetargetEvery cfg == 0
               then retargetDifficulty cfg
                      (takeLast (cfgRetargetEvery cfg) (chainToList bc))
               else cfg

      diff = cfgDifficulty cfg'

  result <- mineBlockAsync diff newIndex timestamp dat prevHash cancelVar
  case result of
    Nothing         -> return Nothing
    Just (h, nonce) ->
      let newBlock = Block
            { blockIndex     = newIndex
            , blockTimestamp = now
            , blockData      = dat
            , blockPrevHash  = prevHash
            , blockNonce     = nonce
            , blockHash      = h
            }
      in return $ Just $ Blockchain (chainBlocks bc |> newBlock) newBlock cfg'

-- | Take the last n elements of a list.
takeLast :: Int -> [a] -> [a]
takeLast n xs = drop (length xs - n) xs

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

-- | Check that a hash meets the difficulty target stored in a config.
isValidHash :: Int -> Hash -> Bool
isValidHash diff h = take diff h == replicate diff '0'

-- | Validate the entire chain using the difficulty in the current config.
-- Note: a production validator would re-run retargeting per window.
isValidChain :: Blockchain -> Bool
isValidChain bc = go (cfgDifficulty (chainConfig bc)) (chainToList bc)
  where
    go _    []           = True
    go diff [b]          = isValidHash diff (blockHash b)
    go diff (b1:b2:rest) =
         blockHash b1 == blockPrevHash b2
      && isValidHash diff (blockHash b1)
      && go diff (b2:rest)