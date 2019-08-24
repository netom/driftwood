{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}

module Raft
    ( Role(..)
    , Message(..)
    , NodeState(..)
    , startState
    ) where

import Data.Binary
import GHC.Generics

data Role
    = Follower
    | Candidate
    | Leader

-- start: follower
-- time out, start election: ? -> candidate
-- received majority of votes: candidate -> leader
-- step down: leader -> follower
-- discover current leader or higher term: candidate -> follower

-- Time is divided to Terms
-- terms increment eternally

-- each node has a "current term" value

data Message
    = VoteRequest
        { msgNodeId :: String
        , msgTerm   :: Int
        }
    | Vote
        { msgNodeId  :: String
        , msgTerm    :: Int
        , msgGranted :: Bool
        }
    | Ping
        { msgNonce :: Integer
        , msgNodeId  :: String
        }
    deriving (Show, Generic)

instance Binary Message

data NodeState = NodeState
    { nsTerm :: Int
    , nsVoted :: Bool
    , nsRole :: Role
    }

startState = NodeState 0 True Follower

timeOutStartElection = undefined

receivedMajority = undefined

stepDown = undefined

discoverLeaderOrNewTerm t = NodeState t False Follower

-- node process:
-- listen on TChan for Messages
-- start as Follower, term = 0, voted = True
-- if timeout, hold an election ("election process?" Control.Concurrent.Timer?)
-- every received message updates current term (oneShotRestart?)
-- every message updates the current term
-- no vote is given in term 0

-- Follower:
-- passive, only listens

-- ElectionTimeout: 100-500ms

-- Election:
-- increment current term
-- convert from follower to:

-- Candidate:
-- vote for self
-- send VoteRequests, retry until
-- * receives majority vote: converts to leader
-- * receives VR from leader: steps down, beacomes follower
-- * no-one wins the election

-- Leader:
-- Sends out HeartBeat messages more frequently than the ElectionTimeout

-- each node SHOULD only give one vote per term
-- persisting to disk is important for crash recovery in vanilla raft
-- ??? other option: no votes given in 0th term at all ???
--   and requests for proper elections, so terms has a hard real-time limit
-- election timeout must be spread out between [T, 2T] (election timeout)

-- Hooks:
-- leader
-- stepDown

someFunc :: IO ()
someFunc = putStrLn "someFunc"
