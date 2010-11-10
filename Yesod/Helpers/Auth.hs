{-# LANGUAGE QuasiQuotes, TypeFamilies, TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
module Yesod.Helpers.Auth
    ( -- * Subsite
      Auth
    , AuthPlugin (..)
    , AuthRoute
    , Route (..)
    , getAuth
    , YesodAuth (..)
      -- * Plugin interface
    , Creds (..)
    , setCreds
      -- * User functions
    , maybeAuthId
    , maybeAuth
    , requireAuthId
    , requireAuth
    ) where

import Yesod
import Language.Haskell.TH.Syntax hiding (lift)
import qualified Data.ByteString.Char8 as S8
import qualified Network.Wai as W

data Auth = Auth

type Method = String
type Piece = String

data AuthPlugin m = AuthPlugin
    { apName :: String
    , apDispatch :: Method -> [Piece] -> GHandler Auth m ()
    , apLogin :: forall s. (Route Auth -> Route m) -> GWidget s m ()
    }

getAuth :: a -> Auth
getAuth = const Auth

-- | User credentials
data Creds m = Creds
    { credsPlugin :: String -- ^ How the user was authenticated
    , credsIdent :: String -- ^ Identifier. Exact meaning depends on plugin.
    , credsExtra :: [(String, String)]
    }

class Yesod m => YesodAuth m where
    type AuthId m

    -- | Default destination on successful login, if no other
    -- destination exists.
    loginDest :: m -> Route m

    -- | Default destination on successful logout, if no other
    -- destination exists.
    logoutDest :: m -> Route m

    getAuthId :: Creds m -> GHandler s m (Maybe (AuthId m))

    showAuthId :: m -> AuthId m -> String
    readAuthId :: m -> String -> Maybe (AuthId m)

    authPlugins :: [AuthPlugin m]

    -- | What to show on the login page.
    loginHandler :: GHandler Auth m RepHtml
    loginHandler = defaultLayout $ do
        setTitle $ string "Login"
        tm <- liftHandler getRouteToMaster
        mapM_ (flip apLogin tm) authPlugins

mkYesodSub "Auth"
    [ ClassP ''YesodAuth [VarT $ mkName "master"]
    ] [$parseRoutes|
/check                 CheckR      GET
/login                 LoginR      GET
/logout                LogoutR     GET POST
/page/#String/*Strings PluginR
|]

credsKey :: String
credsKey = "_ID"

-- | FIXME: won't show up till redirect
setCreds :: YesodAuth m => Bool -> Creds m -> GHandler s m ()
setCreds doRedirects creds = do
    y <- getYesod
    maid <- getAuthId creds
    case maid of
        Nothing ->
            if doRedirects
                then do
                    case authRoute y of
                        Nothing -> do
                            rh <- defaultLayout [$hamlet|%h1 Invalid login|]
                            sendResponse rh
                        Just ar -> do
                            setMessage $ string "Invalid login"
                            redirect RedirectTemporary ar
                else return ()
        Just aid -> do
            setSession credsKey $ showAuthId y aid
            if doRedirects
                then do
                    setMessage $ string "You are now logged in"
                    redirect RedirectTemporary $ loginDest y
                else return ()

getCheckR :: YesodAuth m => GHandler Auth m RepHtmlJson
getCheckR = do
    creds <- maybeAuthId
    defaultLayoutJson (do
        setTitle $ string "Authentication Status"
        addHtml $ html creds) (json creds)
  where
    html creds = [$hamlet|
%h1 Authentication Status
$maybe creds _
    %p Logged in.
$nothing
    %p Not logged in.
|]
    json creds =
        jsonMap
            [ ("logged_in", jsonScalar $ maybe "false" (const "true") creds)
            ]

getLoginR :: YesodAuth m => GHandler Auth m RepHtml
getLoginR = loginHandler

getLogoutR :: YesodAuth m => GHandler Auth m ()
getLogoutR = postLogoutR -- FIXME redirect to post

postLogoutR :: YesodAuth m => GHandler Auth m ()
postLogoutR = do
    y <- getYesod
    deleteSession credsKey
    redirectUltDest RedirectTemporary $ logoutDest y

handlePluginR :: YesodAuth m => String -> [String] -> GHandler Auth m ()
handlePluginR plugin pieces = do
    env <- waiRequest
    let method = S8.unpack $ W.requestMethod env
    case filter (\x -> apName x == plugin) authPlugins of
        [] -> notFound
        ap:_ -> apDispatch ap method pieces

-- | Retrieves user credentials, if user is authenticated.
maybeAuthId :: YesodAuth m => GHandler s m (Maybe (AuthId m))
maybeAuthId = do
    ms <- lookupSession credsKey
    y <- getYesod
    case ms of
        Nothing -> return Nothing
        Just s -> return $ readAuthId y s

maybeAuth :: ( YesodAuth m
             , Key val ~ AuthId m
             , PersistBackend (YesodDB m (GHandler s m))
             , PersistEntity val
             , YesodPersist m
             ) => GHandler s m (Maybe (Key val, val))
maybeAuth = do
    maid <- maybeAuthId
    case maid of
        Nothing -> return Nothing
        Just aid -> do
            ma <- runDB $ get aid
            case ma of
                Nothing -> return Nothing
                Just a -> return $ Just (aid, a)

requireAuthId :: YesodAuth m => GHandler s m (AuthId m)
requireAuthId = maybeAuthId >>= maybe redirectLogin return

requireAuth :: ( YesodAuth m
               , Key val ~ AuthId m
               , PersistBackend (YesodDB m (GHandler s m))
               , PersistEntity val
               , YesodPersist m
               ) => GHandler s m (Key val, val)
requireAuth = maybeAuth >>= maybe redirectLogin return

redirectLogin :: Yesod m => GHandler s m a
redirectLogin = do
    y <- getYesod
    setUltDest'
    case authRoute y of
        Just z -> redirect RedirectTemporary z
        Nothing -> permissionDenied "Please configure authRoute"
