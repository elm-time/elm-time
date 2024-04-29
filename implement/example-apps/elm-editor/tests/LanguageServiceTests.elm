module LanguageServiceTests exposing (..)

import Base64
import Expect
import FileTree
import Frontend.MonacoEditor
import LanguageService
import LanguageServiceInterface
import Test


provide_hover : Test.Test
provide_hover =
    let
        otherFiles =
            [ ( [ "src", "Alpha.elm" ]
              , """
module Alpha exposing (..)

{-| Documentation comment on module Alpha
-}

from_alpha = 123


"""
              )
            , ( [ "src", "Delta.elm" ]
              , """
module Delta exposing (..)

{-| Module comment
-}


{-| Comment on function
-}
from_delta : ( Int, String )
from_delta =
    ( 1, "" )

"""
              )
            ]

        expectationFromScenarioInMain mainModuleText expectedItems =
            hoverExpectationFromScenario
                otherFiles
                ( [ "src", "Main.elm" ], mainModuleText )
                expectedItems
    in
    Test.describe "Provide hover"
        [ Test.test "On local top-level function" <|
            \_ ->
                expectationFromScenarioInMain
                    """
module Main exposing (State)


name = i👈🚁nit


init : State
init =
    0
"""
                    [ "    init : State"
                    ]
        , Test.test "On import syntax module name" <|
            \_ ->
                expectationFromScenarioInMain
                    """
module Main exposing (State)

import A👈🚁lpha


init : State
init =
    0
"""
                    [ "Documentation comment on module Alpha"
                    ]
        , Test.test "On type annotation referencing local declaration" <|
            \_ ->
                expectationFromScenarioInMain
                    """
module Main exposing (State)


name : S👈🚁tate
name = 4

{-| Comment on type alias declaration
-}
type alias State =
    Int

"""
                    [ stringTrimUpToLineBreaks """
    type alias State =
        Int


Comment on type alias declaration"""
                    ]
        , Test.test "On type alias declaration referencing local declaration" <|
            \_ ->
                expectationFromScenarioInMain
                    """
module Main exposing (State)


type alias OtherRecord =
    { field_a : S👈🚁tate
    }


{-| Comment on type alias declaration
-}
type alias State =
    Int

"""
                    [ stringTrimUpToLineBreaks """
    type alias State =
        Int


Comment on type alias declaration"""
                    ]
        , Test.test "On imported module alias" <|
            \_ ->
                expectationFromScenarioInMain
                    """
module Main exposing (State)

import Alpha exposing (from_alpha)
import Delta as ModuleAlias


name = ModuleAlia👈🚁s.from_delta


init : State
init =
    0
"""
                    [ "Module comment"
                    ]
        , Test.test "On declaration from imported module alias" <|
            \_ ->
                expectationFromScenarioInMain
                    """
module Main exposing (State)

import Alpha exposing (from_alpha)
import Delta as ModuleAlias


name = ModuleAlias.from_d👈🚁elta


init : State
init =
    0
"""
                    [ """    from_delta : ( Int, String )

Comment on function"""
                    ]
        , Test.test "On function argument" <|
            \_ ->
                expectationFromScenarioInMain
                    """
module Main exposing (State)


function : Int -> Int
function argumentName =
    argu👈🚁mentName + 1

"""
                    [ """    argumentName : Int"""
                    ]
        , Test.test "On Int" <|
            \_ ->
                expectationFromScenarioInMain
                    """
module Main exposing (..)


function : I👈🚁nt -> Int
function argumentName =
    argumentName

"""
                    [ """
    type Int = Int

An `Int` is a whole number. Valid syntax for integers includes:

    0
    42
    9000
    0xFF   -- 255 in hexadecimal
    0x000A --  10 in hexadecimal

**Note:** `Int` math is well-defined in the range `-2^31` to `2^31 - 1`. Outside
of that range, the behavior is determined by the compilation target. When
generating JavaScript, the safe range expands to `-(2^53 - 1)` to `2^53 - 1` for some
operations, but if we generate WebAssembly some day, we would do the traditional
[integer overflow][io]. This quirk is necessary to get good performance on
quirky compilation targets.

**Historical Note:** The name `Int` comes from the term [integer][]. It appears
that the `int` abbreviation was introduced in [ALGOL 68][68], shortening it
from `integer` in [ALGOL 60][60]. Today, almost all programming languages use
this abbreviation.

[io]: https://en.wikipedia.org/wiki/Integer_overflow
[integer]: https://en.wikipedia.org/wiki/Integer
[60]: https://en.wikipedia.org/wiki/ALGOL_60
[68]: https://en.wikipedia.org/wiki/ALGOL_68
"""
                    ]
        , Test.test "On not" <|
            \_ ->
                expectationFromScenarioInMain
                    """
module Main exposing (..)


false : Bool
false =
    no👈🚁t True


"""
                    [ """
not : Bool -> Bool

Negate a boolean value.

    not True == False
    not False == True
"""
                    ]
        ]


