{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Cardano.DbSync
  ( ConfigFile (..)
  , DbSyncNodeParams (..)
  , DbSyncNodePlugin (..)
  , GenesisFile (..)
  , GenesisHash (..)
  , NetworkName (..)
  , SocketPath (..)
  , DB.MigrationDir (..)

  , defDbSyncNodePlugin
  , runDbSyncNode
  ) where

import           Control.Tracer (Tracer)

import qualified Cardano.BM.Setup as Logging
import           Cardano.BM.Data.Tracer (ToLogObject (..))
import           Cardano.BM.Trace (Trace, appendName, logInfo)
import qualified Cardano.BM.Trace as Logging

import qualified Cardano.Chain.Genesis as Byron
import           Cardano.Client.Subscription (subscribe)
import qualified Cardano.Crypto as Crypto

import           Cardano.Db (LogFileDir (..))
import qualified Cardano.Db as DB
import           Cardano.DbSync.Config
import           Cardano.DbSync.Database
import           Cardano.DbSync.Era
import           Cardano.DbSync.Error
import           Cardano.DbSync.Metrics
import           Cardano.DbSync.Plugin (DbSyncNodePlugin (..))
import           Cardano.DbSync.Plugin.Default (defDbSyncNodePlugin)
import           Cardano.DbSync.Rollback (unsafeRollback)
import           Cardano.DbSync.StateQuery (StateQueryTMVar, getSlotDetails,
                    localStateQueryHandler, newStateQueryTMVar)
import           Cardano.DbSync.Tracing.ToObjectOrphans ()
import           Cardano.DbSync.Types
import           Cardano.DbSync.Util

import           Cardano.Prelude hiding (option, (%), Nat)

import           Cardano.Slotting.Slot (SlotNo (..), WithOrigin (..))

import qualified Codec.CBOR.Term as CBOR

import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Trans.Except.Exit (orDie)
import           Control.Monad.Trans.Except.Extra (hoistEither)

import qualified Data.ByteString.Lazy as BSL
import           Data.Functor.Contravariant (contramap)
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Void (Void)

import           Network.Mux (MuxTrace, WithMuxBearer)
import           Network.Mux.Types (MuxMode (..))

import           Ouroboros.Network.Driver.Simple (runPipelinedPeer)
import           Network.TypedProtocol.Pipelined (Nat(Zero, Succ))

import           Ouroboros.Consensus.Block.Abstract (CodecConfig, ConvertRawHash (..))
import           Ouroboros.Consensus.Byron.Ledger.Config (mkByronCodecConfig)
import           Ouroboros.Consensus.Byron.Node ()
import           Ouroboros.Consensus.Cardano.Block (CardanoBlock, CardanoEras, CodecConfig (..),
                    HardForkBlock (..))
import           Ouroboros.Consensus.Cardano.Node ()
import           Ouroboros.Consensus.HardFork.History.Qry (Interpreter)
import           Ouroboros.Consensus.Network.NodeToClient (ClientCodecs,
                    cChainSyncCodec, cStateQueryCodec, cTxSubmissionCodec)
import           Ouroboros.Consensus.Node.ErrorPolicy (consensusErrorPolicy)
import           Ouroboros.Consensus.Node.Run (RunNode)
import           Ouroboros.Consensus.Shelley.Ledger.Block (ShelleyBlock)
import           Ouroboros.Consensus.Shelley.Ledger.Config (CodecConfig (ShelleyCodecConfig))
import           Ouroboros.Consensus.Shelley.Protocol (TPraosStandardCrypto)

import qualified Ouroboros.Network.NodeToClient.Version as Network
import           Ouroboros.Network.Block (BlockNo (..), HeaderHash, Point (..),
                    Tip (..), genesisPoint, getTipBlockNo, getTipPoint, blockNo)
import           Ouroboros.Network.Mux (MuxPeer (..),  RunMiniProtocol (..))
import           Ouroboros.Network.NodeToClient (IOManager, ClientSubscriptionParams (..),
                    ConnectionId, ErrorPolicyTrace (..), Handshake, LocalAddress,
                    NetworkSubscriptionTracers (..), NodeToClientProtocols (..),
                    TraceSendRecv, WithAddr (..), localSnocket,
                    localTxSubmissionPeerNull, networkErrorPolicies, withIOManager)
import qualified Ouroboros.Network.Point as Point
import           Ouroboros.Network.Point (withOrigin)

import           Ouroboros.Network.Protocol.ChainSync.ClientPipelined (ChainSyncClientPipelined (..),
                    ClientPipelinedStIdle (..), ClientPipelinedStIntersect (..), ClientStNext (..),
                    chainSyncClientPeerPipelined, recvMsgIntersectFound, recvMsgIntersectNotFound,
                    recvMsgRollBackward, recvMsgRollForward)
import           Ouroboros.Network.Protocol.ChainSync.PipelineDecision (pipelineDecisionLowHighMark,
                        PipelineDecision (..), runPipelineDecision, MkPipelineDecision)
import           Ouroboros.Network.Protocol.ChainSync.Type (ChainSync)
import           Ouroboros.Network.Protocol.LocalStateQuery.Client (localStateQueryClientPeer)
import qualified Ouroboros.Network.Snocket as Snocket
import           Ouroboros.Network.Subscription (SubscriptionTrace)

import           Prelude (String)
import qualified Prelude

import qualified System.Metrics.Prometheus.Metric.Gauge as Gauge


runDbSyncNode :: DbSyncNodePlugin -> DbSyncNodeParams -> IO ()
runDbSyncNode plugin enp =
  withIOManager $ \ iomgr -> do
    DB.runMigrations Prelude.id True (enpMigrationDir enp) (Just $ LogFileDir "/tmp")

    enc <- readDbSyncNodeConfig (unConfigFile $ enpConfigFile enp)

    trce <- if not (encEnableLogging enc)
              then pure Logging.nullTracer
              else liftIO $ Logging.setupTrace (Right $ encLoggingConfig enc) "db-sync-node"

    -- For testing and debugging.
    case enpMaybeRollback enp of
      Just slotNo -> void $ unsafeRollback trce slotNo
      Nothing -> pure ()

    orDie renderDbSyncNodeError $ do
      genCfg <- readGenesisConfig enc
      genesisEnv <- hoistEither $ genesisConfigToEnv genCfg
      logProtocolMagicId trce $ genesisProtocolMagicId genCfg

      -- If the DB is empty it will be inserted, otherwise it will be validated (to make
      -- sure we are on the right chain).
      insertValidateGenesisDist trce (encNetworkName enc) genCfg

      liftIO $ do
        -- Must run plugin startup after the genesis distribution has been inserted/validate.
        runDbStartup trce plugin

        case genCfg of
          GenesisByron _bCfg ->
            -- runDbSyncNodeNodeClient genesisEnv iomgr trce plugin (mkByronCodecConfig bCfg) (enpSocketPath enp)
            panic "runDbSyncNode: Cannot support a pure Byron network. The node needs to run 'Protocol: Cardano'."
          GenesisShelley _sCfg ->
            -- runDbSyncNodeNodeClient genesisEnv iomgr trce plugin shelleyCodecConfig (enpSocketPath enp)
            panic "runDbSyncNode: Cannot support a pure Shelley network. The node needs to run 'Protocol: Cardano'."
          GenesisCardano bCfg _sCfg ->
            runDbSyncNodeNodeClient genesisEnv
                iomgr trce plugin (cardanoCodecConfig bCfg) (enpSocketPath enp)
  where
    shelleyCodecConfig :: CodecConfig (ShelleyBlock TPraosStandardCrypto)
    shelleyCodecConfig = ShelleyCodecConfig

    cardanoCodecConfig :: Byron.Config -> CodecConfig (CardanoBlock TPraosStandardCrypto)
    cardanoCodecConfig cfg = CardanoCodecConfig (mkByronCodecConfig cfg) shelleyCodecConfig

-- -------------------------------------------------------------------------------------------------

runDbSyncNodeNodeClient
    :: forall blk. (blk ~ HardForkBlock (CardanoEras TPraosStandardCrypto))
    => DbSyncEnv -> IOManager -> Trace IO Text -> DbSyncNodePlugin
    -> CodecConfig blk-> SocketPath
    -> IO ()
runDbSyncNodeNodeClient env iomgr trce plugin codecConfig (SocketPath socketPath) = do
  queryVar <- newStateQueryTMVar
  logInfo trce $ "localInitiatorNetworkApplication: connecting to node via " <> textShow socketPath
  void $ subscribe
    (localSnocket iomgr socketPath)
    codecConfig
    (envNetworkMagic env)
    networkSubscriptionTracers
    clientSubscriptionParams
    (dbSyncProtocols trce env plugin queryVar)
  where
    clientSubscriptionParams = ClientSubscriptionParams {
        cspAddress = Snocket.localAddressFromPath socketPath,
        cspConnectionAttemptDelay = Nothing,
        cspErrorPolicies = networkErrorPolicies <> consensusErrorPolicy
        }

    networkSubscriptionTracers = NetworkSubscriptionTracers {
        nsMuxTracer = muxTracer,
        nsHandshakeTracer = handshakeTracer,
        nsErrorPolicyTracer = errorPolicyTracer,
        nsSubscriptionTracer = subscriptionTracer
        }

    errorPolicyTracer :: Tracer IO (WithAddr LocalAddress ErrorPolicyTrace)
    errorPolicyTracer = toLogObject $ appendName "ErrorPolicy" trce

    muxTracer :: Show peer => Tracer IO (WithMuxBearer peer MuxTrace)
    muxTracer = toLogObject $ appendName "Mux" trce

    subscriptionTracer :: Tracer IO (Identity (SubscriptionTrace LocalAddress))
    subscriptionTracer = toLogObject $ appendName "Subscription" trce

    handshakeTracer :: Tracer IO (WithMuxBearer
                          (ConnectionId LocalAddress)
                          (TraceSendRecv (Handshake Network.NodeToClientVersion CBOR.Term)))
    handshakeTracer = toLogObject $ appendName "Handshake" trce

dbSyncProtocols
    :: forall blk. (blk ~ HardForkBlock (CardanoEras TPraosStandardCrypto))
    => Trace IO Text
    -> DbSyncEnv
    -> DbSyncNodePlugin
    -> StateQueryTMVar blk (Interpreter (CardanoEras TPraosStandardCrypto))
    -> Network.NodeToClientVersion
    -> ClientCodecs blk IO
    -> ConnectionId LocalAddress
    -> NodeToClientProtocols 'InitiatorMode BSL.ByteString IO () Void
dbSyncProtocols trce env plugin queryVar _version codecs _connectionId =
    NodeToClientProtocols {
          localChainSyncProtocol = localChainSyncProtocol
        , localTxSubmissionProtocol = dummylocalTxSubmit
        , localStateQueryProtocol = localStateQuery
        }
  where
    localChainSyncTracer :: Tracer IO (TraceSendRecv (ChainSync blk (Tip blk)))
    localChainSyncTracer = toLogObject $ appendName "ChainSync" trce

    localChainSyncProtocol :: RunMiniProtocol 'InitiatorMode BSL.ByteString IO () Void
    localChainSyncProtocol = InitiatorProtocolOnly $ MuxPeerRaw $ \channel ->
      liftIO . logException trce "ChainSyncWithBlocksPtcl: " $ do
        logInfo trce "Starting chainSyncClient"
        latestPoints <- getLatestPoints
        currentTip <- getCurrentTipBlockNo
        logDbState trce
        actionQueue <- newDbActionQueue
        (metrics, server) <- registerMetricsServer
        race_
            (runDbThread trce env plugin metrics actionQueue)
            (runPipelinedPeer
                localChainSyncTracer
                (cChainSyncCodec codecs)
                channel
                (chainSyncClientPeerPipelined
                    $ chainSyncClient trce env queryVar metrics latestPoints currentTip actionQueue)
            )
        atomically $ writeDbActionQueue actionQueue DbFinish
        cancel server
        -- We should return leftover bytes returned by 'runPipelinedPeer', but
        -- client application do not care about them (it's only important if one
        -- would like to restart a protocol on the same mux and thus bearer).
        pure ((), Nothing)

    dummylocalTxSubmit :: RunMiniProtocol 'InitiatorMode BSL.ByteString IO () Void
    dummylocalTxSubmit = InitiatorProtocolOnly $ MuxPeer
        Logging.nullTracer
        (cTxSubmissionCodec codecs)
        localTxSubmissionPeerNull

    localStateQuery :: RunMiniProtocol 'InitiatorMode BSL.ByteString IO () Void
    localStateQuery =
      InitiatorProtocolOnly $ MuxPeer
        (contramap (Text.pack . show) . toLogObject $ appendName "local-state-query" trce)
        (cStateQueryCodec codecs)
        (localStateQueryClientPeer (localStateQueryHandler queryVar))


logDbState :: Trace IO Text -> IO ()
logDbState trce = do
    mblk <- DB.runDbNoLogging DB.queryLatestBlock
    case mblk of
      Nothing -> logInfo trce "Cardano.Db is empty"
      Just block ->
          logInfo trce $ Text.concat
                  [ "Cardano.Db tip is at "
                  , Text.pack (showTip block)
                  ]
  where
    showTip :: DB.Block -> String
    showTip blk =
      case (DB.blockSlotNo blk, DB.blockBlockNo blk) of
        (Just slotNo, Just blkNo) -> "slot " ++ show slotNo ++ ", block " ++ show blkNo
        (Just slotNo, Nothing) -> "slot " ++ show slotNo
        (Nothing, Just blkNo) -> "block " ++ show blkNo
        (Nothing, Nothing) -> "genesis"


getLatestPoints :: forall blk. ConvertRawHash blk => IO [Point blk]
getLatestPoints =
    -- Blocks (and the transactions they contain) are inserted within an SQL transaction.
    -- That means that all the blocks (including their transactions) returned by the query
    -- have been completely inserted.
    mapMaybe convert <$> DB.runDbNoLogging (DB.queryCheckPoints 200)
  where
    convert :: (Word64, ByteString) -> Maybe (Point blk)
    convert (slot, hashBlob) =
      fmap (Point . Point.block (SlotNo slot)) (convertHashBlob hashBlob)

    -- in Maybe because the bytestring may not be the right size.
    convertHashBlob :: ByteString -> Maybe (HeaderHash blk)
    convertHashBlob = Just . fromRawHash (Proxy @blk)

getCurrentTipBlockNo :: IO (WithOrigin BlockNo)
getCurrentTipBlockNo = do
    maybeTip <- DB.runDbNoLogging DB.queryLatestBlock
    case maybeTip of
      Just tip -> pure $ convert tip
      Nothing -> pure Origin
  where
    convert :: DB.Block -> WithOrigin BlockNo
    convert blk =
      case DB.blockBlockNo blk of
        Just blockno -> At (BlockNo blockno)
        Nothing -> Origin

-- | 'ChainSyncClient' which traces received blocks and ignores when it
-- receives a request to rollbackwar.  A real wallet client should:
--
--  * at startup send the list of points of the chain to help synchronise with
--    the node;
--  * update its state when the client receives next block or is requested to
--    rollback, see 'clientStNext' below.
--
chainSyncClient
    :: forall blk. (RunNode blk, blk ~ HardForkBlock (CardanoEras TPraosStandardCrypto))
    => Trace IO Text -> DbSyncEnv
    -> StateQueryTMVar blk (Interpreter (CardanoEras TPraosStandardCrypto))
    -> Metrics -> [Point blk] -> WithOrigin BlockNo -> DbActionQueue
    -> ChainSyncClientPipelined blk (Tip blk) IO ()
chainSyncClient trce env queryVar metrics latestPoints currentTip actionQueue =
    ChainSyncClientPipelined $ pure $
      -- Notify the core node about the our latest points at which we are
      -- synchronised.  This client is not persistent and thus it just
      -- synchronises from the genesis block.  A real implementation should send
      -- a list of points up to a point which is k blocks deep.
      SendMsgFindIntersect
        (if null latestPoints then [genesisPoint] else latestPoints)
        ClientPipelinedStIntersect
          { recvMsgIntersectFound    = \_hdr tip -> pure $ go policy Zero currentTip (getTipBlockNo tip)
          , recvMsgIntersectNotFound = \  tip -> pure $ go policy Zero currentTip (getTipBlockNo tip)
          }
  where
    policy = pipelineDecisionLowHighMark 1000 10000

    go :: MkPipelineDecision -> Nat n -> WithOrigin BlockNo -> WithOrigin BlockNo
        -> ClientPipelinedStIdle n blk (Tip blk) IO ()
    go mkPipelineDecision n clientTip serverTip =
      case (n, runPipelineDecision mkPipelineDecision n clientTip serverTip) of
        (_Zero, (Request, mkPipelineDecision')) ->
            SendMsgRequestNext clientStNext (pure clientStNext)
          where
            clientStNext = mkClientStNext $ \clientBlockNo newServerTip -> go mkPipelineDecision' n clientBlockNo (getTipBlockNo newServerTip)
        (_, (Pipeline, mkPipelineDecision')) ->
          SendMsgRequestNextPipelined
            (go mkPipelineDecision' (Succ n) clientTip serverTip)
        (Succ n', (CollectOrPipeline, mkPipelineDecision')) ->
          CollectResponse
            (Just $ SendMsgRequestNextPipelined $ go mkPipelineDecision' (Succ n) clientTip serverTip)
            (mkClientStNext $ \clientBlockNo newServerTip -> go mkPipelineDecision' n' clientBlockNo (getTipBlockNo newServerTip))
        (Succ n', (Collect, mkPipelineDecision')) ->
          CollectResponse
            Nothing
            (mkClientStNext $ \clientBlockNo newServerTip -> go mkPipelineDecision' n' clientBlockNo (getTipBlockNo newServerTip))

    mkClientStNext :: (WithOrigin BlockNo -> Tip blk -> ClientPipelinedStIdle n blk (Tip blk) IO a)
                    -> ClientStNext n blk (Tip blk) IO a
    mkClientStNext finish =
      ClientStNext
        { recvMsgRollForward = \blk tip ->
              logException trce "recvMsgRollForward: " $ do
                Gauge.set (withOrigin 0 (fromIntegral . unBlockNo) (getTipBlockNo tip))
                          (mNodeHeight metrics)
                details <- getSlotDetails trce env queryVar (getTipPoint tip) (genericBlockSlotNo blk)
                newSize <- atomically $ do
                            writeDbActionQueue actionQueue $ mkDbApply blk details
                            lengthDbActionQueue actionQueue
                Gauge.set (fromIntegral newSize) $ mQueuePostWrite metrics
                pure $ finish (At (blockNo blk)) tip
        , recvMsgRollBackward = \point tip ->
              logException trce "recvMsgRollBackward: " $ do
                -- This will get the current tip rather than what we roll back to
                -- but will only be incorrect for a short time span.
                atomically $ writeDbActionQueue actionQueue $ mkDbRollback point
                newTip <- getCurrentTipBlockNo
                pure $ finish newTip tip
        }

logProtocolMagicId :: Trace IO Text -> Crypto.ProtocolMagicId -> ExceptT DbSyncNodeError IO ()
logProtocolMagicId tracer pm =
  liftIO . logInfo tracer $ mconcat
    [ "NetworkMagic: ", textShow (Crypto.unProtocolMagicId pm)
    ]
