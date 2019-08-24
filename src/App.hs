module App
    ( Node(..)
    , ClusterConfig(..)
    , App(..)
    , AppT(..)
    , runApp
    ) where

import           Control.Monad.Reader
import           Data.IORef
import           Network.Socket
import           MlOptions
import           Raft

data Node = Node
    { nodeId :: String
    , nodeHost :: String
    , nodePort :: String
    , nodeAddr :: SockAddr
    } deriving Show

newtype ClusterConfig = ClusterConfig { ccPeers :: [Node] }

data App = App
    { appNodeId    :: String
    , appNodes     :: [Node]
    , appNodeState :: IORef NodeState
    , appSocket    :: Socket
    , appLogLevel  :: LogLevel
    , appLogTime   :: Bool
    }

type AppT = ReaderT App IO

runApp :: App -> AppT () -> IO ()
runApp = flip runReaderT
