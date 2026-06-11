{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | Recursive (multi-level) cascade behaviour, on a dedicated fixture chain:
-- Org -Cascade-> Team -Cascade-> Member / -Restrict-> Badge / -SetNull-> Locker,
-- plus a self-referential Node -Cascade-> Node for the cycle guard.
module RecursiveCascadeSpec (tests) where

import Control.Exception (SomeException, try)
import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import GHC.Generics (Generic)
import Data.Functor.Identity (Identity)

import Manifest.Core.Cascade (OnDelete (..))
import Manifest.Core.Meta (genericTableMeta)
import Manifest.Core.Query (Cond)
import Manifest.Core.Relation (cascade)
import Manifest.Core.Table (Field, Nullable, Pk)
import Manifest.Derive ()
import Manifest.Entity (Entity (..), Table (..))
import Manifest.Postgres (Pool, execText, withConnection)
import Manifest.Session
import Manifest.Testing (withEphemeralDb)
import Harness

-- Fixtures ------------------------------------------------------------------

data OrgT f = Org
  { orgId   :: Field f (Pk Int)
  , orgName :: Field f Text
  } deriving Generic
type Org = OrgT Identity

instance Entity Org where
  tableMeta    = genericTableMeta @OrgT "orgs"
  cascadeRules = [ cascade (Proxy @Team) (Proxy @"teamOrg") Cascade ]

data TeamT f = Team
  { teamId   :: Field f (Pk Int)
  , teamOrg  :: Field f Int
  , teamName :: Field f Text
  } deriving Generic
type Team = TeamT Identity

instance Entity Team where
  tableMeta    = genericTableMeta @TeamT "teams"
  cascadeRules =
    [ cascade (Proxy @Member) (Proxy @"memberTeam") Cascade
    , cascade (Proxy @Badge)  (Proxy @"badgeTeam")  Restrict
    , cascade (Proxy @Locker) (Proxy @"lockerTeam") SetNull
    ]

data MemberT f = Member
  { memberId   :: Field f (Pk Int)
  , memberTeam :: Field f Int
  , memberName :: Field f Text
  } deriving Generic
type Member = MemberT Identity
deriving via (Table "members" MemberT) instance Entity Member

data BadgeT f = Badge
  { badgeId    :: Field f (Pk Int)
  , badgeTeam  :: Field f Int
  , badgeLabel :: Field f Text
  } deriving Generic
type Badge = BadgeT Identity
deriving via (Table "badges" BadgeT) instance Entity Badge

data LockerT f = Locker
  { lockerId   :: Field f (Pk Int)
  , lockerTeam :: Field f (Nullable Int)
  , lockerCode :: Field f Text
  } deriving Generic
type Locker = LockerT Identity
deriving via (Table "lockers" LockerT) instance Entity Locker

-- Self-referential: a node cascades onto its own table (cycle guard target).
data NodeT f = Node
  { nodeId     :: Field f (Pk Int)
  , nodeParent :: Field f (Nullable Int)
  , nodeName   :: Field f Text
  } deriving Generic
type Node = NodeT Identity

instance Entity Node where
  tableMeta    = genericTableMeta @NodeT "nodes"
  cascadeRules = [ cascade (Proxy @Node) (Proxy @"nodeParent") Cascade ]

withRecDb :: (Pool -> IO a) -> IO a
withRecDb body = withEphemeralDb $ \pool -> do
  let ddls =
        [ "CREATE TABLE orgs    (org_id BIGSERIAL PRIMARY KEY, org_name TEXT NOT NULL)"
        , "CREATE TABLE teams   (team_id BIGSERIAL PRIMARY KEY, team_org BIGINT NOT NULL, team_name TEXT NOT NULL)"
        , "CREATE TABLE members (member_id BIGSERIAL PRIMARY KEY, member_team BIGINT NOT NULL, member_name TEXT NOT NULL)"
        , "CREATE TABLE badges  (badge_id BIGSERIAL PRIMARY KEY, badge_team BIGINT NOT NULL, badge_label TEXT NOT NULL)"
        , "CREATE TABLE lockers (locker_id BIGSERIAL PRIMARY KEY, locker_team BIGINT, locker_code TEXT NOT NULL)"
        , "CREATE TABLE nodes   (node_id BIGSERIAL PRIMARY KEY, node_parent BIGINT, node_name TEXT NOT NULL)"
        ]
  withConnection pool (\c -> mapM_ (\s -> execText c s []) ddls)
  body pool

-- | Seed one org with two teams and one member per team; no badges, no lockers.
seedOrg :: Db Org
seedOrg = do
  o  <- add (Org { orgId = 0, orgName = "Acme" } :: Org)
  t1 <- add (Team { teamId = 0, teamOrg = orgId o, teamName = "T1" } :: Team)
  t2 <- add (Team { teamId = 0, teamOrg = orgId o, teamName = "T2" } :: Team)
  _  <- add (Member { memberId = 0, memberTeam = teamId t1, memberName = "M1" } :: Member)
  _  <- add (Member { memberId = 0, memberTeam = teamId t2, memberName = "M2" } :: Member)
  pure o

countAll :: forall a. Entity a => Pool -> IO Int
countAll pool = withSession pool (length <$> selectWhere ([] :: [Cond a]))

-- Tests -----------------------------------------------------------------------

tests :: [Test]
tests = group "RecursiveCascade"
  [ test "Cascade recurses: deleting the org removes teams AND members" $
      withRecDb $ \pool -> do
        usedSubquery <- withSession pool $ do
          o <- seedOrg
          withTransaction $ delete o
          l <- statementLog
          let sqls = map (BC.unpack . fst) l
          pure (any (\s -> "DELETE FROM members" `isInfixOf` s
                        && "IN (SELECT" `isInfixOf` s) sqls)
        assertReturns "orgs gone"    0 (countAll @Org pool)
        assertReturns "teams gone"   0 (countAll @Team pool)
        assertReturns "members gone" 0 (countAll @Member pool)
        assertBool "member delete is scoped by an IN subquery" usedSubquery
  , test "Restrict at depth aborts the whole delete (nothing mutated)" $
      withRecDb $ \pool -> do
        res <- (try :: IO a -> IO (Either SomeException a)) $ withSession pool $ do
          o <- seedOrg
          ts <- selectWhere ([] :: [Cond Team])
          _ <- add (Badge { badgeId = 0, badgeTeam = teamId (head ts), badgeLabel = "B" } :: Badge)
          withTransaction $ delete o
        assertBool "delete was rejected" (either (const True) (const False) res)
        assertReturns "org survives"     1 (countAll @Org pool)
        assertReturns "teams survive"    2 (countAll @Team pool)
        assertReturns "members survive"  2 (countAll @Member pool)
        assertReturns "badge survives"   1 (countAll @Badge pool)
  , test "SetNull at depth nulls the FK; the row survives" $
      withRecDb $ \pool -> do
        fks <- withSession pool $ do
          o <- seedOrg
          ts <- selectWhere ([] :: [Cond Team])
          _ <- add (Locker { lockerId = 0, lockerTeam = Just (teamId (head ts)), lockerCode = "L1" } :: Locker)
          withTransaction $ delete o
          ls <- selectWhere ([] :: [Cond Locker])
          pure (map lockerTeam ls)
        assertEqual "locker survives, FK nulled" [Nothing] fks
  , test "cycle guard: self-ref cascades one level per edge and terminates" $
      withRecDb $ \pool -> do
        names <- withSession pool $ do
          r <- add (Node { nodeId = 0, nodeParent = Nothing, nodeName = "root" } :: Node)
          c <- add (Node { nodeId = 0, nodeParent = Just (nodeId r), nodeName = "child" } :: Node)
          _ <- add (Node { nodeId = 0, nodeParent = Just (nodeId c), nodeName = "grandchild" } :: Node)
          withTransaction $ delete r
          ns <- selectWhere ([] :: [Cond Node])
          pure (map nodeName ns)
        -- Documented limitation: one level per declared edge — the grandchild
        -- row survives (row-level recursion would need WITH RECURSIVE).
        assertEqual "only the grandchild remains" ["grandchild"] names
  , test "Eq/Show on a cyclic rule tree terminate (laziness invariant)" $ do
      -- Node's rule tree is infinite (self-referential); Eq and Show must
      -- touch only the finite fields and never force crChildRules.
      let r = head (cascadeRules @Node)
      assertBool "self-equality terminates" (r == r)
      assertBool "show terminates non-empty" (not (null (show r)))
  ]
