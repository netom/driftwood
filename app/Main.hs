{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import           Control.Concurrent
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
import           Network.Socket hiding     (recv, defaultPort)
import           Network.Socket.ByteString (recv, sendAll)

data Node = Node
    { nodeId :: String
    , nodeHost :: String
    , nodePort :: String
    , nodeSocket :: Socket
    } deriving Show

newtype ClusterConfig = ClusterConfig { ccPeers :: [Node] }

data App = App
    { appNodeId    :: String
    , appPeers     :: [Node]
    , appNodeState :: IORef NodeState
    }

type AppT = ReaderT App IO

runApp :: AppT () -> App -> IO ()
runApp = runReaderT

broadcast :: Message -> AppT ()
broadcast message = do
    ps <- asks appPeers
    let encMsg = BSL.toStrict $ encode message
    liftIO $ forM_ ps $ \Node{..} -> do
        sendAll nodeSocket encMsg

processOptions :: Options -> IO App
processOptions Options{..} = do
    appNodeState <- newIORef startState

    when (length optPeers < 2) $ die
        $  "The number of peers must be at least 2.\n"
        <> "(the number of nodes on the network must be at lest 3).\n"
        <> "You must use third \"arbiter\" node to elect a leader among two nodes.\n"
        <> "If you have only a single node, you don't need to elect a leader.\n"
        <> "If you have no nodes, you have no problems.\n"

    appPeers <- forM optPeers $ \pStr -> do
        let parts = splitOn ":" pStr

        when (length parts /= 2 && length parts /= 3) $ die
            $  "Error parsing node descriptor "
            <> pStr <> ", use format NODE_ID:HOST:PORT or NODE_ID:HOST."

        let nodeId   = parts !! 0
        let nodeHost = parts !! 1

        nodePort <- if length parts == 3
            then return $ parts !! 2
            else return defaultPort

        addrinfos <- getAddrInfo Nothing (Just nodeHost) (Just nodePort)

        when (length addrinfos <= 0) $ die
            $  "Could not resolve host in node descriptor "
            <> pStr <> "."

        let nodeAddr = head addrinfos

        nodeSocket <- socket (addrFamily nodeAddr) Datagram defaultProtocol
        connect nodeSocket (addrAddress nodeAddr)

        return Node{..}

    let appNodeId = optNodeId
    return App{..}

main :: IO ()
main = do
    opts <- execParser options

    app <- processOptions opts

    {-  
    if optArbiter opts
    then do
        addrinfos <- getAddrInfo Nothing (Just optBindIp) (Just optBindPort)
        let serveraddr = head addrinfos
        sock <- socket (addrFamily serveraddr) Datagram defaultProtocol
        bind sock (addrAddress serveraddr)
        print "UDP server is waiting..."
        recv sock 4096 >>= \message -> print ("UDP server received: " ++ (show message))
        print "UDP server socket is closing now."
        close sock
    else do
        addrinfos <- getAddrInfo Nothing (Just "127.0.0.1") (Just "5678")
        let serveraddr = head addrinfos
        sock <- socket (addrFamily serveraddr) Datagram defaultProtocol
        connect sock (addrAddress serveraddr)
        sendAll sock "Message!"
        close sock
     -}

    putStrLn "Done."
