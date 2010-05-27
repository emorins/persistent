{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE FlexibleContexts #-}
module Database.Persist.Sqlite3
    ( Sqlite3
    , runSqlite3
    , derivePersistSqlite3
    , SqlValues (..)
    , HasFilter (..)
    , HasOrder (..)
    , HasUpdate (..)
    ) where

import Database.Persist (Persist, Table (..), Key, Order, Filter, Update)
import Database.Persist.Helper
import Control.Monad.Trans.Reader
import qualified Data.Map as Map
import Language.Haskell.TH.Syntax hiding (lift)
import qualified Language.Haskell.TH.Syntax as TH
import Control.Monad.Trans.Class (MonadTrans (..))
import Control.Monad.IO.Class (MonadIO (..))
import Data.Char
import Control.Arrow (first)
import Data.List (sortBy, intercalate)
import Data.Maybe (mapMaybe)
import Database.HDBC
import Database.HDBC.Sqlite3 (Connection)
import "MonadCatchIO-transformers" Control.Monad.CatchIO
import Control.Applicative (Applicative)
import Data.Convertible (Convertible (..))
import Control.Monad (ap)

newtype Sqlite3 m a = Sqlite3
    { unSqlite3 :: ReaderT Connection m a
    }
    deriving (MonadIO, MonadTrans, Monad, Functor, Applicative, MonadCatchIO)

ask' :: Monad m => Sqlite3 m Connection
ask' = Sqlite3 ask

runSqlite3 :: MonadCatchIO m => Sqlite3 m a -> Connection -> m a
runSqlite3 (Sqlite3 r) conn = do
    r <- onException (runReaderT r conn) $ liftIO $ rollback conn
    liftIO $ commit conn
    return r

derivePersistSqlite3 :: Table -> Q [Dec]
derivePersistSqlite3 t@(Table name cols upda filts ords uni) = do
    let dt = dataTypeDec t
    let monad = ConT ''Sqlite3 `AppT` VarT (mkName "m")

    tsv <- mkToSqlValues t
    fsv <- mkFromSqlValues t
    let sq =
          InstanceD [] (ConT ''SqlValues `AppT` ConT (mkName name))
            [ FunD (mkName "toSqlValues") [tsv]
            , FunD (mkName "fromSqlValues") fsv
            ]

    fc <- mkFilterClause t
    fd <- mkFilterData t
    let hf =
          InstanceD [] (ConT ''HasFilter `AppT`
                        (ConT ''Filter `AppT` ConT (mkName name) `AppT` monad))
            [ FunD (mkName "filterClause") fc
            , FunD (mkName "filterData") fd
            ]

    oc <- mkOrderClause t
    let ho =
          InstanceD [] (ConT ''HasOrder `AppT`
                        (ConT ''Order `AppT` ConT (mkName name) `AppT` monad))
            [FunD (mkName "orderClause") oc]

    uc <- mkUpdateClause t
    ud <- mkUpdateData t
    let hu =
          InstanceD [] (ConT ''HasUpdate `AppT`
                        (ConT ''Update `AppT` ConT (mkName name) `AppT` monad))
            [ FunD (mkName "updateClause") uc
            , FunD (mkName "updateData") ud
            ]

    t' <- TH.lift t
    let mkFun s e = FunD (mkName s) [Clause [] (NormalB $ e `AppE` t') []]

    init' <- [|initialize|]
    insert' <- [|insert|]
    replace' <- [|replace|]
    get' <- [|get|]
    select' <- [|select|]
    filter' <- [|filter''|]
    order' <- [|order|]
    deleteWhere' <- [|deleteWhere|]
    delete' <- [|delete|]
    update' <- [|update|]
    updateWhere' <- [|updateWhere|]

    let inst =
          InstanceD
            [ClassP ''MonadCatchIO [VarT $ mkName "m"]]
            (ConT ''Persist `AppT` ConT (mkName name) `AppT` monad)
            [ keyTypeDec "Sqlite3Key" "Integer" t monad
            , filterTypeDec t monad
            , updateTypeDec t monad
            , orderTypeDec t monad
            , mkFun "initialize" $ init'
            , mkFun "insert" $ insert'
            , mkFun "replace" $ replace'
            , mkFun "get" $ get'
            , mkFun "select" $ select'
            , mkFun "filter" $ filter'
            , mkFun "order" $ order'
            , mkFun "deleteWhere" $ deleteWhere'
            , mkFun "delete" $ delete'
            , mkFun "update" $ update'
            , mkFun "updateWhere" $ updateWhere'
            ]
    return [dt, sq, hf, ho, hu, inst]

initialize :: MonadIO m => Table -> v -> Sqlite3 m ()
initialize t _ = do
    let sql = "CREATE TABLE " ++ tableName t ++ "(id INTEGER PRIMARY KEY" ++
              concatMap (',' :) (map fst $ tableColumns t) ++ ")"
    conn <- ask'
    ts <- liftIO $ getTables conn
    if tableName t `elem` ts
        then return ()
        else do
            _ <- liftIO $ run conn sql []
            return ()

class SqlValues a where
    toSqlValues :: a -> [SqlValue]
    fromSqlValues :: [SqlValue] -> Maybe a

mkToSqlValues :: Table -> Q Clause
mkToSqlValues t = do
    xs <- mapM (const $ newName "x") $ tableColumns t
    ts <- [|toSql|]
    let xs' = map (AppE ts . VarE) xs
    return $ Clause [ConP (mkName $ tableName t) $ map VarP xs]
                    (NormalB $ ListE xs') []

fromSql' :: Convertible SqlValue y => SqlValue -> Maybe y
fromSql' = either (const Nothing) Just . safeConvert

mkFromSqlValues :: Table -> Q [Clause]
mkFromSqlValues t = do
    nothing <- [|Nothing|]
    let cons = ConE $ mkName $ tableName t
    xs <- mapM (const $ newName "x") $ tableColumns t
    fs <- [|fromSql'|]
    let xs' = map (AppE fs . VarE) xs
    let pat = ListP $ map VarP xs
    ap' <- [|ap|]
    just <- [|Just|]
    let cons' = just `AppE` cons
    return
        [ Clause [pat] (NormalB $ foldl (go ap') cons' xs') []
        , Clause [WildP] (NormalB nothing) []
        ]
  where
    go ap' x y = InfixE (Just x) ap' (Just y)

insert t val = do
    let sql = "INSERT INTO " ++ tableName t ++ " VALUES(NULL" ++
              concatMap (const ",?") (tableColumns t) ++ ")"
    conn <- ask'
    ins <- liftIO $ prepare conn sql
    _ <- liftIO $ execute ins $ toSqlValues val
    get <- liftIO $ prepare conn "SELECT last_insert_rowid()"
    _ <- liftIO $ execute get []
    Just [i] <- liftIO $ fetchRow get
    return $ fromInteger $ fromSql i

replace t k val = do
    let sql = "REPLACE INTO " ++ tableName t ++ " VALUES(?" ++
              concatMap (const ",?") (tableColumns t) ++ ")"
    conn <- ask'
    ins <- liftIO $ prepare conn sql
    _ <- liftIO $ execute ins $ SqlInteger (fromIntegral k) : toSqlValues val
    return ()

get t k = do
    let sql = "SELECT * FROM " ++ tableName t ++ " WHERE id=?"
    conn <- ask'
    get <- liftIO $ prepare conn sql
    _ <- liftIO $ execute get [SqlInteger $ fromIntegral k]
    res <- liftIO $ fetchRow get
    case res of
        Just (_:vals) -> return $ fromSqlValues vals
        _ -> return Nothing

class HasFilter a where
    filterClause :: a -> String
    filterData :: a -> SqlValue
class HasOrder a where
    orderClause :: a -> String

mkFilterClause :: Table -> Q [Clause]
mkFilterClause t = do
    return $ concatMap (map go . filtsToList) $ tableFilters t
  where
    go (field, comp) =
        Clause [ConP (mkName $ tableName t ++ upperFirst field ++ comp) [WildP]]
               (NormalB $ LitE $ StringL $ field ++ comp' comp ++ "?") -- FIXME handle nulls
               []
    comp' "Eq" = "="
    comp' "Ne" = "<>"
    comp' "Lt" = "<"
    comp' "Gt" = ">"
    comp' "Le" = "<="
    comp' "Ge" = ">="
    comp' x = error $ "Invalid comparison: " ++ x

mkFilterData :: Table -> Q [Clause]
mkFilterData t = do
    ts <- [|toSql|]
    return $ concatMap (map (go ts) . filtsToList) $ tableFilters t
  where
    go ts (field, comp) =
        Clause [ConP (mkName $ tableName t ++ upperFirst field ++ comp) [VarP $ mkName "x"]]
               (NormalB $ ts `AppE` VarE (mkName "x"))
               []

mkOrderClause :: Table -> Q [Clause]
mkOrderClause t = do
    return $ concatMap go $ tableOrders t
  where
    go (field, asc, desc) =
        (if asc then (:) (go' field "Asc" "") else id)
      $ (if desc then (:) (go' field "Desc" " DESC") else id) []
    go' field suf sql =
        Clause [ConP (mkName $ tableName t ++ upperFirst field ++ suf) []]
               (NormalB $ LitE $ StringL $ field ++ sql)
               []

filter'' t filts = select t filts []

order t ords = select t [] ords

select :: SqlValues val => Num key => MonadIO m
       => HasFilter (Filter val (Sqlite3 m))
       => HasOrder (Order val (Sqlite3 m))
       => Table -> [Filter val (Sqlite3 m)] -> [Order val (Sqlite3 m)]
       -> Sqlite3 m [(key, val)]
select t filts ords = do
    let wher = if null filts
                then ""
                else " WHERE " ++
                     intercalate " AND " (map filterClause filts)
        ord = if null ords
                then ""
                else " ORDER BY " ++
                     intercalate "," (map orderClause ords)
    let sql = "SELECT * FROM " ++ tableName t ++ wher ++ ord
    conn <- ask'
    get <- liftIO $ prepare conn sql
    _ <- liftIO $ execute get $ map filterData filts
    rows <- liftIO $ fetchAllRows get
    return $ mapMaybe fromSqlValues' rows
  where
    fromSqlValues' (x:xs) = do
        x' <- fromSql' x
        xs' <- fromSqlValues xs
        return (fromInteger x', xs')

deleteWhere t filts = do
    let wher = if null filts
                then ""
                else " WHERE " ++
                     intercalate " AND " (map filterClause filts)
        sql = "DELETE FROM " ++ tableName t ++ wher
    conn <- ask'
    del <- liftIO $ prepare conn sql
    _ <- liftIO $ execute del $ map filterData filts
    return ()

delete t k = do
    let sql = "DELETE FROM " ++ tableName t ++ " WHERE id=?"
    conn <- ask'
    del <- liftIO $ prepare conn sql
    _ <- liftIO $ execute del [SqlInteger $ fromIntegral k]
    return ()

class HasUpdate a where
    updateClause :: a -> String
    updateData :: a -> SqlValue

mkUpdateClause :: Table -> Q [Clause]
mkUpdateClause t = do
    return $ map go $ tableUpdates t
  where
    go field =
        Clause [ConP (mkName $ tableName t ++ upperFirst field) [WildP]]
               (NormalB $ LitE $ StringL $ field ++ "=?")
               []

mkUpdateData :: Table -> Q [Clause]
mkUpdateData t = do
    ts <- [|toSql|]
    return $ map (go ts) $ tableUpdates t
  where
    go ts field =
        Clause [ConP (mkName $ tableName t ++ upperFirst field) [VarP $ mkName "x"]]
               (NormalB $ ts `AppE` VarE (mkName "x"))
               []

update t _ [] = return ()
update t k upds = do
    let sql = "UPDATE " ++ tableName t ++ " SET " ++
              intercalate "," (map updateClause upds) ++
              " WHERE id=?"
    conn <- ask'
    up <- liftIO $ prepare conn sql
    _ <- liftIO $ execute up $ map updateData upds ++ [SqlInteger $ fromIntegral k]
    return ()

updateWhere _ _ [] = return ()
updateWhere t filts upds = do
    let wher = if null filts
                then ""
                else " WHERE " ++
                     intercalate " AND " (map filterClause filts)
    let sql = "UPDATE " ++ tableName t ++ " SET " ++
              intercalate "," (map updateClause upds) ++ wher
    let dat = map updateData upds ++ map filterData filts
    conn <- ask'
    up <- liftIO $ prepare conn sql
    _ <- liftIO $ execute up dat
    return ()
