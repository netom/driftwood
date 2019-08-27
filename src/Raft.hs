{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveGeneric #-}

module Raft
    ( Role(..)
    , Message(..)
    , NodeState(..)
    , startState
    ) where

import           Data.Binary
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import           GHC.Generics

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
    | Join
        { msgNonce :: Integer
        , msgNodeId  :: String
        }
    deriving (Show, Generic)

instance Binary Message

type Votes = M.Map String Bool

blankVotes :: [String] -> Votes
blankVotes nIds = M.fromList $ map (,False) nIds

data NodeState = NodeState
    { nsNodeId   :: String
    , nsRole     :: Role
    -- TODO: what happens during a term wraparound?
    , nsTerm     :: Int
    , nsNodes    :: S.Set String
    , nsVotedFor :: Maybe String
    -- Non-empty if there's an election is in progress.
    -- Either empty or M.size nsVotes == S.size nsNodes
    , nsVotes    :: Votes
    }

startState nId nIds = NodeState
    { nsNodeId   = nId
    , nsRole     = Follower
    , nsTerm     = 0
    , nsNodes    = S.fromList nIds
    -- Hack: pretend we already gave a vote to ourselves
    -- (but don't actually give a vote to anyone)
    -- This prevents voting in the 0th term
    -- TODO: validate node list so node IDs are unique.
    , nsVotedFor = Just nId 
    -- No election is in progress
    , nsVotes    = M.empty
    }

-- Process a message
trMsg = undefined

trElectionTimeout NodeState{..} = NodeState
    { nsRole     = Candidate
    , nsTerm     = nsTerm + 1
    , nsVotedFor = Just nsNodeId
    -- An election MUST be started with the node
    -- state given as the input to this function.
    , nsVotes    = M.insert nsNodeId True $ blankVotes $ S.toList nsNodes
    , ..
    }

trHeartbeatTimeout NodeState{..} = 
    -- No election in progress (received majority in this heartbeat)
    if M.size nsVotes == 0
    then NodeState{..}
    -- This is only possible if we didn't receive the majority during
    -- this heartbeat. Step down.
    else trStepDown NodeState{..}

-- This may be called during being a Candidate or a Leader (heartbeat election)
trReceivedMajority NodeState{..} = NodeState
    { nsRole     = Leader
    , nsVotedFor = Nothing
    , nsVotes    = M.empty
    , ..
    }

trStepDown NodeState{..} = NodeState
    { nsRole     = Follower
    , nsVotedFor = Nothing
    , nsVotes    = M.empty
    , ..
    }

discoverLeaderOrNewTerm NodeState{..} = NodeState{..}

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
