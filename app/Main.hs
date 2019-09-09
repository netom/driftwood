{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}

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
import qualified Data.Map as M
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

catchWith :: (MonadIO m, MonadReader env m, HasLogOptions env) => String -> IO a -> m a
catchWith msg act = do
    env <- ask
    liftIO $ catch act $ \(e :: IOException) -> do
        runReaderT (logError $ msg <> ": " <> show e) env
        exitFailure

-- It's like "when", but inside a MonadReader
-- with a predicate working on a part of the environment
whenR :: MonadReader env m => (env -> a) -> (a -> Bool) -> m () -> m ()
whenR getter pred action = do
    a <- asks getter
    when (pred a) action

repeatedElements :: forall a. Ord a => [a] -> [a]
repeatedElements as =
    M.keys . M.filter (>1) $ foldl' foldf M.empty as

    where
        foldf :: M.Map a Int -> a -> M.Map a Int
        foldf m v = M.alter alterf v m

        alterf :: Maybe Int -> Maybe Int
        alterf = \case
            Nothing -> Just 1
            Just i  -> Just $ i + 1

processOptions :: Options -> IO App
processOptions options = do

    runWithOptions options $ do
        appLogLevel <- asks optLogLevel
        appLogTime  <- asks optLogTime

        repeatedNodes <- repeatedElements <$> (fmap $ takeWhile (/=':')) <$> asks optNodes
        when (length repeatedNodes > 0) $ do
            logError
                $  "The following nodes IDs are non-unique: "
                <> intercalate ", " repeatedNodes
            liftIO exitFailure

        whenR (length . optNodes) (< 3) $ do
            logError
                $  "The number of nodes on the network must be at lest 3. "
                <> "You must use a third \"arbiter\" node to elect a leader among two nodes. "
                <> "If you have only a single node, you don't need to elect a leader. "
                <> "If you have no nodes, you have no problems. "
            liftIO exitFailure

        nodes <- forM (optNodes options) $ \nStr -> do
            let parts = splitOn ":" nStr

            when (length parts /= 2 && length parts /= 3) $ do
                logError
                    $  "Error parsing node descriptor "
                    <> nStr <> ", use format NODE_ID:HOST:PORT or NODE_ID:HOST."
                liftIO exitFailure

            let nodeId   = parts !! 0
            let nodeHost = parts !! 1

            nodePort <- if length parts == 3
                then return $ parts !! 2
                else return defaultPort

            addrinfos <- catchWith ("Could not get node address info for " <> nStr) $
                liftIO $ getAddrInfo
                    (Just defaultHints { addrSocketType = Datagram })
                    (Just nodeHost)
                    (Just nodePort)

            when (length addrinfos <= 0) $ do
                logError
                    $  "Could not get node address info for "
                    <> nStr <> ": getaddrinfo retunred an empty list."
                liftIO exitFailure

            let nodeAddr = addrAddress $head addrinfos

            return Node{..}

        addrinfos <- catchWith
            (  "Could not get node address info for binding to "
            <> optBindIp options <> ":" <> optBindPort options
            )
            $ getAddrInfo
                (Just defaultHints { addrSocketType = Datagram })
                (Just $ optBindIp options)
                (Just $ optBindPort options)

        when (length addrinfos <= 0) $ do
            logError
                $  "Could not bind to " <> optBindIp options <> ":"
                <> optBindPort options <> ", getaddrinfo returned an empty list."
            liftIO exitFailure

        let bindAddr = head addrinfos

        appSocket <- catchWith
            "Could not create socket"
            $ socket (addrFamily bindAddr) Datagram defaultProtocol

        catchWith
            ( "Could not bind to IP address " <> optBindIp options )
            $ bind appSocket $ addrAddress bindAddr

        logInfo "Joining the network..."

        nonce <- liftIO $ randomRIO (0 :: Integer, 2^128)

        eAppIdU <- liftIO $ race
            ( forM_ [0..optDiscoveryRetryCount options] $ \_ -> do
                forM_ nodes $ \node ->
                    runWithOptions options $ catchWith
                        ( "Could not send datagram to node " <> nodeId node )
                        $ sendToNode appSocket node $ Join (nodeId node) nonce
                threadDelay $ optDiscoveryRetryWait options
            )
            $ waitForJoin nonce appSocket

        myId <- case eAppIdU of
            Left () -> do
                logError "Could not discover node ID. Am I on the node list?"
                liftIO $ exitFailure
            Right nId -> return nId

        let (mes, appPeers) = partition ((== myId) . nodeId) nodes
        let appMe = head mes

        logInfo $ "SUCCESS. Our node ID is " <> nodeId appMe

        return App{..}

    where
        waitForJoin :: Integer -> Socket -> IO String
        waitForJoin nonce sock = do
            msgBS <- recv sock 4096
            let msg = decode $ BSL.fromStrict msgBS
            -- TODO: what if decode fails?
            case msg of
                Join nId nonce -> return nId
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
