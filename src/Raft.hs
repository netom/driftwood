{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RankNTypes #-}

module Raft
    ( Role(..)
    , NodeState(..)
    , Message(..)
    , Event(..)
    , HasSendMessage(..)
    , HasStartElectionTimer(..)
    , HasStartHeartbeatTimer(..)
    , processEvent
    , runNodeProgram
    ) where

import           Control.Monad.State.Strict
import           Data.Binary
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import           GHC.Generics

-- A node can be any of these:
data Role
    = Follower
    | Candidate
    | Leader

-- Message that is communicated between nodes
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

-- An event from the outside:
-- a message, or timeout
data Event
    = EvMessage Message
    | EvElectionTimeout
    | EvHeartbeatTimeout

-- You can send these over the network, or store them in files:
instance Binary Message

-- Keeps track of who voted for us
type Votes = M.Map String Bool

-- Gives a clean voting sheet
blankVotes :: [String] -> Votes
blankVotes nIds = M.fromList $ map (,False) nIds

-- The state of a single node
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

class HasSendMessage m where
    sendMessage :: String -> Message -> m ()

class HasStartElectionTimer m where
    startElectionTimer :: m ()

class HasStartHeartbeatTimer m where
    startHeartbeatTimer :: m ()

type NodeT m a = (Monad m) => StateT NodeState m a

startState nodeId peerIds = NodeState
    { nsNodeId   = nodeId
    , nsRole     = Follower
    , nsTerm     = 0
    , nsNodes    = S.fromList (nodeId : peerIds)
    -- Hack: pretend we already gave a vote to ourselves
    -- (but don't actually give a vote to anyone)
    -- This prevents voting in the 0th term
    -- TODO: validate node list so node IDs are unique.
    , nsVotedFor = Just nodeId 
    -- No election is in progress
    , nsVotes    = M.empty
    }

-- Process a message
processMessage :: Message -> NodeT m a
processMessage msg = do
    undefined

processEvent :: (HasSendMessage m, HasStartHeartbeatTimer m, HasStartElectionTimer m) => Event -> NodeT m ()
processEvent e = case e of
    EvMessage msg -> processMessage msg
    EvElectionTimeout -> aspire
    EvHeartbeatTimeout -> heartbeatTimeout

heartbeatTimeout :: (HasSendMessage m, HasStartHeartbeatTimer m, HasStartElectionTimer m) => NodeT m ()
heartbeatTimeout = do
    vs <- gets nsVotes

    -- No election in progress (received majority in this heartbeat)
    if M.size vs == 0
    then do
        -- TODO: send messages
        return ()

    -- This is only possible if we didn't receive the majority during
    -- this heartbeat. Step down.
    else follow

aspire :: HasSendMessage m => NodeT m ()
aspire = do
    modify' $ \NodeState{..} -> NodeState
        { nsRole     = Candidate
        , nsTerm     = nsTerm + 1
        , nsVotedFor = Just nsNodeId
        -- An election MUST be started with the node
        -- state given as the input to this function.
        , nsVotes    = M.insert nsNodeId True $ blankVotes $ S.toList nsNodes
        , ..
        }
    -- TODO: send messages

-- This may be called during being a Candidate or a Leader (heartbeat election)
lead :: HasStartHeartbeatTimer m => NodeT m ()
lead = do
    modify' $ \NodeState{..} -> NodeState
        { nsRole     = Leader
        , nsVotedFor = Nothing
        , nsVotes    = M.empty
        , ..
        }
    lift startHeartbeatTimer

-- Convert to follower, start election timer
follow :: HasStartElectionTimer m => NodeT m ()
follow = do
    modify' $ \NodeState{..} -> NodeState
        { nsRole     = Follower
        , nsVotedFor = Nothing
        , nsVotes    = M.empty
        , ..
        }
    lift startElectionTimer

runNodeProgram :: (Monad m, HasStartElectionTimer m) => String -> [String] -> NodeT m a -> m a
runNodeProgram nodeId peerIds program = fst <$> runStateT (lift startElectionTimer >> program) (startState nodeId peerIds)
