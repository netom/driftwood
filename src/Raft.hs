{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}

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

import           Control.Lens
import           Control.Monad.State.Strict
import           Control.Monad.Trans.Maybe
import           Data.Binary hiding (get)
import qualified Data.Map.Strict as M
import           Data.Maybe
import qualified Data.Set as S
import           GHC.Generics

-- A node can be any of these:
data Role
    = Follower
    | Candidate
    | Leader
    deriving Eq

-- Message that is communicated between nodes
data Message
    = VoteRequest
        { msgNodeId :: String
        , msgTerm   :: Int
        , msgLeader :: Bool
        }
    | Vote
        { msgNodeId  :: String
        , msgTerm    :: Int
        , msgGranted :: Bool
        }
    | Join
        { msgNodeId :: String
        , msgNonce  :: Integer
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
    { _nsNodeId   :: String
    , _nsRole     :: Role
    -- TODO: what happens during a term wraparound?
    , _nsTerm     :: Int
    , _nsPeers    :: S.Set String
    , _nsVotedFor :: Maybe String
    -- Non-empty if there's an election in progress.
    -- Either empty or M.size nsVotes == S.size nsPeers
    , _nsVotes    :: Votes
    }

makeLenses ''NodeState

class HasSendMessage m where
    sendMessage :: String -> Message -> m ()

class HasStartElectionTimer m where
    startElectionTimer :: m ()

class HasStartHeartbeatTimer m where
    startHeartbeatTimer :: m ()

type NodeT m a = (Monad m) => StateT NodeState m a

startState nodeId peerIds = NodeState
    { _nsNodeId   = nodeId
    , _nsRole     = Follower
    , _nsTerm     = 0
    , _nsPeers    = S.fromList peerIds
    -- Hack: pretend we already gave a vote to ourselves
    -- (but don't actually give a vote to anyone)
    -- This prevents voting in the 0th term
    , _nsVotedFor = Just nodeId 
    -- No election is in progress
    , _nsVotes    = M.empty
    }

-- Process a message
processMessage :: HasSendMessage m => Message -> NodeT m ()
processMessage msg = do
    ns <- get
    case ns ^. nsRole of
        Follower -> case msg of
            VoteRequest{..} -> do
                when (msgTerm > ns ^. nsTerm) $ do
                    nsTerm <.= msgTerm
                    nsVotedFor <.= Just msgNodeId
                    lift $ sendMessage msgNodeId $ Vote (ns ^. nsNodeId) msgTerm True
                when (msgTerm == ns ^. nsTerm) $ do
                    if isNothing (ns ^. nsVotedFor) || (ns ^. nsVotedFor) == Just msgNodeId
                    then lift $ sendMessage msgNodeId $ Vote (ns ^. nsNodeId) msgTerm True
                    else lift $ sendMessage msgNodeId $ Vote (ns ^. nsNodeId) msgTerm False
            _ -> return ()
        Candidate -> case msg of
            Vote{} -> return ()
            _ -> return ()
        Leader -> case msg of
            Vote{} -> return ()
            _ -> return ()

-- Process an event
processEvent :: (HasSendMessage m, HasStartHeartbeatTimer m, HasStartElectionTimer m) => Event -> NodeT m ()
processEvent e = case e of
    EvMessage msg -> processMessage msg
    EvElectionTimeout -> stepForward
    EvHeartbeatTimeout -> heartbeatTimeout

sendVoteRequests :: HasSendMessage m => NodeT m ()
sendVoteRequests = do
    ns <- get
    forM_ (ns ^. nsPeers) $ \node -> do
        lift $ sendMessage node $ VoteRequest (ns ^. nsNodeId) (ns ^. nsTerm) (ns ^. nsRole == Leader)

-- Called when the heartbear timeout expires.
-- If the node got the majority in the previous heartbeat,
-- then send new vote requests
-- If the node did not get the majority, step down
heartbeatTimeout :: (HasSendMessage m, HasStartHeartbeatTimer m, HasStartElectionTimer m) => NodeT m ()
heartbeatTimeout = do
    ns <- get

    -- No election in progress (received majority in this heartbeat)
    if M.size (ns ^. nsVotes) == 0
    then sendVoteRequests

    -- This is only possible if we didn't receive the majority during
    -- this heartbeat. Step down.
    else follow

-- Become a Candidate, increase Term, and start a new election
stepForward :: HasSendMessage m => NodeT m ()
stepForward = do
    modify' 
        ( \ns -> ns
        & nsRole .~ Candidate
        & nsTerm +~ 1
        & nsVotedFor .~ (Just $ ns ^. nsNodeId)
        & nsVotes .~ (M.insert (ns ^. nsNodeId) True $ blankVotes $ S.toList (ns ^. nsPeers))
        )

    sendVoteRequests

-- This may be called during being a Candidate or a Leader (heartbeat election)
lead :: HasStartHeartbeatTimer m => NodeT m ()
lead = do
    nsRole     <.= Leader
    nsVotedFor <.= Nothing
    nsVotes    <.= M.empty

    lift startHeartbeatTimer

-- Convert to follower, start election timer
follow :: HasStartElectionTimer m => NodeT m ()
follow = do
    nsRole     <.= Follower
    nsVotedFor <.= Nothing
    nsVotes    <.= M.empty

    lift startElectionTimer

runNodeProgram :: (Monad m, HasStartElectionTimer m) => String -> [String] -> NodeT m a -> m a
runNodeProgram nodeId peerIds program = fst <$> runStateT (lift startElectionTimer >> program) (startState nodeId peerIds)
