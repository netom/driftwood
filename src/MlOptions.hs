module MlOptions
    ( Options(..)
    , options
    )where

import Options.Applicative

data Options = Options
    { oConfig  :: FilePath
    , oArbiter :: Bool
    }

options :: ParserInfo Options
options = info
    (helper <*> (
        Options
            <$> (  strOption
                $  long "config"
                <> short 'c'
                <> value "config.yaml"
                <> metavar "CONFIG"
                <> help "The configuration file. Use - to read from the standard input."
                )
            <*> (  switch 
                $ long "arbiter"
                <> short 'a'
                <> help "Give out votes, but never start an election, so never become a leader."
                )
    )) (
        fullDesc
            <> progDesc "Import multiple ADIF files into the main database"
    )