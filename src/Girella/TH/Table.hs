{-# LANGUAGE
    CPP
  , LambdaCase
  , TemplateHaskell
  , ViewPatterns
  #-}
module Girella.TH.Table
  ( -- * TH End points
    makeTypes
  , makeTable
  , makeAdaptorAndInstance
  -- * TH dependencien from this package
  , To
  , optionalColumn
  -- * Re-exported TH dependencies
  , Table (Table)
  , Column
  , dimap
  , ProductProfunctor
  , Nullable
  , p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13, p14, p15, p16
  ) where

import Control.Monad ((<=<))
import Data.Char (isUpper, toLower)
import Data.Foldable (foldl')
import Data.Generics.Uniplate.Data (transformBi)
import Data.Profunctor (dimap)
import Data.Profunctor.Product (ProductProfunctor, p0, p1, p10, p11, p12, p13, p14, p15, p16, p2,
                                p3, p4, p5, p6, p7, p8, p9)
import Data.Profunctor.Product.TH (makeAdaptorAndInstance)
import Language.Haskell.TH
import Language.Haskell.TH.Syntax
import Opaleye.Column (Column, Nullable)
import Opaleye.Table (Table (Table))

import Girella.Compat (instanceD_, dataDView)
import Girella.Conv (Conv)
import Girella.TH.Util (ambiguateName)
import Girella.Table (optionalColumn)
import Girella.To (To)

makeTypes :: Q [Dec] -> Q [Dec]
makeTypes = (fmap concat . mapM makeType =<<)

makeType :: Dec -> Q [Dec]
makeType = \case
#if MIN_VERSION_template_haskell(2,11,0)
  DataD [] origTypeName [] mkind [RecC recConName vtys] deriv ->
#else
  DataD [] origTypeName [] [RecC recConName vtys] deriv ->
#endif
    pure [dataDecl, aliasO, aliasH, toInstance, convInstance]
    where
      dataName = (`appendToName` "P") $ ambiguateName origTypeName
      recName = ambiguateName recConName
      synNameO = ambiguateName origTypeName
      synNameH = (`appendToName` "H") $ ambiguateName origTypeName
      appendToName :: Name -> String -> Name
      appendToName (Name (OccName occ) ns) s = OccName (occ ++ s) `Name` ns
      tvars :: [Name]
      tvars = map mkName . take (length vtys) $ tyvarNames
      tyvarNames = [ x : show i | i <- [(0::Int)..], x <- ['a'..'z'] ] -- a0, b0, ..., a1, b1, ...
      ttys :: [Type]
      ttys = map (\(_,_,tp) -> tp) vtys
      ttysO :: [Type]
      ttysO = map pgRep ttys
        where
          pgRep = \case
            n@(ConT (Name (OccName "Nullable") _)) `AppT` i -> n `AppT` i
            i                                               -> i
      ttysH :: [Type]
      ttysH = map replaceNullable ttys
        where
          replaceNullable :: Type -> Type
          replaceNullable = transformBi $ \case
            Name (OccName "Nullable") _ -> ''Maybe
            s -> s

      dataDecl :: Dec
      dataDecl =
#if MIN_VERSION_template_haskell(2,11,0)
        DataD [] dataName plainTVs mkind recc deriv
#else
        DataD [] dataName plainTVs recc deriv
#endif
        where
          plainTVs = map PlainTV tvars
          recc = [RecC recName (zipWith f tvars vtys)]
          f :: Name -> VarStrictType -> VarStrictType
          f c (n,s,_) = (ambiguateName n, s, VarT c)

      aliasO = TySynD synNameO [] $ foldl' AppT (ConT dataName) ttysO
      aliasH = TySynD synNameH [] $ foldl' AppT (ConT dataName) ttysH
      convInstance :: Dec
      convInstance = instanceD_ [] (ConT ''Conv `AppT` ConT synNameH) []

      toInstance = TySynInstD ''To
                     (TySynEqn [typ, lhs] rhs)
        where
          typ, lhs, rhs :: Type
          typ = VarT (mkName "typ")
          lhs = foldl' AppT (ConT dataName) $ map VarT tvars
          rhs = foldl' AppT (ConT dataName) $ map (AppT typ . VarT) tvars

  _ -> error "This is not a good looking data type"

makeTable :: String -> Name -> Name -> Q [Dec]
makeTable tableName pName = f <=< reify
  where
    f :: Info -> Q [Dec]
    f = \case
      TyConI (dataDView -> Just ([], _dataName, _tvb, [RecC recordName vsts])) ->
        pure [tableSig, table, emptyUpdateSig, emptyUpdateBody]
        where
         tableSig = SigD (mkName "table") tableTy
           where
             tableTy :: Type
             tableTy = ConT ''Table `AppT` tbm `AppT` tb
               where
                 tbm = ConT ''To `AppT` ConT ''Maybe  `AppT` tb
                 tb  = ConT ''To `AppT` ConT ''Column `AppT` ConT (ambiguateName recordName)
         table = FunD (mkName "table") [Clause [] (NormalB e) []]
           where
             e :: Exp
             e = AppE (AppE (ConE 'Table) (LitE $ StringL tableName)) wireRec
             wireRec :: Exp
             wireRec = AppE (VarE pName) (RecConE recordName $ map field vsts)
             field :: VarStrictType -> FieldExp
             field (nm, _, _) = (nm, AppE (VarE 'optionalColumn) (LitE . StringL $ columnName nm))
             columnName :: Name -> String
             columnName (Name (OccName occ) _) = removeApostrophes . concatMap underscore $ occ
             underscore :: Char -> String
             underscore c
               | isUpper c = ['_', toLower c]
               | otherwise = [c]
             removeApostrophes = filter (/= '\'')
         -- TODO opa ConT recordName isn't valid, it just happens to be the
         -- same as the name of the type alias so ambiguateName just
         -- acts as unsafeCoerce here.
         emptyUpdateSig = SigD (mkName "emptyUpdate") (ConT ''To `AppT` ConT ''Maybe `AppT` (ConT ''To `AppT` ConT ''Column `AppT` ConT (ambiguateName recordName)))
         emptyUpdateBody = FunD (mkName "emptyUpdate") [Clause [] (NormalB e) []]
           where
             e :: Exp
             e = foldl' AppE (ConE recordName) . map (const . ConE $ 'Nothing) $ vsts

      _ -> error "makeTable: I need one record"
