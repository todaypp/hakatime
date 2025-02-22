{-# LANGUAGE MultiParamTypeClasses #-}

module Haka.Handlers.Badges
  ( API,
    server,
  )
where

import Control.Exception.Safe (throw, try)
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.ByteString as Bs
import qualified Data.UUID.Types as UUID
import Haka.App (AppCtx (..), AppM, ServerSettings (..))
import qualified Haka.Database as Db
import qualified Haka.Errors as Err
import Haka.Types (ApiToken (..), BadgeRow (..))
import Haka.Utils (compoundDuration)
import Network.HTTP.Client
import Network.HTTP.Client.TLS
import Network.HTTP.Media ((//))
import qualified Relude.Unsafe as Unsafe
import Servant

-- SVG MIME type.
data SVG

instance Accept SVG where
  contentType _ = "image" // "svg+xml"

instance MimeRender SVG Bs.ByteString where
  mimeRender _ = fromStrict

type API = GetBadgeLink :<|> GetBadgeSvg

server ::
  (Text -> Maybe ApiToken -> AppM BadgeResponse)
    :<|> (UUID.UUID -> Maybe Int64 -> AppM Bs.ByteString)
server = badgeLinkHandler :<|> badgeSvgHandler

newtype BadgeResponse = BadgeResponse
  { badgeUrl :: Text
  }
  deriving (Generic, Show)

instance FromJSON BadgeResponse

instance ToJSON BadgeResponse

type GetBadgeLink =
  "badge"
    :> "link"
    :> Capture "project" Text
    :> Header "Authorization" ApiToken
    :> Get '[JSON] BadgeResponse

type GetBadgeSvg =
  "badge"
    :> "svg"
    :> Capture "svg" UUID.UUID
    :> QueryParam "days" Int64
    :> Get '[SVG] Bs.ByteString

badgeLinkHandler :: Text -> Maybe ApiToken -> AppM BadgeResponse
badgeLinkHandler _ Nothing = throw Err.missingAuthError
badgeLinkHandler proj (Just tkn) = do
  p <- asks pool
  ss <- asks srvSettings
  res <- try $ liftIO $ Db.mkBadgeLink p proj tkn

  badgeId <- either Err.logError pure res

  return $
    BadgeResponse
      { badgeUrl = decodeUtf8 (hakaBadgeUrl ss) <> "/badge/svg/" <> UUID.toText badgeId
      }

badgeSvgHandler :: UUID.UUID -> Maybe Int64 -> AppM Bs.ByteString
badgeSvgHandler badgeId daysParam = do
  p <- asks pool

  badgeInfoResult <- try $ liftIO $ Db.getBadgeLinkInfo p badgeId

  badgeRow <- either Err.logError pure badgeInfoResult

  timeResult <-
    try $
      liftIO $
        Db.getTotalActivityTime
          p
          (badgeUsername badgeRow)
          (fromMaybe 7 daysParam)
          (badgeProject badgeRow)

  activityTime <- either Err.logError pure timeResult

  ss <- asks srvSettings

  manager <- liftIO $ newManager tlsManagerSettings
  request <-
    parseRequest
      ( hakaShieldsIOUrl ss
          <> "/static/v1?"
          <> "label="
          <> toString (badgeProject badgeRow)
          <> ("&message=" :: String)
          <> toString (compoundDuration activityTime)
          <> "&color=blue"
      )
  response <- liftIO $ httpLbs request manager

  return $ toStrict $ responseBody response
