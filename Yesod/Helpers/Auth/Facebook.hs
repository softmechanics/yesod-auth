{-# LANGUAGE QuasiQuotes #-}
module Yesod.Helpers.Auth.Facebook
    ( authFacebook
    , facebookUrl
    ) where

import Yesod
import Yesod.Helpers.Auth
import qualified Web.Authenticate.Facebook as Facebook
import Data.Object (fromMapping, lookupScalar)
import Data.Maybe (fromMaybe)

facebookUrl :: AuthRoute
facebookUrl = PluginR "facebook" ["forward"]

authFacebook :: YesodAuth m
             => String -- ^ Application ID
             -> String -- ^ Application secret
             -> [String] -- ^ Requested permissions
             -> AuthPlugin m
authFacebook cid secret perms =
    AuthPlugin "facebook" dispatch login
  where
    url = PluginR "facebook" []
    dispatch "GET" ["forward"] = do
        tm <- getRouteToMaster
        render <- getUrlRender
        let fb = Facebook.Facebook cid secret $ render $ tm url
        redirectString RedirectTemporary $ Facebook.getForwardUrl fb perms
    dispatch "GET" [] = do
        render <- getUrlRender
        tm <- getRouteToMaster
        let fb = Facebook.Facebook cid secret $ render $ tm url
        code <- runFormGet' $ stringInput "code"
        at <- liftIO $ Facebook.getAccessToken fb code
        let Facebook.AccessToken at' = at
        so <- liftIO $ Facebook.getGraphData at "me"
        let c = fromMaybe (error "Invalid response from Facebook") $ do
            m <- fromMapping so
            id' <- lookupScalar "id" m
            let name = lookupScalar "name" m
            let email = lookupScalar "email" m
            let id'' = "http://graph.facebook.com/" ++ id'
            return
                $ Creds "facebook" id''
                $ maybe id (\x -> (:) ("verifiedEmail", x)) email
                $ maybe id (\x -> (:) ("displayName ", x)) name
                [ ("accessToken", at')
                ]
        setCreds True c
    dispatch _ _ = notFound
    login tm = do
        render <- liftHandler getUrlRender
        let fb = Facebook.Facebook cid secret $ render $ tm url
        let furl = Facebook.getForwardUrl fb $ perms
        addHtml [$hamlet|
%p
    %a!href=$furl$ Login with Facebook
|]
