{-# LANGUAGE OverloadedStrings                        #-}
{-# LANGUAGE ScopedTypeVariables                      #-}

module Thentos.FrontendSpec where

import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import Data.Acid.Advanced (query')
import Data.Either (isRight)
import Data.String.Conversions (ST, cs)
import Test.Hspec (Spec, SpecWith, describe, it, before, after, shouldBe, shouldSatisfy, hspec)
import Text.Regex.Easy ((=~#))

import qualified Data.Map as Map
import qualified Test.WebDriver as WD
import qualified Test.WebDriver.Class as WD

import Thentos.Config
import Thentos.DB.Protect
import Thentos.DB.Trans
import Thentos.Frontend (urlSignupConfirm)
import Thentos.Types

import Test.Arbitrary ()
import Test.Util


tests :: IO ()
tests = hspec spec

spec :: Spec
spec = describe "selenium (consult README.md if this test fails)"
           . before setupTestServerFull . after teardownTestServerFull $ do
    resetPassword


resetPassword :: SpecWith TestServerFull
resetPassword = it "reset password" $ \ ((st, _, _), _, (_, feConfig), wd) -> do
    let myUsername = "username"
        myPassword = "password"
        myEmail    = "email@example.com"

    -- create confirmation token
    wd $ do
        WD.openPage (cs $ exposeUrl feConfig)
        WD.findElem (WD.ByLinkText "create_user") >>= WD.click

        let fill :: WD.WebDriver wd => ST -> ST -> wd ()
            fill label text = WD.findElem (WD.ById label) >>= WD.sendKeys text

        fill "create_user.name" myUsername
        fill "create_user.password1" myPassword
        fill "create_user.password2" myPassword
        fill "create_user.email" myEmail

        WD.findElem (WD.ById "create_user_submit") >>= WD.click
        WD.getSource >>= \ s -> liftIO $ (cs s) `shouldSatisfy` (=~# "Please check your email")

    -- check that confirmation token is in DB.
    Right (db1 :: DB) <- query' st $ SnapShot allowEverything
    Map.size (db1 ^. dbUnconfirmedUsers) `shouldBe` 1

    -- click activation link.  (it would be nice if we
    -- somehow had the email here to extract the link from
    -- there, but we don't.)
    case Map.toList $ db1 ^. dbUnconfirmedUsers of
          [(tok, _)] -> wd $ do
              WD.openPage . cs $ urlSignupConfirm feConfig tok
              WD.getSource >>= \ s -> liftIO $ cs s `shouldSatisfy` (=~# "Added a user!")
          bad -> error $ "dbUnconfirmedUsers: " ++ show bad

    -- check that user has arrived in DB.
    Right (db2 :: DB) <- query' st $ SnapShot allowEverything
    Map.size (db2 ^. dbUnconfirmedUsers) `shouldBe` 0
    eUser <- query' st $ LookupUserByName (UserName myUsername) allowEverything
    eUser `shouldSatisfy` isRight
