module Timer
    ( Timer
    , new
    , start
    , stop
    ) where

import           Control.Concurrent
import           Data.IORef
import           System.Random

data Timer = Timer
    { tmTId    :: IORef (Maybe ThreadId)
    , tmDelay  :: (Int, Int)
    , tmAction :: IO ()
    }

new :: (Int, Int) -> IO () -> IO Timer
new delayRange action = do
    ref <- newIORef Nothing
    return $ Timer ref delayRange action

stop :: Timer -> IO ()
stop t = do
    mbTId <- readIORef $ tmTId t
    case mbTId of
        Just tId -> do
            killThread tId
            writeIORef (tmTId t) Nothing
        _ -> return ()

start :: Timer -> IO ()
start t = do
    stop t
    g <- newStdGen
    let (d1, d2) = tmDelay t
    let (delay, _) = randomR (d1, d2) g
    tId <- forkIO $ threadDelay delay >> tmAction t
    writeIORef (tmTId t) $ Just tId
