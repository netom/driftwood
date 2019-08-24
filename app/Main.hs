{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Concurrent
import           Control.Monad
import qualified Data.ByteString.Char8 as BS8
import           Data.String
import           MlOptions
import           Options.Applicative
import           Raft
import           System.IO
import           Network.Socket hiding     (recv)
import           Network.Socket.ByteString (recv, sendAll)

main :: IO ()
main = do
    opts <- execParser options
    if oArbiter opts
    then do
        addrinfos <- getAddrInfo Nothing (Just "127.0.0.1") (Just "5678")
        let serveraddr = head addrinfos
        sock <- socket (addrFamily serveraddr) Datagram defaultProtocol
        bind sock (addrAddress serveraddr)
        print "UDP server is waiting..."
        recv sock 4096 >>= \message -> print ("UDP server received: " ++ (BS8.unpack message))
        print "UDP server socket is closing now."
        close sock
    else do
        addrinfos <- getAddrInfo Nothing (Just "127.0.0.1") (Just "5678")
        let serveraddr = head addrinfos
        sock <- socket (addrFamily serveraddr) Datagram defaultProtocol
        connect sock (addrAddress serveraddr)
        sendAll sock $ BS8.pack "Message!"
        close sock

    putStrLn "Done."
