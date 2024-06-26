{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}
module Typecheck where

import Context
import Syntax
import Control.Monad.Except
import Eval (normalize)
import Control.Monad.Reader
import Data.Text hiding (zip)
import Safe (atMay)

infer :: Nameless -> Gamma (Nameless, Type Local)
infer e = do
    go e
    where
        go = \case
            Var (Bound i) ->
                maybe (throwError ("not found: " <> pack (show i))) (\(a,t) -> pure (Var (Free a), t)) =<< asks (indexId i)
            Var (Free x) ->
                maybe (throwError ("not found: " <> pack (show x))) (pure . (Var (Free x),)) =<< asks (lookupId x)
            Type -> pure (Type, Type)
            BoolT -> pure (BoolT, Type)
            IntT -> pure (IntT, Type)
            Bool b -> pure (Bool b, BoolT)
            Int i -> pure (Int i, IntT)
            Apply l r -> do
                (l', ty1) <- infer l
                ty <- normalize False ty1
                case ty of
                    Pi _ t u -> do
                        r' <- check r t
                        pure (Apply l' r', open r' u)
                    _ -> throwError $ "expected function got: " <> pack (show ty)
            If a b c -> do
                a' <- check a BoolT
                (b', bt) <- infer b
                c' <- check c bt
                pure (If a' b' c', bt)
            Lambda n (Just t) b -> do
                t' <- check t Type
                n' <- fresh n
                (b', u) <- local (addId n' t') $ infer b
                pure (Lambda n (Just t') (bind n' b'), Pi n t' (bind n' u))
            Lambda {} -> throwError "Cannot infer type of lambda without argument type"
            Pi n t u -> do
                t' <- check t Type
                n' <- fresh n
                u' <- local (addId n' t') $ check u Type
                pure (Pi n t' (bind n' u'), Type)
            Sigma t -> do
                t' <- checkSigma t
                pure (Sigma t', Type)
            Record t -> do
                (t', ts) <- inferRecord t
                pure (Record t', Sigma ts)
            Proj e l -> do
                (e', t) <- infer e
                l' <- normalize False l
                
                case (t, l') of
                    (Sigma r, Var (Free (x, _))) -> do
                        let record = unfold 0 r
                        case lookup x record of
                            Just v -> pure (Proj e' l', v)
                            Nothing -> throwError $ "field: " <> pack (show x) <> " not found in record\n" <> pack (show record)
                    (Sigma r, Int i) -> do
                        case atMay r i of
                            Nothing -> throwError "index out of bounds"
                            Just (Indexed v) -> pure (Proj e' l', v)
                            Just (Named _ v) -> pure (Proj e' l', v)
                            Just (LetR {}) -> throwError "recursive let not allowed in sigma type"
                    (_, Var _) -> throwError $ "Attempted projection to something not a record" <> pack (show t)
                    _ -> throwError "Projection must be to a label"
            Ascribe expr t -> do
                t' <- check t Type
                e' <- check expr t'
                pure (Ascribe e' t', t')
        unfold :: Int -> [Entry Local] -> [(Text, Nameless)]
        unfold _ [] = []
        unfold i (x:xs) =
            case x of
                Indexed  e ->
                    let end = unfold (i+1) xs
                    in (pack $ show i, e):end
                Named n e ->
                    let end = unfold (i+1) xs
                    in (n, e): end
                LetR {} -> []
check :: Nameless -> Type Local -> Gamma Nameless
check e ty = do
    ty' <- normalize False ty
    case (e, ty') of
        (Lambda n Nothing b, Pi _ t u) -> do
            x <- fresh n
            b' <- local (Context.addId x t) $ check b (open (Var (Free x)) u)
            pure $ Lambda n Nothing b'
        (Lambda _ Nothing _, _) -> throwError $ "expected function type, got: " <> pack (show ty') <> " against " <> pack (show e)
        _ -> do
            (e', t1) <- infer e
            equate t1 ty'
            pure e'

inferRecord :: [Entry Local] -> Gamma ([Entry Local], [Entry Local])
inferRecord [] = pure ([], [])
inferRecord (x:xs) =
    case x of
        Indexed e -> do
            (e', t) <- infer e
            (xs', ts) <- inferRecord xs
            pure (Indexed e': xs', Indexed t:ts)
        LetR n e t -> do
            n' <- fresh n
            t' <- check t Type
            e' <- local (Context.addId n' t') $ check e t'
            (xs', ts) <- local (Context.addDef n' e' . Context.addId n' t') $ inferRecord xs
            pure (Named n e':xs', Named n t':ts)
        Named n e -> do
            n' <- fresh n
            (e', t) <- infer e
            (xs', ts) <- local (Context.addDef n' e' . Context.addId n' t) $ inferRecord xs
            pure (Named n e':xs', Named n t:ts)

checkSigma :: [Entry Local] -> Gamma [Entry Local]
checkSigma [] = pure []
checkSigma (x:xs) =
    case x of
        Indexed e -> do
            e' <- check e Type
            xs' <- checkSigma xs
            pure (Indexed e':xs')
        Named n e -> do
            n' <- fresh n
            e' <- check e Type
            xs' <- local (Context.addId n' e') $ checkSigma xs
            pure (Named n e': xs')
        LetR {} -> throwError "recursive let is not allowed in sigma type"

equate :: Term Local -> Term Local -> Gamma ()
equate e1 e2 =
    if aeq e1 e2 
        then pure ()
        else do
            n1 <- normalize False e1
            n2 <- normalize False e2
            case (n1, n2) of
                (Type, Type) -> pure ()
                (IntT, IntT) -> pure ()
                (BoolT, BoolT) -> pure ()
                (Int i, Int j) | i == j -> pure ()
                (Bool a, Bool b) | a == b -> pure ()
                (Var x1, Var x2) | x1 == x2 -> pure ()
                (Apply l1 r1, Apply l2 r2) -> equate l1 l2 >> equate r1 r2
                (Proj e1 l1, Proj e2 l2) -> equate e1 e2 >> equate l1 l2
                (If a1 b1 c1, If a2 b2 c2) -> equate a1 a2 >> equate b1 b2 >> equate c1 c2
                (Lambda _ _ b1, Lambda _ _ b2) -> equate b1 b2
                (Pi _ t1 u1, Pi _ t2 u2) -> equate t1 t2 >> equate u1 u2
                (Record r1, Record r2) -> mapM_ equateRow (zip r1 r2)
                (Sigma r1, Sigma r2) -> mapM_ equateRow (zip r1 r2)
                _ -> throwError ("type mismatch\n\t" <> pack (show e1) <> "\n\t" <> pack (show e2))
    where
        equateRow (Indexed e1, Indexed e2) = equate e1 e2
        equateRow (Named n1 e1, Named n2 e2) = if n1 /= n2 then throwError "fields must match" else equate e1 e2
        equateRow (LetR n1 e1 t1, LetR n2 e2 t2) = if n1 /= n2 then throwError "fields must match" else equate e1 e2 >> equate t1 t2
        equateRow _ = throwError "indexed and named field at same position"