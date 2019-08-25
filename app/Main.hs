{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import           App
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
import           Log
import           MlOptions
import           Options.Applicative
import           Raft
import           System.Exit
import           System.IO
import           System.Random
import           Network.Socket hiding     (recv, send, defaultPort, sendTo)
import           Network.Socket.ByteString (recv, send, sendAll, sendTo)

sendToNode' :: Socket -> Node -> Message -> IO ()
sendToNode' sock node msg = do
    _ <- sendTo sock (BSL.toStrict $ encode msg) $ nodeAddr node
    return ()

sendToNode :: (Node -> Bool) -> Message -> AppT ()
sendToNode pred msg = do
    -- TODO: a hashmap would prolly be better.
    -- The first person to run more than 1K nodes please open an issue.
    ps <- asks appNodes
    sock <- asks appSocket
    liftIO $ forM_ ps $ \node -> do
        when (pred node) $ sendToNode' sock node msg

-- sendToNode (withId "blah")
withId :: String -> Node -> Bool
withId = flip $ (==) . nodeId

everyone :: Node -> Bool
everyone = const True

everyoneBut :: String -> Node -> Bool
everyoneBut = flip $ (/=) . nodeId

processOptions :: Options -> IO App
processOptions Options{..} = do
    appNodeState <- newIORef startState

    let appLogLevel = optLogLevel
    let appLogTime = optLogTime

    when (length optPeers < 3) $ do
        logWith' appLogTime LogError appLogLevel
            $  "The number of nodes on the network must be at lest 3. "
            <> "You must use third \"arbiter\" node to elect a leader among two nodes. "
            <> "If you have only a single node, you don't need to elect a leader. "
            <> "If you have no nodes, you have no problems. "
        exitFailure

    appNodes <- forM optPeers $ \pStr -> do
        let parts = splitOn ":" pStr

        when (length parts /= 2 && length parts /= 3) $ do
            logWith' appLogTime LogError appLogLevel
                $  "Error parsing node descriptor "
                <> pStr <> ", use format NODE_ID:HOST:PORT or NODE_ID:HOST."
            exitFailure

        let nodeId   = parts !! 0
        let nodeHost = parts !! 1

        nodePort <- if length parts == 3
            then return $ parts !! 2
            else return defaultPort

        addrinfos <- getAddrInfo
            (Just defaultHints { addrSocketType = Datagram })
            (Just nodeHost)
            (Just nodePort)

        when (length addrinfos <= 0) $ do
            logWith' appLogTime LogError appLogLevel
                $  "Could not resolve host in node descriptor "
                <> pStr <> "."
            exitFailure

        let nodeAddr = addrAddress $head addrinfos

        return Node{..}

    addrinfos <- getAddrInfo Nothing (Just $ optBindIp) (Just $ optBindPort)

    when (length addrinfos <= 0) $ do
        logWith' appLogTime LogError appLogLevel
            $  "Could not bind to " <> optBindIp <> ":"
            <> optBindPort <> ", getaddrinfo returned an empty list."
        exitFailure

    let bindAddr = head addrinfos
    appSocket <- socket (addrFamily bindAddr) Datagram defaultProtocol
    bind appSocket (addrAddress bindAddr)

    logWith' appLogTime LogInfo appLogLevel "Joining the network..."

    nonce <- randomRIO (0, 2^128) :: IO Integer

    eAppIdU <- race
        ( forM_ [0..optDiscoveryRetryCount] $ \_ -> do
            forM_ appNodes $ \n -> sendToNode' appSocket n $ Join nonce (nodeId n)
            threadDelay optDiscoveryRetryWait
        )
        $ waitForJoin nonce appSocket

    appNodeId <- case eAppIdU of
        Left () -> do
            logWith' appLogTime LogError appLogLevel "Could not discover node ID. Am I on the node list?"
            exitFailure
        Right nId -> return nId

    logWith' appLogTime LogInfo appLogLevel $ "SUCCESS. Our node ID is " <> appNodeId

    return App{..}

    where
        waitForJoin :: Integer -> Socket -> IO String
        waitForJoin nonce sock = do
            msgBS <- recv sock 4096
            let msg = decode $ BSL.fromStrict msgBS
            -- TODO: what if decode fails?
            case msg of
                Join nonce nId -> return nId
                -- TODO: nicer solution instead of explicit recursion
                _ -> waitForJoin nonce sock

main :: IO ()
main = do
    opts <- execParser options

    app <- processOptions opts

    runApp app $ do
        logInfo "Listening to incoming messages..."

        liftIO $ forever $ do
            recv (appSocket app) 4096 >>= \message -> runApp app $ do
                logInfo $ show (decode $ BSL.fromStrict message :: Message)

        logInfo "Done."
