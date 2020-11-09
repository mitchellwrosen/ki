{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (when)
import Data.Functor
import Data.IORef
import Data.Maybe
import qualified Ki.Implicit as Ki
import qualified Ki.Internal
import TestUtils
import Prelude hiding (fail)

main :: IO ()
main = do
  test "background context isn't cancelled" do
    (isJust <$> Ki.cancelled) `shouldReturn` False

  test "new scope doesn't start out cancelled" do
    Ki.scoped \_ -> (isJust <$> Ki.cancelled) `shouldReturn` False

  test "`cancelScope` observable by scope's `cancelled`" do
    Ki.scoped \scope -> do
      Ki.cancelScope scope
      (isJust <$> Ki.cancelled) `shouldReturn` True

  test "`cancelScope` observable by inner scope's `cancelled`" do
    Ki.scoped \scope ->
      Ki.scoped \_ -> do
        Ki.cancelScope scope
        (isJust <$> Ki.cancelled) `shouldReturn` True

  childtest "`cancelScope` observable by child's `cancelled`" \fork -> do
    ref <- newIORef Nothing
    Ki.scoped \scope -> do
      fork scope do
        Ki.cancelScope scope
        Ki.cancelled >>= writeIORef ref
      Ki.wait scope
    (isJust <$> readIORef ref) `shouldReturn` True

  childtest "`cancelScope` observable by grandchild's `cancelled`" \fork -> do
    ref <- newIORef Nothing
    Ki.scoped \scope1 -> do
      fork scope1 do
        Ki.scoped \scope2 -> do
          fork scope2 do
            Ki.cancelScope scope1
            Ki.cancelled >>= writeIORef ref
          Ki.wait scope2
      Ki.wait scope1
    (isJust <$> readIORef ref) `shouldReturn` True

  test "inner scope inherits cancellation" do
    Ki.scoped \scope1 -> do
      Ki.cancelScope scope1
      Ki.scoped \_ -> (isJust <$> Ki.cancelled) `shouldReturn` True

  childtest "child thread inherits cancellation" \fork -> do
    ref <- newIORef Nothing
    Ki.scoped \scope -> do
      Ki.cancelScope scope
      fork scope (Ki.cancelled >>= writeIORef ref)
      Ki.wait scope
    (isJust <$> readIORef ref) `shouldReturn` True

  childtest "creating a child thread throws ErrorCall when the scope is closed" \fork -> do
    scope <- Ki.scoped pure
    fork scope (pure ()) `shouldThrow` ErrorCall "ki: scope closed"

  test "cancelled child context removes parent's ref to it" do
    ctx0 <- atomically Ki.Internal.newCtxSTM
    ctx1 <- atomically (Ki.Internal.deriveCtx ctx0)
    (length <$> readTVarIO (Ki.Internal.childrenVar ctx0)) `shouldReturn` 1
    Ki.Internal.cancelCtx ctx1
    (length <$> readTVarIO (Ki.Internal.childrenVar ctx0)) `shouldReturn` 0

  test "`wait` succeeds when no threads are alive" do
    Ki.scoped Ki.wait

  childtest "creates a thread" \fork -> do
    parentThreadId <- myThreadId
    Ki.scoped \scope -> do
      fork scope do
        childThreadId <- myThreadId
        when (parentThreadId == childThreadId) (fail "didn't create a thread")
      Ki.wait scope

  forktest "propagates sync exceptions" \fork -> do
    shouldThrowSuchThat
      ( Ki.scoped \scope -> do
          fork scope (throwIO A)
          Ki.wait scope
      )
      (\(Ki.ThreadFailed _threadId exception) -> fromException exception == Just A)

  forktest "propagates async exceptions" \fork -> do
    shouldThrowSuchThat
      ( Ki.scoped \scope -> do
          fork scope (throwIO B)
          Ki.wait scope
      )
      (\(Ki.ThreadFailed _threadId exception) -> fromException exception == Just B)

  forktest "doesn't propagate own cancel token exceptions" \fork ->
    Ki.scoped \scope -> do
      Ki.cancelScope scope
      fork scope (atomically Ki.cancelledSTM >>= throwIO)
      Ki.wait scope

  forktest "propagates ScopeClosing if it isn't ours" \fork ->
    shouldThrowSuchThat
      ( Ki.scoped \scope -> do
          fork scope (throwIO Ki.Internal.ScopeClosing)
          Ki.wait scope
      )
      (\(Ki.ThreadFailed _threadId exception) -> fromException exception == Just Ki.Internal.ScopeClosing)

  forktest "propagates others' cancel token exceptions" \fork ->
    shouldThrowSuchThat
      ( Ki.scoped \scope -> do
          Ki.cancelScope scope
          fork scope (throwIO (Ki.Internal.CancelToken 0))
          Ki.wait scope
      )
      (\(Ki.ThreadFailed _threadId exception) -> fromException exception == Just (Ki.Internal.CancelToken 0))

  test "`async` returns sync exceptions" do
    Ki.scoped \scope -> do
      result <- Ki.async @() scope (throw A)
      Ki.await result `shouldReturnSuchThat` \case
        Left (Ki.ThreadFailed _threadId exception) -> fromException exception == Just A
        _ -> False

  test "`async` returns async exceptions" do
    Ki.scoped \scope -> do
      result <- Ki.async @() scope (throw B)
      Ki.await result `shouldReturnSuchThat` \case
        Left (Ki.ThreadFailed _threadId exception) -> fromException exception == Just B
        _ -> False

  test "awaiting a failed `fork`ed thread throws the sync exception it failed with" do
    Ki.scoped \scope -> do
      mask \unmask -> do
        thread <- Ki.fork @() scope (throw A)
        unmask (Ki.wait scope) `catch` \(Ki.Internal.ThreadFailedAsync _) -> pure ()
        Ki.await thread
          `shouldThrowSuchThat` \(Ki.ThreadFailed _threadId exception) -> fromException exception == Just A

  test "awaiting a failed `fork`ed thread throws the async exception it failed with" do
    Ki.scoped \scope -> do
      mask \unmask -> do
        thread <- Ki.fork @() scope (throw B)
        unmask (Ki.wait scope) `catch` \(Ki.Internal.ThreadFailedAsync _) -> pure ()
        Ki.await thread
          `shouldThrowSuchThat` \(Ki.ThreadFailed _threadId exception) -> fromException exception == Just B

  childtest "inherits masking state" \fork -> do
    Ki.scoped \scope -> do
      fork scope (getMaskingState `shouldReturn` Unmasked)
      mask_ (fork scope (getMaskingState `shouldReturn` MaskedInterruptible))
      uninterruptibleMask_ (fork scope (getMaskingState `shouldReturn` MaskedUninterruptible))
      Ki.wait scope

  test "provides an unmasking function (`forkWithUnmask`)" do
    Ki.scoped \scope -> do
      _thread <- mask_ (Ki.forkWithUnmask scope \unmask -> unmask getMaskingState `shouldReturn` Unmasked)
      Ki.wait scope

  test "provides an unmasking function (`forkWithUnmask_`)" do
    Ki.scoped \scope -> do
      mask_ (Ki.forkWithUnmask_ scope \unmask -> unmask getMaskingState `shouldReturn` Unmasked)
      Ki.wait scope

  test "provides an unmasking function (`asyncWithUnmask`)" do
    Ki.scoped \scope -> do
      _thread <- (Ki.asyncWithUnmask scope \unmask -> unmask getMaskingState `shouldReturn` Unmasked)
      Ki.wait scope

  test "thread can be awaited after its scope closes" do
    thread <-
      Ki.scoped \scope -> do
        thread <- Ki.fork scope (pure ())
        Ki.wait scope
        pure thread
    Ki.await thread `shouldReturn` ()

forktest :: String -> (Ki.Context => (Ki.Scope -> (Ki.Context => IO ()) -> IO ()) -> IO ()) -> IO ()
forktest name theTest = do
  test (name ++ " (`fork`)") (theTest \scope action -> void (Ki.fork scope action))
  test (name ++ " (`fork_`)") (theTest Ki.fork_)

childtest :: String -> (Ki.Context => (Ki.Scope -> (Ki.Context => IO ()) -> IO ()) -> IO ()) -> IO ()
childtest name theTest = do
  forktest name theTest
  test (name ++ " (`async`)") (theTest \scope action -> void (Ki.async scope action))

data A = A
  deriving stock (Eq, Show)
  deriving anyclass (Exception)

data B = B
  deriving stock (Eq, Show)

instance Exception B where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException
