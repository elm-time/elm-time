module ElmInteractive exposing (..)

import BigInt
import Dict
import Elm.Parser
import Elm.Processing
import Elm.Syntax.Declaration
import Elm.Syntax.Expression
import Elm.Syntax.File
import Elm.Syntax.Module
import Elm.Syntax.ModuleName
import Elm.Syntax.Node
import Elm.Syntax.Pattern
import Elm.Syntax.Range
import Elm.Syntax.Type
import Json.Decode
import Json.Encode
import List.Extra
import Maybe.Extra
import Parser
import Pine
import Result.Extra
import SHA256
import Set


type InteractiveSubmission
    = ExpressionSubmission Elm.Syntax.Expression.Expression
    | DeclarationSubmission Elm.Syntax.Declaration.Declaration


type InteractiveContext
    = DefaultContext
    | InitContextFromApp { modulesTexts : List String }


type alias SubmissionResponse =
    { displayText : String }


type ElmValue
    = ElmList (List ElmValue)
    | ElmChar Char
    | ElmInteger BigInt.BigInt
    | ElmString String
    | ElmTag String (List ElmValue)
    | ElmRecord (List ( String, ElmValue ))
    | ElmInternal String


type alias ProjectParsedElmFile =
    { projectedModuleName : List String
    , fileText : String
    , parsedModule : Elm.Syntax.File.File
    }


submissionInInteractive : InteractiveContext -> List String -> String -> Result String SubmissionResponse
submissionInInteractive context previousSubmissions submission =
    case pineEvalContextForElmInteractive context of
        Err error ->
            Err ("Failed to prepare the initial context: " ++ error)

        Ok initialContext ->
            submissionWithHistoryInInteractive initialContext previousSubmissions submission


submissionWithHistoryInInteractive : Pine.EvalContext -> List String -> String -> Result String SubmissionResponse
submissionWithHistoryInInteractive initialContext previousSubmissions submission =
    case previousSubmissions of
        [] ->
            submissionInInteractiveInPineContext initialContext submission
                |> Result.map Tuple.second

        firstSubmission :: remainingPreviousSubmissions ->
            case submissionInInteractiveInPineContext initialContext firstSubmission of
                Err _ ->
                    submissionWithHistoryInInteractive initialContext remainingPreviousSubmissions submission

                Ok ( expressionContext, _ ) ->
                    submissionWithHistoryInInteractive expressionContext remainingPreviousSubmissions submission


submissionInInteractiveInPineContext : Pine.EvalContext -> String -> Result String ( Pine.EvalContext, SubmissionResponse )
submissionInInteractiveInPineContext expressionContext submission =
    compileInteractiveSubmissionIntoPineExpression expressionContext.applicationArgument submission
        |> Result.andThen
            (\pineExpression ->
                case Pine.evaluateExpression expressionContext pineExpression of
                    Err error ->
                        Err ("Failed to evaluate expression:\n" ++ Pine.displayStringFromPineError error)

                    Ok (Pine.BlobValue _) ->
                        Err "Type mismatch: Pine expression evaluated to a blob"

                    Ok (Pine.ListValue [ newState, responseValue ]) ->
                        submissionResponseFromResponsePineValue responseValue
                            |> Result.map (Tuple.pair { applicationArgument = newState })

                    Ok (Pine.ListValue resultList) ->
                        Err
                            ("Type mismatch: Pine expression evaluated to a list with unexpected number of elements: "
                                ++ String.fromInt (List.length resultList)
                                ++ " instead of 2"
                            )
            )


submissionResponseFromResponsePineValue : Pine.Value -> Result String SubmissionResponse
submissionResponseFromResponsePineValue responseValue =
    case pineValueAsElmValue responseValue of
        Err error ->
            Err ("Failed to encode as Elm value: " ++ error)

        Ok valueAsElmValue ->
            Ok { displayText = elmValueAsExpression valueAsElmValue }


elmValueAsExpression : ElmValue -> String
elmValueAsExpression elmValue =
    case elmValue of
        ElmList list ->
            "[" ++ (list |> List.map elmValueAsExpression |> String.join ",") ++ "]"

        ElmInteger integer ->
            integer |> BigInt.toString

        ElmChar char ->
            "'" ++ (char |> String.fromChar) ++ "'"

        ElmString string ->
            string |> Json.Encode.string |> Json.Encode.encode 0

        ElmRecord fields ->
            if fields == [] then
                "{}"

            else
                "{ " ++ (fields |> List.map (\( fieldName, fieldValue ) -> fieldName ++ " = " ++ elmValueAsExpression fieldValue) |> String.join ", ") ++ " }"

        ElmTag tagName tagArguments ->
            tagName :: (tagArguments |> List.map elmValueAsExpression) |> String.join " "

        ElmInternal desc ->
            "<" ++ desc ++ ">"


elmValueAsJson : ElmValue -> Json.Encode.Value
elmValueAsJson elmValue =
    case elmValue of
        ElmInteger integer ->
            integer
                |> BigInt.toString
                |> Json.Encode.string

        ElmChar char ->
            Json.Encode.string (String.fromChar char)

        ElmString string ->
            Json.Encode.string string

        ElmList list ->
            Json.Encode.list elmValueAsJson list

        ElmRecord fields ->
            Json.Encode.list (\( fieldName, fieldValue ) -> Json.Encode.list identity [ Json.Encode.string fieldName, elmValueAsJson fieldValue ]) fields

        ElmTag tagName tagArguments ->
            Json.Encode.list identity [ Json.Encode.string tagName, Json.Encode.list elmValueAsJson tagArguments ]

        ElmInternal _ ->
            Json.Encode.string (elmValueAsExpression elmValue)


pineValueAsElmValue : Pine.Value -> Result String ElmValue
pineValueAsElmValue pineValue =
    case pineValue of
        Pine.BlobValue blobValue ->
            case blobValue of
                [] ->
                    Ok (ElmInternal "empty-blob")

                firstByte :: _ ->
                    if firstByte == 4 || firstByte == 2 then
                        blobValue
                            |> Pine.bigIntFromBlobValue
                            |> Result.map ElmInteger

                    else if 10 < List.length blobValue then
                        case Pine.decodeExpressionFromValue pineValue of
                            Ok _ ->
                                Ok (ElmInternal "expression")

                            Err _ ->
                                Ok (ElmInternal "___error_skipped_large_blob___")

                    else
                        blobValue
                            |> Pine.bigIntFromUnsignedBlobValue
                            |> BigInt.toString
                            |> String.toInt
                            |> Maybe.withDefault 0
                            |> Char.fromCode
                            |> ElmChar
                            |> Ok

        Pine.ListValue list ->
            case list |> List.map pineValueAsElmValue |> Result.Extra.combine of
                Err error ->
                    Err ("Failed to combine list: " ++ error)

                Ok listValues ->
                    let
                        tryMapToChar elmValue =
                            case elmValue of
                                ElmChar char ->
                                    Just char

                                _ ->
                                    Nothing

                        resultAsList =
                            Ok (ElmList listValues)
                    in
                    if listValues == [] then
                        resultAsList

                    else
                        case listValues of
                            [ ElmString tagName, ElmList tagArguments ] ->
                                if stringStartsWithUpper tagName then
                                    if tagName == elmRecordTypeTagName then
                                        (case tagArguments of
                                            [ recordValue ] ->
                                                elmValueAsElmRecord recordValue

                                            _ ->
                                                Err ("Wrong number of tag arguments: " ++ String.fromInt (List.length tagArguments))
                                        )
                                            |> Result.mapError ((++) "Failed to extract value under record tag: ")

                                    else if tagName == elmStringTypeTagName then
                                        (case tagArguments of
                                            [ ElmString string ] ->
                                                Ok (ElmString string)

                                            [ ElmList charsList ] ->
                                                case charsList |> List.map tryMapToChar |> Maybe.Extra.combine of
                                                    Just chars ->
                                                        chars |> String.fromList |> ElmString |> Ok

                                                    Nothing ->
                                                        Err "Failed to map chars"

                                            _ ->
                                                Err "Unexpected shape of tag arguments"
                                        )
                                            |> Result.mapError ((++) "Failed to extract value under String tag: ")

                                    else
                                        Ok (ElmTag tagName tagArguments)

                                else
                                    resultAsList

                            _ ->
                                case listValues |> List.map tryMapToChar |> Maybe.Extra.combine of
                                    Just chars ->
                                        chars |> String.fromList |> ElmString |> Ok

                                    Nothing ->
                                        resultAsList


elmValueAsElmRecord : ElmValue -> Result String ElmValue
elmValueAsElmRecord elmValue =
    let
        tryMapToRecordField possiblyRecordField =
            case possiblyRecordField of
                ElmList [ ElmString fieldName, fieldValue ] ->
                    if not (stringStartsWithUpper fieldName) then
                        Ok ( fieldName, fieldValue )

                    else
                        Err ("Field name does start with uppercase: '" ++ fieldName ++ "'")

                _ ->
                    Err "Not a list."
    in
    case elmValue of
        ElmList recordFieldList ->
            case recordFieldList |> List.map tryMapToRecordField |> Result.Extra.combine of
                Ok recordFields ->
                    let
                        recordFieldsNames =
                            List.map Tuple.first recordFields
                    in
                    if List.sort recordFieldsNames == recordFieldsNames then
                        Ok (ElmRecord recordFields)

                    else
                        Err "Unexpected order of fields."

                Err parseFieldError ->
                    Err ("Failed to parse field: " ++ parseFieldError)

        _ ->
            Err "Value is not a list."


pineEvalContextForElmInteractive : InteractiveContext -> Result String Pine.EvalContext
pineEvalContextForElmInteractive context =
    let
        contextModulesTexts =
            case context of
                DefaultContext ->
                    []

                InitContextFromApp { modulesTexts } ->
                    modulesTexts
    in
    (elmCoreModulesTexts ++ contextModulesTexts)
        |> List.map parsedElmFileFromOnlyFileText
        |> Result.Extra.combine
        |> Result.andThen
            (\parsedElmFiles ->
                let
                    modulesNamesWithDependencies =
                        parsedElmFiles
                            |> List.map
                                (\file ->
                                    file.parsedModule
                                        |> listModuleTransitiveDependencies (List.map .parsedModule parsedElmFiles)
                                        |> Result.mapError (Tuple.pair file)
                                        |> Result.map (Tuple.pair file)
                                )
                in
                case modulesNamesWithDependencies |> Result.Extra.combine of
                    Err ( file, error ) ->
                        Err
                            ("Failed to resolve dependencies for module "
                                ++ String.join "." (Elm.Syntax.Module.moduleName (Elm.Syntax.Node.value file.parsedModule.moduleDefinition))
                                ++ ": "
                                ++ error
                            )

                    Ok modulesWithDependencies ->
                        let
                            moduleNamesOrderedByDeps =
                                modulesWithDependencies
                                    |> List.concatMap Tuple.second
                                    |> List.Extra.unique
                        in
                        moduleNamesOrderedByDeps
                            |> List.filterMap
                                (\moduleName ->
                                    modulesWithDependencies
                                        |> List.Extra.find
                                            (Tuple.first
                                                >> .parsedModule
                                                >> .moduleDefinition
                                                >> Elm.Syntax.Node.value
                                                >> Elm.Syntax.Module.moduleName
                                                >> (==) moduleName
                                            )
                                )
                            |> List.map Tuple.first
                            |> Ok
            )
        |> Result.andThen
            (\parsedElmFiles ->
                parsedElmFiles
                    |> List.foldl
                        (\moduleToTranslate ->
                            Result.andThen
                                (\aggregate ->
                                    parseElmModuleTextIntoPineValue aggregate moduleToTranslate
                                        |> Result.mapError
                                            ((++)
                                                ("Failed to translate elm module '"
                                                    ++ String.join "." (Elm.Syntax.Node.value (moduleNameFromSyntaxFile moduleToTranslate.parsedModule))
                                                    ++ "': "
                                                )
                                            )
                                        |> Result.map
                                            (\( moduleName, moduleValue ) -> Dict.insert moduleName moduleValue aggregate)
                                )
                        )
                        (Ok Dict.empty)
            )
        |> Result.map
            (\contextModules ->
                let
                    modulesValues =
                        contextModules
                            |> Dict.toList
                            |> List.map (Tuple.mapFirst (String.join "."))
                            |> List.map Pine.valueFromContextExpansionWithName
                in
                Pine.emptyEvalContext |> Pine.addToContextAppArgument modulesValues
            )


