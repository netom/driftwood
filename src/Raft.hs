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
    , MonadRaft(..)
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
        }
    | Vote
        { msgNodeId  :: String
        , msgTerm    :: Int
        , msgGranted :: Bool
        }
    | Heartbeat
        { msgNodeId :: String
        , msgTerm   :: Int
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
    -- Either empty or M.size nsVotes <= S.size nsPeers
    , _nsVotes    :: Votes
    }

makeLenses ''NodeState

class MonadRaft m where
    sendMessage :: String -> Message -> m ()
    startElectionTimer :: m ()
    resetElectionTimer :: m()
    stopElectionTimer :: m()
    startHeartbeatTimer :: m ()
    stopHeartbeatTimer :: m ()

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

-- It's like "when", but inside a MonadState
-- with a predicate working on a part of the environment
whenS :: MonadState s m => (s -> a) -> (a -> Bool) -> m () -> m ()
whenS getter pred action = do
    a <- gets getter
    when (pred a) action

-- Process a message
processMessage :: MonadRaft m => Message -> NodeT m ()
processMessage msg = do
    NodeState{..} <- get
    case _nsRole of
        Follower -> case msg of
            -- Respond to RPCs from candidates and leaders
            -- If election timeout elapses [without VR or HB], convert to candidate
            VoteRequest{..} -> do
                when (_nsTerm < msgTerm) $ do
                    nsTerm .= msgTerm
                    nsVotedFor .= Just msgNodeId
                    lift $ sendMessage msgNodeId $ Vote _nsNodeId msgTerm True
                when (_nsTerm == msgTerm) $ do
                    if isNothing _nsVotedFor || _nsVotedFor == Just msgNodeId
                    then lift $ sendMessage msgNodeId $ Vote _nsNodeId msgTerm True
                    else lift $ sendMessage msgNodeId $ Vote _nsNodeId msgTerm False
                when (_nsTerm > msgTerm) $ do
                    lift $ sendMessage msgNodeId $ Vote _nsNodeId msgTerm False
                lift resetElectionTimer
            Heartbeat{..} -> do
                when (msgTerm > _nsTerm) $ do
                    nsTerm .= msgTerm
                lift resetElectionTimer
            _ -> return ()
        Candidate -> case msg of
            -- On conversion to candidate, start election:
            --   - Increment currentTerm
            --   - Vote for self
            --   - Reset election timer
            --   - Send RequestVote RPCs to all other servers
            -- If votes received from majority of servers: become leader
            -- If [Heartbeat] RPC received from new leader: convert to follower
            -- If election timeout elapses: start new election       
            -- If packet received with greater Term: convert to follower 
            VoteRequest{..} -> do
                lift $ sendMessage msgNodeId $ Vote _nsNodeId msgTerm False
            Vote{} -> do
                -- TODO: record vote
                -- if got majority, go ahead and covert to leader
                return ()
            Heartbeat{..} -> do
                when (msgTerm >= _nsTerm) $ do
                    nsTerm .= msgTerm
                    follow
            _ -> return ()
        Leader -> case msg of
            -- Send periodic HeartBeat RPCs
            -- If packet received with greater Term: convert to follower
            VoteRequest{..} -> do
                when (msgTerm > _nsTerm) $ do
                    nsTerm .= msgTerm
                    follow
                    nsVotedFor .= Just msgNodeId
                    lift $ sendMessage msgNodeId $ Vote _nsNodeId msgTerm True
                    lift $ resetElectionTimer
            Heartbeat{..} -> do
                when (msgTerm > _nsTerm) $ do
                    nsTerm .= msgTerm
                    follow
            _ -> return ()

-- Process an event
processEvent :: MonadRaft m => Event -> NodeT m ()
processEvent e = case e of
    EvMessage msg -> processMessage msg
    EvElectionTimeout -> stepForward
    EvHeartbeatTimeout -> heartbeatTimeout

sendVoteRequests :: MonadRaft m => NodeT m ()
sendVoteRequests = do
    ns <- get
    forM_ (ns ^. nsPeers) $ \node -> do
        lift $ sendMessage node $ VoteRequest (ns ^. nsNodeId) (ns ^. nsTerm)

-- Called when the heartbear timeout expires.
-- If the node got the majority in the previous heartbeat,
-- then send new vote requests
-- If the node did not get the majority, step down
heartbeatTimeout :: MonadRaft m => NodeT m ()
heartbeatTimeout = do
    ns <- get

    -- No election in progress (received majority in this heartbeat)
    -- TODO: count majority properly
    if M.size (ns ^. nsVotes) == 0
    then sendVoteRequests

    -- This is only possible if we didn't receive the majority during
    -- this heartbeat. Step down.
    else follow

-- Become a Candidate, increase Term, and start a new election
stepForward :: MonadRaft m => NodeT m ()
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
lead :: MonadRaft m => NodeT m ()
lead = do
    nsRole     <.= Leader
    nsVotedFor <.= Nothing
    nsVotes    <.= M.empty

    lift stopElectionTimer
    lift startHeartbeatTimer

-- Convert to follower, start election timer
follow :: MonadRaft m => NodeT m ()
follow = do
    nsRole     <.= Follower
    nsVotedFor <.= Nothing
    nsVotes    <.= M.empty

    lift stopHeartbeatTimer
    lift startElectionTimer

runNodeProgram :: (Monad m, MonadRaft m) => String -> [String] -> NodeT m a -> m a
runNodeProgram nodeId peerIds program = fst <$> runStateT (lift startElectionTimer >> program) (startState nodeId peerIds)
