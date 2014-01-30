-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.CodeGen.JS
-- Copyright   :  (c) Phil Freeman 2013
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
-- This module generates code in the simplified Javascript intermediate representation from Purescript code
--
-----------------------------------------------------------------------------

{-# LANGUAGE DoAndIfThenElse #-}

module Language.PureScript.CodeGen.JS (
    module AST,
    declToJs,
    moduleToJs
) where

import Data.Maybe (fromMaybe, mapMaybe)
import Data.List (sortBy)
import Data.Function (on)

import Control.Arrow (second)
import Control.Monad (replicateM, forM)

import qualified Data.Map as M

import Language.PureScript.TypeChecker (Environment(..), NameKind(..))
import Language.PureScript.Values
import Language.PureScript.Names
import Language.PureScript.Scope
import Language.PureScript.Declarations
import Language.PureScript.Pretty.Common
import Language.PureScript.CodeGen.Monad
import Language.PureScript.Options
import Language.PureScript.CodeGen.JS.AST as AST
import Language.PureScript.Types
import Language.PureScript.CodeGen.Optimize
import Language.PureScript.TypeChecker.Monad (canonicalizeType)

-- |
-- Generate code in the simplified Javascript intermediate representation for all declarations in a module
--
moduleToJs :: Options -> Module -> Environment -> [JS]
moduleToJs opts (Module pname@(ProperName name) decls) env =
  [ JSVariableIntroduction (Ident name) Nothing
  , JSApp (JSFunction Nothing [Ident name]
                      (JSBlock (concat $ mapMaybe (\decl -> fmap (map $ optimize opts) $ declToJs opts (ModuleName pname) decl env) (sortBy typeClassesLast decls))))
          [JSAssignment (JSAssignVariable (Ident name))
                         (JSBinary Or (JSVar (Ident name)) (JSObjectLiteral []))]
  ]
  where
  typeClassesLast (ExternDeclaration TypeClassDictionaryImport _ _ _) (ExternDeclaration TypeClassDictionaryImport _ _ _) = EQ
  typeClassesLast (ExternDeclaration TypeClassDictionaryImport _ _ _) _ = GT
  typeClassesLast _ (ExternDeclaration TypeClassDictionaryImport _ _ _) = LT
  typeClassesLast _ _ = EQ

-- |
-- Generate code in the simplified Javascript intermediate representation for a declaration
--
declToJs :: Options -> ModuleName -> Declaration -> Environment -> Maybe [JS]
declToJs opts mp (ValueDeclaration ident _ _ val) e =
  Just [ JSVariableIntroduction ident (Just (valueToJs opts mp e val)),
         setProperty (identToJs ident) (JSVar ident) mp ]
declToJs opts mp (BindingGroupDeclaration vals) e =
  Just $ concatMap (\(ident, val) ->
           [ JSVariableIntroduction ident (Just (valueToJs opts mp e val)),
             setProperty (identToJs ident) (JSVar ident) mp ]
         ) vals
declToJs _ mp (DataDeclaration _ _ ctors) _ =
  Just $ flip concatMap ctors $ \(pn@(ProperName ctor), maybeTy) ->
    let
      ctorJs =
        case maybeTy of
          Nothing -> JSVariableIntroduction (Ident ctor) (Just (JSObjectLiteral [ ("ctor", JSStringLiteral (show (Qualified (Just mp) pn))) ]))
          Just _ -> JSFunction (Just (Ident ctor)) [Ident "value"]
                      (JSBlock [JSReturn
                        (JSObjectLiteral [ ("ctor", JSStringLiteral (show (Qualified (Just mp) pn)))
                                         , ("value", JSVar (Ident "value")) ])])
    in [ ctorJs, setProperty ctor (JSVar (Ident ctor)) mp ]
declToJs opts mp (DataBindingGroupDeclaration ds) e =
  Just $ concat $ mapMaybe (flip (declToJs opts mp) e) ds
declToJs _ mp (ExternDeclaration importTy ident (Just js) _) _ =
  Just [ js
       , setProperty (identToJs ident) (JSVar ident) mp ]
declToJs _ _ _ _ = Nothing

setProperty :: String -> JS -> ModuleName -> JS
setProperty prop val (ModuleName (ProperName moduleName)) = JSAssignment (JSAssignProperty prop (JSAssignVariable (Ident moduleName))) val

valueToJs :: Options -> ModuleName -> Environment -> Value -> JS
valueToJs _ _ _ (NumericLiteral n) = JSNumericLiteral n
valueToJs _ _ _ (StringLiteral s) = JSStringLiteral s
valueToJs _ _ _ (BooleanLiteral b) = JSBooleanLiteral b
valueToJs opts m e (ArrayLiteral xs) = JSArrayLiteral (map (valueToJs opts m e) xs)
valueToJs opts m e (ObjectLiteral ps) = JSObjectLiteral (map (second (valueToJs opts m e)) ps)
valueToJs opts m e (ObjectUpdate o ps) = JSApp (JSAccessor "extend" (JSVar (Ident "Object"))) [ valueToJs opts m e o, JSObjectLiteral (map (second (valueToJs opts m e)) ps)]
valueToJs _ m e (Constructor (Qualified Nothing name)) =
  case M.lookup (m, name) (dataConstructors e) of
    Just (_, Alias aliasModule aliasIdent) -> qualifiedToJS identToJs (Qualified (Just aliasModule) aliasIdent)
    _ -> JSVar . Ident . runProperName $ name
valueToJs _ _ _ (Constructor name) = qualifiedToJS runProperName name
valueToJs opts m e (Block sts) = JSApp (JSFunction Nothing [] (JSBlock (map (statementToJs opts m e) sts))) []
valueToJs opts m e (Case values binders) = bindersToJs opts m e binders (map (valueToJs opts m e) values)
valueToJs opts m e (IfThenElse cond th el) = JSConditional (valueToJs opts m e cond) (valueToJs opts m e th) (valueToJs opts m e el)
valueToJs opts m e (Accessor prop val) = JSAccessor prop (valueToJs opts m e val)
valueToJs opts m e (Indexer index val) = JSIndexer (valueToJs opts m e index) (valueToJs opts m e val)
valueToJs opts m e (App val args) = JSApp (valueToJs opts m e val) (map (valueToJs opts m e) args)
valueToJs opts m e (Abs args val) = JSFunction Nothing args (JSBlock [JSReturn (valueToJs opts m e val)])
valueToJs opts m e (TypedValue _ (Abs args val) ty) | optionsPerformRuntimeTypeChecks opts = JSFunction Nothing args (JSBlock $ runtimeTypeChecks args ty ++ [JSReturn (valueToJs opts m e val)])
valueToJs opts m e (Unary op val) = JSUnary op (valueToJs opts m e val)
valueToJs opts m e (Binary op v1 v2) = JSBinary op (valueToJs opts m e v1) (valueToJs opts m e v2)
valueToJs _ m e (Var ident) = varToJs m e ident
valueToJs opts m e (TypedValue _ val _) = valueToJs opts m e val
valueToJs _ _ _ (TypeClassDictionary _ _) = error "Type class dictionary was not replaced"
valueToJs _ _ _ _ = error "Invalid argument to valueToJs"

runtimeTypeChecks :: [Ident] -> Type -> [JS]
runtimeTypeChecks args ty =
  let
    argTys = getFunctionArgumentTypes ty
  in
    concat $ zipWith argumentCheck (map JSVar args) argTys
  where
  getFunctionArgumentTypes :: Type -> [Type]
  getFunctionArgumentTypes (Function funArgs _) = funArgs
  getFunctionArgumentTypes (ForAll _ ty') = getFunctionArgumentTypes ty'
  getFunctionArgumentTypes _ = []
  argumentCheck :: JS -> Type -> [JS]
  argumentCheck val Number = [typeCheck val "number"]
  argumentCheck val String = [typeCheck val "string"]
  argumentCheck val Boolean = [typeCheck val "boolean"]
  argumentCheck val (TypeApp Array _) = [arrayCheck val]
  argumentCheck val (Object row) =
    let
      (pairs, _) = rowToList row
    in
      typeCheck val "object" : concatMap (\(prop, ty') -> argumentCheck (JSAccessor prop val) ty') pairs
  argumentCheck val (Function _ _) = [typeCheck val "function"]
  argumentCheck val (ForAll _ ty') = argumentCheck val ty'
  argumentCheck _ _ = []
  typeCheck :: JS -> String -> JS
  typeCheck js ty' = JSIfElse (JSBinary NotEqualTo (JSTypeOf js) (JSStringLiteral ty')) (JSBlock [JSThrow (JSStringLiteral $ ty' ++ " expected")]) Nothing
  arrayCheck :: JS -> JS
  arrayCheck js = JSIfElse (JSUnary Not (JSApp (JSAccessor "isArray" (JSVar (Ident "Array"))) [js])) (JSBlock [JSThrow (JSStringLiteral "Array expected")]) Nothing

varToJs :: ModuleName -> Environment -> Qualified Ident -> JS
varToJs m e qual@(Qualified _ ident) = case M.lookup (qualify m qual) (names e) of
  Just (_, ty) | isExtern ty -> JSVar ident
  Just (_, Alias aliasModule aliasIdent) -> qualifiedToJS identToJs (Qualified (Just aliasModule) aliasIdent)
  _ -> case qual of
         Qualified Nothing _ -> JSVar ident
         _ -> qualifiedToJS identToJs qual
  where
  isExtern (Extern ForeignImport) = True
  isExtern (Alias m' ident') = case M.lookup (m', ident') (names e) of
    Just (_, ty') -> isExtern ty'
    Nothing -> error "Undefined alias in varToJs"
  isExtern _ = False

qualifiedToJS :: (a -> String) -> Qualified a -> JS
qualifiedToJS f (Qualified (Just (ModuleName (ProperName m))) a) = JSAccessor (f a) (JSVar (Ident m))
qualifiedToJS f (Qualified Nothing a) = JSVar (Ident (f a))

bindersToJs :: Options -> ModuleName -> Environment -> [([Binder], Maybe Guard, Value)] -> [JS] -> JS
bindersToJs opts m e binders vals = runGen (unusedNames (binders, vals)) $ do
  valNames <- replicateM (length vals) fresh
  jss <- forM binders $ \(bs, grd, result) -> go valNames [JSReturn (valueToJs opts m e result)] bs grd
  return $ JSApp (JSFunction Nothing valNames (JSBlock (concat jss ++ [JSThrow (JSStringLiteral "Failed pattern match")])))
                 vals
  where
    go :: [Ident] -> [JS] -> [Binder] -> Maybe Guard -> Gen [JS]
    go _ done [] Nothing = return done
    go _ done [] (Just cond) = return [JSIfElse (valueToJs opts m e cond) (JSBlock done) Nothing]
    go (v:vs) done' (b:bs) grd = do
      done'' <- go vs done' bs grd
      binderToJs m e v done'' b
    go _ _ _ _ = error "Invalid arguments to bindersToJs"

binderToJs :: ModuleName -> Environment -> Ident -> [JS] -> Binder -> Gen [JS]
binderToJs _ _ _ done NullBinder = return done
binderToJs _ _ varName done (StringBinder str) =
  return [JSIfElse (JSBinary EqualTo (JSVar varName) (JSStringLiteral str)) (JSBlock done) Nothing]
binderToJs _ _ varName done (NumberBinder num) =
  return [JSIfElse (JSBinary EqualTo (JSVar varName) (JSNumericLiteral num)) (JSBlock done) Nothing]
binderToJs _ _ varName done (BooleanBinder True) =
  return [JSIfElse (JSVar varName) (JSBlock done) Nothing]
binderToJs _ _ varName done (BooleanBinder False) =
  return [JSIfElse (JSUnary Not (JSVar varName)) (JSBlock done) Nothing]
binderToJs _ _ varName done (VarBinder ident) =
  return (JSVariableIntroduction ident (Just (JSVar varName)) : done)
binderToJs m e varName done (NullaryBinder ctor) =
  if isOnlyConstructor m e ctor
  then
    return done
  else
    return [JSIfElse (JSBinary EqualTo (JSAccessor "ctor" (JSVar varName)) (JSStringLiteral (show ((\(mp, nm) -> Qualified (Just mp) nm) $ canonicalizeType m e ctor)))) (JSBlock done) Nothing]
binderToJs m e varName done (UnaryBinder ctor b) = do
  value <- fresh
  js <- binderToJs m e value done b
  let success = JSBlock (JSVariableIntroduction value (Just (JSAccessor "value" (JSVar varName))) : js)
  if isOnlyConstructor m e ctor
  then
    return [success]
  else
    return [JSIfElse (JSBinary EqualTo (JSAccessor "ctor" (JSVar varName)) (JSStringLiteral (show ((\(mp, nm) -> Qualified (Just mp) nm) $ canonicalizeType m e ctor))))
                     success
                     Nothing]
binderToJs m e varName done (ObjectBinder bs) = go done bs
  where
  go :: [JS] -> [(String, Binder)] -> Gen [JS]
  go done' [] = return done'
  go done' ((prop, binder):bs') = do
    propVar <- fresh
    done'' <- go done' bs'
    js <- binderToJs m e propVar done'' binder
    return (JSVariableIntroduction propVar (Just (JSAccessor prop (JSVar varName))) : js)
binderToJs m e varName done (ArrayBinder bs) = do
  js <- go done 0 bs
  return [JSIfElse (JSBinary EqualTo (JSAccessor "length" (JSVar varName)) (JSNumericLiteral (Left (fromIntegral $ length bs)))) (JSBlock js) Nothing]
  where
  go :: [JS] -> Integer -> [Binder] -> Gen [JS]
  go done' _ [] = return done'
  go done' index (binder:bs') = do
    elVar <- fresh
    done'' <- go done' (index + 1) bs'
    js <- binderToJs m e elVar done'' binder
    return (JSVariableIntroduction elVar (Just (JSIndexer (JSNumericLiteral (Left index)) (JSVar varName))) : js)
binderToJs m e varName done (ConsBinder headBinder tailBinder) = do
  headVar <- fresh
  tailVar <- fresh
  js1 <- binderToJs m e headVar done headBinder
  js2 <- binderToJs m e tailVar js1 tailBinder
  return [JSIfElse (JSBinary GreaterThan (JSAccessor "length" (JSVar varName)) (JSNumericLiteral (Left 0))) (JSBlock
    ( JSVariableIntroduction headVar (Just (JSIndexer (JSNumericLiteral (Left 0)) (JSVar varName))) :
      JSVariableIntroduction tailVar (Just (JSApp (JSAccessor "slice" (JSVar varName)) [JSNumericLiteral (Left 1)])) :
      js2
    )) Nothing]
binderToJs m e varName done (NamedBinder ident binder) = do
  js <- binderToJs m e varName done binder
  return (JSVariableIntroduction ident (Just (JSVar varName)) : js)

isOnlyConstructor :: ModuleName -> Environment -> Qualified ProperName -> Bool
isOnlyConstructor m e ctor =
  let (ty, _) = fromMaybe (error "Data constructor not found") $ qualify m ctor `M.lookup` dataConstructors e
  in numConstructors ty == 1
  where
  numConstructors ty = length $ filter (\(ty1, _) -> ((==) `on` typeConstructor) ty ty1) $ M.elems $ dataConstructors e
  typeConstructor (TypeConstructor qual) = qualify m qual
  typeConstructor (ForAll _ ty) = typeConstructor ty
  typeConstructor (Function _ ty) = typeConstructor ty
  typeConstructor (TypeApp ty _) = typeConstructor ty
  typeConstructor fn = error $ "Invalid arguments to typeConstructor: " ++ show fn

statementToJs :: Options -> ModuleName -> Environment -> Statement -> JS
statementToJs opts m e (VariableIntroduction ident value) = JSVariableIntroduction ident (Just (valueToJs opts m e value))
statementToJs opts m e (Assignment target value) = JSAssignment (JSAssignVariable target) (valueToJs opts m e value)
statementToJs opts m e (While cond sts) = JSWhile (valueToJs opts m e cond) (JSBlock (map (statementToJs opts m e) sts))
statementToJs opts m e (For ident start end sts) = JSFor ident (valueToJs opts m e start) (valueToJs opts m e end) (JSBlock (map (statementToJs opts m e) sts))
statementToJs opts m e (If ifst) = ifToJs ifst
  where
  ifToJs :: IfStatement -> JS
  ifToJs (IfStatement cond thens elses) = JSIfElse (valueToJs opts m e cond) (JSBlock (map (statementToJs opts m e) thens)) (fmap elseToJs elses)
  elseToJs :: ElseStatement -> JS
  elseToJs (Else sts) = JSBlock (map (statementToJs opts m e) sts)
  elseToJs (ElseIf elif) = ifToJs elif
statementToJs opts m e (Return value) = JSReturn (valueToJs opts m e value)