listModuleTransitiveDependencies : List Elm.Syntax.File.File -> Elm.Syntax.File.File -> Result String (List (List String))
listModuleTransitiveDependencies allFiles file =
    listModuleTransitiveDependenciesExcludingModules Set.empty allFiles file
        |> Result.mapError
            (\( modulePath, error ) -> error ++ ": " ++ String.join " -> " (List.map (String.join ".") modulePath))


listModuleTransitiveDependenciesExcludingModules :
    Set.Set (List String)
    -> List Elm.Syntax.File.File
    -> Elm.Syntax.File.File
    -> Result ( List Elm.Syntax.ModuleName.ModuleName, String ) (List Elm.Syntax.ModuleName.ModuleName)
listModuleTransitiveDependenciesExcludingModules excluded allFiles file =
    let
        currentName =
            Elm.Syntax.Module.moduleName (Elm.Syntax.Node.value file.moduleDefinition)

        currentDependencies =
            getDirectDependenciesFromModule file
    in
    if Set.member currentName excluded then
        Err ( [ currentName ], "Cyclic dependency" )

    else if Set.isEmpty currentDependencies then
        Ok [ currentName ]

    else
        currentDependencies
            |> Set.toList
            |> List.map
                (\currentDependency ->
                    case
                        allFiles
                            |> List.Extra.find
                                (.moduleDefinition
                                    >> Elm.Syntax.Node.value
                                    >> Elm.Syntax.Module.moduleName
                                    >> (==) currentDependency
                                )
                    of
                        Nothing ->
                            Ok []

                        Just currentDependencyFile ->
                            listModuleTransitiveDependenciesExcludingModules
                                (Set.insert currentName excluded)
                                allFiles
                                currentDependencyFile
                )
            |> Result.Extra.combine
            |> Result.mapError (Tuple.mapFirst ((::) currentName))
            |> Result.map (List.concat >> (++) >> (|>) [ currentName ] >> List.Extra.unique)


getDirectDependenciesFromModule : Elm.Syntax.File.File -> Set.Set Elm.Syntax.ModuleName.ModuleName
getDirectDependenciesFromModule file =
    let
        explicit =
            file.imports
                |> List.map (Elm.Syntax.Node.value >> .moduleName >> Elm.Syntax.Node.value)

        implicit =
            if List.member (Elm.Syntax.Node.value (moduleNameFromSyntaxFile file)) moduleNamesWithoutImplicitImport then
                []

            else
                autoImportedModulesNames
    in
    explicit
        ++ implicit
        |> Set.fromList


parsedElmFileFromOnlyFileText : String -> Result String ProjectParsedElmFile
parsedElmFileFromOnlyFileText fileText =
    case parseElmModuleText fileText of
        Err _ ->
            Err ("Failed to parse the module text: " ++ fileText)

        Ok parsedModule ->
            Ok
                { fileText = fileText
                , parsedModule = parsedModule
                , projectedModuleName = Elm.Syntax.Node.value (moduleNameFromSyntaxFile parsedModule)
                }


parseElmModuleTextIntoPineValue : Dict.Dict Elm.Syntax.ModuleName.ModuleName Pine.Value -> ProjectParsedElmFile -> Result String ( Elm.Syntax.ModuleName.ModuleName, Pine.Value )
parseElmModuleTextIntoPineValue availableForDependency moduleToTranslate =
    parseElmModuleTextIntoNamedExports availableForDependency moduleToTranslate
        |> Result.map (Tuple.mapSecond (List.map Pine.valueFromContextExpansionWithName >> Pine.ListValue))


parseElmModuleTextIntoNamedExports : Dict.Dict Elm.Syntax.ModuleName.ModuleName Pine.Value -> ProjectParsedElmFile -> Result String ( Elm.Syntax.ModuleName.ModuleName, List ( String, Pine.Value ) )
parseElmModuleTextIntoNamedExports availableModules moduleToTranslate =
    let
        moduleName =
            Elm.Syntax.Node.value (moduleNameFromSyntaxFile moduleToTranslate.parsedModule)

        moduleAliases : Dict.Dict (List String) (List String)
        moduleAliases =
            moduleToTranslate.parsedModule.imports
                |> List.filterMap
                    (Elm.Syntax.Node.value
                        >> (\imp ->
                                imp.moduleAlias
                                    |> Maybe.map
                                        (\moduleAlias ->
                                            ( Elm.Syntax.Node.value moduleAlias, Elm.Syntax.Node.value imp.moduleName )
                                        )
                           )
                    )
                |> Dict.fromList

        declarationsOfOtherModules : Dict.Dict String InternalDeclaration
        declarationsOfOtherModules =
            availableModules
                |> Dict.toList
                |> List.map (Tuple.mapSecond CompiledDeclaration >> Tuple.mapFirst (String.join "."))
                |> Dict.fromList
    in
    let
        declarationsFromCustomTypes : Dict.Dict String Pine.Value
        declarationsFromCustomTypes =
            moduleToTranslate.parsedModule.declarations
                |> List.map Elm.Syntax.Node.value
                |> List.concatMap
                    (\declaration ->
                        case declaration of
                            Elm.Syntax.Declaration.CustomTypeDeclaration customTypeDeclaration ->
                                customTypeDeclaration.constructors
                                    |> List.map
                                        (Elm.Syntax.Node.value
                                            >> pineExpressionFromElmValueConstructor
                                            >> Tuple.mapSecond Pine.encodeExpressionAsValue
                                        )

                            _ ->
                                []
                    )
                |> Dict.fromList

        localFunctionDeclarations : Dict.Dict String Elm.Syntax.Expression.Function
        localFunctionDeclarations =
            moduleToTranslate.parsedModule.declarations
                |> List.map Elm.Syntax.Node.value
                |> List.concatMap
                    (\declaration ->
                        case declaration of
                            Elm.Syntax.Declaration.FunctionDeclaration functionDeclaration ->
                                [ ( Elm.Syntax.Node.value (Elm.Syntax.Node.value functionDeclaration.declaration).name
                                  , functionDeclaration
                                  )
                                ]

                            _ ->
                                []
                    )
                |> Dict.fromList

        initialCompilationStack =
            { moduleAliases = moduleAliases
            , availableDeclarations =
                declarationsOfOtherModules
                    |> Dict.union (Dict.map (always ElmFunctionDeclaration) localFunctionDeclarations)
                    |> Dict.union (declarationsFromCustomTypes |> Dict.map (always CompiledDeclaration))
            , inliningParentDeclarations = Set.empty
            }

        redirectsForInfix : Dict.Dict String String
        redirectsForInfix =
            moduleToTranslate.parsedModule.declarations
                |> List.map Elm.Syntax.Node.value
                |> List.concatMap
                    (\declaration ->
                        case declaration of
                            Elm.Syntax.Declaration.FunctionDeclaration _ ->
                                []

                            Elm.Syntax.Declaration.CustomTypeDeclaration _ ->
                                []

                            Elm.Syntax.Declaration.InfixDeclaration infixDeclaration ->
                                [ ( "(" ++ Elm.Syntax.Node.value infixDeclaration.operator ++ ")"
                                  , Elm.Syntax.Node.value infixDeclaration.function
                                  )
                                ]

                            _ ->
                                []
                    )
                |> Dict.fromList

        functionDeclarationsResults : List (Result String ( String, DeclarationInTranslation ))
        functionDeclarationsResults =
            localFunctionDeclarations
                |> Dict.toList
                |> List.map
                    (\( _, functionDeclaration ) ->
                        pineExpressionFromElmFunction initialCompilationStack functionDeclaration
                            |> Result.map
                                (Tuple.mapSecond
                                    (\( expression, dependencies ) ->
                                        { expression = expression
                                        , referencedLocalNames = dependencies.referencedNames
                                        }
                                    )
                                )
                            |> Result.mapError
                                ((++)
                                    ("Failed to translate function '"
                                        ++ Elm.Syntax.Node.value (Elm.Syntax.Node.value functionDeclaration.declaration).name
                                        ++ "': "
                                    )
                                )
                    )
    in
    case functionDeclarationsResults |> Result.Extra.combine of
        Err error ->
            Err ("Failed to translate declaration: " ++ error)

        Ok functionDeclarations ->
            let
                availableFunctionDeclarationsDict =
                    Dict.fromList functionDeclarations

                declarationsValuesFromCustomTypes : List ( String, Pine.Value )
                declarationsValuesFromCustomTypes =
                    declarationsFromCustomTypes
                        |> Dict.toList

                functionDeclarationsValues =
                    functionDeclarations
                        |> List.map
                            (\( name, expression ) ->
                                ( name, buildDeclarationValue availableFunctionDeclarationsDict ( name, expression ) )
                            )

                declarationsValuesForInfix =
                    redirectsForInfix
                        |> Dict.toList
                        |> List.filterMap
                            (\( name, function ) ->
                                functionDeclarationsValues
                                    |> List.Extra.find (Tuple.first >> (==) function)
                                    |> Maybe.map (Tuple.second >> Tuple.pair name)
                            )
            in
            Ok
                ( moduleName
                , declarationsValuesFromCustomTypes ++ functionDeclarationsValues ++ declarationsValuesForInfix
                )


type alias DeclarationInTranslation =
    { referencedLocalNames : Set.Set String
    , expression : Pine.Expression
    }


buildDeclarationValue : Dict.Dict String DeclarationInTranslation -> ( String, DeclarationInTranslation ) -> Pine.Value
buildDeclarationValue availableDeclarations ( declarationName, declaration ) =
    let
        referencedNames =
            listReferencedLocalNamesTransitive
                availableDeclarations
                declaration.referencedLocalNames

        closureDeclarations =
            availableDeclarations
                |> Dict.toList
                |> List.filter (Tuple.first >> Set.member >> (|>) referencedNames)
                |> List.map (Tuple.mapSecond .expression)
    in
    buildClosureExpression
        closureDeclarations
        declaration.expression
        |> Pine.encodeExpressionAsValue


listReferencedLocalNamesTransitive : Dict.Dict String DeclarationInTranslation -> Set.Set String -> Set.Set String
listReferencedLocalNamesTransitive availableDeclarations roots =
    let
        step =
            roots
                |> Set.toList
                |> List.concatMap
                    (\root ->
                        root
                            :: (availableDeclarations
                                    |> Dict.get root
                                    |> Maybe.map (.referencedLocalNames >> Set.toList)
                                    |> Maybe.withDefault []
                               )
                    )
                |> Set.fromList
    in
    if step == roots then
        roots

    else
        listReferencedLocalNamesTransitive availableDeclarations step


