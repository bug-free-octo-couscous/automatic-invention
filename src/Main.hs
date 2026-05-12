-- app/Main.hs
module Main where

import Blockchain
import Control.Concurrent.STM (newTVarIO)

main :: IO ()
main = do
  putStrLn "Mining genesis block..."
  let cfg     = defaultConfig   -- swap in any ChainConfig here
  genesis    <- createGenesisBlock cfg
  let chain0  = mkBlockchain genesis cfg

  chain1 <- mineNext chain0 "Alice sends 10 coins to Bob"
  chain2 <- mineNext chain1 "Bob sends 5 coins to Carol"
  chain3 <- mineNext chain2 "Carol sends 1 coin to Jihoo"

  mapM_ printBlock (chainToList chain3)
  putStrLn $ "\nChain valid?       " ++ show (isValidChain chain3)
  putStrLn $ "Final difficulty:  " ++ show (cfgDifficulty (chainConfig chain3))

-- | Mine one block, creating a fresh cancellation token each time.
-- In a real node, share the TVar with a network-listener thread so it can
-- cancel mining when a peer broadcasts a valid block first.
mineNext :: Blockchain -> String -> IO Blockchain
mineNext bc dat = do
  let idx = blockIndex (chainTip bc) + 1
  putStrLn $ "Mining block " ++ show idx
          ++ " (difficulty " ++ show (cfgDifficulty (chainConfig bc)) ++ ")..."
  cancelVar <- newTVarIO False
  result    <- addBlock bc dat cancelVar
  case result of
    Just chain -> return chain
    Nothing    -> fail "Mining was cancelled"

printBlock :: Block -> IO ()
printBlock b = do
  putStrLn $ replicate 50 '-'
  putStrLn $ "Index:     " ++ show (blockIndex b)
  putStrLn $ "Data:      " ++ blockData b
  putStrLn $ "Nonce:     " ++ show (blockNonce b)
  putStrLn $ "Prev Hash: " ++ blockPrevHash b
  putStrLn $ "Hash:      " ++ blockHash b