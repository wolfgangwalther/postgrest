{-|
Module      : PostgREST.Auth
Description : PostgREST authorization functions.

This module provides functions to deal with the JWT authorization (http://jwt.io).
It also can be used to define other authorization functions,
in the future Oauth, LDAP and similar integrations can be coded here.

Authentication should always be implemented in an external service.
In the test suite there is an example of simple login function that can be used for a
very simple authentication system inside the PostgreSQL database.
-}
{-# LANGUAGE RecordWildCards #-}
module PostgREST.Auth
  ( containsRole
  , jwtClaims
  , JWTClaims
  ) where

import qualified Crypto.JWT          as JWT
import qualified Data.Aeson          as JSON
import qualified Data.HashMap.Strict as M
import qualified Data.Vector         as V

import Control.Lens            (set)
import Control.Monad.Except    (liftEither)
import Data.Either.Combinators (mapLeft)
import Data.Time.Clock         (UTCTime)

import PostgREST.Config (AppConfig (..), JSPath, JSPathExp (..))
import PostgREST.Error  (Error (..))

import Protolude


type JWTClaims = M.HashMap Text JSON.Value

-- | Receives the JWT secret and audience (from config) and a JWT and returns a
-- map of JWT claims.
jwtClaims :: Monad m =>
  AppConfig -> LByteString -> UTCTime -> ExceptT Error m JWTClaims
jwtClaims _ "" _ = return M.empty
jwtClaims AppConfig{..} payload time = do
  secret <- liftEither . maybeToRight JwtTokenMissing $ configJWKS
  eitherClaims <-
    lift . runExceptT $
      JWT.verifyClaimsAt validation secret time =<< JWT.decodeCompact payload
  liftEither . mapLeft jwtClaimsError $ claimsMap configJwtRoleClaimKey <$> eitherClaims
  where
    validation =
      JWT.defaultJWTValidationSettings audienceCheck & set JWT.allowedSkew 1

    audienceCheck :: JWT.StringOrURI -> Bool
    audienceCheck = maybe (const True) (==) configJwtAudience

    jwtClaimsError :: JWT.JWTError -> Error
    jwtClaimsError JWT.JWTExpired = JwtTokenInvalid "JWT expired"
    jwtClaimsError e              = JwtTokenInvalid $ show e

-- | Turn JWT ClaimSet into something easier to work with.
--
-- Also, here the jspath is applied to put the "role" in the map.
claimsMap :: JSPath -> JWT.ClaimsSet -> JWTClaims
claimsMap jspath claims =
  case JSON.toJSON claims of
    val@(JSON.Object o) ->
      M.delete "role" o `M.union` role val
    _ ->
      M.empty
  where
    role value =
      maybe M.empty (M.singleton "role") $ walkJSPath (Just value) jspath

    walkJSPath :: Maybe JSON.Value -> JSPath -> Maybe JSON.Value
    walkJSPath x                      []                = x
    walkJSPath (Just (JSON.Object o)) (JSPKey key:rest) = walkJSPath (M.lookup key o) rest
    walkJSPath (Just (JSON.Array ar)) (JSPIdx idx:rest) = walkJSPath (ar V.!? idx) rest
    walkJSPath _                      _                 = Nothing

-- | Whether a response from jwtClaims contains a role claim
containsRole :: JWTClaims -> Bool
containsRole = M.member "role"
