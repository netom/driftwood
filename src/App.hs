{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module App
    ( Node(..)
    , ClusterConfig(..)
    , App(..)
    , AppT(..)
    , HasLogOptions
    , runApp
    , sendToNode
    , logDebug
    , logInfo
    , logWarn
    , logError
    , appLog
    ) where

import           AppOptions
import           Control.Monad.Reader
import qualified Data.ByteString.Lazy as BSL
import           Data.Binary
import           Data.Char
import           Data.IORef
import           Data.Time.Clock
import           Network.Socket (Socket, SockAddr)
import           Network.Socket.ByteString (sendTo)
import           Raft
import           System.Random
import           Timer

data Node = Node
    { nodeId :: String
    , nodeHost :: String
    , nodePort :: String
    , nodeAddr :: SockAddr
    } deriving Show

newtype ClusterConfig = ClusterConfig { ccPeers :: [Node] }

data App = App
    { appMe        :: Node
    , appPeers     :: [Node]
    , appSocket    :: Socket
    , appLogLevel  :: LogLevel
    , appLogTime   :: Bool
    }

appLog :: Bool -> LogLevel -> LogLevel -> String -> IO ()
appLog logTime appLevel myLevel s = when (myLevel >= appLevel) $ do
    when logTime $ do
        putStr "["
        getCurrentTime >>= (putStr . show)
        putStr "] "
    putStr $ (map toUpper $ show myLevel) <> " "
    putStrLn s

class HasLogOptions env where
    logLevel :: env -> LogLevel
    logTime  :: env -> Bool

instance HasLogOptions App where
    logLevel = appLogLevel
    logTime  = appLogTime

instance HasLogOptions Options where
    logLevel = optLogLevel
    logTime  = optLogTime

logWith :: (MonadReader env m, MonadIO m, HasLogOptions env) => LogLevel -> String -> m ()
logWith myLevel s = do
    appLevel <- asks logLevel
    logTime <- asks logTime
    liftIO $ appLog logTime appLevel myLevel s

logDebug :: (MonadReader env m, MonadIO m, HasLogOptions env) => String -> m ()
logDebug = logWith LogDebug

logInfo :: (MonadReader env m, MonadIO m, HasLogOptions env) => String -> m ()
logInfo = logWith LogInfo

logWarn :: (MonadReader env m, MonadIO m, HasLogOptions env) => String -> m ()
logWarn = logWith LogDebug

logError :: (MonadReader env m, MonadIO m, HasLogOptions env) => String -> m ()
logError = logWith LogError

sendToNode :: Socket -> Node -> Message -> IO ()
sendToNode sock node msg = do
    _ <- sendTo sock (BSL.toStrict $ encode msg) $ nodeAddr node
    return ()

newtype AppT a = AppT { runAppT :: ReaderT App IO a } deriving (Functor, Applicative, Monad, MonadIO, MonadReader App)

instance HasSendMessage AppT where
    sendMessage node msg = do
        ps <- asks appPeers
        sock <- asks appSocket
        liftIO $ forM_ ps $ \peer -> do
            when (nodeId peer == node) $ sendToNode sock peer msg

instance HasStartElectionTimer AppT where
    startElectionTimer = do
        g <- liftIO $ newStdGen
        let (delay, _) = randomR (2000000, 4000000) g
        app <- ask
        _ <- liftIO $ start delay $ runApp app $ do
            logDebug "Election timeout!"
            -- TODO: send an election timeout message to the Raft module
        return ()

instance HasStartHeartbeatTimer AppT where
    startHeartbeatTimer = do
        g <- liftIO $ newStdGen
        let (delay, _) = randomR (500000, 1000000) g
        app <- ask
        _ <- liftIO $ start delay $ runApp app $ do
            logDebug "Heartbeat timeout!"
            -- TODO: send a heartbeat timeout message to the Raft module
        return ()

runApp :: App -> AppT () -> IO ()
runApp a m = runReaderT (runAppT m) a
