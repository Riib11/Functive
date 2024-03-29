{-# LANGUAGE LambdaCase #-}

module Typing where

import           Control.Monad
import           Control.Monad.Trans
import           Control.Monad.Trans.State as State
import qualified Data.ByteString           as BS
import qualified Data.ByteString.Char8     as BSC
import           Data.ByteString.Internal

import           Debug
import           Evaluating
import           Grammar

{-

  # Check

-}

type Check a = StateT TypeContext IO a

-- handles check in temporary sub-state
subCheck :: Check a -> Check a
subCheck check = do
                 saved_state <- get
                 a <- check
                 put saved_state
                 return a

{-

  # Type Context

-}

data TypeContext = TypeContext
  { freeTypeVarCounter :: Int
  , declarations       :: [Declaration]
  , rewrites           :: [Rewrite] }

data Rewrite     = Rewrite     Name TypeVar -- fn := t
data Declaration = Declaration Expr TypeVar -- e : t

instance Show TypeContext where
  show ctx =
    "rewrites:\n"     ++ foldl (\str r -> str++" - "++show r++"\n") "" (rewrites ctx) ++
    "declarations:\n" ++ foldl (\str d -> str++" - "++show d++"\n") "" (declarations ctx)

instance Show Declaration where
  show (Declaration e a) = show e++" : "++show a

instance Show Rewrite where
  show (Rewrite a b) = show a++" := "++show b

{-

  ## Utilities

-}

emptyTypeContext :: TypeContext
emptyTypeContext = TypeContext
  { freeTypeVarCounter = 0
  , declarations       = []
  , rewrites           = [] }

{-

  # Type Variable

-}

data TypeVar = Bound    Type
             | FreeName Name
             | FreeFunc TypeVar TypeVar
             | FreeAppl TypeVar TypeVar
             | FreeProd Name    TypeVar
             | FreeCons TypeVar Expr

instance Show TypeVar where
  show = \case Bound t      -> "{"++show t++"}"
               FreeName n   -> show n
               FreeFunc a b -> "("++show a++" -> "++show b++")"
               FreeAppl a b -> "("++show a++" "++show b++")"
               FreeProd n a -> "(forall "++show n++", "++show a++")"
               FreeCons a e -> "("++show a++" "++show e++")"

{-

  ## Syntactic Equality

-}

-- TODO: comparing FreeCons should make use of «evaluate»
syneqTypeVar :: TypeVar -> TypeVar -> Bool
syneqTypeVar a b = case (a, b) of
  (Bound t, Bound s)           -> syneqType t s
  (FreeName n,   FreeName m  ) -> syneqName n m
  (FreeAppl t s, FreeAppl r q) -> syneqTypeVar t r && syneqTypeVar s q
  (FreeProd n t, FreeProd m s) -> syneqName    n m && syneqTypeVar t s
  (FreeCons t e, FreeCons s f) -> syneqTypeVar t s && syneqExpr e f
  (_, _)                       -> False

{-

  ## Utilities

-}

-- create new FreeName of the form «t#» where "#" is a natural.
newFreeName :: Check TypeVar
newFreeName = do
  i <- gets freeTypeVarCounter
  modify $ \ctx -> ctx { freeTypeVarCounter=i+1 } -- increment
  let fn = FreeName . Name $ "t"++show i
  informCheck "FreeName" $ show fn
  return fn

getFreeNames :: TypeVar -> Check [Name]
getFreeNames = \case
  Bound    _   -> return []
  FreeName n   -> return [n]
  FreeFunc a b -> do
                  a_fns <- getFreeNames a
                  b_fns <- getFreeNames b
                  return $ a_fns ++ b_fns
  FreeAppl a b -> do
                  fa <- getFreeNames a
                  fb <- getFreeNames b
                  return $ fa ++ fb
  FreeProd n a -> getFreeNames a
  FreeCons a e -> getFreeNames a

{-

  # Rewriting

-}

-- ==> «a := t», where «a» is free and «t» cannot contain «a»
rewrite :: Rewrite -> Check ()
rewrite r@(Rewrite n t) = do
  n_tv <- getRewritten (FreeName n)
  t <- getRewritten t
  case n_tv of
    fn@(FreeName n) -> do
      let r = Rewrite n t
      informCheck "Rewrite" $ show r
      fns <- getFreeNames t
      if length fns > 1 && n `elem` fns
        then fail $ "self-referencial rewrite: "++show r
        else modify $ \ctx -> ctx { rewrites=r:rewrites ctx }
    _ -> error $ "rewrite of non-FreeName: "++show r

-- applies any rewrites in the given typevar
getRewritten :: TypeVar -> Check TypeVar
getRewritten = \case
    Bound    b   -> return $ Bound b
    FreeName n   -> getRewrittenFreeName n
    FreeFunc a b -> do
                    a' <- getRewritten a; b' <- getRewritten b
                    return $ FreeFunc a' b'
    FreeAppl a b -> do
                    a' <- getRewritten a
                    b' <- getRewritten b
                    return $ FreeAppl a' b'
    FreeProd n a -> do
                    a' <- getRewritten a
                    return $ FreeProd n a'
    FreeCons a e -> do
                    a' <- getRewritten a
                    return $ FreeCons a' e

getRewrittenFreeName :: Name -> Check TypeVar
getRewrittenFreeName n = do
  rsMatches <- filter (\(Rewrite n' s) -> n == n') <$> gets rewrites
  case rsMatches of
    []             -> return $ FreeName n
    [Rewrite n' s] -> getRewritten s
    _              -> fail "multiple rewrites of same FreeName"

getRewrittenType :: Type -> Check TypeVar
getRewrittenType = \case
  TypeName n   -> getRewritten $ FreeName n
  TypeFunc t s -> do
                  t <- getRewrittenType t
                  s <- getRewrittenType s
                  return $ FreeFunc t s
  TypeAppl t s -> do
                  t <- getRewrittenType t
                  s <- getRewrittenType s
                  return $ FreeAppl t s
  TypeProd n t -> do
                  t <- getRewrittenType t
                  return $ FreeProd n t
  TypeCons t e -> do
                  t <- getRewrittenType t
                  return $ FreeCons t e

{-

  # Declaring

-}

-- ==> «e : t»
declare :: Declaration -> Check ()
declare d@(Declaration e t) = do
  ds <- gets declarations
  t <- getRewritten t
  let d = Declaration e t
  informCheck "Declare" $ show d
  -- unify with the types of any previous declarations of «e»
  let f (Declaration e' t') hasUnified =
        if syneqExpr e e'
          then unify t t' >> return True
          else               return hasUnified
  -- add new declaration if «e» has already been declared
  hasUnified <- foldl (>>=) (return False) $ map f ds
  unless hasUnified . modify $ \ctx -> ctx { declarations=d:ds }

-- gets simplified type var declared for the given expression
-- if there is none in the current context, errors
getDeclaration :: Expr -> Check TypeVar
getDeclaration e =
  -- scan for first matching declaration
  let helper (Just a) _                 = return $ Just a  -- already found match
      helper Nothing  (Declaration f t) = if syneqExpr e f -- check for match
                                            then Just <$> getRewritten t
                                            else return Nothing
  in do
    ds <- gets declarations
    let fld jma (Declaration f t) = do
                                    ma <- jma
                                    helper ma (Declaration f t)
    mb_t <- foldl fld (return Nothing) ds
    case mb_t of
      Just t  -> return t
      Nothing -> fail $ "no declaration found for expr: " ++ show e

{-

  # Unifying

  Assert that two type variables are equal, then resolve this fact to be true via
  rewriting. If unresolvable, fail.

-}

-- attempts to unify types; may add rewrites to context
unify :: TypeVar -> TypeVar -> Check ()
unify tv1 tv2 = do
  tv1 <- getRewritten tv1
  tv2 <- getRewritten tv2
  informCheck "Begin Unify" $ show tv1++" <~> "++show tv2
  let unableToUnify = fail $ "unable to unify bound types: "++show tv1++" , "++show tv2
  let symmetric = unify tv2 tv1
  unless (syneqTypeVar tv1 tv2) $ case (tv1, tv2) of
    --
    -- Bound on left
    --
    -- t <~> fn
    (Bound t,              FreeName n  ) -> rewrite $ Rewrite n (Bound t)
    -- t <~> s
    (Bound t,              Bound s     ) -> unless (syneqType t s) unableToUnify
    -- (t -> s) <~> (a -> b)
    (Bound (TypeFunc t s), FreeFunc a b) -> do
                                            unify (Bound t) a
                                            unify (Bound s) b
    -- (t s) <~> (a b)
    (Bound (TypeAppl t s), FreeAppl a b) -> do
                                            unify (Bound t) a
                                            unify (Bound s) b
    -- (forall n, t)  <~> (forall m, a)
    (Bound (TypeProd n t), FreeProd m a) -> do
                                            nT <- getDeclaration (ExprName n)
                                            mT <- getDeclaration (ExprName m)
                                            unify nT mT
                                            unify (Bound t) a
    -- (t e) <~> (a f)
    (Bound (TypeCons t e), FreeCons a f) -> do
                                            unify (Bound t) a
                                            eT <- getDeclaration e
                                            fT <- getDeclaration f
                                            unify eT fT
    --
    -- Free on left
    --
    -- fn <~> a
    (FreeName n,           a           )  -> rewrite $ Rewrite n a
    -- (a -> b) <~> (c -> d)
    (FreeFunc a b,         FreeFunc c d)  -> do
                                             unify a c
                                             unify b d
    -- (a b) <~> (c d)
    (FreeAppl a b,         FreeAppl c d)  -> do
                                             unify a c
                                             unify b d
    -- (a e) <~> (b f)
    (FreeCons a e,         FreeCons b f)  -> do
                                             unify a b
                                             eT <- getDeclaration e
                                             fT <- getDeclaration f
                                             unify eT fT
    --
    -- symmetric cases
    --
    -- (a -> b) <~> _
    (FreeFunc a b, _) -> symmetric
    -- (a b) <~> _
    (FreeAppl a b, _) -> symmetric
    -- (a e) <~> _
    (FreeCons a e, _) -> symmetric
    --
    -- no other pairs can unify
    --
    (_,  _) -> unableToUnify
  informCheck "End Unify" $ show tv1++" <~> "++show tv2

{-

  ## Primitive Types

-}

bindPrimitive :: Name -> Check ()
bindPrimitive n = do
  informCheck "Primitive" $ show n
  rewrite $ Rewrite n (Bound $ TypeName n)

{-

  # Type Checking

-}

{-

  ## Check Prgm

-}

checkPrgm :: Prgm -> Check ()
checkPrgm (Prgm stmts) = do
                         informCheck "Begin Check" "Prgm ..."
                         void $ traverse checkStmt stmts
                         informCheck "End Check"   "Prgm ..."

{-

  ## Check Stmt

-}


checkStmt :: Stmt -> Check ()
checkStmt stmt = do
  informCheck "Begin Check" $ show stmt
  case stmt of
    -- Definition n : t := e .
    Definition n t e -> do
                        t <- getRewrittenType t
                        s <- subCheck $ do
                               checkExpr e
                               getDeclaration e              -- e:s
                        unify t s                            -- t <~> s
                        declare $ Declaration (ExprName n) t -- ==> n:t
    -- Fixedpoint n : t := e .
    Fixedpoint n t e -> do
                        t <- getRewrittenType t
                        declare $ Declaration (ExprName n) t -- => n:t
                        s <- subCheck $ do
                               checkExpr e
                               getDeclaration e              -- e:s
                        unify t s                            -- t <~> s
    -- Assumption n : t .
    Assumption n t   -> do
                        t <- getRewrittenType t
                        declare $ Declaration (ExprName n) t -- ==> n:t
    -- Signature n := t .
    Signature  n t   -> do
                        t <- getRewrittenType t
                        rewrite $ Rewrite n t                -- ==> n := t
    -- Primitive n .
    Primitive  n     -> bindPrimitive n                      -- ==> primitive(n)
  informCheck "End Check" $ show stmt

{-

  ## Check Expr

-}

checkExpr :: Expr -> Check ()
checkExpr expr = do
  informCheck "Begin Check" $ show expr
  case expr of
    -- n
    ExprName n     -> do
                   let ne = ExprName n
                   a <- newFreeName                           -- + a
                   declare $ Declaration ne a                 -- ==> n : a
    -- (n => e)
    ExprFunc n e   -> do
                      let ne = ExprName n
                      (a, b) <- subCheck $ do                 -- open local context
                        checkExpr e; b <- getDeclaration e    -- e : b
                        checkExpr ne; a <- getDeclaration ne  -- n : a
                        return (a, b)                         -- close local context
                                                              -- ==> (fun n=>e) : (a->b)
                      declare $ Declaration (ExprFunc n e) (FreeFunc a b)
    -- (rec n of m => e)
    ExprRecu n m e -> do
                      let (ne, me) = (ExprName n, ExprName m)
                      (a, b, c) <- subCheck $ do             -- open local context
                        checkExpr e; b <- getDeclaration e   -- e : b
                        checkExpr me; a <- getDeclaration me -- n : c
                        checkExpr ne; c <- getDeclaration ne -- m : a
                        return (a, b, c)                     -- close local context
                      unify b c                              -- ==> b <~> c
                                                             -- (rec n of m => e) : a -> b
                      declare $ Declaration (ExprRecu n m e) (FreeFunc a b)
    -- (e f)
    ExprAppl e f   -> do
                      checkExpr e; a <- getDeclaration e      -- e : a
                      debugState
                      checkExpr f; b <- getDeclaration f      -- f : b
                      debugState
                      c <- newFreeName                        -- ==> + c
                      unify a (FreeFunc b c)                  -- a <~> (b -> c)
                      debugState
                      declare $ Declaration (ExprAppl e f) c  -- (e f) : c
                      debugState
  getDeclaration expr >>= informCheck "End Check" . show

{-

  # Logging

-}

informCheck :: String -> String -> Check ()
informCheck hdr msg = lift.inform $ buffer 20 hdr++" "++msg

debugState :: Check ()
debugState = get >>= lift.debug.show