hoverExpectationFromScenario :
    List ( List String, String )
    -> ( List String, String )
    -> List String
    -> Expect.Expectation
hoverExpectationFromScenario otherFiles ( fileOpenedInEditorPath, fileOpenedInEditorText ) expectedItems =
    case String.split "👈🚁" fileOpenedInEditorText of
        [ textUntilCursor, textAfterCursor ] ->
            hoverExpectationFromScenarioDescribingOpenFile
                otherFiles
                { filePath = fileOpenedInEditorPath
                , textUntilCursor = textUntilCursor
                , textAfterCursor = textAfterCursor
                }
                expectedItems

        splitElements ->
            Expect.fail
                ("Unexpected shape of fileOpenedInEditorText: Unexpected number of split symbols: "
                    ++ String.fromInt (List.length splitElements - 1)
                )


hoverExpectationFromScenarioDescribingOpenFile :
    List ( List String, String )
    -> { filePath : List String, textUntilCursor : String, textAfterCursor : String }
    -> List String
    -> Expect.Expectation
hoverExpectationFromScenarioDescribingOpenFile otherFiles fileOpenedInEditor expectedItems =
    let
        languageServiceState =
            buildLanguageServiceStateFindingParsableModuleText
                { maxLinesToRemoveBeforeCursor = 0 }
                otherFiles
                fileOpenedInEditor

        wholeText =
            fileOpenedInEditor.textUntilCursor ++ fileOpenedInEditor.textAfterCursor

        positionLineNumber =
            fileOpenedInEditor.textUntilCursor |> String.lines |> List.length

        lineText =
            wholeText
                |> String.lines
                |> List.drop (positionLineNumber - 1)
                |> List.head

        positionColumn =
            fileOpenedInEditor.textUntilCursor
                |> String.lines
                |> List.reverse
                |> List.head
                |> Maybe.map (String.length >> (+) 1)
                |> Maybe.withDefault 0

        computedItems : List String
        computedItems =
            LanguageService.provideHover
                { filePathOpenedInEditor = fileOpenedInEditor.filePath
                , positionLineNumber = fileOpenedInEditor.textUntilCursor |> String.lines |> List.length
                , positionColumn = positionColumn
                , lineText = Maybe.withDefault "" lineText
                }
                languageServiceState

        normalizeHoverItemsForComparison : List String -> List String
        normalizeHoverItemsForComparison =
            List.map String.trim
    in
    Expect.equal
        (normalizeHoverItemsForComparison expectedItems)
        (normalizeHoverItemsForComparison computedItems)