elmCoreModulesTexts : List String
elmCoreModulesTexts =
    [ """
module Basics exposing (..)


infix right 0 (<|) = apL
infix left  0 (|>) = apR
infix right 2 (||) = or
infix right 3 (&&) = and
infix non   4 (==) = eq
infix non   4 (/=) = neq
infix non   4 (<)  = lt
infix non   4 (>)  = gt
infix non   4 (<=) = le
infix non   4 (>=) = ge
infix right 5 (++) = append
infix left  6 (+)  = add
infix left  6 (-)  = sub
infix left  7 (*)  = mul
infix left  7 (//) = idiv
infix left  9 (<<) = composeL
infix right 9 (>>) = composeR


type Bool = True | False


type String
    = String (List Char.Char)


eq : a -> a -> Bool
eq a b =
    PineKernel.equal [ a, b ]


neq : a -> a -> Bool
neq a b =
    PineKernel.logical_not (PineKernel.equal [ a, b ])


add : number -> number -> number
add a b =
    PineKernel.add_int [ a, b ]


sub : number -> number -> number
sub a b =
    PineKernel.sub_int [ a, b ]


mul : number -> number -> number
mul a b =
    PineKernel.mul_int [ a, b ]


idiv : number -> number -> number
idiv a b =
    PineKernel.div_int [ a, b ]


and : Bool -> Bool -> Bool
and a b =
    PineKernel.logical_and [ a, b ]


or : Bool -> Bool -> Bool
or a b =
    PineKernel.logical_or [ a, b ]


append : appendable -> appendable -> appendable
append a b =
    case a of
    String stringA ->
        case b of
        String stringB ->
            String (PineKernel.concat [stringA, stringB])
        _ -> PineKernel.concat [a, b]
    _ -> PineKernel.concat [a, b]


lt : comparable -> comparable -> Bool
lt a b =
    PineKernel.logical_and
    [ (le a b)
    , PineKernel.logical_not (PineKernel.equal [a, b])
    ]


gt : comparable -> comparable -> Bool
gt a b =
    PineKernel.logical_and
    [ (ge a b)
    , PineKernel.logical_not (PineKernel.equal [a, b])
    ]


le : comparable -> comparable -> Bool
le a b =
    PineKernel.equal [ PineKernel.sort_int [a, b], [a, b] ]


ge : comparable -> comparable -> Bool
ge a b =
    PineKernel.equal [ PineKernel.sort_int [b, a], [b, a] ]


apR : a -> (a -> b) -> b
apR x f =
    f x


apL : (a -> b) -> a -> b
apL f x =
    f x


composeL : (b -> c) -> (a -> b) -> (a -> c)
composeL g f x =
    g (f x)


composeR : (a -> b) -> (b -> c) -> (a -> c)
composeR f g x =
    g (f x)


identity : a -> a
identity x =
    x


always : a -> b -> a
always a _ =
    a


not : Bool -> Bool
not bool =
    if PineKernel.equal [ bool, True ] then
        False
    else
        True

"""
    , """
module Tuple exposing
  ( pair
  , first, second
  , mapFirst, mapSecond, mapBoth
  )


pair : a -> b -> (a, b)
pair a b =
  (a, b)


first : (a, b) -> a
first (x,_) =
    x


second : (a, b) -> b
second (_,y) =
    y


mapFirst : (a -> x) -> (a, b) -> (x, b)
mapFirst func (x,y) =
    (func x, y)


mapSecond : (b -> y) -> (a, b) -> (a, y)
mapSecond func (x,y) =
    (x, func y)


mapBoth : (a -> x) -> (b -> y) -> (a, b) -> (x, y)
mapBoth funcA funcB (x,y) =
    ( funcA x, funcB y )

"""
    , -- https://github.com/elm/core/blob/84f38891468e8e153fc85a9b63bdafd81b24664e/src/List.elm
      """
module List exposing (..)


import Basics exposing (..)
import Maybe exposing (Maybe(..))


infix right 5 (::) = cons


singleton : a -> List a
singleton value =
    [value]


repeat : Int -> a -> List a
repeat n value =
    repeatHelp [] n value


repeatHelp : List a -> Int -> a -> List a
repeatHelp result n value =
    if n <= 0 then
        result
    else
        repeatHelp (cons value result) (n - 1) value


range : Int -> Int -> List Int
range lo hi =
    rangeHelp lo hi []


rangeHelp : Int -> Int -> List Int -> List Int
rangeHelp lo hi list =
    if lo <= hi then
        rangeHelp lo (hi - 1) (cons hi list)
    else
        list


cons : a -> List a -> List a
cons element list =
    PineKernel.concat [ [ element ], list ]


map : (a -> b) -> List a -> List b
map f xs =
    foldr (\\x acc -> cons (f x) acc) [] xs


foldl : (a -> b -> b) -> b -> List a -> b
foldl func acc list =
    case list of
        [] ->
            acc

        x :: xs ->
            foldl func (func x acc) xs


foldr : (a -> b -> b) -> b -> List a -> b
foldr func acc list =
    foldl func acc (reverse list)


filter : (a -> Bool) -> List a -> List a
filter isGood list =
    foldr (\\x xs -> if isGood x then cons x xs else xs) [] list


length : List a -> Int
length list =
    PineKernel.length list


reverse : List a -> List a
reverse list =
    PineKernel.reverse list


member : a -> List a -> Bool
member x xs =
    any (\\a -> a == x) xs


any : (a -> Bool) -> List a -> Bool
any isOkay list =
    case list of
        [] ->
            False

        x :: xs ->
            if isOkay x then
                True

            else
                any isOkay xs


append : List a -> List a -> List a
append xs ys =
    concat [ xs, ys ]


concat : List (List a) -> List a
concat lists =
    PineKernel.concat lists


isEmpty : List a -> Bool
isEmpty xs =
    case xs of
        [] ->
            True

        _ ->
            False


head : List a -> Maybe a
head list =
    case list of
        x :: xs ->
            Just x

        [] ->
            Nothing


tail : List a -> Maybe (List a)
tail list =
    case list of
        x :: xs ->
            Just xs

        [] ->
            Nothing


take : Int -> List a -> List a
take n list =
    PineKernel.take [ n, list ]


drop : Int -> List a -> List a
drop n list =
    PineKernel.skip [ n, list ]


"""
    , """
module Char exposing (..)


import Basics exposing (Bool, Int, (&&), (||), (>=), (<=))


type alias Char = Int


toCode : Char -> Int
toCode char =
    -- Add the sign prefix byte
    PineKernel.concat [ PineKernel.take [ 1, 0 ], char ]

"""
    , """
module Maybe exposing (..)


type Maybe a
    = Just a
    | Nothing


withDefault : a -> Maybe a -> a
withDefault default maybe =
    case maybe of
        Just value -> value
        Nothing -> default


map : (a -> b) -> Maybe a -> Maybe b
map f maybe =
    case maybe of
        Just value ->
            Just (f value)

        Nothing ->
            Nothing


andThen : (a -> Maybe b) -> Maybe a -> Maybe b
andThen callback maybeValue =
    case maybeValue of
        Just value ->
            callback value

        Nothing ->
            Nothing

"""
    , """
module String exposing (..)

import Basics exposing (..)
import Char
import List exposing ((::))
import Maybe exposing (Maybe)
import Tuple


type String
    = String (List Char.Char)


toList : String -> List Char
toList string =
    case string of
    String list -> list


fromList : List Char -> String
fromList =
    String


fromChar : Char -> String
fromChar char =
    String [ char ]


isEmpty : String -> Bool
isEmpty string =
    string == ""


length : String -> Int
length =
    toList >> List.length


reverse : String -> String
reverse =
    toList >> List.reverse >> fromList


repeat : Int -> String -> String
repeat n =
    toList >> List.repeat n >> List.concat >> fromList


replace : String -> String -> String -> String
replace before after string =
    join after (split before string)


append : String -> String -> String
append a b =
    PineKernel.concat [ toList a, toList b ]


concat : List String -> String
concat strings =
    join "" strings


split : String -> String -> List String
split sep string =
    if sep == "" then
        List.map fromChar (toList string)

    else splitHelperOnList [] (toList sep) (toList string)


splitHelperOnList : List Char -> List Char -> List Char -> List String
splitHelperOnList current sep string =
    if string == [] then
        [ fromList current ]

    else if sep == (List.take (List.length sep) string) then
        [ fromList current ] ++ splitHelperOnList [] sep (List.drop (List.length sep) string)

    else
        splitHelperOnList (current ++ List.take 1 string) sep (List.drop 1 string)


join : String -> List String -> String
join sep chunks =
    fromList (joinOnList (toList sep) (List.map toList chunks))


joinOnList : List Char -> List (List Char) -> List Char
joinOnList sep chunks =
    case chunks of
        [] ->
            []

        nextChunk :: remaining ->
            if remaining == []
            then
                nextChunk
            else
                nextChunk ++ sep ++ joinOnList sep remaining


slice : Int -> Int -> String -> String
slice start end string =
    let
        absoluteIndex relativeIndex =
            if relativeIndex < 0 then
                relativeIndex + length string

            else
                relativeIndex

        absoluteStart =
            absoluteIndex start
    in
    fromList (List.take (absoluteIndex end - absoluteStart) (List.drop absoluteStart (toList string)))


left : Int -> String -> String
left n string =
    fromList (List.take n (toList string))


right : Int -> String -> String
right n string =
    if n < 1 then
        ""
    else
        slice -n (length string) string


dropLeft : Int -> String -> String
dropLeft n string =
    fromList (List.drop n (toList string))


dropRight : Int -> String -> String
dropRight n string =
    if n < 1 then
        string
    else
        slice 0 -n string


contains : String -> String -> Bool
contains pattern string =
    if startsWith pattern string then
        True
    else
        if length pattern < length string then
            contains pattern (dropLeft 1 string)
        else
            False


startsWith : String -> String -> Bool
startsWith pattern string =
    left (length pattern) string == pattern


endsWith : String -> String -> Bool
endsWith pattern string =
    right (length pattern) string == pattern


toInt : String -> Maybe Int
toInt =
    toIntDecimal


toIntDecimal : String -> Maybe Int
toIntDecimal =
    toIntFromDigitsChars digitCharactersDecimal


fromInt : Int -> String
fromInt =
    fromIntDecimal


fromIntDecimal : Int -> String
fromIntDecimal int =
    fromList (fromIntFromDigitsChars digitCharactersDecimal int)


digitCharactersDecimal : List ( Char, Int )
digitCharactersDecimal =
    [ ( '0', 0 )
    , ( '1', 1 )
    , ( '2', 2 )
    , ( '3', 3 )
    , ( '4', 4 )
    , ( '5', 5 )
    , ( '6', 6 )
    , ( '7', 7 )
    , ( '8', 8 )
    , ( '9', 9 )
    ]


toIntFromDigitsChars : List ( Char, Int ) -> String -> Maybe Int
toIntFromDigitsChars digitsCharacters string =
    case toList string of
        [] ->
            Nothing

        firstChar :: lessFirstChar ->
            let
                ( valueString, signMultiplier ) =
                    case firstChar of
                        '-' ->
                            ( lessFirstChar, -1 )

                        '+' ->
                            ( lessFirstChar, 1 )

                        _ ->
                            ( toList string, 1 )
            in
            Maybe.map (\\value -> value * signMultiplier)
                (toUnsignedIntFromDigitsChars digitsCharacters valueString)


toUnsignedIntFromDigitsChars : List ( Char, Int ) -> List Char -> Maybe Int
toUnsignedIntFromDigitsChars digitsCharacters string =
    let
        digitValueFromCharacter char =
            Maybe.map Tuple.second (List.head (List.filter (\\(c, _) -> c == char) digitsCharacters))
    in
    case string of
        [] ->
            Nothing

        digits ->
            List.foldl
                (\\maybeDigitValue ->
                    Maybe.andThen
                        (\\aggregate ->
                            case maybeDigitValue of
                                Nothing ->
                                    Nothing

                                Just digitValue ->
                                    Just (aggregate * List.length digitsCharacters + digitValue)
                        )
                )
                (Just 0)
                (List.map digitValueFromCharacter digits)


fromIntFromDigitsChars : List ( Char, Int ) -> Int -> List Char
fromIntFromDigitsChars digitsCharacters int =
    if int < 0 then
        [ '-' ] ++ fromIntFromDigitsChars digitsCharacters -int

    else
        let
            digitCharacterFromValue digitValue =
                Maybe.map Tuple.first (List.head (List.filter (\\( _, c ) -> c == digitValue) digitsCharacters))

            upperDigitsValue =
                int // 10

            lastDigitValue =
                int - (upperDigitsValue * 10)

            upperDigitsString =
                if upperDigitsValue < 1 then
                    []

                else
                    fromIntFromDigitsChars digitsCharacters upperDigitsValue
        in
        upperDigitsString ++ [ Maybe.withDefault 'e' (digitCharacterFromValue lastDigitValue) ]

"""
    ]


