{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module Generate.JavaScript
  ( ReplBuilder(..)
  , generateForRepl
  , Mode(..)
  , MainsBuilder(..)
  , MainTrie(..)
  , generateMains
  )
  where


import Prelude hiding (cycle)
import qualified Data.ByteString.Builder as B
import Data.Monoid ((<>))
import qualified Data.List as List
import Data.Map ((!))
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text

import qualified AST.Optimized as Opt
import qualified AST.Module.Name as ModuleName
import qualified Elm.Interface as I
import qualified Elm.Name as N
import qualified Generate.JavaScript.Builder as JS
import qualified Generate.JavaScript.Expression as Expr
import qualified Generate.JavaScript.Name as Name



-- GENERATE FOR REPL


data ReplBuilder =
  ReplBuilder
    { _repl_code :: B.Builder
    , _repl_name :: B.Builder
    }


generateForRepl :: Opt.Graph -> ModuleName.Canonical -> N.Name -> ReplBuilder
generateForRepl (Opt.Graph _ graph _) home name =
  ReplBuilder
    { _repl_code =
        stateToBuilder $
          addGlobal (Name.Debug Name.Client) graph emptyState (Opt.Global home name)
    , _repl_name =
        Name.toBuilder (Name.fromGlobal home name)
    }



-- GENERATE MAINS


data MainsBuilder =
  MainsBuilder
    { _main_code :: B.Builder
    , _main_trie :: MainTrie
    }


data Mode = Debug | Prod


generateMains :: Mode -> Name.Target -> Opt.Graph -> I.Interfaces -> [ModuleName.Canonical] -> Either [ModuleName.Canonical] MainsBuilder
generateMains mode target (Opt.Graph mains graph fields) interfaces roots =
  let
    rootSet = Set.fromList roots
    rootMap = Map.restrictKeys mains rootSet
  in
  if Map.size rootMap == Set.size rootSet then
    let
      realMode = toRealMode mode target fields
      state = Map.foldrWithKey (addMain realMode graph) emptyState rootMap
    in
    Right $ MainsBuilder (stateToBuilder state) (toMainTrie realMode interfaces rootMap)

  else
    Left $ Set.toList $
      Set.intersection rootSet (Map.keysSet mains)


addMain :: Name.Mode -> Graph -> ModuleName.Canonical -> main -> State -> State
addMain mode graph home _ state =
  addGlobal mode graph state (Opt.Global home "main")


toRealMode :: Mode -> Name.Target -> Map.Map N.Name Int -> Name.Mode
toRealMode mode target fields =
  case mode of
    Debug ->
      Name.Debug target

    Prod ->
      Name.Prod target (Name.shortenFieldNames fields)



-- GRAPH TRAVERSAL STATE


data State =
  State
    { _revBuilders :: [B.Builder]
    , _seenGlobals :: Set.Set Opt.Global
    }


emptyState :: State
emptyState =
  State [] Set.empty


stateToBuilder :: State -> B.Builder
stateToBuilder (State revBuilders _) =
  List.foldl1' (\builder b -> b <> builder) revBuilders



-- ADD DEPENDENCIES


type Graph = Map.Map Opt.Global Opt.Node


addGlobal :: Name.Mode -> Graph -> State -> Opt.Global -> State
addGlobal mode graph state@(State builders seen) global =
  if Set.member global seen then
    state
  else
    addGlobalHelp mode graph global $
      State builders (Set.insert global seen)


addGlobalHelp :: Name.Mode -> Graph -> Opt.Global -> State -> State
addGlobalHelp mode graph global state =
  let
    addDeps deps someState =
      Set.foldl' (addGlobal mode graph) someState deps
  in
  case graph ! global of
    Opt.Define expr deps ->
      addStmt (addDeps deps state) (
        var global (Expr.generate mode expr)
      )

    Opt.DefineTailFunc argNames body deps ->
      addStmt (addDeps deps state) (
        var global (Expr.generateFunction (map Name.fromLocal argNames) (Expr.generate mode body))
      )

    Opt.Ctor name index arity ->
      let (args, ctor) = Expr.generateCtor mode name index arity in
      addStmt state (
        var global (Expr.generateFunction args ctor)
      )

    Opt.Link linkedGlobal ->
      addGlobal mode graph state linkedGlobal

    Opt.Cycle cycle deps ->
      addStmt (addDeps deps state) (
        generateCycle mode global cycle
      )

    Opt.Manager effectsType ->
      generateManager mode graph global effectsType state

    Opt.Kernel (Opt.KContent clientChunks clientDeps) maybeServer ->
      case maybeServer of
        Just (Opt.KContent serverChunks serverDeps) | Name.isServer mode ->
          addBuilder (addDeps serverDeps state) (generateKernel mode serverChunks)

        _ ->
          addBuilder (addDeps clientDeps state) (generateKernel mode clientChunks)

    Opt.PortIncoming decoder deps ->
      addStmt (addDeps deps state) (
        generatePort mode global "incomingPort" decoder
      )

    Opt.PortOutgoing encoder deps ->
      addStmt (addDeps deps state) (
        generatePort mode global "outgoingPort" encoder
      )


addStmt :: State -> JS.Stmt -> State
addStmt state stmt =
  addBuilder state (JS.stmtToBuilder stmt)


addBuilder :: State -> B.Builder -> State
addBuilder (State revBuilders seen) builder =
  State (builder:revBuilders) seen


var :: Opt.Global -> Expr.Code -> JS.Stmt
var (Opt.Global home name) code =
  JS.Var [ (Name.fromGlobal home name, Just (Expr.codeToExpr code)) ]



-- GENERATE CYCLES


generateCycle :: Name.Mode -> Opt.Global -> [(N.Name, Opt.Expr)] -> JS.Stmt
generateCycle mode (Opt.Global home _) cycle =
  let
    safeDefs = map (generateSafeCycle mode home) cycle
    realDefs = map (generateRealCycle home) cycle
    -- TODO add `try` in debug mode nice infinite recursion reports
  in
  JS.Block (safeDefs ++ realDefs)


generateSafeCycle :: Name.Mode -> ModuleName.Canonical -> (N.Name, Opt.Expr) -> JS.Stmt
generateSafeCycle mode home (name, expr) =
  JS.FunctionStmt (Name.fromCycle home name) [] $
    Expr.codeToStmtList (Expr.generate mode expr)


generateRealCycle :: ModuleName.Canonical -> (N.Name, expr) -> JS.Stmt
generateRealCycle home (name, _) =
  let
    safeName = Name.fromCycle home name
    realName = Name.fromGlobal home name
  in
  JS.Block
    [ JS.Var [ ( realName, Just (JS.Call (JS.Ref safeName) []) ) ]
    , JS.ExprStmt $ JS.Assign (JS.LRef safeName) $
        JS.Function Nothing [] [ JS.Return (Just (JS.Ref realName)) ]
    ]



-- GENERATE KERNEL


generateKernel :: Name.Mode -> [Opt.KChunk] -> B.Builder
generateKernel mode chunks =
  List.foldl' (addChunk mode) mempty chunks


addChunk :: Name.Mode -> B.Builder -> Opt.KChunk -> B.Builder
addChunk mode builder chunk =
  case chunk of
    Opt.JS javascript ->
      B.byteString javascript <> builder

    Opt.ElmVar home name ->
      Name.toBuilder (Name.fromGlobal home name) <> builder

    Opt.JsVar home name ->
      Name.toBuilder (Name.fromKernel home name) <> builder

    Opt.ElmField name ->
      Name.toBuilder (Name.fromField mode name) <> builder

    Opt.JsField int ->
      Name.toBuilder (Name.fromInt int) <> builder

    Opt.Enum int ->
      Name.toBuilder (Name.fromInt int) <> builder

    Opt.Debug ->
      case mode of
        Name.Debug _ ->
          builder

        Name.Prod _ _ ->
          "_UNUSED" <> builder

    Opt.Prod ->
      case mode of
        Name.Debug _ ->
          "_UNUSED" <> builder

        Name.Prod _ _ ->
          builder



-- GENERATE PORTS


generatePort :: Name.Mode -> Opt.Global -> N.Name -> Opt.Expr -> JS.Stmt
generatePort mode (Opt.Global home name) makePort converter =
  let
    definition =
      JS.Call (JS.Ref (Name.fromKernel N.platform makePort))
        [ JS.String (N.toBuilder name)
        , Expr.codeToExpr (Expr.generate mode converter)
        ]
  in
  JS.Var [ (Name.fromGlobal home name, Just definition) ]



-- GENERATE MANAGER



generateManager :: Name.Mode -> Graph -> Opt.Global -> Opt.EffectsType -> State -> State
generateManager mode graph (Opt.Global home@(ModuleName.Canonical _ moduleName) _) effectsType state =
  let
    managerLVar =
      JS.LBracket
        (JS.Ref (Name.fromKernel N.platform "effectManagers"))
        (JS.String (N.toBuilder moduleName))

    (deps, args, stmts) =
      generateManagerHelp home effectsType

    createManager =
      JS.ExprStmt $ JS.Assign managerLVar $
        JS.Call (JS.Ref (Name.fromKernel N.platform "createManager")) args
  in
  addStmt (List.foldl' (addGlobal mode graph) state deps) $
    JS.Block (createManager : stmts)


generateLeaf :: ModuleName.Canonical -> N.Name -> JS.Stmt
generateLeaf home@(ModuleName.Canonical _ moduleName) name =
  let
    definition =
      JS.Call leaf [ JS.String (N.toBuilder moduleName) ]
  in
  JS.Var [ (Name.fromGlobal home name, Just definition) ]


{-# NOINLINE leaf #-}
leaf :: JS.Expr
leaf =
  JS.Ref (Name.fromKernel N.platform "leaf")


generateManagerHelp :: ModuleName.Canonical -> Opt.EffectsType -> ([Opt.Global], [JS.Expr], [JS.Stmt])
generateManagerHelp home effectsType =
  let
    dep name = Opt.Global home name
    ref name = JS.Ref (Name.fromGlobal home name)
  in
  case effectsType of
    Opt.Cmd ->
      ( [ dep "init", dep "onEffects", dep "onSelfMsg", dep "cmdMap" ]
      , [ ref "init", ref "onEffects", ref "onSelfMsg", ref "cmdMap" ]
      , [ generateLeaf home "command" ]
      )

    Opt.Sub ->
      ( [ dep "init", dep "onEffects", dep "onSelfMsg", dep "subMap" ]
      , [ ref "init", ref "onEffects", ref "onSelfMsg", JS.Int 0, ref "subMap" ]
      , [ generateLeaf home "subscription" ]
      )

    Opt.Fx ->
      ( [ dep "init", dep "onEffects", dep "onSelfMsg", dep "cmdMap", dep "subMap" ]
      , [ ref "init", ref "onEffects", ref "onSelfMsg", ref "cmdMap", ref "subMap" ]
      , [ generateLeaf home "command"
        , generateLeaf home "subscription"
        ]
      )



-- MAIN TRIE


data MainTrie =
  MainTrie
    { _main :: Maybe B.Builder
    , _subs :: Map.Map N.Name MainTrie
    }


emptyTrie :: MainTrie
emptyTrie =
  MainTrie Nothing Map.empty


toMainTrie :: Name.Mode -> I.Interfaces -> Map.Map ModuleName.Canonical Opt.Main -> MainTrie
toMainTrie mode interfaces mains =
  Map.foldrWithKey (addMainTrie mode interfaces) emptyTrie mains


addMainTrie :: Name.Mode -> I.Interfaces -> ModuleName.Canonical -> Opt.Main -> MainTrie -> MainTrie
addMainTrie mode interfaces home@(ModuleName.Canonical _ moduleName) main trie =
  let
    segments = Text.splitOn "." moduleName
    initMain = Expr.generateMain mode interfaces home segments main
    newTrie = segmentsToTrie segments (JS.exprToBuilder initMain)
  in
  merge trie newTrie


segmentsToTrie :: [N.Name] -> B.Builder -> MainTrie
segmentsToTrie segments mainBuilder =
  case segments of
    [] ->
      MainTrie (Just mainBuilder) Map.empty

    segment : otherSegments ->
      MainTrie Nothing (Map.singleton segment (segmentsToTrie otherSegments mainBuilder))


merge :: MainTrie -> MainTrie -> MainTrie
merge (MainTrie main1 subs1) (MainTrie main2 subs2) =
  MainTrie
    (checkedMerge main1 main2)
    (Map.unionWith merge subs1 subs2)


checkedMerge :: Maybe a -> Maybe a -> Maybe a
checkedMerge a b =
  case (a, b) of
    (Nothing, main) ->
      main

    (main, Nothing) ->
      main

    (Just _, Just _) ->
      error "cannot have two modules with the same name"
