{-# LANGUAGE BlockArguments #-}

module Haka.Database
  ( processHeartbeatRequest,
    importHeartbeats,
    Db (..),
    getUserByToken,
    validateUserAndProject,
    validateUserAndTag,
    mkBadgeLink,
    getApiTokens,
    deleteApiToken,
    genProjectStatistics,
    getTimeline,
    createNewApiToken,
    clearTokens,
    generateStatistics,
    DatabaseException (..),
    createAuthTokens,
    refreshAuthTokens,
    getUserTags,
    getUserProjects,
  )
where

import Control.Exception.Safe (MonadThrow, throw)
import Data.Aeson as A
import Data.Time.Clock (UTCTime)
import qualified Data.Vector as V
import qualified Haka.Db.Sessions as Sessions
import Haka.Errors (DatabaseException (..))
import qualified Haka.PasswordUtils as PUtils
import Haka.Types
  ( ApiToken (..),
    BadgeRow (..),
    HeartbeatPayload (..),
    LeaderboardRow (..),
    Project (..),
    ProjectStatRow (..),
    StatRow (..),
    StoredApiToken,
    StoredUser (..),
    Tag (..),
    TimelineRow (..),
    TokenData (..),
    TokenMetadata (..),
  )
import qualified Haka.Utils as Utils
import qualified Hasql.Pool as HqPool
import PostgreSQL.Binary.Data (UUID)

data OperationError = UsageError | Text
  deriving (Show)

class (Monad m, MonadThrow m) => Db m where
  -- | Given an Api token return the user that it belongs to.
  getUser :: HqPool.Pool -> ApiToken -> m (Maybe Text)

  -- | Given a refresh token return the user that it belongs to.
  getUserByRefreshToken :: HqPool.Pool -> Text -> m (Maybe Text)

  -- | Check if the credentials are valid.
  validateCredentials :: HqPool.Pool -> Text -> Text -> m (Maybe Text)

  -- | Store the given heartbeats in the Db and return their IDs.
  saveHeartbeats :: HqPool.Pool -> [HeartbeatPayload] -> m [Int64]

  -- | Retrieve a list of statistics within the given time range.
  getTotalStats :: HqPool.Pool -> Text -> (UTCTime, UTCTime) -> Maybe Text -> Int64 -> m [StatRow]

  -- | Retrieve the activity timeline for a period of time.
  getTimelineStats :: HqPool.Pool -> Text -> (UTCTime, UTCTime) -> Int64 -> m [TimelineRow]

  -- | Retrieve a list of statistics within the given time range.
  getProjectStats :: HqPool.Pool -> Text -> Text -> (UTCTime, UTCTime) -> Int64 -> m [ProjectStatRow]

  -- | Retrieve a list of aggregated statistics for a tag within the given time range.
  getTagStats :: HqPool.Pool -> Text -> Text -> (UTCTime, UTCTime) -> Int64 -> m [ProjectStatRow]

  -- | Create a pair of an access token a refresh token for use on web interface.
  createWebToken :: HqPool.Pool -> Text -> Int64 -> m TokenData

  -- | Register a new user.
  registerUser :: HqPool.Pool -> Text -> Text -> Int64 -> m TokenData

  -- | Delete the given auth and refresh tokens from the Db.
  deleteTokens :: HqPool.Pool -> ApiToken -> Text -> m Int64

  -- | Create a new API token that can be used on the client (no expiry date).
  createAPIToken :: HqPool.Pool -> Text -> m Text

  -- | Return a list of active API tokens.
  listApiTokens :: HqPool.Pool -> Text -> m [StoredApiToken]

  -- | Delete an API token.
  deleteToken :: HqPool.Pool -> ApiToken -> m ()

  -- | Update the last used timestamp for the token.
  updateTokenUsage :: HqPool.Pool -> ApiToken -> m ()

  -- | Get the total number of seconds spent on a given user/project combination.
  getTotalActivityTime :: HqPool.Pool -> Text -> Int64 -> Text -> m (Maybe Int64)

  -- | Create a unique badge link for the user/project combination.
  createBadgeLink :: HqPool.Pool -> Text -> Text -> m UUID

  -- | Find the user/project combination from the badge id.
  getBadgeLinkInfo :: HqPool.Pool -> UUID -> m BadgeRow

  -- | Get the status of a queue item.
  getJobStatus :: HqPool.Pool -> A.Value -> m (Maybe Text)

  -- | Delete stale failed jobs.
  deleteFailedJobs :: HqPool.Pool -> A.Value -> m Int64

  -- | Attach the given tags to a project.
  setTags :: HqPool.Pool -> StoredUser -> Project -> V.Vector Text -> m Int64

  -- | Get the tags associated with a project.
  getTags :: HqPool.Pool -> StoredUser -> Project -> m (V.Vector Text)

  -- | Get all the tags associated with a user.
  getAllTags :: HqPool.Pool -> StoredUser -> m (V.Vector Text)

  -- | Get all the projects of a user.
  getAllProjects :: HqPool.Pool -> StoredUser -> UTCTime -> UTCTime -> m (V.Vector Text)

  -- | Validate that a project has the given owner.
  checkProjectOwner :: HqPool.Pool -> StoredUser -> Project -> m Bool

  -- | Validate that a user has the given tag.
  checkTagOwner :: HqPool.Pool -> StoredUser -> Tag -> m Bool

  -- | Extract leaderboard information
  getLeaderboards :: HqPool.Pool -> UTCTime -> UTCTime -> m [LeaderboardRow]

  -- | Get total time between the given time ranges.
  getTotalTimeBetween :: HqPool.Pool -> V.Vector (Text, Text, UTCTime, UTCTime) -> m [Int64]

  -- | Get total coding time of the current day.
  getTotalTimeToday :: HqPool.Pool -> Text -> m Int64

  -- | Update token metadata set by the user.
  updateTokenMetadata :: HqPool.Pool -> Text -> TokenMetadata -> m ()

instance Db IO where
  getUser pool token = do
    res <- HqPool.use pool (Sessions.getUser token)
    either (throw . SessionException) pure res
  getUserByRefreshToken pool token = do
    res <- HqPool.use pool (Sessions.getUserByRefreshToken token)
    either (throw . SessionException) pure res
  validateCredentials pool user passwd = do
    res <- HqPool.use pool (Sessions.validateUser PUtils.validatePassword user passwd)
    either
      (throw . SessionException)
      ( \isValid -> if isValid then pure $ Just user else pure Nothing
      )
      res
  saveHeartbeats pool heartbeats = do
    res <- HqPool.use pool (Sessions.saveHeartbeats heartbeats)
    either (throw . SessionException) pure res
  getTotalStats pool user trange tagName cutOffLimit = do
    res <- HqPool.use pool (Sessions.getTotalStats user trange tagName cutOffLimit)
    either (throw . SessionException) pure res
  getTimelineStats pool user trange cutOffLimit = do
    res <- HqPool.use pool (Sessions.getTimeline user trange cutOffLimit)
    either (throw . SessionException) pure res
  getProjectStats pool user proj trange cutOffLimit = do
    res <- HqPool.use pool (Sessions.getProjectStats user proj trange cutOffLimit)
    either (throw . SessionException) pure res
  getTagStats pool user tag trange cutOffLimit = do
    res <- HqPool.use pool (Sessions.getTagStats user tag trange cutOffLimit)
    either (throw . SessionException) pure res
  deleteTokens pool token refreshToken = do
    res <- HqPool.use pool (Sessions.deleteTokens token refreshToken)
    either (throw . SessionException) pure res
  createAPIToken pool user = do
    res <- HqPool.use pool (Sessions.createAPIToken user)
    either (throw . SessionException) pure res
  createWebToken pool user expiry = do
    tknData <- mkTokenData user
    res <- HqPool.use pool (Sessions.createAccessTokens expiry tknData)
    whenLeft tknData res (throw . SessionException)
  registerUser pool user passwd expiry = do
    tknData <- mkTokenData user
    hashUser <- PUtils.mkUser user passwd
    case hashUser of
      Left err -> throw $ RegistrationFailed (show err)
      Right hashUser' -> do
        u <- PUtils.createUser pool hashUser'
        case u of
          Left e -> throw $ OperationException (Utils.toStrError e)
          Right userCreated ->
            if userCreated
              then do
                res <- HqPool.use pool (Sessions.createAccessTokens expiry tknData)
                whenLeft tknData res (throw . SessionException)
              else throw $ UsernameExists user
  listApiTokens pool user = do
    res <- HqPool.use pool (Sessions.listApiTokens user)
    either (throw . SessionException) pure res
  deleteToken pool tkn = do
    res <- HqPool.use pool (Sessions.deleteToken tkn)
    either (throw . SessionException) pure res
  updateTokenUsage pool (ApiToken tkn) = do
    res <- HqPool.use pool (Sessions.updateTokenUsage tkn)
    either (throw . SessionException) pure res
  getTotalActivityTime pool user days proj = do
    res <- HqPool.use pool (Sessions.getTotalActivityTime user days proj)
    either (throw . SessionException) pure res
  createBadgeLink pool user proj = do
    res <- HqPool.use pool (Sessions.createBadgeLink user proj)
    either (throw . SessionException) pure res
  getBadgeLinkInfo pool badgeId = do
    res <- HqPool.use pool (Sessions.getBadgeLinkInfo badgeId)
    either (throw . SessionException) pure res
  getJobStatus pool payload = do
    res <- HqPool.use pool (Sessions.getJobStatus payload)
    either (throw . SessionException) pure res
  deleteFailedJobs pool payload = do
    res <- HqPool.use pool (Sessions.deleteFailedJobs payload)
    either (throw . SessionException) pure res
  setTags pool user projectName tags = do
    res <- HqPool.use pool (Sessions.setTags user projectName tags)
    either (throw . SessionException) pure res
  getTags pool user projectName = do
    res <- HqPool.use pool (Sessions.getTags user projectName)
    either (throw . SessionException) pure res
  getAllTags pool user = do
    res <- HqPool.use pool (Sessions.getAllTags user)
    either (throw . SessionException) pure res
  getAllProjects pool user t0 t1 = do
    res <- HqPool.use pool (Sessions.getAllProjects user t0 t1)
    either (throw . SessionException) pure res
  checkProjectOwner pool user projectName = do
    res <- HqPool.use pool (Sessions.checkProjectOwner user projectName)
    either (throw . SessionException) pure res
  checkTagOwner pool user tag = do
    res <- HqPool.use pool (Sessions.checkTagOwner user tag)
    either (throw . SessionException) pure res
  getLeaderboards pool t0 t1 = do
    res <- HqPool.use pool (Sessions.getLeaderboards t0 t1)
    either (throw . SessionException) pure res
  getTotalTimeBetween pool ranges = do
    -- We return in reverse order because we insert with descending but we sort in ascending.
    res <- HqPool.use pool (Sessions.getTotalTimeBetween ranges)
    either (throw . SessionException) (pure . reverse) res
  getTotalTimeToday pool user = do
    res <- HqPool.use pool (Sessions.getTotalTimeToday user)
    either (throw . SessionException) pure res
  updateTokenMetadata pool user metadata = do
    res <- HqPool.use pool (Sessions.updateTokenMetadata user metadata)
    either (throw . SessionException) pure res

mkTokenData :: Text -> IO TokenData
mkTokenData user = do
  refreshToken <- Utils.toBase64 <$> Utils.randomToken
  token <- Utils.toBase64 <$> Utils.randomToken
  pure $
    TokenData
      { tknOwner = user,
        tknToken = token,
        tknRefreshToken = refreshToken
      }

processHeartbeatRequest :: Db m => HqPool.Pool -> ApiToken -> [HeartbeatPayload] -> m [Int64]
processHeartbeatRequest pool token heartbeats = do
  retrievedUser <- getUser pool token
  case retrievedUser of
    Nothing -> throw UnknownApiToken
    Just userName -> do
      updateTokenUsage pool token
      saveHeartbeats pool (updateHeartbeats heartbeats userName)

editorInfo :: [HeartbeatPayload] -> [Utils.EditorInfo]
editorInfo = map (Utils.userAgentInfo . user_agent)

-- Update the missing fields with info gatherred from the user-agent.
updateHeartbeats :: [HeartbeatPayload] -> Text -> [HeartbeatPayload]
updateHeartbeats heartbeats name =
  zipWith
    ( \info beat ->
        beat
          { sender = Just name,
            editor = Utils.editor info,
            plugin = Utils.plugin info,
            platform = Utils.platform info
          }
    )
    (editorInfo heartbeats)
    heartbeats

importHeartbeats :: Db m => HqPool.Pool -> Text -> [HeartbeatPayload] -> m [Int64]
importHeartbeats pool username heartbeats = do
  saveHeartbeats pool (updateHeartbeats heartbeats username)

generateStatistics ::
  Db m =>
  HqPool.Pool ->
  ApiToken ->
  Int64 ->
  Maybe Text ->
  (UTCTime, UTCTime) ->
  m [StatRow]
generateStatistics pool token timeLimit tagName tmRange = do
  retrievedUser <- getUser pool token
  case retrievedUser of
    Nothing -> throw UnknownApiToken
    Just username -> getTotalStats pool username tmRange tagName timeLimit

getTimeline ::
  Db m =>
  HqPool.Pool ->
  ApiToken ->
  Int64 ->
  (UTCTime, UTCTime) ->
  m [TimelineRow]
getTimeline pool token timeLimit tmRange = do
  retrievedUser <- getUser pool token
  case retrievedUser of
    Nothing -> throw UnknownApiToken
    Just username -> getTimelineStats pool username tmRange timeLimit

genProjectStatistics ::
  Db m =>
  HqPool.Pool ->
  ApiToken ->
  Text ->
  Int64 ->
  (UTCTime, UTCTime) ->
  m [ProjectStatRow]
genProjectStatistics pool token proj timeLimit tmRange = do
  retrievedUser <- getUser pool token
  case retrievedUser of
    Nothing -> throw UnknownApiToken
    Just username -> getProjectStats pool username proj tmRange timeLimit

createNewApiToken :: Db m => HqPool.Pool -> ApiToken -> m Text
createNewApiToken pool token = do
  retrievedUser <- getUser pool token
  case retrievedUser of
    Nothing -> throw UnknownApiToken
    Just username -> createAPIToken pool username

createAuthTokens :: Db m => Text -> Text -> HqPool.Pool -> Int64 -> m TokenData
createAuthTokens user passwd pool expiry = do
  res <- validateCredentials pool user passwd
  case res of
    Nothing -> throw InvalidCredentials
    Just u -> createWebToken pool u expiry

refreshAuthTokens :: Db m => Maybe Text -> HqPool.Pool -> Int64 -> m TokenData
refreshAuthTokens Nothing _ _ = throw MissingRefreshTokenCookie
refreshAuthTokens (Just refreshToken) pool expiry = do
  res <- getUserByRefreshToken pool refreshToken
  case res of
    Nothing -> throw ExpiredRefreshToken
    Just u -> createWebToken pool u expiry

clearTokens :: Db m => ApiToken -> Maybe Text -> HqPool.Pool -> m ()
clearTokens _ Nothing _ = throw MissingRefreshTokenCookie
clearTokens token (Just refreshToken) pool = do
  res <- deleteTokens pool token refreshToken
  -- TODO: Improve this.
  case res of
    0 -> throw InvalidCredentials
    1 -> throw InvalidCredentials
    2 -> pass
    _ -> throw (OperationException "failed to delete all the tokens while logout")

getApiTokens :: Db m => HqPool.Pool -> ApiToken -> m [StoredApiToken]
getApiTokens pool token = do
  retrievedUser <- getUser pool token
  case retrievedUser of
    Nothing -> throw UnknownApiToken
    Just username -> listApiTokens pool username

deleteApiToken :: Db m => HqPool.Pool -> ApiToken -> Text -> m ()
deleteApiToken pool token tknId = do
  retrievedUser <- getUser pool token
  case retrievedUser of
    Nothing -> throw UnknownApiToken
    Just _ -> deleteToken pool (ApiToken tknId)

mkBadgeLink :: Db m => HqPool.Pool -> Text -> ApiToken -> m UUID
mkBadgeLink pool proj token = do
  retrievedUser <- getUser pool token
  case retrievedUser of
    Nothing -> throw UnknownApiToken
    Just user -> createBadgeLink pool user proj

getUserByToken :: Db m => HqPool.Pool -> ApiToken -> m Text
getUserByToken pool token = do
  retrievedUser <- getUser pool token
  case retrievedUser of
    Nothing -> throw UnknownApiToken
    Just user -> pure user

validateUserAndProject :: Db m => HqPool.Pool -> ApiToken -> Project -> m StoredUser
validateUserAndProject pool token projectName = do
  retrievedUser <- getUser pool token
  case retrievedUser of
    Nothing -> throw UnknownApiToken
    Just user -> do
      isOk <- checkProjectOwner pool (StoredUser user) projectName

      if isOk
        then pure $ StoredUser user
        else throw (InvalidRelation (StoredUser user) projectName)

validateUserAndTag :: Db m => HqPool.Pool -> ApiToken -> Tag -> m StoredUser
validateUserAndTag pool token tag = do
  retrievedUser <- getUser pool token
  case retrievedUser of
    Nothing -> throw UnknownApiToken
    Just user -> do
      isOk <- checkTagOwner pool (StoredUser user) tag

      if isOk
        then pure $ StoredUser user
        else throw (InvalidTagRelation (StoredUser user) tag)

getUserTags :: Db m => HqPool.Pool -> ApiToken -> m (V.Vector Text)
getUserTags pool token = do
  retrievedUser <- getUser pool token
  case retrievedUser of
    Nothing -> throw UnknownApiToken
    Just user -> getAllTags pool (StoredUser user)

getUserProjects :: Db m => HqPool.Pool -> ApiToken -> UTCTime -> UTCTime -> m (V.Vector Text)
getUserProjects pool token t0 t1 = do
  retrievedUser <- getUser pool token
  case retrievedUser of
    Nothing -> throw UnknownApiToken
    Just user -> getAllProjects pool (StoredUser user) t0 t1
