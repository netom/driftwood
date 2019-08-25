module Timer
    ( start
    , cancel
    ) where

import           Control.Concurrent

newtype Timer = Timer { fromTimer :: ThreadId }

start :: Int -> IO () -> IO Timer
start delay action = do
    Timer <$> ( forkIO $ threadDelay delay >> action )

cancel :: Timer -> IO ()
cancel = killThread . fromTimer