provide_completion_items : Test.Test
provide_completion_items =
    let
        otherFiles =
            [ ( [ "src", "Alpha.elm" ]
              , """
module Alpha exposing (..)

{-| Documentation comment on module Alpha
-}

from_alpha = 123


"""
              )
            , ( [ "src", "Beta.elm" ]
              , """
module Beta exposing (from_beta, from_beta_function)


from_beta = "a string literal"


from_beta_function : Int -> String
from_beta_function arg =
  String.fromInt arg


from_beta_not_exposed : String
from_beta_not_exposed = "literal"

"""
              )
            , ( [ "src", "Beta", "Gamma.elm" ]
              , """
module Beta.Gamma exposing (..)


from_beta_gamma = 567


"""
              )
            , ( [ "src", "Delta.elm" ]
              , """
module Delta exposing (..)


from_delta = (1, 3)


"""
              )
            , ( [ "src", "Beta", "Epsilon.elm" ]
              , """
module Epsilon exposing (..)


from_epsilon = ""


"""
              )
            ]

        expectationFromScenarioInMain { removeCoreModules } mainModuleText expectedItems =
            let
                prepareLangServiceState origState =
                    if removeCoreModules then
                        { origState | coreModulesCache = [] }

                    else
                        origState
            in
            completionItemsExpectationFromScenario
                prepareLangServiceState
                otherFiles
                ( [ "src", "Main.elm" ], mainModuleText )
                expectedItems
    in
    Test.describe "Provide completion items"
        [ Test.test "In top-level declaration after equals sign" <|
            \_ ->
                expectationFromScenarioInMain { removeCoreModules = True }
                    """
module Main exposing (State)

import Alpha exposing (from_alpha)
import Beta
import Beta.Gamma
import Delta as ModuleAlias


{-| Comment on declaration
-}
type alias State =
    Int

name = ✂➕

type Event
    = Increment
    | Decrement


init : State
init =
    0
"""
                    [ { label = "Alpha"
                      , documentation = "Documentation comment on module Alpha"
                      , insertText = "Alpha"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Beta"
                      , documentation = ""
                      , insertText = "Beta"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Beta.Gamma"
                      , documentation = ""
                      , insertText = "Beta.Gamma"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Delta as ModuleAlias"
                      , documentation = ""
                      , insertText = "ModuleAlias"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Decrement"
                      , documentation = stringTrimUpToLineBreaks """
    Decrement

A variant of the choice type `Event`

    type Event
        = Increment
        | Decrement
"""
                      , insertText = "Decrement"
                      , kind = Frontend.MonacoEditor.EnumMemberCompletionItemKind
                      }
                    , { label = "Event"
                      , documentation = stringTrimUpToLineBreaks """
    type Event
        = Increment
        | Decrement
"""
                      , insertText = "Event"
                      , kind = Frontend.MonacoEditor.EnumCompletionItemKind
                      }
                    , { label = "Increment"
                      , documentation = stringTrimUpToLineBreaks """
    Increment

A variant of the choice type `Event`

    type Event
        = Increment
        | Decrement
"""
                      , insertText = "Increment"
                      , kind = Frontend.MonacoEditor.EnumMemberCompletionItemKind
                      }
                    , { label = "State"
                      , documentation = stringTrimUpToLineBreaks """
    type alias State =
        Int

Comment on declaration
"""
                      , insertText = "State"
                      , kind = Frontend.MonacoEditor.StructCompletionItemKind
                      }
                    , { label = "from_alpha"
                      , documentation = "    from_alpha"
                      , insertText = "from_alpha"
                      , kind = Frontend.MonacoEditor.FunctionCompletionItemKind
                      }
                    , { label = "init"
                      , documentation = stringTrimUpToLineBreaks """
    init : State
"""
                      , insertText = "init"
                      , kind = Frontend.MonacoEditor.FunctionCompletionItemKind
                      }
                    ]
        , Test.test "In top-level declaration after equals sign and Module referece" <|
            \_ ->
                expectationFromScenarioInMain { removeCoreModules = False }
                    """
module Main exposing (State)

import Alpha exposing (from_alpha)
import Beta
import Beta.Gamma
import Delta as ModuleAlias


{-| Comment on declaration
-}
type alias State =
    Int


type Event
    = Increment
    | Decrement

name =Beta.✂➕

init : State
init =
    0
"""
                    [ { label = "Gamma"
                      , documentation = ""
                      , insertText = "Gamma"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "from_beta"
                      , documentation = stringTrimUpToLineBreaks """
    from_beta
"""
                      , insertText = "from_beta"
                      , kind = Frontend.MonacoEditor.FunctionCompletionItemKind
                      }
                    , { label = "from_beta_function"
                      , documentation = stringTrimUpToLineBreaks """
    from_beta_function : Int -> String
"""
                      , insertText = "from_beta_function"
                      , kind = Frontend.MonacoEditor.FunctionCompletionItemKind
                      }
                    ]
        , Test.test "In application expression after function" <|
            \_ ->
                expectationFromScenarioInMain { removeCoreModules = True }
                    """
module Main exposing (State)

import Alpha
import Beta


type alias State =
    Int

name = Alpha.from_alpha ✂➕

type Event
    = Increment
    | Decrement


init : State
init =
    0
"""
                    [ { label = "Alpha"
                      , documentation = "Documentation comment on module Alpha"
                      , insertText = "Alpha"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Beta"
                      , documentation = ""
                      , insertText = "Beta"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Decrement"
                      , documentation = stringTrimUpToLineBreaks """
    Decrement

A variant of the choice type `Event`

    type Event
        = Increment
        | Decrement
"""
                      , insertText = "Decrement"
                      , kind = Frontend.MonacoEditor.EnumMemberCompletionItemKind
                      }
                    , { label = "Event"
                      , documentation = stringTrimUpToLineBreaks """
    type Event
        = Increment
        | Decrement
"""
                      , insertText = "Event"
                      , kind = Frontend.MonacoEditor.EnumCompletionItemKind
                      }
                    , { label = "Increment"
                      , documentation = stringTrimUpToLineBreaks """
    Increment

A variant of the choice type `Event`

    type Event
        = Increment
        | Decrement
"""
                      , insertText = "Increment"
                      , kind = Frontend.MonacoEditor.EnumMemberCompletionItemKind
                      }
                    , { label = "State"
                      , documentation = stringTrimUpToLineBreaks """
    type alias State =
        Int
"""
                      , insertText = "State"
                      , kind = Frontend.MonacoEditor.StructCompletionItemKind
                      }
                    , { label = "init"
                      , documentation = stringTrimUpToLineBreaks """
    init : State
"""
                      , insertText = "init"
                      , kind = Frontend.MonacoEditor.FunctionCompletionItemKind
                      }
                    , { label = "name"
                      , documentation = "    name"
                      , insertText = "name"
                      , kind = Frontend.MonacoEditor.FunctionCompletionItemKind
                      }
                    ]
        , Test.test "Right of 'import '" <|
            \_ ->
                expectationFromScenarioInMain { removeCoreModules = True }
                    """
module Main exposing (..)

import ✂➕

local_decl = 123

"""
                    [ { label = "Alpha"
                      , documentation = "Documentation comment on module Alpha"
                      , insertText = "Alpha"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Beta"
                      , documentation = ""
                      , insertText = "Beta"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Beta.Gamma"
                      , documentation = ""
                      , insertText = "Beta.Gamma"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Delta"
                      , documentation = ""
                      , insertText = "Delta"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Epsilon"
                      , documentation = ""
                      , insertText = "Epsilon"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    ]
        , Test.test "Right of 'import E'" <|
            \_ ->
                expectationFromScenarioInMain { removeCoreModules = True }
                    """
module Main exposing (..)

import E✂➕

local_decl = 123

"""
                    [ { label = "Alpha"
                      , documentation = "Documentation comment on module Alpha"
                      , insertText = "Alpha"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Beta"
                      , documentation = ""
                      , insertText = "Beta"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Beta.Gamma"
                      , documentation = ""
                      , insertText = "Beta.Gamma"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Delta"
                      , documentation = ""
                      , insertText = "Delta"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    , { label = "Epsilon"
                      , documentation = ""
                      , insertText = "Epsilon"
                      , kind = Frontend.MonacoEditor.ModuleCompletionItemKind
                      }
                    ]
        , Test.test "In declaration in let-block after equals sign" <|
            \_ ->
                expectationFromScenarioInMain { removeCoreModules = True }
                    """
module Main exposing (..)


alpha =
  let
    epsilon =✂➕

    delta = 678
  in
  delta


beta =
  let
    gamma = ""
  in
  gamma

"""
                    [ { label = "alpha"
                      , documentation = "    alpha"
                      , insertText = "alpha"
                      , kind = Frontend.MonacoEditor.FunctionCompletionItemKind
                      }
                    , { label = "beta"
                      , documentation = "    beta"
                      , insertText = "beta"
                      , kind = Frontend.MonacoEditor.FunctionCompletionItemKind
                      }
                    , { label = "delta"
                      , documentation = "    delta"
                      , insertText = "delta"
                      , kind = Frontend.MonacoEditor.FunctionCompletionItemKind
                      }
                    ]
        , Test.test "None in multi-line comment before module declaration" <|
            \_ ->
                expectationFromScenarioInMain { removeCoreModules = False }
                    """
{- First line in comment
Second line ✂➕
-}

module Main exposing (..)

import Alpha exposing (..)
import Beta


beta : Int
beta = 123

"""
                    []
        , Test.test "None in middle of multi-line documentation comment on a function declaration" <|
            \_ ->
                expectationFromScenarioInMain { removeCoreModules = False }
                    """
module Main exposing (..)

import Alpha exposing (..)
import Beta


{-| First line in comment
Second line ✂➕
-}
beta : Int
beta = 123

"""
                    []
        , Test.test "None at the beginning of multi-line comment" <|
            \_ ->
                expectationFromScenarioInMain { removeCoreModules = False }
                    """
module Main exposing (..)

import Alpha exposing (..)
import Beta


{-✂➕ First line in comment
Second line
-}


beta : Int
beta = 123

"""
                    []
        , Test.test "None at the end of multi-line comment" <|
            \_ ->
                expectationFromScenarioInMain { removeCoreModules = False }
                    """
module Main exposing (..)

import Alpha exposing (..)
import Beta


{- First line in comment
Second line
 ✂➕-}


beta : Int
beta = 123

"""
                    []
        , Test.test "None in single-line comment in a function declaration" <|
            \_ ->
                expectationFromScenarioInMain { removeCoreModules = False }
                    """
module Main exposing (..)

import Alpha exposing (..)
import Beta


beta : Int
beta =
  -- Beginning of the comment ✂➕
  123

"""
                    []

        {- TODO: Add test for completion items out of core modules like List, Maybe, Result, etc. -}
        ]


completionItemsExpectationFromScenario :
    (LanguageService.LanguageServiceState -> LanguageService.LanguageServiceState)
    -> List ( List String, String )
    -> ( List String, String )
    -> List Frontend.MonacoEditor.MonacoCompletionItem
    -> Expect.Expectation
completionItemsExpectationFromScenario modifyLanguageServiceState otherFiles ( fileOpenedInEditorPath, fileOpenedInEditorText ) expectedItems =
    case String.split "✂➕" fileOpenedInEditorText of
        [ textUntilCursor, textAfterCursor ] ->
            expectationFromScenarioDescribingOpenFile
                modifyLanguageServiceState
                otherFiles
                { filePath = fileOpenedInEditorPath
                , textUntilCursor = textUntilCursor
                , textAfterCursor = textAfterCursor
                }
                expectedItems

        splitElements ->
            Expect.fail
                ("Unexpected shape of fileOpenedInEditorText: Unexpected number of split symbols: "
                    ++ String.fromInt (List.length splitElements - 1)
                )


expectationFromScenarioDescribingOpenFile :
    (LanguageService.LanguageServiceState -> LanguageService.LanguageServiceState)
    -> List ( List String, String )
    -> { filePath : List String, textUntilCursor : String, textAfterCursor : String }
    -> List Frontend.MonacoEditor.MonacoCompletionItem
    -> Expect.Expectation
expectationFromScenarioDescribingOpenFile modifyLanguageServiceState otherFiles fileOpenedInEditor expectedItems =
    let
        languageServiceState =
            buildLanguageServiceStateFindingParsableModuleText
                { maxLinesToRemoveBeforeCursor = 3 }
                otherFiles
                fileOpenedInEditor
                |> modifyLanguageServiceState
    in
    Expect.equal expectedItems
        (LanguageService.provideCompletionItems
            { filePathOpenedInEditor = fileOpenedInEditor.filePath
            , textUntilPosition = fileOpenedInEditor.textUntilCursor
            , cursorLineNumber = fileOpenedInEditor.textUntilCursor |> String.lines |> List.length
            }
            languageServiceState
        )


buildLanguageServiceStateFindingParsableModuleText :
    { maxLinesToRemoveBeforeCursor : Int }
    -> List ( List String, String )
    -> { filePath : List String, textUntilCursor : String, textAfterCursor : String }
    -> LanguageService.LanguageServiceState
buildLanguageServiceStateFindingParsableModuleText { maxLinesToRemoveBeforeCursor } otherFiles fileOpenedInEditor =
    let
        textUntilCursorLines =
            String.lines fileOpenedInEditor.textUntilCursor

        fileTreeWithPreviousLinesRemoved linesToRemove =
            let
                textUntilCursor =
                    textUntilCursorLines
                        |> List.reverse
                        |> List.drop linesToRemove
                        |> List.reverse
                        |> String.join "\n"

                fileOpenedInEditorText =
                    textUntilCursor ++ fileOpenedInEditor.textAfterCursor

                allFiles =
                    ( fileOpenedInEditor.filePath, fileOpenedInEditorText )
                        :: otherFiles
            in
            allFiles
                |> List.foldl
                    (\( filePath, fileContentString ) ->
                        FileTree.setNodeAtPathInSortedFileTree
                            ( filePath
                            , FileTree.BlobNode (fileContentFromString fileContentString)
                            )
                    )
                    (FileTree.TreeNode [])
    in
    List.range 0 maxLinesToRemoveBeforeCursor
        |> List.foldr
            (fileTreeWithPreviousLinesRemoved >> LanguageService.updateLanguageServiceState)
            LanguageService.initLanguageServiceState


fileContentFromString : String -> LanguageServiceInterface.FileTreeBlobNode
fileContentFromString asText =
    { asBase64 =
        case Base64.fromString asText of
            Just base64 ->
                base64

            Nothing ->
                "Failed encoding to base64"
    , asText = Just asText
    }


stringTrimUpToLineBreaks : String -> String
stringTrimUpToLineBreaks string =
    case String.lines string of
        [] ->
            string

        firstLine :: afterFirstLine ->
            let
                right =
                    case List.reverse afterFirstLine of
                        lastLine :: middleLinesReversed ->
                            String.join "\n" (List.reverse middleLinesReversed) ++ String.trimRight lastLine

                        [] ->
                            ""
            in
            String.trimLeft firstLine ++ right
