{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
-- | This module exports all functions used for evaluation of IHaskell input.
module IHaskell.Eval.Evaluate (
  interpret, evaluate, Interpreter, liftIO
  ) where

import ClassyPrelude hiding (liftIO, hGetContents)
import Prelude(putChar, tail, init)
import Data.List.Utils
import Data.List(findIndex)
import Data.String.Utils
import Text.Printf
import System.Random

import Language.Haskell.Exts.Parser
import Language.Haskell.Exts.Pretty
import Language.Haskell.Exts.Syntax hiding (Name)

import InteractiveEval
import HscTypes
import GhcMonad (liftIO)
import GHC hiding (Stmt)
import GHC.Paths
import Exception hiding (evaluate)

import qualified System.IO.Strict as StrictIO

import IHaskell.Types

debug :: Bool
debug = False

write :: GhcMonad m => String -> m ()
write x = when debug $ liftIO $ hPutStrLn stderr x

type LineNumber = Int
type ColumnNumber = Int
type Interpreter = Ghc
data Command
  = Directive String
  | Import String
  | Declaration String
  | Statement String
  | ParseError LineNumber ColumnNumber String
  deriving Show

globalImports :: [String]
globalImports = 
  [ "import Prelude"
  , "import Control.Applicative ((<$>))"
  , "import GHC.IO.Handle (hDuplicateTo, hDuplicate)"
  , "import System.IO"
  ]

directiveChar :: Char
directiveChar = ':'

-- | Run an interpreting action. This is effectively runGhc with
-- initialization and importing.
interpret :: Interpreter a -> IO a
interpret action = runGhc (Just libdir) $ do
  -- Set the dynamic session flags
  dflags <- getSessionDynFlags
  setSessionDynFlags $ dflags { hscTarget = HscInterpreted, ghcLink = LinkInMemory }

  -- Import modules.
  imports <- mapM parseImportDecl globalImports
  setContext $ map IIDecl imports

  -- Run the rest of the interpreter
  action

-- | Evaluate some IPython input code.
evaluate :: String                    -- ^ Haskell code or other interpreter commands.
         -> Interpreter [DisplayData] -- ^ All of the output.
evaluate code
  | strip code == "" = return [] 
  | otherwise = joinDisplays <$> mapM evalCommand (parseCommands $ strip code)

joinDisplays :: [[DisplayData]] -> [DisplayData]
joinDisplays displays = 
  let isPlain (Display mime _) = (mime == PlainText)
      allDisplays = concat displays
      plains = filter isPlain allDisplays
      other = filter (not . isPlain) allDisplays 
      getText (Display PlainText text) = text
      joinedPlains = Display PlainText $ concat $ map getText plains in
    joinedPlains : other

parseCommands :: String     -- ^ Code containing commands.
              -> [Command]  -- ^ Commands contained in code string.
parseCommands code = concatMap makeCommands pieces
  where
    -- Group the text into different pieces.
    -- Pieces can be declarations, statement lists, or directives.
    -- We distinguish declarations from statements via the first line an
    -- indentation, and directives based on the first character.
    indentLevel (' ':str) = 1 + indentLevel str
    indentLevel _ = 0 :: Int

    makePieces :: [String] -> [String]
    makePieces [] = []
    makePieces (first:rest)
      | isDirective first = first : makePieces rest
      | otherwise = unlines (first:take endOfBlock rest) : makePieces (drop endOfBlock rest)
          where
            endOfBlock = fromMaybe (length rest) $ findIndex (\x -> indentLevel x <= indentLevel first) rest


    pieces = trace (show $ makePieces $ lines code ) $ makePieces $ lines code
    makeCommands lines
      | isDirective lines = [createDirective lines]
      | isDeclaration lines =
          case parseDecl $ trace ("Decl<" ++ lines ++ "<>>>") lines of
            ParseOk declaration -> [Declaration $ prettyPrint declaration]
            ParseFailed srcLoc errMsg -> [ParseError (srcLine srcLoc) (srcColumn srcLoc) errMsg]
      | otherwise = 
          case parseStmts $ trace ("STMT<" ++ lines ++ "<s>>") lines of
            Left (srcLine, srcColumn, errMsg) -> [ParseError srcLine srcColumn errMsg]
            Right stmts -> map (Statement . prettyPrint) $ init stmts
    isDeclaration line = any (`isInfixOf` line) ["type", "newtype", "data"]
    isDirective line = startswith [directiveChar] stripped || startswith "import" stripped
      where stripped = strip line
    createDirective line =
      case strip line of
        ':':_ -> Directive $ strip line
        _ -> Import $ strip line

evalCommand :: Command -> Interpreter [DisplayData]
evalCommand (Import importStr) = do
  write $ "Import: " ++ importStr
  importDecl <- parseImportDecl importStr
  context <- getContext
  setContext $ IIDecl importDecl : context
  return []

evalCommand (Directive directive) = do
  write $ "Directive: " ++ directive
  return [Display MimeHtml $ printf "<span style='font-weight: bold; color: green;'>%s</span>" directive]

evalCommand (Statement stmt) = do
  write $ "Statement: " ++ stmt
  ghandle handler $ do
    (printed, result) <- capturedStatement stmt
    case result of
      RunOk _ ->
        return [Display PlainText printed]
      RunException exception -> do
        write $ "RunException: " ++ show exception
        return [Display MimeHtml $ makeError $ show exception]
      RunBreak{} ->
        error "Should not break."
  where 
    handler :: SomeException -> Interpreter [DisplayData]
    handler exception = do
      write $ concat ["Break: ", show exception, "\nfrom statement:\n", stmt]
      return [Display MimeHtml $ makeError $ show exception]

evalCommand (Declaration decl) = do
  write $ "Declaration: " ++ decl
  ghandle handler $ runDecls decl >> return []
  where 
    handler :: SomeException -> Interpreter [DisplayData]
    handler exception = do
      write $ concat ["Break: ", show exception, "\nfrom declaration:\n", decl]
      return [Display MimeHtml $ makeError $ show exception]

evalCommand (ParseError line col err) =
  return [Display MimeHtml $ makeError $ printf "Error (line %d, column %d): %s" line col err]

capturedStatement :: String -> Interpreter (String, RunResult)
capturedStatement stmt = do
  -- Generate random variable names to use so that we cannot accidentally
  -- override the variables by using the right names in the terminal.
  randStr <- liftIO $ show . abs <$> (randomIO :: IO Int)
  let fileVariable = "file_var_" ++ randStr :: String
      fileName = ".ihaskell_capture" :: String
      oldVariable = fileVariable ++ "_old" :: String
      initStmts :: [String]
      initStmts = [
        printf "%s <- openFile \"%s\" WriteMode" fileVariable fileName,
        printf "%s <- hDuplicate stdout" oldVariable,
        printf "hDuplicateTo %s stdout" fileVariable]
      postStmts :: [String]
      postStmts = [
               "hFlush stdout",
        printf "hDuplicateTo %s stdout" oldVariable,
        printf "hClose %s" fileVariable]
      goStmt s = runStmt s RunToCompletion

  forM_ initStmts goStmt
  result <- goStmt stmt
  forM_ postStmts goStmt

  -- We must use strict IO, because we write to that file again if we
  -- execute more statements. If we read lazily, we may cause errors when
  -- trying to open the file for writing later.
  printedOutput <- liftIO $ StrictIO.readFile fileName

  return (printedOutput, result)

parseStmts :: String -> Either (LineNumber, ColumnNumber, String) [Stmt]
parseStmts code = 
  case parseResult of
    ParseOk (Do stmts) -> Right stmts
    ParseOk _ -> Right []
    ParseFailed srcLoc errMsg -> Left (srcLine srcLoc, srcColumn srcLoc, errMsg) 
  where
    parseResult = parseExp doBlock
    doBlock = unlines $ ("do" : map indent (lines code)) ++ [indent returnStmt]
    indent = ("  " ++) 
    returnStmt = "return ()"

makeError :: String -> String
makeError = printf "<span style='color: red; font-style: italic;'>%s</span>"
