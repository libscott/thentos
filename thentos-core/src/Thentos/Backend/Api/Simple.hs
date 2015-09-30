{-# LANGUAGE DataKinds                                #-}
{-# LANGUAGE ExistentialQuantification                #-}
{-# LANGUAGE FlexibleContexts                         #-}
{-# LANGUAGE FlexibleInstances                        #-}
{-# LANGUAGE GADTs                                    #-}
{-# LANGUAGE InstanceSigs                             #-}
{-# LANGUAGE MultiParamTypeClasses                    #-}
{-# LANGUAGE OverloadedStrings                        #-}
{-# LANGUAGE RankNTypes                               #-}
{-# LANGUAGE ScopedTypeVariables                      #-}
{-# LANGUAGE TupleSections                            #-}
{-# LANGUAGE TypeFamilies                             #-}
{-# LANGUAGE TypeOperators                            #-}
{-# LANGUAGE TypeSynonymInstances                     #-}
{-# LANGUAGE UndecidableInstances                     #-}

module Thentos.Backend.Api.Simple where

import Control.Lens ((^.))
import Data.Proxy (Proxy(Proxy))
import Data.Void (Void)
import Network.Wai (Application)
import Servant.API ((:<|>)((:<|>)), (:>), Get, Post, Delete, Capture, ReqBody, JSON, Raw)
import Servant.Server (ServerT, Server, serve, enter)
import Servant.Utils.StaticFiles (serveDirectory)
import System.Log.Logger (Priority(INFO))

import System.Log.Missing (logger)
import Thentos.Action
import Thentos.Action.Core (ActionState, Action)
import Thentos.Backend.Api.Auth
import Thentos.Backend.Core
import Thentos.Config
import Thentos.Types
import Thentos.Util (getJsDir)


-- * main

runApi :: HttpConfig -> ActionState -> IO ()
runApi cfg asg = do
    jsDir <- getJsDir
    logger INFO $ "running rest api Thentos.Backend.Api.Simple on " ++ show (bindUrl cfg) ++ "."
    runWarpWithCfg cfg $ serveApi asg jsDir

serveApi :: ActionState -> FilePath -> Application
serveApi actionState jsDir = addCacheControlHeaders . serve (Proxy :: Proxy Api) $ api actionState jsDir

type Api =
         (ThentosAssertHeaders :> ThentosAuth :> ThentosBasic)
    :<|> ("js" :> ThentosFrontend)

api :: ActionState -> FilePath -> Server Api
api actionState basePath = (\mTok -> enter (enterAction actionState baseActionErrorToServantErr mTok) thentosBasic) :<|> thentosFrontend basePath


-- * combinators

type ThentosBasic =
       "user" :> ThentosUser
  :<|> "service" :> ThentosService
  :<|> "thentos_session" :> ThentosThentosSession
  :<|> "service_session" :> ThentosServiceSession

thentosBasic :: ServerT ThentosBasic (Action Void)
thentosBasic =
       thentosUser
  :<|> thentosService
  :<|> thentosThentosSession
  :<|> thentosServiceSession


-- * user

type ThentosUser =
       ReqBody '[JSON] UserFormData :> Post '[JSON] UserId
  :<|> "login" :> ReqBody '[JSON] LoginFormData :> Post '[JSON] ThentosSessionToken
  :<|> Capture "uid" UserId :> Delete '[JSON] ()
  :<|> Capture "uid" UserId :> "name" :> Get '[JSON] UserName
  :<|> Capture "uid" UserId :> "email" :> Get '[JSON] UserEmail

thentosUser :: ServerT ThentosUser (Action Void)
thentosUser =
       addUser
  :<|> (\ (LoginFormData n p) -> snd <$> startThentosSessionByUserName n p)
  :<|> deleteUser
  :<|> (((^. userName) . snd) <$>) . lookupConfirmedUser
  :<|> (((^. userEmail) . snd) <$>) . lookupConfirmedUser


-- * service

type ThentosService =
       ReqBody '[JSON] (UserId, ServiceName, ServiceDescription) :> Post '[JSON] (ServiceId, ServiceKey)
           -- FIXME: it would be much nicer to infer the owner from
           -- the session token, but that requires changes to the
           -- various action monads we are kicking around all over the
           -- place.  coming up soon!

  :<|> Capture "sid" ServiceId :> Delete '[JSON] ()
  :<|> Get '[JSON] [ServiceId]

thentosService :: ServerT ThentosService (Action Void)
thentosService =
         (\ (uid, sn, sd) -> addService (UserA uid) sn sd)
    :<|> deleteService
    :<|> allServiceIds


-- * session

type ThentosThentosSession =
       ReqBody '[JSON] ByUserOrServiceId   :> Post '[JSON] ThentosSessionToken
  :<|> ReqBody '[JSON] ThentosSessionToken :> Get '[JSON] Bool
  :<|> ReqBody '[JSON] ThentosSessionToken :> Delete '[JSON] ()

thentosThentosSession :: ServerT ThentosThentosSession (Action Void)
thentosThentosSession =
       startThentosSession
  :<|> existsThentosSession
  :<|> endThentosSession
  where startThentosSession (ByUser (id', pass)) = startThentosSessionByUserId id' pass
        startThentosSession (ByService (id', key)) = startThentosSessionByServiceId id' key


-- * service session

type ThentosServiceSession =
       ReqBody '[JSON] ServiceSessionToken :> Get '[JSON] Bool
  :<|> ReqBody '[JSON] ServiceSessionToken :> "meta" :> Get '[JSON] ServiceSessionMetadata
  :<|> ReqBody '[JSON] ServiceSessionToken :> Delete '[JSON] ()

thentosServiceSession :: ServerT ThentosServiceSession (Action Void)
thentosServiceSession =
       existsServiceSession
  :<|> getServiceSessionMetadata
  :<|> endServiceSession


-- * frontend

type ThentosFrontend = Raw

thentosFrontend :: FilePath -> Server ThentosFrontend
thentosFrontend = serveDirectory
