{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Concurrent.STM.TChan
import           Control.Monad
import           Control.Monad.Reader
import           Data.Binary
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import           Data.IORef
import           Data.List.Split
import           Data.Maybe
import           Data.String
import           MlOptions
import           Options.Applicative
import           Raft
import           System.Exit
import           System.IO
import           System.Random
import           Network.Socket hiding     (recv, send, defaultPort, sendTo)
import           Network.Socket.ByteString (recv, send, sendAll, sendTo)

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
    , appSocketIn  :: Socket
    , appSocketOut :: Socket
    }

type AppT = ReaderT App IO

runApp :: App -> AppT () -> IO ()
runApp = flip runReaderT

sendToNode' :: Socket -> Node -> Message -> IO ()
sendToNode' sock node msg = do
    _ <- sendTo sock (BSL.toStrict $ encode msg) $ nodeAddr node
    return ()

sendToNode :: (Node -> Bool) -> Message -> AppT ()
sendToNode pred msg = do
    -- TODO: a hashmap would prolly be better.
    -- The first person to run more than 1K nodes please open an issue.
    ps <- asks appNodes
    sock <- asks appSocketOut
    liftIO $ forM_ ps $ \node -> do
        when (pred node) $ sendToNode' sock node msg

-- sendToNode (withId "blah")
withId :: String -> Node -> Bool
withId nId = (nId ==) . nodeId

everyOne :: Node -> Bool
everyOne = const True

processOptions :: Options -> IO App
processOptions Options{..} = do
    appNodeState <- newIORef startState

    when (length optPeers < 2) $ die
        $  "The number of peers must be at least 2.\n"
        <> "(the number of nodes on the network must be at lest 3).\n"
        <> "You must use third \"arbiter\" node to elect a leader among two nodes.\n"
        <> "If you have only a single node, you don't need to elect a leader.\n"
        <> "If you have no nodes, you have no problems.\n"

    appNodes <- forM optPeers $ \pStr -> do
        let parts = splitOn ":" pStr

        when (length parts /= 2 && length parts /= 3) $ die
            $  "Error parsing node descriptor "
            <> pStr <> ", use format NODE_ID:HOST:PORT or NODE_ID:HOST."

        let nodeId   = parts !! 0
        let nodeHost = parts !! 1

        nodePort <- if length parts == 3
            then return $ parts !! 2
            else return defaultPort

        addrinfos <- getAddrInfo
            (Just defaultHints { addrSocketType = Datagram })
            (Just nodeHost)
            (Just nodePort)

        when (length addrinfos <= 0) $ die
            $  "Could not resolve host in node descriptor "
            <> pStr <> "."

        let nodeAddr = addrAddress $head addrinfos

        --nodeSocket <- socket (addrFamily nodeAddr) Datagram defaultProtocol
        --connect nodeSocket (addrAddress nodeAddr)

        return Node{..}

    addrinfos <- getAddrInfo Nothing (Just $ optBindIp) (Just $ optBindPort)

    when (length addrinfos <= 0) $ die
        $  "Could not bind to " <> optBindIp <> ":"
        <> optBindPort <> ", getaddrinfo returned an empty list."

    let bindAddr = head addrinfos
    appSocketIn <- socket (addrFamily bindAddr) Datagram defaultProtocol
    bind appSocketIn (addrAddress bindAddr)

    appSocketOut <- socket (addrFamily bindAddr) Datagram defaultProtocol

    putStrLn "Joining the network..."

    nonce <- randomRIO (0, 2^128) :: IO Integer

    eAppIdU <- race
        -- TODO: retry count option? retry wait time option?
        ( forM_ [1..5] $ \_ -> do
            forM_ appNodes $ \n -> sendToNode' appSocketOut n $ Ping nonce (nodeId n)
            threadDelay 100000
        )
        $ waitForPing nonce appSocketIn

    appNodeId <- case eAppIdU of
        Left () -> die "Could not discover node ID. Am I in the node list?"
        Right nId -> return nId

    putStrLn $ "SUCCESS. Our node ID is " <> appNodeId

    return App{..}

    where
        waitForPing :: Integer -> Socket -> IO String
        waitForPing nonce sock = do
            msgBS <- recv sock 4096
            let msg = decode $ BSL.fromStrict msgBS
            -- TODO: what if decode fails?
            case msg of
                Ping nonce nId -> return nId
                -- TODO: nicer solution instead of explicit recursion
                _ -> waitForPing nonce sock

main :: IO ()
main = do
    opts <- execParser options

    app <- processOptions opts

    putStrLn "Listening to incoming messages..."

    forkIO $ forever $ do
        recv (appSocketIn app) 4096 >>= \message -> putStrLn $ "*** " <> show (decode $ BSL.fromStrict message :: Message)

    runApp app $ do
        sendToNode everyOne $ Ping 0 "Message!"

    threadDelay 10000000

    putStrLn "Done."
