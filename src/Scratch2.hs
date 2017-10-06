{-|
Copyright   : (c) Dave Laing, 2017
License     : BSD3
Maintainer  : dave.laing.80@gmail.com
Stability   : experimental
Portability : non-portable
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Scratch2 where

import Data.Proxy (Proxy(..))
import GHC.TypeLits (KnownSymbol, KnownNat)
import GHC.Exts (Constraint)

import Control.Monad.Trans (MonadIO, liftIO)
import Control.Monad.Except (throwError)

import Control.Concurrent.STM
import qualified Control.Concurrent.STM.Map as SM

import Data.Hashable (Hashable(..))

import Network.Socket (SockAddr)

import Servant.API
import Servant.API.ContentTypes (AllCTRender(..), AllCTUnrender(..))
import Servant.Server (ServantErr, Server)

import Reflex

import GHC.Generics
import Data.Aeson

class Embed tag api where
  type PayloadIn api
  type PayloadOut api -- do we need this?

  type FireIn' tag h api
  type Queues tag api
  type TupleListConstraints h api :: Constraint

  mkQueue :: MonadIO m
          => Proxy tag
          -> Proxy api
          -> m (Queues tag api)

  serve :: ( Eq tag
           , Hashable tag
           , TupleListConstraints h api
           )
        => Proxy api
        -> tag
        -> h
        -> FireIn' tag h api
        -> Queues tag api
        -> Server api

class Embed tag api => EmbedEvents t tag api where
  type EventsIn t tag api
  type EventsIn t tag api = EventsIn' t tag () api

  type PairIn' t tag h api
  type EventsIn' t tag h api
  type EventsOut t tag api

  mkPair :: ( Reflex t
            , Monad m
            , TriggerEvent t m
            )
         => Proxy tag
         -> Proxy h
         -> Proxy api
         -> m (PairIn' t tag h api)

  splitPair :: Proxy t
            -> Proxy tag
            -> Proxy h
            -> Proxy api
            -> PairIn' t tag h api
            -> (EventsIn' t tag h api, FireIn' tag h api)

  mkOut :: Reflex t
        => Proxy api
        -> Event t (tag, PayloadOut api)
        -> EventsOut t tag api

  addToQueue :: ( Reflex t
                , Monad m
                , PerformEvent t m
                , MonadIO (Performable m)
                , Eq tag
                , Hashable tag
                )
             => Proxy tag
             -> Proxy api
             -> EventsOut t tag api
             -> Queues tag api
             -> m ()


instance (Embed tag a, Embed tag b) =>
  Embed tag (a :<|> b) where

  type PayloadIn (a :<|> b) =
    Either (PayloadIn a) (PayloadIn b)

  type PayloadOut (a :<|> b) =
    Either (PayloadOut a) (PayloadOut b)

  type FireIn' tag h (a :<|> b) =
    FireIn' tag h a :<|>
    FireIn' tag h b

  type Queues tag (a :<|> b) =
    Queues tag a :<|> Queues tag b

  type TupleListConstraints h (a :<|> b) =
    (TupleListConstraints h a, TupleListConstraints h b)

  mkQueue pt _ =
    (:<|>) <$>
      mkQueue pt (Proxy :: Proxy a) <*>
      mkQueue pt (Proxy :: Proxy b)

  serve _ t h (fA :<|> fB) (qA :<|> qB) =
    serve (Proxy :: Proxy a) t h fA qA :<|>
    serve (Proxy :: Proxy b) t h fB qB

instance (EmbedEvents t tag a, EmbedEvents t tag b) =>
  EmbedEvents t tag (a :<|> b) where

  type PairIn' t tag h (a :<|> b) =
    PairIn' t tag h a :<|>
    PairIn' t tag h b

  type EventsIn' t tag h (a :<|> b) =
    EventsIn' t tag h a :<|>
    EventsIn' t tag h b

  type EventsOut t tag (a :<|> b) =
    EventsOut t tag a :<|> EventsOut t tag b

  mkPair pTag pH _ =
    (:<|>) <$>
      mkPair pTag pH (Proxy :: Proxy a) <*>
      mkPair pTag pH (Proxy :: Proxy b)

  splitPair pT pTag pH _ (pA :<|> pB) =
    let
      (fA, eA) = splitPair pT pTag pH (Proxy :: Proxy a) pA
      (fB, eB) = splitPair pT pTag pH (Proxy :: Proxy b) pB
    in
      (fA :<|> fB, eA :<|> eB)

  mkOut _ ee =
    let
      l (Left e)  = Just e
      l (Right _) = Nothing

      r (Right e) = Just e
      r (Left _)  = Nothing

      wrap (t, Just x)  = Just (t, x)
      wrap (_, Nothing) = Nothing
    in
      mkOut (Proxy :: Proxy a) (fmapMaybe (wrap . fmap l) ee) :<|>
      mkOut (Proxy :: Proxy b) (fmapMaybe (wrap . fmap r) ee)

  addToQueue pt _ (eoA :<|> eoB) (qA :<|> qB) = do
    addToQueue pt (Proxy :: Proxy a) eoA qA
    addToQueue pt (Proxy :: Proxy b) eoB qB

instance (KnownSymbol capture, FromHttpApiData a, Embed tag api) =>
  Embed tag (Capture capture a :> api)  where

  type PayloadIn (Capture capture a :> api) =
    (a, PayloadIn api)

  type PayloadOut (Capture capture a :> api) =
    PayloadOut api

  type FireIn' tag h (Capture capture a :> api) =
    FireIn' tag (a, h) api

  type Queues tag (Capture capture a :> api) =
    Queues tag api

  type TupleListConstraints h (Capture capture a :> api) =
    (TupleListConstraints (a, h) api)

  mkQueue pt _ =
    mkQueue pt (Proxy :: Proxy api)

  serve _ t h f q a =
    serve (Proxy :: Proxy api) t (a, h) f q

instance (KnownSymbol capture, FromHttpApiData a, EmbedEvents t tag api) =>
  EmbedEvents t tag (Capture capture a :> api)  where

  type PairIn' t tag h (Capture capture a :> api) =
    PairIn' t tag (a, h) api

  type EventsIn' t tag h (Capture capture a :> api) =
    EventsIn' t tag (a, h) api

  type EventsOut t tag (Capture capture a :> api) =
    EventsOut t tag api

  mkPair pTag (_ :: Proxy h) _ =
    mkPair pTag (Proxy :: Proxy (a, h)) (Proxy :: Proxy api)

  splitPair pT pTag (_ :: Proxy h) _ =
    splitPair pT pTag (Proxy :: Proxy (a, h)) (Proxy :: Proxy api)

  mkOut _ =
    mkOut (Proxy :: Proxy api)

  addToQueue pt _ =
    addToQueue pt (Proxy :: Proxy api)

instance (KnownSymbol capture, FromHttpApiData a, Embed tag api) =>
  Embed tag (CaptureAll capture a :> api) where

  type PayloadIn (CaptureAll capture a :> api) =
    ([a], PayloadIn api)

  type PayloadOut (CaptureAll capture a :> api) =
    PayloadOut api

  type FireIn' tag h (CaptureAll capture a :> api) =
    FireIn' tag ([a], h) api

  type Queues tag (CaptureAll capture a :> api) =
    Queues tag api

  type TupleListConstraints h (CaptureAll capture a :> api) =
    (TupleListConstraints ([a], h) api)

  mkQueue pt _ =
    mkQueue pt (Proxy :: Proxy api)

  serve _ t h f q a =
    serve (Proxy :: Proxy api) t (a, h) f q

instance (KnownSymbol capture, FromHttpApiData a, EmbedEvents t tag api) =>
  EmbedEvents t tag (CaptureAll capture a :> api) where

  type PairIn' t tag h (CaptureAll capture a :> api) =
    PairIn' t tag ([a], h) api

  type EventsIn' t tag h (CaptureAll capture a :> api) =
    EventsIn' t tag ([a], h) api

  type EventsOut t tag (CaptureAll capture a :> api) =
    EventsOut t tag api

  mkPair pTag (_ :: Proxy h) _ =
    mkPair pTag (Proxy :: Proxy ([a], h)) (Proxy :: Proxy api)

  splitPair pT pTag (_ :: Proxy h) _ =
    splitPair pT pTag (Proxy :: Proxy ([a], h)) (Proxy :: Proxy api)

  mkOut _ =
    mkOut (Proxy :: Proxy api)

  addToQueue pt _ =
    addToQueue pt (Proxy :: Proxy api)

instance (KnownSymbol sym, FromHttpApiData a, Embed tag api) =>
  Embed tag (Header sym a :> api) where

  type PayloadIn (Header sym a :> api) =
    (Maybe a, PayloadIn api)

  type PayloadOut (Header sym a :> api) =
    PayloadOut api

  type FireIn' tag h (Header sym a :> api) =
    FireIn' tag (Maybe a, h) api

  type Queues tag (Header sym a :> api) =
    Queues tag api

  type TupleListConstraints h (Header sym a :> api) =
    (TupleListConstraints (Maybe a, h) api)

  mkQueue pt _ =
    mkQueue pt (Proxy :: Proxy api)

  serve _ t h f q a =
    serve (Proxy :: Proxy api) t (a, h) f q

instance (KnownSymbol sym, FromHttpApiData a, EmbedEvents t tag api) =>
  EmbedEvents t tag (Header sym a :> api) where

  type PairIn' t tag h (Header sym a :> api) =
    PairIn' t tag (Maybe a, h) api

  type EventsIn' t tag h (Header sym a :> api) =
    EventsIn' t tag (Maybe a, h) api

  type EventsOut t tag (Header sym a :> api) =
    EventsOut t tag api

  mkPair pTag (_ :: Proxy h) _ =
    mkPair pTag (Proxy :: Proxy (Maybe a, h)) (Proxy :: Proxy api)

  splitPair pT pTag (_ :: Proxy h) _ =
    splitPair pT pTag (Proxy :: Proxy (Maybe a, h)) (Proxy :: Proxy api)

  mkOut _ =
    mkOut (Proxy :: Proxy api)

  addToQueue pt _ =
    addToQueue pt (Proxy :: Proxy api)

instance (KnownSymbol sym, FromHttpApiData a, Embed tag api) =>
  Embed tag (QueryParam sym a :> api) where

  type PayloadIn (QueryParam sym a :> api) =
    (Maybe a, PayloadIn api)

  type PayloadOut (QueryParam sym a :> api) =
    PayloadOut api

  type FireIn' tag h (QueryParam sym a :> api) =
    FireIn' tag ((Maybe a), h) api

  type Queues tag (QueryParam sym a :> api) =
    Queues tag api

  type TupleListConstraints h (QueryParam sym a :> api) =
    (TupleListConstraints (Maybe a, h) api)

  mkQueue pt _ =
    mkQueue pt (Proxy :: Proxy api)

  serve _ t h f q a =
    serve (Proxy :: Proxy api) t (a, h) f q

instance (KnownSymbol sym, FromHttpApiData a, EmbedEvents t tag api) =>
  EmbedEvents t tag (QueryParam sym a :> api) where

  type PairIn' t tag h (QueryParam sym a :> api) =
    PairIn' t tag ((Maybe a), h) api

  type EventsIn' t tag h (QueryParam sym a :> api) =
    EventsIn' t tag ((Maybe a), h) api

  type EventsOut t tag (QueryParam sym a :> api) =
    EventsOut t tag api

  mkPair pTag (_ :: Proxy h) _ =
    mkPair pTag (Proxy :: Proxy (Maybe a, h)) (Proxy :: Proxy api)

  splitPair pT pTag (_ :: Proxy h) _ =
    splitPair pT pTag (Proxy :: Proxy (Maybe a, h)) (Proxy :: Proxy api)

  mkOut _ =
    mkOut (Proxy :: Proxy api)

  addToQueue pt _ =
    addToQueue pt (Proxy :: Proxy api)

instance (KnownSymbol sym, FromHttpApiData a, Embed tag api) =>
  Embed tag (QueryParams sym a :> api) where

  type PayloadIn (QueryParams sym a :> api) =
    ([a], PayloadIn api)

  type PayloadOut (QueryParams sym a :> api) =
    PayloadOut api

  type FireIn' tag h (QueryParams sym a :> api) =
    FireIn' tag ([a], h) api

  type Queues tag (QueryParams sym a :> api) =
    Queues tag api

  type TupleListConstraints h (QueryParams sym a :> api) =
    (TupleListConstraints ([a], h) api)

  mkQueue pt _ =
    mkQueue pt (Proxy :: Proxy api)

  serve _ t h f q a =
    serve (Proxy :: Proxy api) t (a, h) f q

instance (KnownSymbol sym, FromHttpApiData a, EmbedEvents t tag api) =>
  EmbedEvents t tag (QueryParams sym a :> api) where

  type PairIn' t tag h (QueryParams sym a :> api) =
    PairIn' t tag ([a], h) api

  type EventsIn' t tag h (QueryParams sym a :> api) =
    EventsIn' t tag ([a], h) api

  type EventsOut t tag (QueryParams sym a :> api) =
    EventsOut t tag api

  mkPair pTag (_ :: Proxy h) _ =
    mkPair pTag (Proxy :: Proxy ([a], h)) (Proxy :: Proxy api)

  splitPair pT pTag (_ :: Proxy h) _ =
    splitPair pT pTag (Proxy :: Proxy ([a], h)) (Proxy :: Proxy api)

  mkOut _ =
    mkOut (Proxy :: Proxy api)

  addToQueue pt _ =
    addToQueue pt (Proxy :: Proxy api)

instance (KnownSymbol sym, Embed tag api) =>
  Embed tag (QueryFlag sym :> api) where

  type PayloadIn (QueryFlag sym :> api) =
    (Bool, PayloadIn api)

  type PayloadOut (QueryFlag sym :> api) =
    PayloadOut api

  type FireIn' tag h (QueryFlag sym :> api) =
    FireIn' tag (Bool, h) api

  type Queues tag (QueryFlag sym :> api) =
    Queues tag api

  type TupleListConstraints h (QueryFlag sym :> api) =
    (TupleListConstraints (Bool, h) api)

  mkQueue pt _ =
    mkQueue pt (Proxy :: Proxy api)

  serve _ t h f q a =
    serve (Proxy :: Proxy api) t (a, h) f q

instance (KnownSymbol sym, EmbedEvents t tag api) =>
  EmbedEvents t tag (QueryFlag sym :> api) where

  type PairIn' t tag h (QueryFlag sym :> api) =
    PairIn' t tag (Bool, h) api

  type EventsIn' t tag h (QueryFlag sym :> api) =
    EventsIn' t tag (Bool, h) api

  type EventsOut t tag (QueryFlag sym :> api) =
    EventsOut t tag api

  mkPair pTag (_ :: Proxy h) _ =
    mkPair pTag (Proxy :: Proxy (Bool, h)) (Proxy :: Proxy api)

  splitPair pT pTag (_ :: Proxy h) _ =
    splitPair pT pTag (Proxy :: Proxy (Bool, h)) (Proxy :: Proxy api)

  mkOut _ =
    mkOut (Proxy :: Proxy api)

  addToQueue pt _ =
    addToQueue pt (Proxy :: Proxy api)

instance (AllCTUnrender list a, Embed tag api) =>
  Embed tag (ReqBody list a :> api) where

  type PayloadIn (ReqBody list a :> api) =
    (a, PayloadIn api)

  type PayloadOut (ReqBody list a :> api) =
    PayloadOut api

  type FireIn' tag h (ReqBody list a :> api) =
    FireIn' tag (a, h) api

  type Queues tag (ReqBody list a :> api) =
    Queues tag api

  type TupleListConstraints h (ReqBody list a :> api) =
    (TupleListConstraints (a, h) api)

  mkQueue pt _ =
    mkQueue pt (Proxy :: Proxy api)

  serve _ t h f q a =
    serve (Proxy :: Proxy api) t (a, h) f q

instance (AllCTUnrender list a, EmbedEvents t tag api) =>
  EmbedEvents t tag (ReqBody list a :> api) where

  type PairIn' t tag h (ReqBody list a :> api) =
    PairIn' t tag (a, h) api

  type EventsIn' t tag h (ReqBody list a :> api) =
    EventsIn' t tag (a, h) api

  type EventsOut t tag (ReqBody list a :> api) =
    EventsOut t tag api

  mkPair pTag (_ :: Proxy h) _ =
    mkPair pTag (Proxy :: Proxy (a, h)) (Proxy :: Proxy api)

  splitPair pT pTag (_ :: Proxy h) _ =
    splitPair pT pTag (Proxy :: Proxy (a, h)) (Proxy :: Proxy api)

  mkOut _ =
    mkOut (Proxy :: Proxy api)

  addToQueue pt _ =
    addToQueue pt (Proxy :: Proxy api)

instance (KnownSymbol path, Embed tag api) =>
  Embed tag (path :> api) where

  type PayloadIn (path :> api) =
    PayloadIn api

  type PayloadOut (path :> api) =
    PayloadOut api

  type FireIn' tag h (path :> api) =
    FireIn' tag h api

  type Queues tag (path :> api) =
    Queues tag api

  type TupleListConstraints h (path :> api) =
    (TupleListConstraints h api)

  mkQueue pt _ =
    mkQueue pt (Proxy :: Proxy api)

  serve _  =
    serve (Proxy :: Proxy api)

instance (KnownSymbol path, EmbedEvents t tag api) =>
  EmbedEvents t tag (path :> api) where

  type PairIn' t tag h (path :> api) =
    PairIn' t tag h api

  type EventsIn' t tag h (path :> api) =
    EventsIn' t tag h api

  type EventsOut t tag (path :> api) =
    EventsOut t tag api

  mkPair pTag (_ :: Proxy h) _ =
    mkPair pTag (Proxy :: Proxy h) (Proxy :: Proxy api)

  splitPair pT pTag (_ :: Proxy h) _ =
    splitPair pT pTag (Proxy :: Proxy h) (Proxy :: Proxy api)

  mkOut _ =
    mkOut (Proxy :: Proxy api)

  addToQueue pt _ =
    addToQueue pt (Proxy :: Proxy api)

instance (Embed tag api) =>
  Embed tag (IsSecure :> api) where

  type PayloadIn (IsSecure :> api) =
    (IsSecure, PayloadIn api)

  type PayloadOut (IsSecure :> api) =
    PayloadOut api

  type FireIn' tag h (IsSecure :> api) =
    FireIn' tag (IsSecure, h) api

  type Queues tag (IsSecure :> api) =
    Queues tag api

  type TupleListConstraints h (IsSecure :> api) =
    (TupleListConstraints (IsSecure, h) api)

  mkQueue pt _ =
    mkQueue pt (Proxy :: Proxy api)

  serve _ t h f q a =
    serve (Proxy :: Proxy api) t (a, h) f q

instance (EmbedEvents t tag api) =>
  EmbedEvents t tag (IsSecure :> api) where

  type PairIn' t tag h (IsSecure :> api) =
    PairIn' t tag (IsSecure, h) api

  type EventsIn' t tag h (IsSecure :> api) =
    EventsIn' t tag (IsSecure, h) api

  type EventsOut t tag (IsSecure :> api) =
    EventsOut t tag api

  mkPair pTag (_ :: Proxy h) _ =
    mkPair pTag (Proxy :: Proxy (IsSecure, h)) (Proxy :: Proxy api)

  splitPair pT pTag (_ :: Proxy h) _ =
    splitPair pT pTag (Proxy :: Proxy (IsSecure, h)) (Proxy :: Proxy api)

  mkOut _ =
    mkOut (Proxy :: Proxy api)

  addToQueue pt _ =
    addToQueue pt (Proxy :: Proxy api)

instance (Embed tag api) =>
  Embed tag (HttpVersion :> api) where

  type PayloadIn (HttpVersion :> api) =
    (HttpVersion, PayloadIn api)

  type PayloadOut (HttpVersion :> api) =
    PayloadOut api

  type FireIn' tag h (HttpVersion :> api) =
    FireIn' tag (HttpVersion, h) api

  type Queues tag (HttpVersion :> api) =
    Queues tag api

  type TupleListConstraints h (HttpVersion :> api) =
    (TupleListConstraints (HttpVersion, h) api)

  mkQueue pt _ =
    mkQueue pt (Proxy :: Proxy api)

  serve _ t h f q a =
    serve (Proxy :: Proxy api) t (a, h) f q

instance (EmbedEvents t tag api) =>
  EmbedEvents t tag (HttpVersion :> api) where

  type PairIn' t tag h (HttpVersion :> api) =
    PairIn' t tag (HttpVersion, h) api

  type EventsIn' t tag h (HttpVersion :> api) =
    EventsIn' t tag (HttpVersion, h) api

  type EventsOut t tag (HttpVersion :> api) =
    EventsOut t tag api

  mkPair pTag (_ :: Proxy h) _ =
    mkPair pTag (Proxy :: Proxy (HttpVersion, h)) (Proxy :: Proxy api)

  splitPair pT pTag (_ :: Proxy h) _ =
    splitPair pT pTag (Proxy :: Proxy (HttpVersion, h)) (Proxy :: Proxy api)

  mkOut _ =
    mkOut (Proxy :: Proxy api)

  addToQueue pt _ =
    addToQueue pt (Proxy :: Proxy api)

instance (Embed tag api) =>
  Embed tag (RemoteHost :> api) where

  type PayloadIn (RemoteHost :> api) =
    (SockAddr, PayloadIn api)

  type PayloadOut (RemoteHost :> api) =
    PayloadOut api

  type FireIn' tag h (RemoteHost :> api) =
    FireIn' tag (SockAddr, h) api

  type Queues tag (RemoteHost :> api) =
    Queues tag api

  type TupleListConstraints h (RemoteHost :> api) =
    (TupleListConstraints (SockAddr, h) api)

  mkQueue pt _ =
    mkQueue pt (Proxy :: Proxy api)

  serve _ t h f q a =
    serve (Proxy :: Proxy api) t (a, h) f q

instance (EmbedEvents t tag api) =>
  EmbedEvents t tag (RemoteHost :> api) where

  type PairIn' t tag h (RemoteHost :> api) =
    PairIn' t tag (SockAddr, h) api

  type EventsIn' t tag h (RemoteHost :> api) =
    EventsIn' t tag (SockAddr, h) api

  type EventsOut t tag (RemoteHost :> api) =
    EventsOut t tag api

  mkPair pTag (_ :: Proxy h) _ =
    mkPair pTag (Proxy :: Proxy (SockAddr, h)) (Proxy :: Proxy api)

  splitPair pT pTag (_ :: Proxy h) _ =
    splitPair pT pTag (Proxy :: Proxy (SockAddr, h)) (Proxy :: Proxy api)

  mkOut _ =
    mkOut (Proxy :: Proxy api)

  addToQueue pt _ =
    addToQueue pt (Proxy :: Proxy api)

instance (Embed tag api) =>
  Embed tag (Vault :> api) where

  type PayloadIn (Vault :> api) =
    (Vault, PayloadIn api)

  type PayloadOut (Vault :> api) =
    PayloadOut api

  type FireIn' tag h (Vault :> api) =
    FireIn' tag (Vault, h) api

  type Queues tag (Vault :> api) =
    Queues tag api

  type TupleListConstraints h (Vault :> api) =
    (TupleListConstraints (Vault, h) api)

  mkQueue pt _ =
    mkQueue pt (Proxy :: Proxy api)

  serve _ t h f q a =
    serve (Proxy :: Proxy api) t (a, h) f q

instance (EmbedEvents t tag api) =>
  EmbedEvents t tag (Vault :> api) where

  type PairIn' t tag h (Vault :> api) =
    PairIn' t tag (Vault, h) api

  type EventsIn' t tag h (Vault :> api) =
    EventsIn' t tag (Vault, h) api

  type EventsOut t tag (Vault :> api) =
    EventsOut t tag api

  mkPair pTag (_ :: Proxy h) _ =
    mkPair pTag (Proxy :: Proxy (Vault, h)) (Proxy :: Proxy api)

  splitPair pT pTag (_ :: Proxy h) _ =
    splitPair pT pTag (Proxy :: Proxy (Vault, h)) (Proxy :: Proxy api)

  mkOut _ =
    mkOut (Proxy :: Proxy api)

  addToQueue pt _ =
    addToQueue pt (Proxy :: Proxy api)

instance (KnownSymbol realm, Embed tag api) =>
  Embed tag (BasicAuth realm usr :> api) where

  type PayloadIn (BasicAuth realm usr :> api) =
    (usr, PayloadIn api)

  type PayloadOut (BasicAuth realm usr :> api) =
    PayloadOut api

  type FireIn' tag h (BasicAuth realm usr :> api) =
    FireIn' tag (usr, h) api

  type Queues tag (BasicAuth realm usr :> api) =
    Queues tag api

  type TupleListConstraints h (BasicAuth realm usr :> api) =
    (TupleListConstraints (usr, h) api)

  mkQueue pt _ =
    mkQueue pt (Proxy :: Proxy api)

  serve _ t h f q a =
    serve (Proxy :: Proxy api) t (a, h) f q

instance (KnownSymbol realm, EmbedEvents t tag api) =>
  EmbedEvents t tag (BasicAuth realm usr :> api) where

  type PairIn' t tag h (BasicAuth realm usr :> api) =
    PairIn' t tag (usr, h) api

  type EventsIn' t tag h (BasicAuth realm usr :> api) =
    EventsIn' t tag (usr, h) api

  type EventsOut t tag (BasicAuth realm usr :> api) =
    EventsOut t tag api

  mkPair pTag (_ :: Proxy h) _ =
    mkPair pTag (Proxy :: Proxy (usr, h)) (Proxy :: Proxy api)

  splitPair pT pTag (_ :: Proxy h) _ =
    splitPair pT pTag (Proxy :: Proxy (usr, h)) (Proxy :: Proxy api)

  mkOut _ =
    mkOut (Proxy :: Proxy api)

  addToQueue pt _ =
    addToQueue pt (Proxy :: Proxy api)

instance (AllCTRender ctypes a, ReflectMethod method, KnownNat status) =>
  Embed tag (Verb (method :: k1) status ctypes a) where

  type PayloadIn (Verb method status ctypes a) =
    ()

  type PayloadOut (Verb method status ctypes a) =
    Either ServantErr a

  type FireIn' tag h (Verb method status ctypes a) =
    (tag, RevTupleListFlatten h) -> IO ()

  type Queues tag (Verb method status ctypes a) =
    SM.Map tag (Either ServantErr a)

  type TupleListConstraints h (Verb method status ctypes a) =
    TupleList h

  mkQueue _ _ =
    liftIO . atomically $ SM.empty

  serve _ t h f q = do
    res <- liftIO $ do
      f (t, revTupleListFlatten h)
      atomically $ do
        v <- SM.lookup t q
        case v of
          Just x -> do
            SM.delete t q
            return x
          Nothing ->
            retry
    case res of
      Left e -> throwError e
      Right x -> pure x

instance (AllCTRender ctypes a, ReflectMethod method, KnownNat status) =>
  EmbedEvents t tag (Verb (method :: k1) status ctypes a) where

  type PairIn' t tag h (Verb method status ctypes a) =
    (Event t (tag, RevTupleListFlatten h), (tag, RevTupleListFlatten h) -> IO ())

  type EventsIn' t tag h (Verb method status ctypes a) =
    Event t (tag, RevTupleListFlatten h)

  type EventsOut t tag (Verb method status ctypes a) =
    Event t (tag, Either ServantErr a)

  mkPair _ (_ :: Proxy h) _ =
    newTriggerEvent

  splitPair _ _ _ _ =
    id

  mkOut _ =
    id

  addToQueue _ _ eo q =
    let
      f (k, v) = liftIO . atomically $ SM.insert k v q
    in
      performEvent_ $ f <$> eo

class TupleList xs where
  type RevTupleListFlatten xs

  revTupleListFlatten :: xs -> RevTupleListFlatten xs

instance TupleList () where
  type RevTupleListFlatten () =
    ()

  revTupleListFlatten _ =
    ()

instance TupleList (a, ()) where
  type RevTupleListFlatten (a, ()) =
    a

  revTupleListFlatten (a, ()) =
    a

instance TupleList (a, (b, ())) where
  type RevTupleListFlatten (a, (b, ())) =
    (b, a)

  revTupleListFlatten (a, (b, ())) =
    (b, a)

instance TupleList (a, (b, (c, ()))) where
  type RevTupleListFlatten (a, (b, (c, ()))) =
    (c, b, a)

  revTupleListFlatten (a, (b, (c, ()))) =
    (c, b, a)

newtype Payload = Payload { value :: String }
  deriving (Eq, Ord, Show, Generic)

instance FromJSON Payload
instance ToJSON Payload

type MyAPI =
       "payloads" :> Get '[JSON] [Payload]
  :<|> "payloads" :> ReqBody '[JSON] Payload :> PostNoContent '[JSON] NoContent
  :<|> "payloads" :> Capture "index" Int :> DeleteNoContent '[JSON] NoContent

type TestAPI = "one" :> Capture "i1" Int :> TestAPI2
          :<|> "two" :> Capture "b1" Bool :> TestAPI2

type TestAPI2 = "three" :> Capture "i2" Int :> Get '[JSON] Int
           :<|> "four" :> Capture "b2" Bool :> Get '[JSON] Bool