moduleNamesWithoutImplicitImport : List (List String)
moduleNamesWithoutImplicitImport =
    autoImportedModulesNames
        ++ [ [ "Char" ]
           , [ "Tuple" ]
           ]


autoImportedModulesNames : List (List String)
autoImportedModulesNames =
    [ [ "Basics" ]
    , [ "Maybe" ]
    , [ "List" ]
    , [ "String" ]
    ]


elmValuesToExposeToGlobal : List ( List String, String )
elmValuesToExposeToGlobal =
    [ ( [ "Basics" ], "identity" )
    , ( [ "Basics" ], "always" )
    , ( [ "Basics" ], "not" )
    , ( [ "Basics" ], "(==)" )
    , ( [ "Basics" ], "(/=)" )
    , ( [ "Basics" ], "(&&)" )
    , ( [ "Basics" ], "(||)" )
    , ( [ "Basics" ], "(<)" )
    , ( [ "Basics" ], "(>)" )
    , ( [ "Basics" ], "(<=)" )
    , ( [ "Basics" ], "(>=)" )
    , ( [ "Basics" ], "(++)" )
    , ( [ "Basics" ], "(+)" )
    , ( [ "Basics" ], "(-)" )
    , ( [ "Basics" ], "(*)" )
    , ( [ "Basics" ], "(//)" )
    , ( [ "Basics" ], "(|>)" )
    , ( [ "Basics" ], "(<|)" )
    , ( [ "Basics" ], "(>>)" )
    , ( [ "Basics" ], "(<<)" )
    , ( [ "Basics" ], "True" )
    , ( [ "Basics" ], "False" )
    , ( [ "List" ], "(::)" )
    , ( [ "Maybe" ], "Nothing" )
    , ( [ "Maybe" ], "Just" )
    ]


type alias CompilationStack =
    { moduleAliases : Dict.Dict (List String) (List String)
    , availableDeclarations : Dict.Dict String InternalDeclaration
    , inliningParentDeclarations : Set.Set String
    }


addInliningParentDeclaration : String -> CompilationStack -> CompilationStack
addInliningParentDeclaration name compilation =
    { compilation
        | inliningParentDeclarations = compilation.inliningParentDeclarations |> Set.insert name
    }


type InternalDeclaration
    = CompiledDeclaration Pine.Value
    | ElmFunctionDeclaration Elm.Syntax.Expression.Function


type alias CompiledExpressionDependencies =
    { referencedNames : Set.Set String }


concatDependencies : List CompiledExpressionDependencies -> CompiledExpressionDependencies
concatDependencies dependencies =
    { referencedNames = dependencies |> List.concatMap (.referencedNames >> Set.toList) |> Set.fromList }


noDependencies : CompiledExpressionDependencies
noDependencies =
    { referencedNames = Set.empty }


pineExpressionFromElm :
    CompilationStack
    -> Elm.Syntax.Expression.Expression
    -> Result String ( Pine.Expression, CompiledExpressionDependencies )
pineExpressionFromElm stack elmExpression =
    case elmExpression of
        Elm.Syntax.Expression.Literal literal ->
            Ok
                ( Pine.LiteralExpression (valueFromString literal)
                , { referencedNames = Set.empty }
                )

        Elm.Syntax.Expression.CharLiteral char ->
            Ok
                ( Pine.LiteralExpression (Pine.valueFromChar char)
                , { referencedNames = Set.empty }
                )

        Elm.Syntax.Expression.Integer integer ->
            Ok
                ( Pine.LiteralExpression (Pine.valueFromBigInt (BigInt.fromInt integer))
                , { referencedNames = Set.empty }
                )

        Elm.Syntax.Expression.Hex integer ->
            Ok
                ( Pine.LiteralExpression (Pine.valueFromBigInt (BigInt.fromInt integer))
                , { referencedNames = Set.empty }
                )

        Elm.Syntax.Expression.Negation negatedElmExpression ->
            case pineExpressionFromElm stack (Elm.Syntax.Node.value negatedElmExpression) of
                Err error ->
                    Err ("Failed to compile negated expression: " ++ error)

                Ok ( negatedExpression, dependencies ) ->
                    Ok
                        ( Pine.KernelApplicationExpression
                            { functionName = "neg_int"
                            , argument = negatedExpression
                            }
                        , dependencies
                        )

        Elm.Syntax.Expression.FunctionOrValue moduleName localName ->
            if moduleName == [] then
                pineExpressionFromElmFunctionOrValue localName stack

            else
                getDeclarationValueFromCompilation ( moduleName, localName ) stack
                    |> Result.map
                        (\declaredValue ->
                            ( Pine.ApplicationExpression
                                { function = Pine.LiteralExpression declaredValue
                                , argument = Pine.ListExpression []
                                }
                            , noDependencies
                            )
                        )

        Elm.Syntax.Expression.Application application ->
            case application of
                [] ->
                    Err "Invalid shape of application: Zero elements in the application list"

                appliedFunctionElmSyntax :: elmArguments ->
                    case
                        elmArguments
                            |> List.map (Elm.Syntax.Node.value >> pineExpressionFromElm stack)
                            |> Result.Extra.combine
                    of
                        Err error ->
                            Err ("Failed to compile Elm arguments: " ++ error)

                        Ok arguments ->
                            let
                                continueWithNonKernelApplication =
                                    case
                                        appliedFunctionElmSyntax
                                            |> Elm.Syntax.Node.value
                                            |> pineExpressionFromElm stack
                                    of
                                        Err error ->
                                            Err ("Failed to compile Elm function syntax: " ++ error)

                                        Ok ( appliedFunctionSyntax, dependencies ) ->
                                            Ok
                                                ( positionalApplicationExpressionFromListOfArguments
                                                    appliedFunctionSyntax
                                                    (arguments |> List.map Tuple.first)
                                                , dependencies
                                                    :: (arguments |> List.map Tuple.second)
                                                    |> concatDependencies
                                                )
                            in
                            case Elm.Syntax.Node.value appliedFunctionElmSyntax of
                                Elm.Syntax.Expression.FunctionOrValue functionModuleName functionLocalName ->
                                    if functionModuleName == [ pineKernelModuleName ] then
                                        case arguments of
                                            [ ( singleArgumentExpression, singleArgumentDependencies ) ] ->
                                                Ok
                                                    ( Pine.KernelApplicationExpression
                                                        { functionName = functionLocalName
                                                        , argument = singleArgumentExpression
                                                        }
                                                    , singleArgumentDependencies
                                                    )

                                            _ ->
                                                Err "Invalid argument list for kernel application: Wrap arguments into a single list expression"

                                    else
                                        continueWithNonKernelApplication

                                _ ->
                                    continueWithNonKernelApplication

        Elm.Syntax.Expression.OperatorApplication operator _ leftExpr rightExpr ->
            let
                orderedElmExpression =
                    mapExpressionForOperatorPrecedence elmExpression
            in
            if orderedElmExpression /= elmExpression then
                pineExpressionFromElm stack orderedElmExpression

            else
                pineExpressionFromElm stack (Elm.Syntax.Node.value leftExpr)
                    |> Result.mapError ((++) "Failed to compile left expression: ")
                    |> Result.andThen
                        (\( leftExpression, leftDeps ) ->
                            pineExpressionFromElm stack (Elm.Syntax.Node.value rightExpr)
                                |> Result.mapError ((++) "Failed to compile right expression: ")
                                |> Result.andThen
                                    (\( rightExpression, rightDeps ) ->
                                        pineExpressionFromElmFunctionOrValue ("(" ++ operator ++ ")") stack
                                            |> Result.map
                                                (\( operationFunction, operationFunctionDeps ) ->
                                                    ( Pine.ApplicationExpression
                                                        { function =
                                                            Pine.ApplicationExpression
                                                                { function = operationFunction
                                                                , argument = leftExpression
                                                                }
                                                        , argument = rightExpression
                                                        }
                                                    , [ leftDeps, rightDeps, operationFunctionDeps ]
                                                        |> concatDependencies
                                                    )
                                                )
                                    )
                        )
                    |> Result.mapError ((++) ("Failed to compile OperatorApplication '" ++ operator ++ "': "))

        Elm.Syntax.Expression.PrefixOperator operator ->
            pineExpressionFromElmFunctionOrValue ("(" ++ operator ++ ")") stack

        Elm.Syntax.Expression.IfBlock elmCondition elmExpressionIfTrue elmExpressionIfFalse ->
            case pineExpressionFromElm stack (Elm.Syntax.Node.value elmCondition) of
                Err error ->
                    Err ("Failed to compile Elm condition: " ++ error)

                Ok ( conditionExpression, conditionExpressionDeps ) ->
                    case pineExpressionFromElm stack (Elm.Syntax.Node.value elmExpressionIfTrue) of
                        Err error ->
                            Err ("Failed to compile Elm expressionIfTrue: " ++ error)

                        Ok ( expressionIfTrue, expressionIfTrueDeps ) ->
                            case pineExpressionFromElm stack (Elm.Syntax.Node.value elmExpressionIfFalse) of
                                Err error ->
                                    Err ("Failed to compile Elm expressionIfFalse: " ++ error)

                                Ok ( expressionIfFalse, expressionIfFalseDeps ) ->
                                    Ok
                                        ( Pine.ConditionalExpression
                                            { condition = conditionExpression
                                            , ifTrue = expressionIfTrue
                                            , ifFalse = expressionIfFalse
                                            }
                                        , [ conditionExpressionDeps, expressionIfFalseDeps, expressionIfTrueDeps ]
                                            |> concatDependencies
                                        )

        Elm.Syntax.Expression.LetExpression letBlock ->
            pineExpressionFromElmLetBlock stack letBlock

        Elm.Syntax.Expression.ParenthesizedExpression parenthesizedExpression ->
            pineExpressionFromElm stack (Elm.Syntax.Node.value parenthesizedExpression)

        Elm.Syntax.Expression.ListExpr listExpression ->
            listExpression
                |> List.map (Elm.Syntax.Node.value >> pineExpressionFromElm stack)
                |> Result.Extra.combine
                |> Result.map
                    (\list ->
                        ( Pine.ListExpression (List.map Tuple.first list)
                        , concatDependencies (List.map Tuple.second list)
                        )
                    )

        Elm.Syntax.Expression.CaseExpression caseBlock ->
            pineExpressionFromElmCaseBlock stack caseBlock

        Elm.Syntax.Expression.LambdaExpression lambdaExpression ->
            pineExpressionFromElmLambda stack lambdaExpression

        Elm.Syntax.Expression.RecordExpr recordExpr ->
            recordExpr
                |> List.map Elm.Syntax.Node.value
                |> pineExpressionFromElmRecord stack

        Elm.Syntax.Expression.TupledExpression tupleElements ->
            tupleElements
                |> List.map (Elm.Syntax.Node.value >> pineExpressionFromElm stack)
                |> Result.Extra.combine
                |> Result.map
                    (\elements ->
                        ( elements |> List.map Tuple.first |> Pine.ListExpression
                        , elements |> List.map Tuple.second |> concatDependencies
                        )
                    )

        Elm.Syntax.Expression.RecordAccess expressionNode nameNode ->
            pineExpressionFromElmRecordAccess stack
                (Elm.Syntax.Node.value nameNode)
                (Elm.Syntax.Node.value expressionNode)

        _ ->
            Err
                ("Unsupported type of expression: "
                    ++ (elmExpression |> Elm.Syntax.Expression.encode |> Json.Encode.encode 0)
                )


pineExpressionFromElmLetBlock :
    CompilationStack
    -> Elm.Syntax.Expression.LetBlock
    -> Result String ( Pine.Expression, CompiledExpressionDependencies )
