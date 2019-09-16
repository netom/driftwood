module Spec where

import           Control.Concurrent
import           Control.Monad
import           Data.IORef
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck
import qualified Timer as T

minDelay = 1000
maxDelay = 2000
eps = 100

timerTests :: IO ()
timerTests = do
    x <- newIORef False

    t <- T.new (minDelay, maxDelay) $ do
        writeIORef x True

    -- Starts a timer, and looks for it's effect before the minimal
    -- and after the maximal amount of delay
    forM_ [1..100] $ \_ -> do
        writeIORef x False
        T.start t
        assertEqual "timer already finished" False <$> readIORef x
        threadDelay $ minDelay - eps
        threadDelay $ maxDelay + eps
        assertEqual "timer did not complete" True <$> readIORef x

    -- Restarts the timer over and over and check it's effects
    writeIORef x False
    T.start t
    forM_ [1..100] $ \_ -> do
        threadDelay $ minDelay - eps
        assertEqual "timer already finished" False <$> readIORef x
        T.start t
    threadDelay $ maxDelay + eps
    assertEqual "timer did not complete" True <$> readIORef x

    return ()

tests :: TestTree
tests = testGroup "Tests" [testCase "Timer tests" timerTests]

main = defaultMain tests
