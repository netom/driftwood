module Timer
    ( Timer
    , start
    , stop
    , reset
    ) where

import           Control.Concurrent
import           Data.IORef

data Timer = Timer
    { tmTId    :: IORef (Maybe ThreadId)
    , tmDelay  :: Int
    , tmAction :: IO ()
    }

new :: Int -> IO () -> IO Timer
new delay action = do
    ref <- newIORef Nothing
    return $ Timer ref delay action

start :: Timer -> Int -> IO ()
start t i = do
    mbTId <- readIORef $ tmTId t
    case mbTId of
        Just _ -> return ()
        _ -> do
            tId <- forkIO $ threadDelay (tmDelay t) >> tmAction t
            ref <- writeIORef (tmTId t) $ Just tId
            writeIORef (tmTId t) Nothing

stop :: Timer -> IO ()
stop t = do
    mbTId <- readIORef $ tmTId t
    case mbTId of
        Just tId -> do
            killThread tId
            writeIORef (tmTId t) Nothing
        _ -> return ()

reset :: Timer -> IO ()
reset t = do
    mbTId <- readIORef $ tmTId t
    case mbTId of
        Just tId -> do
            killThread tId
            tId' <- forkIO $ threadDelay (tmDelay t) >> tmAction t
            atomicModifyIORef' (tmTId t) (\_ -> (Just tId',()))
        _ -> return ()