pineExpressionFromElmLetBlock stack letBlock =
    let
        declarationsResults =
            letBlock.declarations
                |> List.map (Elm.Syntax.Node.value >> pineExpressionFromElmLetDeclaration stack)
    in
    case declarationsResults |> Result.Extra.combine of
        Err error ->
            Err ("Failed to translate declaration in let block: " ++ error)

        Ok declarations ->
            case pineExpressionFromElm stack (Elm.Syntax.Node.value letBlock.expression) of
                Err error ->
                    Err ("Failed to translate expression in let block: " ++ error)

                Ok ( expressionInExpandedContext, expressionInExpandedContextDeps ) ->
                    Ok
                        ( buildClosureExpression
                            (List.concat (List.map Tuple.first declarations))
                            expressionInExpandedContext
                        , expressionInExpandedContextDeps
                            :: List.map Tuple.second declarations
                            |> concatDependencies
                        )


pineExpressionFromElmLetDeclaration :
    CompilationStack
    -> Elm.Syntax.Expression.LetDeclaration
    -> Result String ( List ( String, Pine.Expression ), CompiledExpressionDependencies )
pineExpressionFromElmLetDeclaration stack declaration =
    case declaration of
        Elm.Syntax.Expression.LetFunction letFunction ->
            pineExpressionFromElmFunction stack letFunction
                |> Result.map
                    (\( functionName, ( function, functionDeps ) ) ->
                        ( [ ( functionName, function ) ], functionDeps )
                    )

        Elm.Syntax.Expression.LetDestructuring patternNode expressionNode ->
            (case declarationsFromPattern (Elm.Syntax.Node.value patternNode) of
                Err error ->
                    Err ("Failed to translate pattern: " ++ error)

                Ok deconstruct ->
                    case pineExpressionFromElm stack (Elm.Syntax.Node.value expressionNode) of
                        Err error ->
                            Err ("Failed to translate expression: " ++ error)

                        Ok ( pineExpression, pineExpressionDeps ) ->
                            Ok ( deconstruct pineExpression, pineExpressionDeps )
            )
                |> Result.mapError ((++) "Failed destructuring in let block: ")


pineExpressionFromElmFunction :
    CompilationStack
    -> Elm.Syntax.Expression.Function
    -> Result String ( String, ( Pine.Expression, CompiledExpressionDependencies ) )
pineExpressionFromElmFunction stack function =
    pineExpressionFromElmFunctionWithoutName stack
        { arguments = (Elm.Syntax.Node.value function.declaration).arguments |> List.map Elm.Syntax.Node.value
        , expression = Elm.Syntax.Node.value (Elm.Syntax.Node.value function.declaration).expression
        }
        |> Result.map
            (\functionWithoutName ->
                ( Elm.Syntax.Node.value (Elm.Syntax.Node.value function.declaration).name
                , functionWithoutName
                )
            )


pineExpressionFromElmFunctionWithoutName :
    CompilationStack
    -> { arguments : List Elm.Syntax.Pattern.Pattern, expression : Elm.Syntax.Expression.Expression }
    -> Result String ( Pine.Expression, CompiledExpressionDependencies )
pineExpressionFromElmFunctionWithoutName stack function =
    case pineExpressionFromElm stack function.expression of
        Err error ->
            Err ("Failed to translate expression in let function: " ++ error)

        Ok ( functionBodyExpression, functionBodyExpressionDeps ) ->
            case
                function.arguments
                    |> List.map
                        (\pattern ->
                            declarationsFromPattern pattern
                                |> Result.map (\deconstruct -> ( deconstruct, inspectionSymbolFromPattern pattern ))
                        )
                    |> Result.Extra.combine
            of
                Err error ->
                    Err ("Failed to translate function argument pattern: " ++ error)

                Ok argumentsDeconstructDeclarationsBuilders ->
                    let
                        functionId =
                            function.expression
                                |> Elm.Syntax.Expression.encode
                                |> Json.Encode.encode 0
                                |> SHA256.fromString
                                |> SHA256.toHex
                                |> String.left 8

                        argumentsDeconstructionDeclarations =
                            argumentsDeconstructDeclarationsBuilders
                                |> List.indexedMap
                                    (\argIndex ( deconstruction, inspectionSymbol ) ->
                                        let
                                            argumentNameBeforeDeconstruct =
                                                String.join "_" [ "function", functionId, "argument", String.fromInt argIndex, inspectionSymbol ]
                                        in
                                        ( argumentNameBeforeDeconstruct
                                        , deconstruction (expressionToLookupNameInEnvironment argumentNameBeforeDeconstruct)
                                        )
                                    )

                        letBlockExpression =
                            buildClosureExpression
                                (List.concatMap Tuple.second argumentsDeconstructionDeclarations)
                                functionBodyExpression
                    in
                    Ok
                        ( functionExpressionFromArgumentsNamesAndExpression
                            (argumentsDeconstructionDeclarations |> List.map Tuple.first)
                            letBlockExpression
                        , functionBodyExpressionDeps
                        )


inspectionSymbolFromPattern : Elm.Syntax.Pattern.Pattern -> String
inspectionSymbolFromPattern pattern =
    case pattern of
        Elm.Syntax.Pattern.AllPattern ->
            "ignored"

        Elm.Syntax.Pattern.VarPattern name ->
            name

        _ ->
            "other_pattern"


declarationsFromPattern : Elm.Syntax.Pattern.Pattern -> Result String (Pine.Expression -> List ( String, Pine.Expression ))
declarationsFromPattern pattern =
    case pattern of
        Elm.Syntax.Pattern.VarPattern varName ->
            Ok (\deconstructedExpression -> [ ( varName, deconstructedExpression ) ])

        Elm.Syntax.Pattern.AllPattern ->
            Ok (always [])

        Elm.Syntax.Pattern.TuplePattern tupleElements ->
            let
                getTupleElementExpression =
                    listItemFromIndexExpression
            in
            case
                tupleElements
                    |> List.map Elm.Syntax.Node.value
                    |> List.map declarationsFromPattern
                    |> Result.Extra.combine
            of
                Err error ->
                    Err ("Failed to compile tuple element: " ++ error)

                Ok tupleElementsDeconstructions ->
                    Ok
                        (\deconstructedExpression ->
                            tupleElementsDeconstructions
                                |> List.indexedMap
                                    (\tupleElementIndex tupleElement ->
                                        tupleElement (getTupleElementExpression tupleElementIndex deconstructedExpression)
                                    )
                                |> List.concat
                        )

        Elm.Syntax.Pattern.RecordPattern fieldsElements ->
            (\recordExpression ->
                fieldsElements
                    |> List.map Elm.Syntax.Node.value
                    |> List.map (\fieldName -> ( fieldName, pineExpressionForRecordAccess fieldName recordExpression ))
            )
                |> Ok

        _ ->
            Err ("Unsupported type of pattern: " ++ (pattern |> Elm.Syntax.Pattern.encode |> Json.Encode.encode 0))


functionExpressionFromArgumentsNamesAndExpression : List String -> Pine.Expression -> Pine.Expression
functionExpressionFromArgumentsNamesAndExpression argumentsNames expression =
    argumentsNames
        |> List.foldr (\argumentName prevExpression -> buildFunctionBindingArgumentToName argumentName prevExpression)
            expression


buildFunctionBindingArgumentToName : String -> Pine.Expression -> Pine.Expression
buildFunctionBindingArgumentToName argumentName function =
    makeElmFunction argumentName (Pine.LiteralExpression (Pine.encodeExpressionAsValue function))


