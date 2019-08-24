module MlOptions
    ( Options(..)
    , options
    , defaultPort
    )where

import Options.Applicative

data Options = Options
    { optBindIp   :: String
    , optBindPort :: String
    , optDiscoveryRetryCount :: Int
    , optDiscoveryRetryWait :: Int
    , optArbiter  :: Bool
    , optPeers    :: [String]
    } deriving Show

defaultPort = "10987"

options :: ParserInfo Options
options = info
    (helper <*> (
        Options
            <$> (  strOption
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
            <*> (  option auto
                $  long "discovery-retry-count"
                <> short 'c'
                <> value 5
                <> metavar "RETRY"
                <> help ("The number of retries during the initial discovery phase. Default is 5.")
                )
            <*> (  option auto
                $  long "discovery-wait-time"
                <> short 'w'
                <> value 100000
                <> metavar "WAIT"
                <> help ("The number of microseconds to wait during the initial discovery phase. Default is 100,000.")
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