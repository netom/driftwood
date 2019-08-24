module MlOptions
    ( Options(..)
    , options
    , defaultPort
    )where

import Options.Applicative

data Options = Options
    { optNodeId      :: String
    , optBindIp   :: String
    , optBindPort :: String
    , optArbiter  :: Bool
    , optPeers    :: [String]
    } deriving Show

defaultPort = "10987"

options :: ParserInfo Options
options = info
    (helper <*> (
        Options
            <$> (  argument str
                $  metavar "NODE_ID"
                <> help "The unique ID of this node."
                )
            <*> (  strOption
                $  long "ip"
                <> short 'i'
                <> value "0.0.0.0"
                <> metavar "IP"
                <> help "The IP address to bind to. Defaults to 0.0.0.0 (all ip addresses)."
                )
            <*> (  strOption
                $  long "port"
                <> short 'p'
                <> value defaultPort
                <> metavar "PORT"
                <> help ("The port to bind to. Defaults to " <> defaultPort <> ".")
                )
            <*> (  switch 
                $ long "arbiter"
                <> short 'a'
                <> help "Give out votes, but never start an election, so never become a leader."
                )
            <*> (  some $ strOption
                $  long "node"
                <> short 'n'
                <> metavar "NODE"
                <> help "An other node in the network."
                )
    )) (
        fullDesc
            <> progDesc "Microscopic leader election tool."
    )