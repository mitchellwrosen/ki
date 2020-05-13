{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ViewPatterns #-}

module Trio.Indef
  ( withScope,
    joinScope,
    scopeIsClosing,
    async,
    asyncMasked,
    await,
    cancel,
    Scope,
    Promise,
    RestoreMaskingState,
    ScopeClosed (..),
    ThreadFailed (..),
  )
where

import Control.Applicative ((<|>))
import Control.Exception (AsyncException (ThreadKilled), Exception (fromException, toException), SomeException, asyncExceptionFromException, asyncExceptionToException)
import Control.Monad (join, void)
import Data.Foldable (for_)
import Data.Functor (($>))
import Data.Set (Set)
import qualified Data.Set as Set
import Trio.Internal.Conc (blockUntilTVar, registerBlock, retryingUntilSuccess)
import Trio.Sig (IO, STM, TMVar, TVar, ThreadId, atomically, forkIOWithUnmask, modifyTVar', myThreadId, newEmptyTMVar, newTVarIO, putTMVar, readTMVar, readTVar, retry, throwIO, throwSTM, throwTo, try, uninterruptibleMask, uninterruptibleMask_, unsafeUnmask, writeTVar)
import Prelude hiding (IO)

-- import Trio.Internal.Debug

-- | A thread scope, which scopes the lifetime of threads spawned within it.
data Scope = Scope
  { -- Invariant: if closed, no threads are starting
    closedVar :: TVar Bool,
    cancelledVar :: TVar Bool,
    runningVar :: TVar (Set ThreadId),
    startingVar :: TVar Int
  }

data Promise a = Promise
  { threadId :: ThreadId,
    resultVar :: TMVar (Either SomeException a)
  }

data ScopeClosed
  = ScopeClosed
  deriving stock (Show)
  deriving anyclass (Exception)

data ThreadFailed = ThreadFailed
  { threadId :: ThreadId,
    exception :: SomeException
  }
  deriving stock (Show)
  deriving anyclass (Exception)

-- | Unexported async variant of 'ThreadFailed'.
data AsyncThreadFailed = AsyncThreadFailed
  { threadId :: ThreadId,
    exception :: SomeException
  }
  deriving stock (Show)

instance Exception AsyncThreadFailed where
  fromException = asyncExceptionFromException
  toException = asyncExceptionToException

translateAsyncThreadFailed :: SomeException -> SomeException
translateAsyncThreadFailed ex =
  case fromException ex of
    Just AsyncThreadFailed {threadId, exception} ->
      toException ThreadFailed {threadId, exception}
    _ -> ex

type RestoreMaskingState =
  forall x. IO x -> IO x

newScope :: IO Scope
newScope = do
  cancelledVar <- newTVarIO "cancelled" False
  closedVar <- newTVarIO "closed" False
  runningVar <- newTVarIO "running" Set.empty
  startingVar <- newTVarIO "starting" 0
  pure Scope {cancelledVar, closedVar, runningVar, startingVar}

withScope :: (Scope -> IO a) -> IO a
withScope f = do
  scope <- newScope
  uninterruptibleMask \restore -> do
    result <- restore (try (f scope))
    hardCloseScope scope
    either (throwIO . translateAsyncThreadFailed) pure result

joinScope :: Scope -> Int -> IO ()
joinScope scope@Scope {cancelledVar} micros
  | micros < 0 = atomically (softJoinScope scope)
  | micros == 0 = uninterruptibleMask_ (hardCloseScope scope)
  | otherwise = do
    atomically (writeTVar cancelledVar True)
    blockUntilTimeout <- registerBlock micros
    let happyTeardown :: STM (IO ())
        happyTeardown =
          softJoinScope scope $> pure ()
    let sadTeardown :: STM (IO ())
        sadTeardown =
          blockUntilTimeout $> uninterruptibleMask_ (hardCloseScope scope)
    (join . atomically) (happyTeardown <|> sadTeardown)

-- | Block until all threads spawned within the scope finish, then close the
-- scope.
softJoinScope :: Scope -> STM ()
softJoinScope Scope {closedVar, runningVar, startingVar} = do
  blockUntilTVar startingVar (== 0)
  blockUntilTVar runningVar Set.null
  writeTVar closedVar True

-- Precondition: uninterruptibly masked
hardCloseScope :: Scope -> IO ()
hardCloseScope scope =
  atomically (setScopeToClosed scope) >>= \case
    Nothing -> pure ()
    Just childrenVar -> do
      cancellingThreadId <- myThreadId
      children <- atomically (readTVar childrenVar)
      for_ (Set.delete cancellingThreadId children) \child ->
        -- Kill the child with asynchronous exceptions unmasked, because
        -- we don't want to deadlock with a child concurrently trying to
        -- throw a exception back to us. But if any exceptions are thrown
        -- to us during this time, just ignore them. We already have an
        -- exception to throw, and we prefer it because it was delivered
        -- first.
        retryingUntilSuccess (unsafeUnmask (throwTo child ThreadKilled))

      if Set.member cancellingThreadId children
        then do
          atomically (blockUntilTVar childrenVar ((== 1) . Set.size))
          throwIO ThreadKilled
        else atomically (blockUntilTVar childrenVar Set.null)

-- | Wait for all threads to finish starting, then close a scope. Returns the
-- threads that are still running, if a state transition occurred (i.e. the
-- scope was not already closed).
setScopeToClosed :: Scope -> STM (Maybe (TVar (Set ThreadId)))
setScopeToClosed Scope {closedVar, runningVar, startingVar} = do
  readTVar closedVar >>= \case
    False -> do
      blockUntilTVar startingVar (== 0)
      writeTVar closedVar True
      pure (Just runningVar)
    True -> pure Nothing

scopeIsClosing :: Scope -> STM Bool
scopeIsClosing Scope {cancelledVar} =
  readTVar cancelledVar

-- | Spawn a thread within a scope.
async :: Scope -> IO a -> IO (Promise a)
async scope action =
  asyncMasked scope \unmask -> unmask action

-- | Like 'async', but spawns a thread with asynchronous exceptions
-- uninterruptibly masked, and provides the action with a function to unmask
-- asynchronous exceptions.
asyncMasked :: Scope -> (RestoreMaskingState -> IO a) -> IO (Promise a)
asyncMasked Scope {closedVar, runningVar, startingVar} action = do
  uninterruptibleMask_ do
    atomically do
      readTVar closedVar >>= \case
        False -> modifyTVar' startingVar (+ 1)
        True -> throwSTM ScopeClosed

    parentThreadId <- myThreadId
    resultVar <- atomically (newEmptyTMVar "result")

    childThreadId <-
      forkIOWithUnmask \unmask -> do
        childThreadId <- myThreadId
        result <- try (action unmask)
        case result of
          Left (NotThreadKilled exception) ->
            throwTo parentThreadId (AsyncThreadFailed childThreadId exception)
          _ -> pure ()
        atomically do
          running <- readTVar runningVar
          if Set.member childThreadId running
            then do
              putTMVar resultVar result
              writeTVar runningVar $! Set.delete childThreadId running
            else retry

    atomically do
      modifyTVar' startingVar (subtract 1)
      modifyTVar' runningVar (Set.insert childThreadId)

    pure
      Promise
        { threadId = childThreadId,
          resultVar
        }

-- | Wait for a promise to be fulfilled. If the thread failed, re-throws the
-- exception wrapped in a 'ThreadFailed'
await :: Promise a -> STM a
await Promise {resultVar, threadId} =
  readTMVar resultVar >>= \case
    Left exception -> throwSTM ThreadFailed {threadId, exception}
    Right result -> pure result

-- | Throw a 'ThreadKilled' to a thread, and wait for it to finish.
cancel :: Promise a -> IO ()
cancel Promise {resultVar, threadId} = do
  throwTo threadId ThreadKilled
  void (atomically (readTMVar resultVar))

pattern NotThreadKilled :: SomeException -> SomeException
pattern NotThreadKilled ex <-
  (asNotThreadKilled -> Just ex)

asNotThreadKilled :: SomeException -> Maybe SomeException
asNotThreadKilled ex
  | Just ThreadKilled <- fromException ex = Nothing
  | otherwise = Just ex
