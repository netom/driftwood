module Log
    ( logDebug
    , logInfo
    , logWarn
    , logError
    , logWith
    , logWith'
    ) where

import           App
import           MlOptions
import           Data.Char
import           Data.Time.Clock
import           Control.Monad.Reader

logWith' :: Bool -> LogLevel -> LogLevel -> String -> IO ()
logWith' logTime myLevel level s = when (myLevel >= level) $ do
    when logTime $ do
        putStr "["
        getCurrentTime >>= (putStr . show)
        putStr "] "
    putStr $ (map toUpper $ show myLevel) <> " "
    putStrLn s

logWith :: LogLevel -> String -> AppT ()
logWith myLevel s = do
    level <- asks appLogLevel
    logTime <- asks appLogTime
    liftIO $ logWith' logTime myLevel level s
        
logDebug :: String -> AppT ()
logDebug = logWith LogDebug

logInfo :: String -> AppT ()
logInfo = logWith LogInfo

logWarn :: String -> AppT ()
logWarn = logWith LogDebug

logError :: String -> AppT ()
logError = logWith LogError

