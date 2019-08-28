{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           App
import           AppOptions
import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Concurrent.STM.TChan
import           Control.Exception
import           Control.Monad
import           Control.Monad.Reader
import           Data.Binary
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import           Data.IORef
import           Data.List
import           Data.List.Split
import           Data.Maybe
import           Data.String
import           Network.Socket hiding     (recv, send, defaultPort, sendTo)
import           Network.Socket.ByteString (recv, send, sendAll, sendTo)
import           Options.Applicative
import           Raft
import           System.Exit
import           System.IO
import           System.Random
import           Timer

processOptions :: Options -> IO App
processOptions Options{..} = do

    let appLogLevel = optLogLevel
    let appLogTime = optLogTime

    let appLog' = appLog appLogTime appLogLevel

    let catchWith msg act = catch act $ \(e :: IOException) -> do
            appLog' LogError $ msg <> ": " <> show e
            exitFailure

    when (length optPeers < 3) $ do
        appLog' LogError 
            $  "The number of nodes on the network must be at lest 3. "
            <> "You must use third \"arbiter\" node to elect a leader among two nodes. "
            <> "If you have only a single node, you don't need to elect a leader. "
            <> "If you have no nodes, you have no problems. "
        exitFailure

    nodes <- forM optPeers $ \pStr -> do
        let parts = splitOn ":" pStr

        when (length parts /= 2 && length parts /= 3) $ do
            appLog' LogError 
                $  "Error parsing node descriptor "
                <> pStr <> ", use format NODE_ID:HOST:PORT or NODE_ID:HOST."
            exitFailure

        let nodeId   = parts !! 0
        let nodeHost = parts !! 1

        nodePort <- if length parts == 3
            then return $ parts !! 2
            else return defaultPort

        addrinfos <- catchWith ("Could not get node address info for " <> pStr) $
            getAddrInfo
                (Just defaultHints { addrSocketType = Datagram })
                (Just nodeHost)
                (Just nodePort)

        when (length addrinfos <= 0) $ do
            appLog' LogError 
                $  "Could not get node address info for "
                <> pStr <> ": getaddrinfo retunred an empty list."
            exitFailure

        let nodeAddr = addrAddress $head addrinfos

        return Node{..}

    addrinfos <- catchWith
        (  "Could not get node address info for binding to "
        <> optBindIp <> ":" <> optBindPort
        )
        $ getAddrInfo
            (Just defaultHints { addrSocketType = Datagram })
            (Just $ optBindIp)
            (Just $ optBindPort)

    when (length addrinfos <= 0) $ do
        appLog' LogError
            $  "Could not bind to " <> optBindIp <> ":"
            <> optBindPort <> ", getaddrinfo returned an empty list."
        exitFailure

    let bindAddr = head addrinfos

    appSocket <- catchWith
        "Could not create socket"
        $ socket (addrFamily bindAddr) Datagram defaultProtocol

    catchWith
        ( "Could not bind to IP address " <> optBindIp )
        $ bind appSocket $ addrAddress bindAddr

    appLog' LogInfo "Joining the network..."

    nonce <- randomRIO (0, 2^128) :: IO Integer

    eAppIdU <- race
        ( forM_ [0..optDiscoveryRetryCount] $ \_ -> do
            forM_ nodes $ \node ->
                catchWith
                    ( "Could not send datagram to node " <> nodeId node )
                    $ sendToNode appSocket node $ Join nonce (nodeId node)
            threadDelay optDiscoveryRetryWait
        )
        $ waitForJoin nonce appSocket

    myId <- case eAppIdU of
        Left () -> do
            appLog' LogError "Could not discover node ID. Am I on the node list?"
            exitFailure
        Right nId -> return nId

    let (mes, appPeers) = partition ((== myId) . nodeId) nodes
    let appMe = head mes

    appLog' LogInfo $ "SUCCESS. Our node ID is " <> nodeId appMe

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

    runApp app $ runNodeProgram (nodeId $ appMe app) (nodeId <$> appPeers app) $ do
        lift $ logInfo "Listening to incoming messages..."

        sock <- asks appSocket
        liftIO $ forever $ do
            recv sock 4096 >>= \message -> runApp app $ do
                logInfo $ show (decode $ BSL.fromStrict message :: Message)
