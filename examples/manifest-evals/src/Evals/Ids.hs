{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Evals.Ids where
import Manifest (DbType)
newtype OrgId            = OrgId Int            deriving stock (Eq, Show) deriving newtype DbType
newtype DatasetId        = DatasetId Int        deriving stock (Eq, Show) deriving newtype DbType
newtype DatasetVersionId = DatasetVersionId Int deriving stock (Eq, Show) deriving newtype DbType
newtype ExampleId        = ExampleId Int        deriving stock (Eq, Show) deriving newtype DbType
newtype TargetId         = TargetId Int         deriving stock (Eq, Show) deriving newtype DbType
newtype TargetVersionId  = TargetVersionId Int  deriving stock (Eq, Show) deriving newtype DbType
newtype GraderId         = GraderId Int         deriving stock (Eq, Show) deriving newtype DbType
newtype GraderVersionId  = GraderVersionId Int  deriving stock (Eq, Show) deriving newtype DbType
newtype RunId            = RunId Int            deriving stock (Eq, Show) deriving newtype DbType
newtype OutputId         = OutputId Int         deriving stock (Eq, Show) deriving newtype DbType
newtype ScoreId          = ScoreId Int          deriving stock (Eq, Show) deriving newtype DbType
newtype RunMetricId      = RunMetricId Int      deriving stock (Eq, Show) deriving newtype DbType