{-| Builds an expression that maps the current application argument into a literal and wraps that in a function application expression that will bind the next application argument to the given name, together with the earlier captured context.
In other words, it captures the current environment together with the function to enable transport to and reuse in other places.
-}
makeElmFunction : String -> Pine.Expression -> Pine.Expression
makeElmFunction argumentName functionExpression =
    Pine.ListExpression
        [ Pine.LiteralExpression (Pine.valueFromString "Application")
        , Pine.ListExpression
            [ Pine.ListExpression
                [ Pine.LiteralExpression (Pine.valueFromString "function")
                , functionExpression |> Pine.encodeExpressionAsValue |> Pine.LiteralExpression
                ]
            , Pine.ListExpression
                [ Pine.LiteralExpression (Pine.valueFromString "argument")
                , Pine.ListExpression
                    [ Pine.LiteralExpression (Pine.valueFromString "KernelApplication")
                    , Pine.ListExpression
                        [ Pine.ListExpression
                            [ Pine.LiteralExpression (Pine.valueFromString "functionName")
                            , Pine.LiteralExpression (Pine.valueFromString "concat")
                            ]
                        , Pine.ListExpression
                            [ Pine.LiteralExpression (Pine.valueFromString "argument")
                            , Pine.ListExpression
                                [ Pine.LiteralExpression (Pine.valueFromString "List")
                                , Pine.ListExpression
                                    [ Pine.ListExpression
                                        [ Pine.ListExpression
                                            [ Pine.LiteralExpression (Pine.valueFromString argumentName)
                                            , Pine.ApplicationArgumentExpression
                                            ]
                                        ]
                                        |> Pine.encodeExpressionAsValue
                                        |> Pine.LiteralExpression
                                    , Pine.ListExpression
                                        [ Pine.LiteralExpression (Pine.valueFromString "Literal")

                                        -- Below is the part we cannot express using a literal.
                                        , Pine.ApplicationArgumentExpression
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]


buildPositionalApplicationExpression : { function : Pine.Expression, argument : Pine.Expression } -> Pine.Expression
buildPositionalApplicationExpression { function, argument } =
    Pine.ApplicationExpression
        { function = function
        , argument = argument
        }


buildClosureExpression : List ( String, Pine.Expression ) -> Pine.Expression -> Pine.Expression
buildClosureExpression environment expression =
    let
        declarationsValues =
            environment
                |> List.map (Tuple.mapSecond Pine.encodeExpressionAsValue)
                |> List.map Pine.valueFromContextExpansionWithName
    in
    Pine.ApplicationExpression
        { function =
            expression
                |> Pine.encodeExpressionAsValue
                |> Pine.LiteralExpression
        , argument =
            pineKernel_ListConcat
                (Pine.ListExpression
                    [ declarationsValues |> Pine.ListValue |> Pine.LiteralExpression
                    , Pine.ApplicationArgumentExpression
                    ]
                )
        }


pineExpressionFromElmValueConstructor : Elm.Syntax.Type.ValueConstructor -> ( String, Pine.Expression )
pineExpressionFromElmValueConstructor valueConstructor =
    let
        constructorName =
            Elm.Syntax.Node.value valueConstructor.name

        argumentsNames =
            valueConstructor.arguments
                |> List.indexedMap
                    (\i _ -> String.join "_" [ "const_tag", constructorName, "arg", String.fromInt i ])
    in
    ( constructorName
    , argumentsNames
        |> List.foldl
            buildFunctionBindingArgumentToName
            (Pine.tagValueExpression constructorName (argumentsNames |> List.map expressionToLookupNameInEnvironment))
    )


pineExpressionFromElmCaseBlock :
    CompilationStack
    -> Elm.Syntax.Expression.CaseBlock
    -> Result String ( Pine.Expression, CompiledExpressionDependencies )
pineExpressionFromElmCaseBlock stack caseBlock =
    case pineExpressionFromElm stack (Elm.Syntax.Node.value caseBlock.expression) of
        Err error ->
            Err ("Failed to compile case block expression: " ++ error)

        Ok ( expression, conditionDependencies ) ->
            case
                caseBlock.cases
                    |> List.map (pineExpressionFromElmCaseBlockCase stack expression)
                    |> Result.Extra.combine
            of
                Err error ->
                    Err ("Failed to compile case in case-of block: " ++ error)

                Ok cases ->
                    let
                        conditionalFromCase deconstructedCase nextBlockExpression =
                            Pine.ConditionalExpression
                                { condition = deconstructedCase.conditionExpression
                                , ifTrue =
                                    buildClosureExpression
                                        deconstructedCase.declarations
                                        (Tuple.first deconstructedCase.thenExpression)
                                , ifFalse = nextBlockExpression
                                }

                        casesDependencies =
                            cases |> List.map (.thenExpression >> Tuple.second)
                    in
                    Ok
                        ( List.foldr
                            conditionalFromCase
                            (Pine.LiteralExpression (Pine.valueFromString "Error in mapping of case-of block: No matching branch."))
                            cases
                        , conditionDependencies
                            :: casesDependencies
                            |> concatDependencies
                        )


pineExpressionFromElmCaseBlockCase :
    CompilationStack
    -> Pine.Expression
    -> Elm.Syntax.Expression.Case
    ->
        Result
            String
            { conditionExpression : Pine.Expression
            , declarations : List ( String, Pine.Expression )
            , thenExpression : ( Pine.Expression, CompiledExpressionDependencies )
            }
pineExpressionFromElmCaseBlockCase stack caseBlockValueExpression ( elmPattern, elmExpression ) =
    case pineExpressionFromElm stack (Elm.Syntax.Node.value elmExpression) of
        Err error ->
            Err ("Failed to compile case expression: " ++ error)

        Ok caseValueExpression ->
            pineExpressionFromElmPattern stack caseBlockValueExpression elmPattern
                |> Result.map
                    (\deconstruction ->
                        { conditionExpression = deconstruction.conditionExpression
                        , declarations = deconstruction.declarations
                        , thenExpression = caseValueExpression
                        }
                    )


pineExpressionFromElmPattern :
    CompilationStack
    -> Pine.Expression
    -> Elm.Syntax.Node.Node Elm.Syntax.Pattern.Pattern
    ->
        Result
            String
            { conditionExpression : Pine.Expression
            , declarations : List ( String, Pine.Expression )
            }
pineExpressionFromElmPattern stack caseBlockValueExpression elmPattern =
    let
        continueWithOnlyEqualsCondition valueToCompare =
            Ok
                { conditionExpression = equalCondition [ caseBlockValueExpression, valueToCompare ]
                , declarations = []
                }
    in
    case Elm.Syntax.Node.value elmPattern of
        Elm.Syntax.Pattern.AllPattern ->
            Ok
                { conditionExpression = Pine.LiteralExpression Pine.trueValue
                , declarations = []
                }

        Elm.Syntax.Pattern.ListPattern listElements ->
            let
                conditionsAndDeclarationsFromPattern elementIndex =
                    pineExpressionFromElmPattern stack
                        (listItemFromIndexExpression elementIndex caseBlockValueExpression)
                        >> Result.map
                            (\listElementResult ->
                                { conditions = [ listElementResult.conditionExpression ]
                                , declarations = listElementResult.declarations
                                }
                            )
            in
            listElements
                |> List.indexedMap conditionsAndDeclarationsFromPattern
                |> Result.Extra.combine
                |> Result.map
                    (\elementsResults ->
                        let
                            matchesLengthCondition =
                                equalCondition
                                    [ Pine.LiteralExpression (Pine.valueFromBigInt (BigInt.fromInt (List.length listElements)))
                                    , countListElementsExpression caseBlockValueExpression
                                    ]

                            condition =
                                (matchesLengthCondition
                                    :: List.concatMap .conditions elementsResults
                                )
                                    |> booleanConjunctionExpressionFromList
                                        (equalCondition [ caseBlockValueExpression, Pine.ListExpression [] ])

                            declarations =
                                elementsResults |> List.concatMap .declarations
                        in
                        { conditionExpression = condition
                        , declarations = declarations
                        }
                    )

        Elm.Syntax.Pattern.UnConsPattern unconsLeft unconsRight ->
            case ( Elm.Syntax.Node.value unconsLeft, Elm.Syntax.Node.value unconsRight ) of
                ( Elm.Syntax.Pattern.VarPattern unconsLeftName, Elm.Syntax.Pattern.VarPattern unconsRightName ) ->
                    let
                        declarations =
                            [ ( unconsLeftName
                              , pineKernel_ListHead caseBlockValueExpression
                              )
                            , ( unconsRightName
                              , listSkipExpression 1 caseBlockValueExpression
                              )
                            ]

                        conditionExpression =
                            Pine.KernelApplicationExpression
                                { functionName = "logical_not"
                                , argument =
                                    equalCondition [ caseBlockValueExpression, listSkipExpression 1 caseBlockValueExpression ]
                                }
                    in
                    Ok
                        { conditionExpression = conditionExpression
                        , declarations = declarations
                        }

                _ ->
                    Err "Unsupported shape of uncons pattern."

        Elm.Syntax.Pattern.NamedPattern qualifiedName customTypeArgumentPatterns ->
            let
                mapArgumentsToOnlyNameResults =
                    customTypeArgumentPatterns
                        |> List.map Elm.Syntax.Node.value
                        |> List.map
                            (\argumentPattern ->
                                case argumentPattern of
                                    Elm.Syntax.Pattern.VarPattern argumentName ->
                                        Ok argumentName

                                    Elm.Syntax.Pattern.AllPattern ->
                                        Ok "unused_from_elm_all_pattern"

                                    _ ->
                                        Err ("Unsupported type of pattern: " ++ (argumentPattern |> Elm.Syntax.Pattern.encode |> Json.Encode.encode 0))
                            )

                conditionExpression =
                    equalCondition
                        [ Pine.LiteralExpression (Pine.valueFromString qualifiedName.name)
                        , pineKernel_ListHead caseBlockValueExpression
                        ]
            in
            case mapArgumentsToOnlyNameResults |> Result.Extra.combine of
                Err error ->
                    Err ("Failed to compile pattern in case block: " ++ error)

                Ok declarationsNames ->
                    let
                        argumentFromIndexExpression argumentIndex =
                            listSkipExpression
                                argumentIndex
                                (listItemFromIndexExpression 1 caseBlockValueExpression)

                        declarations =
                            declarationsNames
                                |> List.indexedMap
                                    (\argumentIndex declarationName ->
                                        ( declarationName
                                        , pineKernel_ListHead (argumentFromIndexExpression argumentIndex)
                                        )
                                    )
                    in
                    Ok
                        { conditionExpression = conditionExpression
                        , declarations = declarations
                        }

        Elm.Syntax.Pattern.CharPattern char ->
            continueWithOnlyEqualsCondition (Pine.LiteralExpression (Pine.valueFromChar char))

        Elm.Syntax.Pattern.IntPattern int ->
            continueWithOnlyEqualsCondition (Pine.LiteralExpression (Pine.valueFromBigInt (BigInt.fromInt int)))

        Elm.Syntax.Pattern.VarPattern name ->
            Ok
                { conditionExpression = Pine.LiteralExpression Pine.trueValue
                , declarations =
                    [ ( name
                      , caseBlockValueExpression
                      )
                    ]
                }

        _ ->
            Err
                ("Unsupported type of pattern in case-of block case: "
                    ++ Json.Encode.encode 0 (Elm.Syntax.Pattern.encode (Elm.Syntax.Node.value elmPattern))
                )


booleanConjunctionExpressionFromList : Pine.Expression -> List Pine.Expression -> Pine.Expression
booleanConjunctionExpressionFromList defaultIfEmpty operands =
    case operands of
        [] ->
            defaultIfEmpty

        firstOperator :: otherOperators ->
            otherOperators
                |> List.foldl
                    (\single aggregate -> applyKernelFunctionWithTwoArguments "logical_and" aggregate single)
                    firstOperator


listItemFromIndexExpression : Int -> Pine.Expression -> Pine.Expression
listItemFromIndexExpression itemIndex listExpression =
    pineKernel_ListHead (listSkipExpression itemIndex listExpression)


countListElementsExpression : Pine.Expression -> Pine.Expression
countListElementsExpression =
    pineKernel_ListLength


pineKernel_ListHead : Pine.Expression -> Pine.Expression
pineKernel_ListHead listExpression =
    Pine.KernelApplicationExpression
        { functionName = "list_head"
        , argument = listExpression
        }


pineKernel_ListLength : Pine.Expression -> Pine.Expression
pineKernel_ListLength listExpression =
    Pine.KernelApplicationExpression
        { functionName = "length"
        , argument = listExpression
        }


pineKernel_ListConcat : Pine.Expression -> Pine.Expression
pineKernel_ListConcat argument =
    Pine.KernelApplicationExpression
        { functionName = "concat"
        , argument = argument
        }


positionalApplicationExpressionFromListOfArguments : Pine.Expression -> List Pine.Expression -> Pine.Expression
positionalApplicationExpressionFromListOfArguments function arguments =
    case arguments of
        [] ->
            function

        nextArgument :: followingArguments ->
            positionalApplicationExpressionFromListOfArguments
                (buildPositionalApplicationExpression
                    { function = function
                    , argument = nextArgument
                    }
                )
                followingArguments


listSkipExpression : Int -> Pine.Expression -> Pine.Expression
listSkipExpression numberToDrop listExpression =
    if numberToDrop < 1 then
        listExpression

    else
        applyKernelFunctionWithTwoArguments
            "skip"
            (Pine.LiteralExpression (Pine.valueFromBigInt (BigInt.fromInt numberToDrop)))
            listExpression


pineExpressionFromElmLambda :
    CompilationStack
    -> Elm.Syntax.Expression.Lambda
    -> Result String ( Pine.Expression, CompiledExpressionDependencies )
pineExpressionFromElmLambda stack lambda =
    pineExpressionFromElmFunctionWithoutName stack
        { arguments = lambda.args |> List.map Elm.Syntax.Node.value
        , expression = Elm.Syntax.Node.value lambda.expression
        }


pineExpressionFromElmRecord :
    CompilationStack
    -> List Elm.Syntax.Expression.RecordSetter
    -> Result String ( Pine.Expression, CompiledExpressionDependencies )
pineExpressionFromElmRecord stack recordSetters =
    recordSetters
        |> List.map (Tuple.mapFirst Elm.Syntax.Node.value)
        |> List.sortBy Tuple.first
        |> List.map
            (\( fieldName, fieldExpressionNode ) ->
                case pineExpressionFromElm stack (Elm.Syntax.Node.value fieldExpressionNode) of
                    Err error ->
                        Err ("Failed to compile record field: " ++ error)

                    Ok ( fieldExpression, fieldExpressionDeps ) ->
                        Ok
                            ( Pine.ListExpression
                                [ Pine.LiteralExpression (Pine.valueFromString fieldName)
                                , fieldExpression
                                ]
                            , fieldExpressionDeps
                            )
            )
        |> Result.Extra.combine
        |> Result.map
            (\fields ->
                ( fields
                    |> List.map Tuple.first
                    |> Pine.ListExpression
                    |> List.singleton
                    |> Pine.tagValueExpression elmRecordTypeTagName
                , fields |> List.map Tuple.second |> concatDependencies
                )
            )


pineExpressionFromElmRecordAccess :
    CompilationStack
    -> String
    -> Elm.Syntax.Expression.Expression
    -> Result String ( Pine.Expression, CompiledExpressionDependencies )
pineExpressionFromElmRecordAccess stack fieldName recordElmExpression =
    pineExpressionFromElm stack recordElmExpression
        |> Result.mapError ((++) "Failed to compile record expression: ")
        |> Result.map
            (\( recordExpression, recordExpressionDeps ) ->
                ( pineExpressionForRecordAccess fieldName recordExpression
                , recordExpressionDeps
                )
            )


pineExpressionForRecordAccess : String -> Pine.Expression -> Pine.Expression
pineExpressionForRecordAccess fieldName recordExpression =
    let
        recordFieldsExpression =
            pineKernel_ListHead (listItemFromIndexExpression 1 recordExpression)
    in
    Pine.ConditionalExpression
        { condition =
            equalCondition
                [ Pine.LiteralExpression (Pine.valueFromString elmRecordTypeTagName)
                , pineKernel_ListHead recordExpression
                ]
        , ifTrue =
            Pine.StringTagExpression
                { tag = "Completed record access: " ++ fieldName
                , tagged = expressionToLookupNameInGivenScope fieldName recordFieldsExpression
                }
        , ifFalse =
            Pine.StringTagExpression
                { tag = "Failed record access: " ++ fieldName
                , tagged =
                    Pine.LiteralExpression
                        (Pine.valueFromString "Error: Used record access on value which is not a record")
                }
        }


pineExpressionFromElmFunctionOrValue : String -> CompilationStack -> Result String ( Pine.Expression, CompiledExpressionDependencies )
pineExpressionFromElmFunctionOrValue name compilation =
    let
        continueWithoutLocalResolution _ =
            pineExpressionFromElmFunctionOrValueWithoutLocalResolution name compilation
    in
    case compilation.availableDeclarations |> Dict.get name of
        Nothing ->
            continueWithoutLocalResolution ()

        Just (ElmFunctionDeclaration elmFunctionDeclaration) ->
            if compilation.inliningParentDeclarations |> Set.member name then
                continueWithoutLocalResolution ()

            else
                pineExpressionFromElmFunction (addInliningParentDeclaration name compilation) elmFunctionDeclaration
                    |> Result.mapError ((++) ("Failed to inline function '" ++ name ++ "': "))
                    |> Result.map Tuple.second

        Just (CompiledDeclaration compiledDeclaration) ->
            Ok
                ( Pine.ApplicationExpression
                    { function = Pine.LiteralExpression compiledDeclaration
                    , argument = Pine.ApplicationArgumentExpression
                    }
                , noDependencies
                )


pineExpressionFromElmFunctionOrValueWithoutLocalResolution : String -> CompilationStack -> Result String ( Pine.Expression, CompiledExpressionDependencies )
pineExpressionFromElmFunctionOrValueWithoutLocalResolution name compilation =
    case elmValuesToExposeToGlobal |> List.filter (Tuple.second >> (==) name) |> List.head of
        Nothing ->
            Ok
                ( Pine.ApplicationExpression
                    { function = expressionToLookupNameInEnvironment name
                    , argument = Pine.ApplicationArgumentExpression
                    }
                , { referencedNames = Set.singleton name }
                )

        Just ( moduleName, nameInModule ) ->
            getDeclarationValueFromCompilation ( moduleName, nameInModule ) compilation
                |> Result.map
                    (\function ->
                        ( Pine.ApplicationExpression
                            { function = Pine.LiteralExpression function
                            , argument = Pine.ListExpression []
                            }
                        , noDependencies
                        )
                    )


getDeclarationValueFromCompilation : ( List String, String ) -> CompilationStack -> Result String Pine.Value
getDeclarationValueFromCompilation ( localModuleName, nameInModule ) compilation =
    let
        canonicalModuleName =
            Dict.get localModuleName compilation.moduleAliases
                |> Maybe.withDefault localModuleName
    in
    case compilation.availableDeclarations |> Dict.get (String.join "." canonicalModuleName) of
        Nothing ->
            Err ("Did not find module '" ++ String.join "." canonicalModuleName ++ "'")

        Just (ElmFunctionDeclaration _) ->
            Err ("Got function declaration for module '" ++ String.join "." canonicalModuleName ++ "'")

        Just (CompiledDeclaration moduleValue) ->
            let
                nameInModuleAsValue =
                    Pine.valueFromString nameInModule
            in
            Pine.lookUpNameInListValue nameInModuleAsValue moduleValue
                |> Result.mapError
                    (Pine.displayStringFromPineError
                        >> String.replace "\n" ": "
                        >> (++) ("Failed lookup in module '" ++ (String.join "." canonicalModuleName ++ "': "))
                    )


expressionToLookupNameInEnvironment : String -> Pine.Expression
expressionToLookupNameInEnvironment name =
    expressionToLookupNameInGivenScope name Pine.ApplicationArgumentExpression


expressionToLookupNameInGivenScope : String -> Pine.Expression -> Pine.Expression
expressionToLookupNameInGivenScope name scopeExpression =
    pineKernel_ListHead
        (applyKernelFunctionWithTwoArguments
            "look_up_name_in_ListValue"
            (Pine.LiteralExpression (Pine.valueFromString name))
            scopeExpression
        )


equalCondition : List Pine.Expression -> Pine.Expression
equalCondition list =
    Pine.KernelApplicationExpression
        { functionName = "equal"
        , argument = Pine.ListExpression list
        }


applyKernelFunctionWithTwoArguments : String -> Pine.Expression -> Pine.Expression -> Pine.Expression
applyKernelFunctionWithTwoArguments kernelFunctionName argA argB =
    Pine.KernelApplicationExpression
        { functionName = kernelFunctionName
        , argument = Pine.ListExpression [ argA, argB ]
        }


moduleNameFromSyntaxFile : Elm.Syntax.File.File -> Elm.Syntax.Node.Node (List String)
moduleNameFromSyntaxFile file =
    case Elm.Syntax.Node.value file.moduleDefinition of
        Elm.Syntax.Module.NormalModule normalModule ->
            normalModule.moduleName

        Elm.Syntax.Module.PortModule portModule ->
            portModule.moduleName

        Elm.Syntax.Module.EffectModule effectModule ->
            effectModule.moduleName


mapExpressionForOperatorPrecedence : Elm.Syntax.Expression.Expression -> Elm.Syntax.Expression.Expression
mapExpressionForOperatorPrecedence originalExpression =
    case originalExpression of
        Elm.Syntax.Expression.OperatorApplication operator direction leftExpr rightExpr ->
            let
                operatorPriority =
                    operatorPrecendencePriority |> Dict.get operator |> Maybe.withDefault 0

                mappedLeftExpr =
                    Elm.Syntax.Node.Node (Elm.Syntax.Node.range leftExpr)
                        (mapExpressionForOperatorPrecedence (Elm.Syntax.Node.value leftExpr))

                mappedRightExpr =
                    Elm.Syntax.Node.Node (Elm.Syntax.Node.range rightExpr)
                        (mapExpressionForOperatorPrecedence (Elm.Syntax.Node.value rightExpr))

                orderedLeft =
                    case Elm.Syntax.Node.value mappedLeftExpr of
                        Elm.Syntax.Expression.OperatorApplication leftOperator _ leftLeftExpr leftRightExpr ->
                            let
                                operatorLeftPriority =
                                    operatorPrecendencePriority |> Dict.get leftOperator |> Maybe.withDefault 0

                                areStillOrderedBySyntaxRange =
                                    compareLocations
                                        (Elm.Syntax.Node.range leftExpr).start
                                        (Elm.Syntax.Node.range leftLeftExpr).start
                                        == LT
                            in
                            if
                                (operatorLeftPriority < operatorPriority)
                                    || ((operatorLeftPriority == operatorPriority) && areStillOrderedBySyntaxRange)
                            then
                                mapExpressionForOperatorPrecedence
                                    (Elm.Syntax.Expression.OperatorApplication leftOperator
                                        direction
                                        leftLeftExpr
                                        (Elm.Syntax.Node.Node
                                            (Elm.Syntax.Range.combine [ Elm.Syntax.Node.range leftRightExpr, Elm.Syntax.Node.range rightExpr ])
                                            (Elm.Syntax.Expression.OperatorApplication operator direction leftRightExpr rightExpr)
                                        )
                                    )

                            else
                                originalExpression

                        _ ->
                            originalExpression
            in
            if mappedLeftExpr /= leftExpr || mappedRightExpr /= rightExpr then
                mapExpressionForOperatorPrecedence (Elm.Syntax.Expression.OperatorApplication operator direction mappedLeftExpr mappedRightExpr)

            else
                case Elm.Syntax.Node.value mappedRightExpr of
                    Elm.Syntax.Expression.OperatorApplication rightOperator _ rightLeftExpr rightRightExpr ->
                        let
                            operatorRightPriority =
                                operatorPrecendencePriority |> Dict.get rightOperator |> Maybe.withDefault 0

                            areStillOrderedBySyntaxRange =
                                compareLocations
                                    (Elm.Syntax.Node.range leftExpr).start
                                    (Elm.Syntax.Node.range rightLeftExpr).start
                                    == LT
                        in
                        if
                            (operatorRightPriority < operatorPriority)
                                || ((operatorRightPriority == operatorPriority) && areStillOrderedBySyntaxRange)
                        then
                            mapExpressionForOperatorPrecedence
                                (Elm.Syntax.Expression.OperatorApplication rightOperator
                                    direction
                                    (Elm.Syntax.Node.Node
                                        (Elm.Syntax.Range.combine [ Elm.Syntax.Node.range leftExpr, Elm.Syntax.Node.range rightLeftExpr ])
                                        (Elm.Syntax.Expression.OperatorApplication operator direction leftExpr rightLeftExpr)
                                    )
                                    rightRightExpr
                                )

                        else
                            orderedLeft

                    _ ->
                        orderedLeft

        _ ->
            originalExpression


compareLocations : Elm.Syntax.Range.Location -> Elm.Syntax.Range.Location -> Order
compareLocations left right =
    if left.row < right.row then
        LT

    else if right.row < left.row then
        GT

    else
        compare left.column right.column


valueFromString : String -> Pine.Value
valueFromString =
    Pine.valueFromString >> List.singleton >> Pine.tagValue elmStringTypeTagName


pineKernelModuleName : String
pineKernelModuleName =
    "PineKernel"


elmStringTypeTagName : String
elmStringTypeTagName =
    "String"


elmRecordTypeTagName : String
elmRecordTypeTagName =
    "Elm_Record"


operatorPrecendencePriority : Dict.Dict String Int
operatorPrecendencePriority =
    [ ( "+", 0 )
    , ( "-", 0 )
    , ( "*", 1 )
    , ( "//", 1 )
    , ( "/", 1 )
    ]
        |> Dict.fromList


{-| The expression evaluates to a list with two elements:
The first element contains the new interactive session state for the possible next submission.
The second element contains the response, the value to display to the user.
-}
compileInteractiveSubmissionIntoPineExpression : Pine.Value -> String -> Result String Pine.Expression
compileInteractiveSubmissionIntoPineExpression environment submission =
    case getDeclarationsFromEnvironment environment of
        Err error ->
            Err ("Failed to get declarations from environment: " ++ error)

        Ok environmentDeclarations ->
            let
                buildExpressionForNewStateAndResponse config =
                    Pine.ListExpression
                        [ config.newStateExpression
                        , config.responseExpression
                        ]

                initialStack =
                    { moduleAliases = Dict.empty
                    , availableDeclarations = environmentDeclarations |> Dict.map (always CompiledDeclaration)
                    , inliningParentDeclarations = Set.empty
                    }
            in
            case parseInteractiveSubmissionFromString submission of
                Err error ->
                    Ok
                        (buildExpressionForNewStateAndResponse
                            { newStateExpression = Pine.ApplicationArgumentExpression
                            , responseExpression =
                                Pine.LiteralExpression (Pine.valueFromString ("Failed to parse submission: " ++ error))
                            }
                        )

                Ok (DeclarationSubmission elmDeclaration) ->
                    case elmDeclaration of
                        Elm.Syntax.Declaration.FunctionDeclaration functionDeclaration ->
                            case pineExpressionFromElmFunction initialStack functionDeclaration of
                                Err error ->
                                    Err ("Failed to translate Elm function declaration: " ++ error)

                                Ok ( declaredName, ( declaredFunctionExpression, _ ) ) ->
                                    Ok
                                        (buildExpressionForNewStateAndResponse
                                            { newStateExpression =
                                                Pine.KernelApplicationExpression
                                                    { functionName = "concat"
                                                    , argument =
                                                        Pine.ListExpression
                                                            [ Pine.ListExpression
                                                                [ Pine.LiteralExpression
                                                                    (Pine.valueFromContextExpansionWithName
                                                                        ( declaredName
                                                                        , Pine.encodeExpressionAsValue declaredFunctionExpression
                                                                        )
                                                                    )
                                                                ]
                                                            , Pine.ApplicationArgumentExpression
                                                            ]
                                                    }
                                            , responseExpression =
                                                Pine.LiteralExpression (Pine.valueFromString ("Declared " ++ declaredName))
                                            }
                                        )

                        Elm.Syntax.Declaration.AliasDeclaration _ ->
                            Err "Alias declaration as submission is not implemented"

                        Elm.Syntax.Declaration.CustomTypeDeclaration _ ->
                            Err "Custom type declaration as submission is not implemented"

                        Elm.Syntax.Declaration.PortDeclaration _ ->
                            Err "Port declaration as submission is not implemented"

                        Elm.Syntax.Declaration.InfixDeclaration _ ->
                            Err "Infix declaration as submission is not implemented"

                        Elm.Syntax.Declaration.Destructuring _ _ ->
                            Err "Destructuring as submission is not implemented"

                Ok (ExpressionSubmission elmExpression) ->
                    case pineExpressionFromElm initialStack elmExpression of
                        Err error ->
                            Err ("Failed to compile Elm to Pine expression: " ++ error)

                        Ok ( pineExpression, _ ) ->
                            Ok
                                (buildExpressionForNewStateAndResponse
                                    { newStateExpression = Pine.ApplicationArgumentExpression
                                    , responseExpression =
                                        Pine.ApplicationExpression
                                            { function =
                                                pineExpression
                                                    |> Pine.encodeExpressionAsValue
                                                    |> Pine.LiteralExpression
                                            , argument = Pine.ApplicationArgumentExpression
                                            }
                                    }
                                )


getDeclarationsFromEnvironment : Pine.Value -> Result String (Dict.Dict String Pine.Value)
getDeclarationsFromEnvironment environment =
    case environment of
        Pine.BlobValue _ ->
            Err "Is not a list but a blob"

        Pine.ListValue environmentList ->
            environmentList
                |> List.map
                    (\environmentEntry ->
                        (case environmentEntry of
                            Pine.BlobValue _ ->
                                Err "Is not a list but a blob"

                            Pine.ListValue [ nameValue, namedValue ] ->
                                Pine.stringFromValue nameValue
                                    |> Result.mapError ((++) "Failed to decode string: ")
                                    |> Result.map (\name -> ( name, namedValue ))

                            Pine.ListValue list ->
                                Err
                                    ("Unexpected number of elements in environment entry list: Not 2 but "
                                        ++ String.fromInt (List.length list)
                                    )
                        )
                            |> Result.mapError ((++) "Failed to decode environment entry: ")
                    )
                |> Result.Extra.combine
                |> Result.map (List.reverse >> Dict.fromList)


parseInteractiveSubmissionFromString : String -> Result String InteractiveSubmission
parseInteractiveSubmissionFromString submission =
    let
        unified =
            String.replace "\n" " " submission
    in
    if
        String.contains " = " unified
            && not (String.startsWith "let " (String.trim unified))
            && not (String.startsWith "{" (String.trim submission))
    then
        parseDeclarationFromString submission
            |> Result.mapError parserDeadEndsToString
            |> Result.Extra.join
            |> Result.map DeclarationSubmission

    else
        parseExpressionFromString submission
            |> Result.mapError parserDeadEndsToString
            |> Result.Extra.join
            |> Result.map ExpressionSubmission


parseExpressionFromString : String -> Result (List Parser.DeadEnd) (Result String Elm.Syntax.Expression.Expression)
parseExpressionFromString expressionCode =
    -- https://github.com/stil4m/elm-syntax/issues/34
    let
        indentAmount =
            4

        indentedExpressionCode =
            expressionCode
                |> String.lines
                |> List.map ((++) (String.repeat indentAmount (String.fromChar ' ')))
                |> String.join "\n"

        declarationTextBeforeExpression =
            "wrapping_expression_in_function = \n"
    in
    parseDeclarationFromString (declarationTextBeforeExpression ++ indentedExpressionCode)
        |> Result.mapError (List.map (mapLocationForPrefixText declarationTextBeforeExpression >> mapLocationForIndentAmount indentAmount))
        |> Result.map
            (Result.andThen
                (\declaration ->
                    case declaration of
                        Elm.Syntax.Declaration.FunctionDeclaration functionDeclaration ->
                            functionDeclaration
                                |> .declaration
                                |> Elm.Syntax.Node.value
                                |> .expression
                                |> Elm.Syntax.Node.value
                                |> Ok

                        _ ->
                            Err "Failed to extract the wrapping function."
                )
            )


parseDeclarationFromString : String -> Result (List Parser.DeadEnd) (Result String Elm.Syntax.Declaration.Declaration)
parseDeclarationFromString declarationCode =
    -- https://github.com/stil4m/elm-syntax/issues/34
    let
        moduleTextBeforeDeclaration =
            """
module Main exposing (..)


"""

        moduleText =
            moduleTextBeforeDeclaration ++ declarationCode
    in
    parseElmModuleText moduleText
        |> Result.mapError (List.map (mapLocationForPrefixText moduleTextBeforeDeclaration))
        |> Result.map
            (.declarations
                >> List.map Elm.Syntax.Node.value
                >> List.head
                >> Result.fromMaybe "Failed to extract the declaration from the parsed module."
            )


mapLocationForPrefixText : String -> Parser.DeadEnd -> Parser.DeadEnd
mapLocationForPrefixText prefixText =
    let
        prefixLines =
            String.lines prefixText
    in
    mapLocation
        { row = 1 - List.length prefixLines
        , col = -(prefixLines |> List.reverse |> List.head |> Maybe.withDefault "" |> String.length)
        }


mapLocationForIndentAmount : Int -> Parser.DeadEnd -> Parser.DeadEnd
mapLocationForIndentAmount indentAmount =
    mapLocation { row = 0, col = -indentAmount }


mapLocation : { row : Int, col : Int } -> Parser.DeadEnd -> Parser.DeadEnd
mapLocation offset deadEnd =
    { deadEnd | row = deadEnd.row + offset.row, col = deadEnd.col + offset.col }


parseElmModuleTextToJson : String -> String
parseElmModuleTextToJson elmModule =
    let
        jsonValue =
            case parseElmModuleText elmModule of
                Err _ ->
                    [ ( "Err", "Failed to parse this as module text" |> Json.Encode.string ) ] |> Json.Encode.object

                Ok file ->
                    [ ( "Ok", file |> Elm.Syntax.File.encode ) ] |> Json.Encode.object
    in
    jsonValue |> Json.Encode.encode 0


parseElmModuleText : String -> Result (List Parser.DeadEnd) Elm.Syntax.File.File
parseElmModuleText =
    Elm.Parser.parse >> Result.map (Elm.Processing.process Elm.Processing.init)


parserDeadEndsToString : List Parser.DeadEnd -> String
parserDeadEndsToString deadEnds =
    String.concat (List.intersperse "; " (List.map parserDeadEndToString deadEnds))


parserDeadEndToString : Parser.DeadEnd -> String
parserDeadEndToString deadend =
    parserProblemToString deadend.problem ++ " at row " ++ String.fromInt deadend.row ++ ", col " ++ String.fromInt deadend.col


parserProblemToString : Parser.Problem -> String
parserProblemToString p =
    case p of
        Parser.Expecting s ->
            "expecting '" ++ s ++ "'"

        Parser.ExpectingInt ->
            "expecting int"

        Parser.ExpectingHex ->
            "expecting hex"

        Parser.ExpectingOctal ->
            "expecting octal"

        Parser.ExpectingBinary ->
            "expecting binary"

        Parser.ExpectingFloat ->
            "expecting float"

        Parser.ExpectingNumber ->
            "expecting number"

        Parser.ExpectingVariable ->
            "expecting variable"

        Parser.ExpectingSymbol s ->
            "expecting symbol '" ++ s ++ "'"

        Parser.ExpectingKeyword s ->
            "expecting keyword '" ++ s ++ "'"

        Parser.ExpectingEnd ->
            "expecting end"

        Parser.UnexpectedChar ->
            "unexpected char"

        Parser.Problem s ->
            "problem " ++ s

        Parser.BadRepeat ->
            "bad repeat"


stringStartsWithUpper : String -> Bool
stringStartsWithUpper =
    String.uncons >> Maybe.map (Tuple.first >> Char.isUpper) >> Maybe.withDefault False


json_encode_pineValue : Pine.Value -> Json.Encode.Value
json_encode_pineValue value =
    case value of
        Pine.ListValue list ->
            let
                defaultListEncoding =
                    Json.Encode.object
                        [ ( "List", Json.Encode.list json_encode_pineValue list ) ]
            in
            case Pine.stringFromListValue list of
                Err _ ->
                    defaultListEncoding

                Ok asString ->
                    Json.Encode.object
                        [ ( "ListAsString", Json.Encode.string asString ) ]

        Pine.BlobValue blob ->
            Json.Encode.object
                [ ( "Blob", Json.Encode.list Json.Encode.int blob ) ]


json_decode_pineValue : Json.Decode.Decoder Pine.Value
json_decode_pineValue =
    json_decode_pineValueWithDictionary Dict.empty


json_decode_pineValueWithDictionary : Dict.Dict String Pine.Value -> Json.Decode.Decoder Pine.Value
json_decode_pineValueWithDictionary dictionary =
    json_decode_optionalNullableField "Dictionary" (json_decode_pineValueDictionary dictionary)
        |> Json.Decode.map (Maybe.withDefault Dict.empty >> (\newDict -> Dict.union newDict dictionary))
        |> Json.Decode.andThen json_decode_pineValueApplyingDictionary


json_decode_pineValueDictionary : Dict.Dict String Pine.Value -> Json.Decode.Decoder (Dict.Dict String Pine.Value)
json_decode_pineValueDictionary dictionary =
    Json.Decode.list (json_decode_pineValueDictionaryEntry dictionary)
        |> Json.Decode.map Dict.fromList


json_decode_pineValueDictionaryEntry : Dict.Dict String Pine.Value -> Json.Decode.Decoder ( String, Pine.Value )
json_decode_pineValueDictionaryEntry dictionary =
    Json.Decode.map2 Tuple.pair
        (Json.Decode.field "key" Json.Decode.string)
        (Json.Decode.field "value" (Json.Decode.lazy (\_ -> json_decode_pineValueWithDictionary dictionary)))


json_decode_pineValueApplyingDictionary : Dict.Dict String Pine.Value -> Json.Decode.Decoder Pine.Value
json_decode_pineValueApplyingDictionary dictionary =
    Json.Decode.oneOf
        [ Json.Decode.field "List"
            (Json.Decode.lazy (\_ -> Json.Decode.list (json_decode_pineValueWithDictionary dictionary)))
            |> Json.Decode.map Pine.ListValue
        , Json.Decode.field "ListAsString" Json.Decode.string
            |> Json.Decode.map Pine.valueFromString
        , Json.Decode.field "Blob" (Json.Decode.list Json.Decode.int)
            |> Json.Decode.map Pine.BlobValue
        , Json.Decode.field "Reference" Json.Decode.string
            |> Json.Decode.andThen
                (\reference ->
                    dictionary
                        |> Dict.get reference
                        |> Maybe.map Json.Decode.succeed
                        |> Maybe.withDefault (Json.Decode.fail ("Did not find dictionary entry for reference '" ++ reference ++ "'"))
                )
        ]


json_decode_optionalNullableField : String -> Json.Decode.Decoder a -> Json.Decode.Decoder (Maybe a)
json_decode_optionalNullableField fieldName decoder =
    Json.Decode.map (Maybe.andThen identity)
        (json_decode_optionalField fieldName (Json.Decode.nullable decoder))


json_decode_optionalField : String -> Json.Decode.Decoder a -> Json.Decode.Decoder (Maybe a)
json_decode_optionalField fieldName decoder =
    let
        finishDecoding json =
            case Json.Decode.decodeValue (Json.Decode.field fieldName Json.Decode.value) json of
                Ok _ ->
                    -- The field is present, so run the decoder on it.
                    Json.Decode.map Just (Json.Decode.field fieldName decoder)

                Err _ ->
                    -- The field was missing, which is fine!
                    Json.Decode.succeed Nothing
    in
    Json.Decode.value
        |> Json.Decode.andThen finishDecoding
