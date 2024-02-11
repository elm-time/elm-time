module FirCompiler exposing
    ( Deconstruction(..)
    , EmitStack
    , EnvironmentDeconstructionEntry
    , EnvironmentFunctionEntry
    , Expression(..)
    , FunctionEnvironment(..)
    , attemptReduceDecodeAndEvaluateExpressionRecursive
    , buildRecordOfPartiallyAppliedFunction
    , countListElementsExpression
    , emitDeclarationBlock
    , emitExpression
    , emitExpressionInDeclarationBlock
    , emitWrapperForPartialApplication
    , emitWrapperForPartialApplicationZero
    , equalCondition
    , equalCondition_Pine
    , estimatePineValueSize
    , evaluateAsIndependentExpression
    , getTransitiveDependencies
    , listDirectDependenciesOfExpression
    , listFunctionAppExpressions
    , listItemFromIndexExpression
    , listItemFromIndexExpression_Pine
    , listSkipExpression
    , listSkipExpression_Pine
    , listTransitiveDependenciesOfExpression
    , parseFunctionParameters
    , parseFunctionRecordFromValueTagged
    , partialApplicationExpressionFromListOfArguments
    , pineExpressionIsIndependent
    , pineKernel_ListHead
    , pineKernel_ListHead_Pine
    , recursionDomainsFromDeclarationDependencies
    )

import Common
import Dict
import Pine
import Set


type Expression
    = LiteralExpression Pine.Value
    | ListExpression (List Expression)
    | KernelApplicationExpression KernelApplicationExpressionStruct
    | ConditionalExpression ConditionalExpressionStruct
    | FunctionExpression (List FunctionParam) Expression
      {-
         Keeping a specialized function application model enables distinguishing cases with immediate full application.
         The emission of specialized code for these cases reduces runtime expenses.
      -}
    | FunctionApplicationExpression Expression (List Expression)
      {-
         The reference expression references a name introduced by a parent declaration block or function param deconstruction.
         Referencing a declaration from a declaration block enables (mutual) recursion.
         References, in general, enable modeling closures.
      -}
    | ReferenceExpression String
    | DeclarationBlockExpression (Dict.Dict String Expression) Expression
    | PineFunctionApplicationExpression Pine.Expression Expression
      -- The tag expression case is only a wrapper to label a node for inspection and does not influence the evaluation result.
    | StringTagExpression String Expression


type alias KernelApplicationExpressionStruct =
    { functionName : String
    , argument : Expression
    }


type alias ConditionalExpressionStruct =
    { condition : Expression
    , ifTrue : Expression
    , ifFalse : Expression
    }


type alias FunctionParam =
    List ( String, List Deconstruction )


type Deconstruction
    = ListItemDeconstruction Int
    | SkipItemsDeconstruction Int
    | PineFunctionApplicationDeconstruction Pine.Expression


type alias EmitStack =
    { importedFunctions : Dict.Dict String Pine.Value
    , declarationsDependencies : Dict.Dict String (Set.Set String)

    -- The functions in the first item in the environment list
    , environmentFunctions : List EnvironmentFunctionEntry

    -- Deconstructions we can derive from the second item in the environment list
    , environmentDeconstructions : Dict.Dict String EnvironmentDeconstructionEntry
    }


{-| The recursive function implementing adaptive application of function arguments.
-}
environmentFunctionPartialApplicationName : String
environmentFunctionPartialApplicationName =
    "<internal-partial-application>"


type alias EnvironmentFunctionEntry =
    { functionName : String
    , parameterCount : Int
    , expectedEnvironment : FunctionEnvironment
    }


type FunctionEnvironment
    = LocalEnvironment { expectedDecls : List String }
    | ImportedEnvironment
        { -- Path to the tagged function record relative to the entry in the current environment.
          pathToRecordFromEnvEntry : List Deconstruction
        }


type alias EnvironmentDeconstructionEntry =
    List Deconstruction


emitExpression : EmitStack -> Expression -> Result String Pine.Expression
emitExpression stack expression =
    case expression of
        LiteralExpression literal ->
            Ok (Pine.LiteralExpression literal)

        ListExpression list ->
            case Common.resultListMapCombine (\item -> emitExpression stack item) list of
                Err err ->
                    Err err

                Ok listEmitted ->
                    Ok (reduceExpressionToLiteralIfIndependent (Pine.ListExpression listEmitted))

        KernelApplicationExpression kernelApplication ->
            case emitExpression stack kernelApplication.argument of
                Err err ->
                    Err err

                Ok argument ->
                    Ok
                        (Pine.KernelApplicationExpression
                            { functionName = kernelApplication.functionName
                            , argument = argument
                            }
                        )

        ConditionalExpression conditional ->
            case emitExpression stack conditional.condition of
                Err err ->
                    Err err

                Ok condition ->
                    case emitExpression stack conditional.ifTrue of
                        Err err ->
                            Err err

                        Ok ifTrue ->
                            case emitExpression stack conditional.ifFalse of
                                Err err ->
                                    Err err

                                Ok ifFalse ->
                                    Ok
                                        (Pine.ConditionalExpression
                                            { condition = condition
                                            , ifTrue = ifTrue
                                            , ifFalse = ifFalse
                                            }
                                        )

        ReferenceExpression localReference ->
            emitReferenceExpression localReference stack

        FunctionExpression functionParams functionBody ->
            emitFunctionExpression stack functionParams functionBody

        FunctionApplicationExpression functionExpression arguments ->
            emitFunctionApplication functionExpression arguments stack

        DeclarationBlockExpression declarations innerExpression ->
            emitExpressionInDeclarationBlock
                stack
                { availableEmittedFunctions = [] }
                declarations
                innerExpression

        StringTagExpression tag tagged ->
            case emitExpression stack tagged of
                Err err ->
                    Err err

                Ok emitted ->
                    Ok (Pine.StringTagExpression tag emitted)

        PineFunctionApplicationExpression pineFunctionExpression argument ->
            Result.map
                (\emittedArgument ->
                    attemptReduceDecodeAndEvaluateExpressionRecursive
                        { maxDepth = 3 }
                        { expression =
                            Pine.LiteralExpression
                                (Pine.encodeExpressionAsValue pineFunctionExpression)
                        , environment = emittedArgument
                        }
                )
                (emitExpression stack argument)


emitFunctionExpression : EmitStack -> List FunctionParam -> Expression -> Result String Pine.Expression
emitFunctionExpression stack functionParams functionBody =
    emitExpressionInDeclarationBlock
        stack
        { availableEmittedFunctions = [] }
        Dict.empty
        (FunctionExpression functionParams functionBody)


type alias DeclarationBlockFunctionEntry =
    { parameters : List FunctionParam
    , innerExpression : Expression
    }


type alias EmitDeclarationBlockPrefix =
    { availableEmittedFunctions : List ( EnvironmentFunctionEntry, Pine.Value )
    }


type alias EmitDeclarationBlockResult =
    { newEnvFunctionsValues : List ( EnvironmentFunctionEntry, ( Pine.Expression, Pine.Value ) )
    , prependedEnvFunctionsExpressions : List Pine.Expression
    , parseAndEmitFunction : Expression -> ( DeclarationBlockFunctionEntry, Result String Pine.Expression )
    , envFunctionsExpression : Pine.Expression
    }


emitExpressionInDeclarationBlock :
    EmitStack
    -> EmitDeclarationBlockPrefix
    -> Dict.Dict String Expression
    -> Expression
    -> Result String Pine.Expression
emitExpressionInDeclarationBlock stackBeforeAddingDeps environmentPrefix blockDeclarations mainExpression =
    let
        blockDeclarationsIncludingImports =
            Dict.union blockDeclarations
                (Dict.map (always LiteralExpression) stackBeforeAddingDeps.importedFunctions)

        stackBefore =
            { stackBeforeAddingDeps
                | declarationsDependencies =
                    Dict.foldl
                        (\declName declExpression ->
                            Dict.insert declName (listDirectDependenciesOfExpression declExpression)
                        )
                        stackBeforeAddingDeps.declarationsDependencies
                        blockDeclarations
            }

        mainExpressionOuterDependencies : Set.Set String
        mainExpressionOuterDependencies =
            listTransitiveDependenciesOfExpression stackBefore mainExpression

        beforeEnvironmentFunctionsNames : Set.Set String
        beforeEnvironmentFunctionsNames =
            List.foldl
                (\beforeEnvFunction aggregate ->
                    Set.insert beforeEnvFunction.functionName aggregate
                )
                Set.empty
                stackBefore.environmentFunctions

        usedBlockDeclarations : Dict.Dict String Expression
        usedBlockDeclarations =
            Dict.foldl
                (\declName declExpression aggregate ->
                    if Set.member declName mainExpressionOuterDependencies then
                        -- Not supporting shadowing at the moment: Filter out every name we already have from a parent scope.
                        if not (Set.member declName beforeEnvironmentFunctionsNames) then
                            Dict.insert declName declExpression aggregate

                        else
                            aggregate

                    else
                        aggregate
                )
                Dict.empty
                blockDeclarationsIncludingImports

        mainExpressionAsFunction : DeclarationBlockFunctionEntry
        mainExpressionAsFunction =
            parseFunctionParameters mainExpression

        closureCaptures : List ( String, EnvironmentDeconstructionEntry )
        closureCaptures =
            Dict.foldl
                (\declName deconstruction aggregate ->
                    if Set.member declName mainExpressionOuterDependencies then
                        ( declName, deconstruction ) :: aggregate

                    else
                        aggregate
                )
                []
                stackBefore.environmentDeconstructions
    in
    if mainExpressionAsFunction.parameters == [] && Dict.isEmpty usedBlockDeclarations then
        emitExpression stackBeforeAddingDeps mainExpressionAsFunction.innerExpression

    else
        case
            emitDeclarationBlock
                stackBefore
                environmentPrefix
                usedBlockDeclarations
                { closureCaptures = closureCaptures
                , additionalDeps = [ mainExpression ]
                }
        of
            Err err ->
                Err err

            Ok ( _, blockDeclarationsEmitted ) ->
                let
                    ( _, mainExpressionEmitResult ) =
                        blockDeclarationsEmitted.parseAndEmitFunction mainExpression
                in
                case mainExpressionEmitResult of
                    Err err ->
                        Err ("Failed emitting main expression: " ++ err)

                    Ok mainExpressionEmitted ->
                        Ok
                            (emitWrapperForPartialApplication
                                blockDeclarationsEmitted.envFunctionsExpression
                                (List.length mainExpressionAsFunction.parameters)
                                mainExpressionEmitted
                            )


type ClosureCapture
    = DeconstructionCapture EnvironmentDeconstructionEntry
    | ExpressionCapture Expression


emitDeclarationBlock :
    EmitStack
    -> EmitDeclarationBlockPrefix
    -> Dict.Dict String Expression
    ->
        { closureCaptures : List ( String, EnvironmentDeconstructionEntry )
        , additionalDeps : List Expression
        }
    -> Result String ( EmitStack, EmitDeclarationBlockResult )
emitDeclarationBlock stackBefore environmentPrefix blockDeclarations config =
    let
        availableEmittedDependencies : Dict.Dict String (Set.Set String)
        availableEmittedDependencies =
            List.foldl
                (\( availableEmitted, _ ) ->
                    Dict.insert
                        availableEmitted.functionName
                        (case availableEmitted.expectedEnvironment of
                            LocalEnvironment localEnv ->
                                Set.fromList localEnv.expectedDecls

                            ImportedEnvironment _ ->
                                Set.empty
                        )
                )
                Dict.empty
                environmentPrefix.availableEmittedFunctions

        blockDeclarationsDirectDependencies : Dict.Dict String (Set.Set String)
        blockDeclarationsDirectDependencies =
            Dict.foldl
                (\declName declExpression ->
                    Dict.insert declName (listDirectDependenciesOfExpression declExpression)
                )
                Dict.empty
                blockDeclarations

        dependenciesRelations : Dict.Dict String (Set.Set String)
        dependenciesRelations =
            Dict.union availableEmittedDependencies blockDeclarationsDirectDependencies

        blockDeclarationsTransitiveDependencies : Dict.Dict String (Set.Set String)
        blockDeclarationsTransitiveDependencies =
            Dict.map
                (\_ declDirectDeps -> getTransitiveDependencies dependenciesRelations declDirectDeps)
                blockDeclarationsDirectDependencies

        additionalImports : Set.Set String
        additionalImports =
            List.foldl
                (\depExpr aggregate ->
                    Set.union aggregate (listTransitiveDependenciesOfExpression stackBefore depExpr)
                )
                Set.empty
                config.additionalDeps

        allDependencies : Set.Set String
        allDependencies =
            Set.union
                additionalImports
                (getTransitiveDependencies
                    dependenciesRelations
                    (Dict.foldl (\_ dependencies -> Set.union dependencies)
                        Set.empty
                        blockDeclarationsDirectDependencies
                    )
                )

        stackBeforeAvailableDeclarations : Set.Set String
        stackBeforeAvailableDeclarations =
            List.foldl (.functionName >> Set.insert)
                (Dict.foldl (\declName _ -> Set.insert declName) Set.empty stackBefore.environmentDeconstructions)
                stackBefore.environmentFunctions

        usedAvailableEmitted : List ( EnvironmentFunctionEntry, Pine.Expression )
        usedAvailableEmitted =
            List.foldl
                (\( availableEmitted, emittedValue ) aggregate ->
                    if Set.member availableEmitted.functionName allDependencies then
                        ( availableEmitted, Pine.LiteralExpression emittedValue ) :: aggregate

                    else
                        aggregate
                )
                []
                environmentPrefix.availableEmittedFunctions

        blockDeclarationsList : List ( String, Expression )
        blockDeclarationsList =
            Dict.toList blockDeclarations

        allBlockDeclarationsAsFunctions : List ( String, DeclarationBlockFunctionEntry )
        allBlockDeclarationsAsFunctions =
            List.map
                (\( declName, declExpression ) ->
                    ( declName
                    , parseFunctionParameters declExpression
                    )
                )
                blockDeclarationsList

        composeEnvironmentFunctions :
            { prefix : List a
            , forwarded : List a
            , appendedFromDecls : List a
            , appendedFromClosureCaptures : List a
            }
            -> List a
        composeEnvironmentFunctions { prefix, forwarded, appendedFromDecls, appendedFromClosureCaptures } =
            prefix ++ forwarded ++ appendedFromDecls ++ appendedFromClosureCaptures

        prefixEnvironmentFunctions : List EnvironmentFunctionEntry
        prefixEnvironmentFunctions =
            List.map
                (\( functionEntry, _ ) -> functionEntry)
                usedAvailableEmitted

        prependedEnvFunctionsExpressions : List Pine.Expression
        prependedEnvFunctionsExpressions =
            List.map Tuple.second usedAvailableEmitted

        forwardedDecls : List String
        forwardedDecls =
            List.map .functionName stackBefore.environmentFunctions

        contentsDependOnFunctionApplication : Bool
        contentsDependOnFunctionApplication =
            List.any
                (\( _, declExpression ) -> expressionNeedsAdaptiveApplication declExpression)
                blockDeclarationsList
                || List.any
                    (\depExpr -> expressionNeedsAdaptiveApplication depExpr)
                    config.additionalDeps

        closureCapturesForInternals : List ( String, Expression )
        closureCapturesForInternals =
            if List.member environmentFunctionPartialApplicationName forwardedDecls then
                []

            else if not contentsDependOnFunctionApplication then
                []

            else
                [ ( environmentFunctionPartialApplicationName
                  , if Set.member environmentFunctionPartialApplicationName stackBeforeAvailableDeclarations then
                        ReferenceExpression environmentFunctionPartialApplicationName

                    else
                        LiteralExpression adaptivePartialApplicationRecursiveValue
                  )
                ]

        closureCapturesForBlockDecls : List ( String, Expression )
        closureCapturesForBlockDecls =
            {-
               To avoid repeated evaluation of declarations without parameters from a let-block at runtime,
               Map them to closure captures list so these are only evaluated once.
            -}
            List.foldl
                (\( declName, asFunction ) aggregate ->
                    if asFunction.parameters /= [] then
                        aggregate

                    else
                        case Dict.get declName blockDeclarationsTransitiveDependencies of
                            Nothing ->
                                aggregate

                            Just declDependencies ->
                                if
                                    not (Set.member declName declDependencies)
                                        && (Set.diff declDependencies stackBeforeAvailableDeclarations == Set.empty)
                                then
                                    ( declName
                                    , asFunction.innerExpression
                                    )
                                        :: aggregate

                                else
                                    aggregate
                )
                []
                allBlockDeclarationsAsFunctions

        blockDeclarationsAsFunctionsLessClosure : List ( String, DeclarationBlockFunctionEntry )
        blockDeclarationsAsFunctionsLessClosure =
            List.filter
                (\( declName, _ ) ->
                    not (List.any (Tuple.first >> (==) declName) closureCapturesForBlockDecls)
                )
                allBlockDeclarationsAsFunctions

        closureCaptures : List ( String, ClosureCapture )
        closureCaptures =
            List.concat
                [ List.map (Tuple.mapSecond DeconstructionCapture) config.closureCaptures
                , List.map (Tuple.mapSecond ExpressionCapture)
                    (closureCapturesForInternals ++ closureCapturesForBlockDecls)
                ]

        newEnvironmentFunctionsNames : List String
        newEnvironmentFunctionsNames =
            composeEnvironmentFunctions
                { prefix = List.map (Tuple.first >> .functionName) usedAvailableEmitted
                , forwarded = forwardedDecls
                , appendedFromDecls = List.map Tuple.first blockDeclarationsAsFunctionsLessClosure
                , appendedFromClosureCaptures = List.map Tuple.first closureCaptures
                }

        newEnvironmentFunctionsFromDecls : List EnvironmentFunctionEntry
        newEnvironmentFunctionsFromDecls =
            List.map
                (\( functionName, functionEntry ) ->
                    { functionName = functionName
                    , parameterCount = List.length functionEntry.parameters
                    , expectedEnvironment =
                        LocalEnvironment
                            { expectedDecls = newEnvironmentFunctionsNames }
                    }
                )
                blockDeclarationsAsFunctionsLessClosure

        newEnvironmentFunctionsFromClosureCaptures : List EnvironmentFunctionEntry
        newEnvironmentFunctionsFromClosureCaptures =
            List.map
                (\( captureName, _ ) ->
                    { functionName = captureName
                    , parameterCount = 0
                    , expectedEnvironment = LocalEnvironment { expectedDecls = [] }
                    }
                )
                closureCaptures

        environmentFunctions : List EnvironmentFunctionEntry
        environmentFunctions =
            composeEnvironmentFunctions
                { prefix = prefixEnvironmentFunctions
                , forwarded = stackBefore.environmentFunctions
                , appendedFromDecls = newEnvironmentFunctionsFromDecls
                , appendedFromClosureCaptures = newEnvironmentFunctionsFromClosureCaptures
                }

        commonEmitStack : EmitStack
        commonEmitStack =
            { importedFunctions = stackBefore.importedFunctions
            , declarationsDependencies = stackBefore.declarationsDependencies
            , environmentFunctions = environmentFunctions
            , environmentDeconstructions = Dict.empty
            }

        emitFunction : DeclarationBlockFunctionEntry -> Result String Pine.Expression
        emitFunction functionEntry =
            let
                functionEmitStack =
                    { commonEmitStack
                        | environmentDeconstructions =
                            environmentDeconstructionsFromFunctionParams functionEntry.parameters
                    }
            in
            emitExpression functionEmitStack functionEntry.innerExpression

        emitBlockDeclarationsResult : Result String (List ( String, ( DeclarationBlockFunctionEntry, Pine.Expression ) ))
        emitBlockDeclarationsResult =
            Common.resultListMapCombine
                (\( functionName, blockDeclAsFunction ) ->
                    case emitFunction blockDeclAsFunction of
                        Err err ->
                            Err ("Failed to emit '" ++ functionName ++ "': " ++ err)

                        Ok emittedExpression ->
                            Ok ( functionName, ( blockDeclAsFunction, emittedExpression ) )
                )
                blockDeclarationsAsFunctionsLessClosure

        closureCapturesExpressionsResult : Result String (List Pine.Expression)
        closureCapturesExpressionsResult =
            Common.resultListMapCombine
                (\( _, closureCapture ) ->
                    case closureCapture of
                        DeconstructionCapture deconstruction ->
                            Ok
                                (pineExpressionForDeconstructions
                                    deconstruction
                                    (listItemFromIndexExpression_Pine 1 Pine.EnvironmentExpression)
                                )

                        ExpressionCapture expression ->
                            emitExpression stackBefore expression
                )
                closureCaptures
    in
    closureCapturesExpressionsResult
        |> Result.andThen
            (\closureCapturesExpressions ->
                emitBlockDeclarationsResult
                    |> Result.map
                        (\blockDeclarationsEmitted ->
                            let
                                closureCapturesExpressionsWrapped =
                                    List.map
                                        (\captureExpression ->
                                            Pine.ListExpression
                                                [ Pine.LiteralExpression Pine.stringAsValue_Literal
                                                , captureExpression
                                                ]
                                        )
                                        closureCapturesExpressions

                                newEnvFunctionsValues : List ( EnvironmentFunctionEntry, ( Pine.Expression, Pine.Value ) )
                                newEnvFunctionsValues =
                                    List.map
                                        (\( declName, ( declAsFunction, declExpr ) ) ->
                                            ( { functionName = declName
                                              , parameterCount = List.length declAsFunction.parameters
                                              , expectedEnvironment =
                                                    LocalEnvironment { expectedDecls = newEnvironmentFunctionsNames }
                                              }
                                            , ( declExpr
                                              , Pine.encodeExpressionAsValue declExpr
                                              )
                                            )
                                        )
                                        blockDeclarationsEmitted

                                newEnvFunctionsExpressionsFromDecls : List Pine.Expression
                                newEnvFunctionsExpressionsFromDecls =
                                    List.map (Tuple.second >> Tuple.second >> Pine.LiteralExpression)
                                        newEnvFunctionsValues

                                appendedEnvFunctionsExpressions : List Pine.Expression
                                appendedEnvFunctionsExpressions =
                                    newEnvFunctionsExpressionsFromDecls
                                        ++ closureCapturesExpressionsWrapped

                                envFunctionsExpression =
                                    if stackBefore.environmentFunctions == [] then
                                        Pine.ListExpression
                                            (prependedEnvFunctionsExpressions ++ appendedEnvFunctionsExpressions)

                                    else
                                        Pine.KernelApplicationExpression
                                            { functionName = "concat"
                                            , argument =
                                                Pine.ListExpression
                                                    [ Pine.ListExpression prependedEnvFunctionsExpressions
                                                    , {-
                                                         Here we depend on the returned list having the same layout as stackBefore.environmentFunctions.
                                                         2023-12-31: Observed some tests failing, and fixed this by wrapping into the application of 'take'.
                                                         This observation indicates that some part of the compiler emitted a longer list than is described in stackBefore.environmentFunctions.
                                                      -}
                                                      Pine.KernelApplicationExpression
                                                        { functionName = "take"
                                                        , argument =
                                                            Pine.ListExpression
                                                                [ Pine.LiteralExpression
                                                                    (Pine.valueFromInt (List.length stackBefore.environmentFunctions))
                                                                , listItemFromIndexExpression_Pine
                                                                    0
                                                                    Pine.EnvironmentExpression
                                                                ]
                                                        }
                                                    , Pine.ListExpression appendedEnvFunctionsExpressions
                                                    ]
                                            }

                                parseAndEmitFunction : Expression -> ( DeclarationBlockFunctionEntry, Result String Pine.Expression )
                                parseAndEmitFunction expression =
                                    let
                                        functionEntry =
                                            parseFunctionParameters expression
                                    in
                                    ( functionEntry
                                    , emitFunction functionEntry
                                    )
                            in
                            ( commonEmitStack
                            , { newEnvFunctionsValues = newEnvFunctionsValues
                              , prependedEnvFunctionsExpressions = prependedEnvFunctionsExpressions
                              , parseAndEmitFunction = parseAndEmitFunction
                              , envFunctionsExpression = envFunctionsExpression
                              }
                            )
                        )
            )


{-| Searches the tree of subexpressions for any that might require adaptive application.
-}
expressionNeedsAdaptiveApplication : Expression -> Bool
expressionNeedsAdaptiveApplication expression =
    {-
       This function seems brittle because it needs to match the behavior of others, such as emitFunctionApplication.
       Changing something in the selection for inlining might require changes here as well.
       Perhaps it is better to somehow reuse the same logic here.
    -}
    case expression of
        LiteralExpression _ ->
            False

        ListExpression list ->
            List.any expressionNeedsAdaptiveApplication list

        KernelApplicationExpression application ->
            expressionNeedsAdaptiveApplication application.argument

        ConditionalExpression conditional ->
            expressionNeedsAdaptiveApplication conditional.condition
                || expressionNeedsAdaptiveApplication conditional.ifTrue
                || expressionNeedsAdaptiveApplication conditional.ifFalse

        FunctionExpression _ functionBody ->
            expressionNeedsAdaptiveApplication functionBody

        FunctionApplicationExpression funcExpr args ->
            case funcExpr of
                LiteralExpression _ ->
                    {-
                       Whether that function should be inlined or not, in any case we should not need
                       to supply the generic function for adaptive application.
                    -}
                    List.any expressionNeedsAdaptiveApplication args

                _ ->
                    expressionNeedsAdaptiveApplication funcExpr || (args /= [])

        DeclarationBlockExpression declarations innerExpression ->
            Dict.foldl
                (\_ decl aggregate ->
                    expressionNeedsAdaptiveApplication decl
                        || aggregate
                )
                (expressionNeedsAdaptiveApplication innerExpression)
                declarations

        ReferenceExpression _ ->
            False

        StringTagExpression _ tagged ->
            expressionNeedsAdaptiveApplication tagged

        PineFunctionApplicationExpression _ argument ->
            expressionNeedsAdaptiveApplication argument


{-| Derive an ordered list of recursion domains from a dictionary of dependencies with their transitive dependencies.
Each recursion domain is a set of names of declarations that mutually depend on each other.
The overall list of recursion domains is ordered by their dependencies on each other.
The first element in the list is a set of declarations that do not depend on any other declaration.
-}
recursionDomainsFromDeclarationDependencies : Dict.Dict String (Set.Set String) -> List (Set.Set String)
recursionDomainsFromDeclarationDependencies declarationDependencies =
    let
        integrateDecl declName declDependencies recursionDomains =
            let
                -- Inserts the new domain into the list of domains at the position where the none of the following domains depend on it.
                insertDomainRecursive :
                    Set.Set String
                    -> List (Set.Set String)
                    -> List (Set.Set String)
                    -> List (Set.Set String)
                insertDomainRecursive domainToInsert skipped following =
                    case following of
                        [] ->
                            skipped ++ [ domainToInsert ]

                        next :: rest ->
                            let
                                allCurrentAndFollowing =
                                    List.foldl Set.union next rest

                                dependingOnAnyCurrentOrFollowing : Bool
                                dependingOnAnyCurrentOrFollowing =
                                    not (Set.isEmpty (Set.intersect declDependencies allCurrentAndFollowing))

                                allDependenciesOfNext : Set.Set String
                                allDependenciesOfNext =
                                    Set.foldl
                                        (\nextDeclName aggregate ->
                                            Set.union
                                                aggregate
                                                (Maybe.withDefault Set.empty (Dict.get nextDeclName declarationDependencies))
                                        )
                                        Set.empty
                                        next

                                nextDependingOnNewDomain : Bool
                                nextDependingOnNewDomain =
                                    Set.member declName allDependenciesOfNext
                            in
                            if dependingOnAnyCurrentOrFollowing then
                                if nextDependingOnNewDomain then
                                    -- Merge the new domain into the current domain
                                    skipped ++ [ Set.union domainToInsert next ] ++ rest

                                else
                                    insertDomainRecursive domainToInsert (skipped ++ [ next ]) rest

                            else
                                skipped ++ [ domainToInsert ] ++ following
            in
            insertDomainRecursive (Set.singleton declName) [] recursionDomains
    in
    Dict.foldl integrateDecl [] declarationDependencies


parseFunctionParameters : Expression -> DeclarationBlockFunctionEntry
parseFunctionParameters expression =
    case expression of
        FunctionExpression functionParams functionBody ->
            let
                innerParsed =
                    parseFunctionParameters functionBody
            in
            { parameters = functionParams ++ innerParsed.parameters
            , innerExpression = innerParsed.innerExpression
            }

        StringTagExpression _ tagged ->
            parseFunctionParameters tagged

        _ ->
            { parameters = []
            , innerExpression = expression
            }


emitReferenceExpression : String -> EmitStack -> Result String Pine.Expression
emitReferenceExpression name compilation =
    case
        emitApplyFunctionFromCurrentEnvironment
            compilation
            { functionName = name }
            []
    of
        Just functionApplicationResult ->
            functionApplicationResult

        Nothing ->
            case Dict.get name compilation.environmentDeconstructions of
                Nothing ->
                    Err
                        ("Failed referencing '"
                            ++ name
                            ++ "'. "
                            ++ String.fromInt (Dict.size compilation.environmentDeconstructions)
                            ++ " deconstructions in scope: "
                            ++ String.join ", " (Dict.keys compilation.environmentDeconstructions)
                            ++ ". "
                            ++ String.fromInt (List.length compilation.environmentFunctions)
                            ++ " functions in scope: "
                            ++ String.join ", " (List.map .functionName compilation.environmentFunctions)
                        )

                Just deconstruction ->
                    Ok
                        (pineExpressionForDeconstructions deconstruction
                            (listItemFromIndexExpression_Pine 1 Pine.EnvironmentExpression)
                        )


listTransitiveDependenciesOfExpression : EmitStack -> Expression -> Set.Set String
listTransitiveDependenciesOfExpression dependenciesRelations expression =
    getTransitiveDependencies dependenciesRelations.declarationsDependencies
        (listDirectDependenciesOfExpression expression)


listDirectDependenciesOfExpression : Expression -> Set.Set String
listDirectDependenciesOfExpression expression =
    case expression of
        LiteralExpression _ ->
            Set.empty

        ListExpression list ->
            List.foldl
                (\item aggregate -> Set.union (listDirectDependenciesOfExpression item) aggregate)
                Set.empty
                list

        KernelApplicationExpression application ->
            listDirectDependenciesOfExpression application.argument

        ConditionalExpression conditional ->
            listDirectDependenciesOfExpression conditional.condition
                |> Set.union (listDirectDependenciesOfExpression conditional.ifTrue)
                |> Set.union (listDirectDependenciesOfExpression conditional.ifFalse)

        ReferenceExpression reference ->
            Set.singleton reference

        FunctionExpression functionParam functionBody ->
            let
                functionBodyDependencies =
                    listDirectDependenciesOfExpression functionBody

                functionParamNames =
                    List.foldl
                        (\param aggregate ->
                            List.foldl Set.insert
                                aggregate
                                (List.map Tuple.first param)
                        )
                        Set.empty
                        functionParam
            in
            Set.diff functionBodyDependencies functionParamNames

        FunctionApplicationExpression functionExpression arguments ->
            List.foldl
                (\argument aggregate -> Set.union (listDirectDependenciesOfExpression argument) aggregate)
                (listDirectDependenciesOfExpression functionExpression)
                arguments

        DeclarationBlockExpression declarations innerExpression ->
            let
                innerDependencies =
                    Dict.foldl
                        (\_ decl aggregate -> Set.union (listDirectDependenciesOfExpression decl) aggregate)
                        (listDirectDependenciesOfExpression innerExpression)
                        declarations
            in
            Dict.foldl
                (\declName _ -> Set.remove declName)
                innerDependencies
                declarations

        StringTagExpression _ tagged ->
            listDirectDependenciesOfExpression tagged

        PineFunctionApplicationExpression _ argument ->
            listDirectDependenciesOfExpression argument


getTransitiveDependencies : Dict.Dict String (Set.Set String) -> Set.Set String -> Set.Set String
getTransitiveDependencies dependenciesDependencies current =
    let
        stepResult =
            Set.union current
                (getTransitiveDependenciesStep dependenciesDependencies current)
    in
    if stepResult == current then
        stepResult

    else
        getTransitiveDependencies dependenciesDependencies stepResult


getTransitiveDependenciesStep : Dict.Dict String (Set.Set String) -> Set.Set String -> Set.Set String
getTransitiveDependenciesStep dependenciesDependencies references =
    Set.foldl
        (\reference aggregate ->
            case Dict.get reference dependenciesDependencies of
                Nothing ->
                    aggregate

                Just dependencies ->
                    Set.union dependencies aggregate
        )
        Set.empty
        references


pineExpressionForDeconstructions : List Deconstruction -> Pine.Expression -> Pine.Expression
pineExpressionForDeconstructions deconstructions expression =
    List.foldl
        (\deconstruction aggregate ->
            pineExpressionForDeconstruction deconstruction aggregate
        )
        expression
        deconstructions


pineExpressionForDeconstruction : Deconstruction -> Pine.Expression -> Pine.Expression
pineExpressionForDeconstruction deconstruction =
    case deconstruction of
        ListItemDeconstruction index ->
            listItemFromIndexExpression_Pine index

        SkipItemsDeconstruction count ->
            listSkipExpression_Pine count

        PineFunctionApplicationDeconstruction pineFunctionExpression ->
            \emittedArgument ->
                attemptReduceDecodeAndEvaluateExpressionRecursive
                    { maxDepth = 3 }
                    { expression =
                        pineFunctionExpression
                            |> Pine.encodeExpressionAsValue
                            |> Pine.LiteralExpression
                    , environment = emittedArgument
                    }


environmentDeconstructionsFromFunctionParams : List FunctionParam -> Dict.Dict String EnvironmentDeconstructionEntry
environmentDeconstructionsFromFunctionParams parameters =
    Dict.fromList (closureParameterFromParameters parameters)


closureParameterFromParameters : List FunctionParam -> FunctionParam
closureParameterFromParameters =
    List.indexedMap
        (\paramIndex ->
            List.map (Tuple.mapSecond ((::) (ListItemDeconstruction paramIndex)))
        )
        >> List.concat


emitFunctionApplication : Expression -> List Expression -> EmitStack -> Result String Pine.Expression
emitFunctionApplication functionExpression arguments compilation =
    if arguments == [] then
        emitExpression compilation functionExpression

    else
        Common.resultListIndexedMapCombine
            (\argumentIndex argumentExpression ->
                case emitExpression compilation argumentExpression of
                    Err err ->
                        Err
                            ("Failed emitting argument "
                                ++ String.fromInt argumentIndex
                                ++ " for function application: "
                                ++ err
                            )

                    Ok result ->
                        Ok result
            )
            arguments
            |> Result.andThen
                (\argumentsPine ->
                    let
                        genericFunctionApplication () =
                            emitExpression compilation functionExpression
                                |> Result.mapError ((++) "Failed emitting function expression: ")
                                |> Result.andThen (emitFunctionApplicationPine compilation argumentsPine)
                    in
                    case functionExpression of
                        FunctionExpression params funcBody ->
                            if List.length params /= List.length argumentsPine then
                                genericFunctionApplication ()

                            else
                                let
                                    funcBodyDeps : Set.Set String
                                    funcBodyDeps =
                                        listTransitiveDependenciesOfExpression compilation funcBody

                                    closureCaptures : List ( String, EnvironmentDeconstructionEntry )
                                    closureCaptures =
                                        Dict.foldl
                                            (\declName deconstruction aggregate ->
                                                if Set.member declName funcBodyDeps then
                                                    ( declName, deconstruction ) :: aggregate

                                                else
                                                    aggregate
                                            )
                                            []
                                            compilation.environmentDeconstructions

                                    envFunctionsFromClosureCaptures : List EnvironmentFunctionEntry
                                    envFunctionsFromClosureCaptures =
                                        List.map
                                            (\( captureName, _ ) ->
                                                { functionName = captureName
                                                , parameterCount = 0
                                                , expectedEnvironment = LocalEnvironment { expectedDecls = [] }
                                                }
                                            )
                                            closureCaptures

                                    appendedEnvFunctionsExpressions : List Pine.Expression
                                    appendedEnvFunctionsExpressions =
                                        List.map
                                            (\( _, deconstruction ) ->
                                                Pine.ListExpression
                                                    [ Pine.LiteralExpression Pine.stringAsValue_Literal
                                                    , pineExpressionForDeconstructions
                                                        deconstruction
                                                        (listItemFromIndexExpression_Pine 1 Pine.EnvironmentExpression)
                                                    ]
                                            )
                                            closureCaptures

                                    environmentFunctions : List EnvironmentFunctionEntry
                                    environmentFunctions =
                                        compilation.environmentFunctions ++ envFunctionsFromClosureCaptures

                                    newEmitStack =
                                        { compilation
                                            | environmentDeconstructions =
                                                environmentDeconstructionsFromFunctionParams params
                                            , environmentFunctions = environmentFunctions
                                        }

                                    prevEnvFunctionsExpr : Pine.Expression
                                    prevEnvFunctionsExpr =
                                        listItemFromIndexExpression_Pine 0 Pine.EnvironmentExpression

                                    envFunctionsExpr : Pine.Expression
                                    envFunctionsExpr =
                                        if envFunctionsFromClosureCaptures == [] then
                                            prevEnvFunctionsExpr

                                        else
                                            Pine.KernelApplicationExpression
                                                { functionName = "concat"
                                                , argument =
                                                    Pine.ListExpression
                                                        [ {-
                                                             Here we depend on the returned list having the same layout as stackBefore.environmentFunctions.
                                                             2023-12-31: Observed some tests failing, and fixed this by wrapping into the application of 'take'.
                                                             This observation indicates that some part of the compiler emitted a longer list than is described in stackBefore.environmentFunctions.
                                                          -}
                                                          Pine.KernelApplicationExpression
                                                            { functionName = "take"
                                                            , argument =
                                                                Pine.ListExpression
                                                                    [ Pine.LiteralExpression
                                                                        (Pine.valueFromInt (List.length compilation.environmentFunctions))
                                                                    , prevEnvFunctionsExpr
                                                                    ]
                                                            }
                                                        , Pine.ListExpression appendedEnvFunctionsExpressions
                                                        ]
                                                }
                                in
                                case emitExpression newEmitStack funcBody of
                                    Err err ->
                                        Err ("Failed emitting function body: " ++ err)

                                    Ok funcBodyEmitted ->
                                        Ok
                                            (Pine.DecodeAndEvaluateExpression
                                                { expression =
                                                    Pine.LiteralExpression
                                                        (Pine.encodeExpressionAsValue funcBodyEmitted)
                                                , environment =
                                                    Pine.ListExpression
                                                        [ envFunctionsExpr
                                                        , Pine.ListExpression argumentsPine
                                                        ]
                                                }
                                            )

                        ReferenceExpression functionName ->
                            case
                                emitApplyFunctionFromCurrentEnvironment
                                    compilation
                                    { functionName = functionName }
                                    argumentsPine
                            of
                                Just functionApplicationResult ->
                                    functionApplicationResult

                                Nothing ->
                                    genericFunctionApplication ()

                        _ ->
                            genericFunctionApplication ()
                )


emitFunctionApplicationPine : EmitStack -> List Pine.Expression -> Pine.Expression -> Result String Pine.Expression
emitFunctionApplicationPine emitStack arguments functionExpressionPine =
    let
        genericPartialApplication () =
            partialApplicationExpressionFromListOfArguments
                arguments
                emitStack
                functionExpressionPine
    in
    if not (pineExpressionIsIndependent functionExpressionPine) then
        genericPartialApplication ()
            |> Ok

    else
        evaluateAsIndependentExpression functionExpressionPine
            |> Result.map
                (\functionValue ->
                    case parseFunctionRecordFromValueTagged functionValue of
                        Err _ ->
                            genericPartialApplication ()

                        Ok functionRecord ->
                            let
                                combinedArguments =
                                    [ List.map Pine.LiteralExpression
                                        functionRecord.argumentsAlreadyCollected
                                    , arguments
                                    ]
                                        |> List.concat
                            in
                            if functionRecord.parameterCount /= List.length combinedArguments then
                                genericPartialApplication ()

                            else
                                let
                                    mappedEnvironment =
                                        Pine.ListExpression
                                            [ functionRecord.envFunctions
                                                |> List.map Pine.LiteralExpression
                                                |> Pine.ListExpression
                                            , Pine.ListExpression combinedArguments
                                            ]

                                    findReplacementForExpression expression =
                                        if expression == Pine.EnvironmentExpression then
                                            Just mappedEnvironment

                                        else
                                            Nothing
                                in
                                transformPineExpressionWithOptionalReplacement
                                    findReplacementForExpression
                                    functionRecord.innerFunction
                                    |> Tuple.first
                                    |> searchForExpressionReductionRecursive { maxDepth = 5 }
                )


emitApplyFunctionFromCurrentEnvironment :
    EmitStack
    -> { functionName : String }
    -> List Pine.Expression
    -> Maybe (Result String Pine.Expression)
emitApplyFunctionFromCurrentEnvironment compilation { functionName } arguments =
    let
        currentEnvironmentFunctionEntryFromName : String -> Maybe ( Int, EnvironmentFunctionEntry )
        currentEnvironmentFunctionEntryFromName name =
            Common.listFindWithIndex
                (\envEntry -> envEntry.functionName == name)
                compilation.environmentFunctions
    in
    case currentEnvironmentFunctionEntryFromName functionName of
        Nothing ->
            Nothing

        Just ( functionIndexInEnv, function ) ->
            let
                getEnvFunctionsExpression =
                    Pine.EnvironmentExpression
                        |> listItemFromIndexExpression_Pine 0

                getFunctionExpression =
                    getEnvFunctionsExpression
                        |> listItemFromIndexExpression_Pine functionIndexInEnv
            in
            case function.expectedEnvironment of
                ImportedEnvironment importedEnv ->
                    let
                        funcRecordLessTag =
                            getFunctionExpression
                                |> pineExpressionForDeconstructions importedEnv.pathToRecordFromEnvEntry

                        {-
                           The paths here mirror the composition in 'buildRecordOfPartiallyAppliedFunction'
                        -}
                        importedGetFunctionExpr =
                            funcRecordLessTag
                                |> pineExpressionForDeconstructions
                                    [ ListItemDeconstruction 1
                                    , ListItemDeconstruction 0
                                    ]

                        importedGetEnvFunctionsExpression =
                            funcRecordLessTag
                                |> pineExpressionForDeconstructions
                                    [ ListItemDeconstruction 1
                                    , ListItemDeconstruction 2
                                    ]
                    in
                    Just
                        (Ok
                            (if function.parameterCount == List.length arguments then
                                Pine.DecodeAndEvaluateExpression
                                    { expression = importedGetFunctionExpr
                                    , environment =
                                        Pine.ListExpression
                                            [ importedGetEnvFunctionsExpression
                                            , Pine.ListExpression arguments
                                            ]
                                    }

                             else
                                Pine.DecodeAndEvaluateExpression
                                    { expression =
                                        Pine.ListExpression
                                            [ Pine.LiteralExpression Pine.stringAsValue_Literal
                                            , funcRecordLessTag
                                            ]
                                    , environment =
                                        Pine.ListExpression
                                            [ Pine.ListExpression []
                                            , Pine.ListExpression arguments
                                            ]
                                    }
                                    |> partialApplicationExpressionFromListOfArguments
                                        arguments
                                        compilation
                            )
                        )

                LocalEnvironment localEnv ->
                    let
                        currentEnv =
                            List.map .functionName compilation.environmentFunctions

                        currentEnvCoversExpected =
                            List.take (List.length localEnv.expectedDecls) currentEnv
                                == localEnv.expectedDecls

                        buildEnvironmentRecursive :
                            List Pine.Expression
                            -> List String
                            -> Result String Pine.Expression
                        buildEnvironmentRecursive alreadyMapped remainingToBeMapped =
                            case remainingToBeMapped of
                                [] ->
                                    Ok (Pine.ListExpression alreadyMapped)

                                nextExpectedFunctionName :: remainingExpectedFunctions ->
                                    case currentEnvironmentFunctionEntryFromName nextExpectedFunctionName of
                                        Nothing ->
                                            Err
                                                ("Function '"
                                                    ++ functionName
                                                    ++ "' expects environment function '"
                                                    ++ nextExpectedFunctionName
                                                    ++ "' but it is not in the environment"
                                                )

                                        Just ( indexInEnv, _ ) ->
                                            buildEnvironmentRecursive
                                                (alreadyMapped
                                                    ++ [ listItemFromIndexExpression_Pine
                                                            indexInEnv
                                                            getEnvFunctionsExpression
                                                       ]
                                                )
                                                remainingExpectedFunctions

                        buildExpectedEnvironmentResult =
                            if currentEnvCoversExpected then
                                Ok getEnvFunctionsExpression

                            else
                                buildEnvironmentRecursive [] localEnv.expectedDecls
                    in
                    case buildExpectedEnvironmentResult of
                        Err err ->
                            Just (Err err)

                        Ok expectedEnvironment ->
                            Just
                                (Ok
                                    (if function.parameterCount == List.length arguments then
                                        Pine.DecodeAndEvaluateExpression
                                            { expression = getFunctionExpression
                                            , environment =
                                                Pine.ListExpression
                                                    [ expectedEnvironment
                                                    , Pine.ListExpression arguments
                                                    ]
                                            }

                                     else
                                        (if function.parameterCount == 0 then
                                            Pine.DecodeAndEvaluateExpression
                                                { expression = getFunctionExpression
                                                , environment =
                                                    Pine.ListExpression
                                                        [ expectedEnvironment
                                                        , Pine.ListExpression arguments
                                                        ]
                                                }

                                         else
                                            buildRecordOfPartiallyAppliedFunction
                                                { getFunctionInnerExpression = getFunctionExpression
                                                , getEnvFunctionsExpression = expectedEnvironment
                                                , parameterCount = function.parameterCount
                                                , argumentsAlreadyCollected = []
                                                }
                                        )
                                            |> partialApplicationExpressionFromListOfArguments
                                                arguments
                                                compilation
                                    )
                                )


partialApplicationExpressionFromListOfArguments :
    List Pine.Expression
    -> EmitStack
    -> Pine.Expression
    -> Pine.Expression
partialApplicationExpressionFromListOfArguments arguments emitStack function =
    adaptivePartialApplicationExpression
        { function = function
        , arguments = arguments
        , applicationFunctionSource =
            emitReferenceExpression environmentFunctionPartialApplicationName emitStack
                |> Result.toMaybe
        }


emitWrapperForPartialApplication : Pine.Expression -> Int -> Pine.Expression -> Pine.Expression
emitWrapperForPartialApplication envFunctionsExpression parameterCount innerExpression =
    if parameterCount == 0 then
        emitWrapperForPartialApplicationZero
            { getFunctionInnerExpression =
                innerExpression
                    |> Pine.encodeExpressionAsValue
                    |> Pine.LiteralExpression
            , getEnvFunctionsExpression = envFunctionsExpression
            }

    else
        buildRecordOfPartiallyAppliedFunction
            { getFunctionInnerExpression =
                innerExpression
                    |> Pine.encodeExpressionAsValue
                    |> Pine.LiteralExpression
            , parameterCount = parameterCount
            , getEnvFunctionsExpression = envFunctionsExpression
            , argumentsAlreadyCollected = []
            }


emitWrapperForPartialApplicationZero :
    { getFunctionInnerExpression : Pine.Expression
    , getEnvFunctionsExpression : Pine.Expression
    }
    -> Pine.Expression
emitWrapperForPartialApplicationZero { getFunctionInnerExpression, getEnvFunctionsExpression } =
    Pine.DecodeAndEvaluateExpression
        { expression = getFunctionInnerExpression
        , environment =
            Pine.ListExpression
                [ getEnvFunctionsExpression
                , Pine.ListExpression []
                ]
        }


adaptivePartialApplicationExpression :
    { function : Pine.Expression
    , arguments : List Pine.Expression
    , applicationFunctionSource : Maybe Pine.Expression
    }
    -> Pine.Expression
adaptivePartialApplicationExpression { function, arguments, applicationFunctionSource } =
    if arguments == [] then
        function

    else
        let
            applicationFunctionExpr =
                Maybe.withDefault
                    (Pine.LiteralExpression adaptivePartialApplicationRecursiveValue)
                    applicationFunctionSource
        in
        Pine.DecodeAndEvaluateExpression
            { expression = applicationFunctionExpr
            , environment =
                Pine.ListExpression
                    [ applicationFunctionExpr
                    , function
                    , Pine.ListExpression arguments
                    ]
            }


adaptivePartialApplicationRecursiveValue : Pine.Value
adaptivePartialApplicationRecursiveValue =
    Pine.encodeExpressionAsValue adaptivePartialApplicationRecursiveExpression


{-| In adaptive (partial) function application, we check whether the function is a structured function record or not.
-}
adaptivePartialApplicationRecursiveExpression : Pine.Expression
adaptivePartialApplicationRecursiveExpression =
    let
        selfFunctionLocalExpression =
            listItemFromIndexExpression_Pine 0 Pine.EnvironmentExpression

        functionLocalExpression =
            listItemFromIndexExpression_Pine 1 Pine.EnvironmentExpression

        remainingArgumentsLocalExpression =
            listItemFromIndexExpression_Pine 2 Pine.EnvironmentExpression

        nextArgumentLocalExpression =
            listItemFromIndexExpression_Pine 0 remainingArgumentsLocalExpression

        applyNextExpression =
            Pine.ConditionalExpression
                { condition =
                    {-
                       If the first element in 'function' equals 'Function',
                    -}
                    equalCondition_Pine
                        [ listItemFromIndexExpression_Pine 0 functionLocalExpression
                        , Pine.LiteralExpression Pine.stringAsValue_Function
                        ]
                , ifTrue =
                    {-
                       assume the second list item is a list with the following items:
                       + 0: inner function
                       + 1: number of parameters expected by the inner function
                       + 2: captured environment functions
                       + 3: the arguments collected so far.
                    -}
                    let
                        partiallyAppliedFunctionRecord =
                            listItemFromIndexExpression_Pine 1 functionLocalExpression

                        innerFunction =
                            partiallyAppliedFunctionRecord
                                |> listItemFromIndexExpression_Pine 0

                        numberOfParametersExpectedByInnerFunction =
                            partiallyAppliedFunctionRecord
                                |> listItemFromIndexExpression_Pine 1

                        environmentFunctions =
                            partiallyAppliedFunctionRecord
                                |> listItemFromIndexExpression_Pine 2

                        previouslyCollectedArguments =
                            partiallyAppliedFunctionRecord
                                |> listItemFromIndexExpression_Pine 3

                        collectedArguments =
                            Pine.KernelApplicationExpression
                                { functionName = "concat"
                                , argument =
                                    Pine.ListExpression
                                        [ previouslyCollectedArguments
                                        , Pine.ListExpression [ nextArgumentLocalExpression ]
                                        ]
                                }

                        collectedArgumentsLength =
                            countListElementsExpression_Pine collectedArguments

                        collectedArgumentsAreComplete =
                            equalCondition_Pine
                                [ collectedArgumentsLength
                                , numberOfParametersExpectedByInnerFunction
                                ]
                    in
                    -- First, check if the argument we collect here is the last one.
                    Pine.ConditionalExpression
                        { condition = collectedArgumentsAreComplete
                        , ifTrue =
                            -- If it is, we can apply the inner function.
                            Pine.DecodeAndEvaluateExpression
                                { expression = innerFunction
                                , environment =
                                    Pine.ListExpression
                                        [ environmentFunctions
                                        , collectedArguments
                                        ]
                                }
                        , ifFalse =
                            -- If it is not, we need to collect more arguments.
                            updateRecordOfPartiallyAppliedFunction
                                { getFunctionInnerExpression = innerFunction
                                , parameterCountExpression = numberOfParametersExpectedByInnerFunction
                                , getEnvFunctionsExpression = environmentFunctions
                                , argumentsAlreadyCollectedExpression = collectedArguments
                                }
                        }
                , ifFalse =
                    attemptReduceDecodeAndEvaluateExpressionRecursiveWithDefaultDepth
                        { expression = functionLocalExpression
                        , environment = nextArgumentLocalExpression
                        }
                }
    in
    Pine.ConditionalExpression
        { condition =
            equalCondition_Pine
                [ Pine.ListExpression []
                , remainingArgumentsLocalExpression
                ]
        , ifTrue = functionLocalExpression
        , ifFalse =
            Pine.DecodeAndEvaluateExpression
                { expression = selfFunctionLocalExpression
                , environment =
                    Pine.ListExpression
                        [ selfFunctionLocalExpression
                        , applyNextExpression
                        , listSkipExpression_Pine 1 remainingArgumentsLocalExpression
                        ]
                }
        }


buildRecordOfPartiallyAppliedFunction :
    { getFunctionInnerExpression : Pine.Expression
    , getEnvFunctionsExpression : Pine.Expression
    , parameterCount : Int
    , argumentsAlreadyCollected : List Pine.Expression
    }
    -> Pine.Expression
buildRecordOfPartiallyAppliedFunction config =
    updateRecordOfPartiallyAppliedFunction
        { getFunctionInnerExpression = config.getFunctionInnerExpression
        , getEnvFunctionsExpression = config.getEnvFunctionsExpression
        , parameterCountExpression =
            Pine.LiteralExpression (Pine.valueFromInt config.parameterCount)
        , argumentsAlreadyCollectedExpression = Pine.ListExpression config.argumentsAlreadyCollected
        }


updateRecordOfPartiallyAppliedFunction :
    { getFunctionInnerExpression : Pine.Expression
    , getEnvFunctionsExpression : Pine.Expression
    , parameterCountExpression : Pine.Expression
    , argumentsAlreadyCollectedExpression : Pine.Expression
    }
    -> Pine.Expression
updateRecordOfPartiallyAppliedFunction config =
    Pine.ListExpression
        [ Pine.LiteralExpression Pine.stringAsValue_Function
        , Pine.ListExpression
            [ config.getFunctionInnerExpression
            , config.parameterCountExpression
            , config.getEnvFunctionsExpression
            , config.argumentsAlreadyCollectedExpression
            ]
        ]


parseFunctionRecordFromValueTagged :
    Pine.Value
    ->
        Result
            String
            { innerFunctionValue : Pine.Value
            , innerFunction : Pine.Expression
            , parameterCount : Int
            , envFunctions : List Pine.Value
            , argumentsAlreadyCollected : List Pine.Value
            }
parseFunctionRecordFromValueTagged value =
    case value of
        Pine.BlobValue _ ->
            Err "Is not a list but a blob"

        Pine.ListValue listItems ->
            case listItems of
                [ functionTag, functionRecord ] ->
                    if functionTag == Pine.stringAsValue_Function then
                        parseFunctionRecordFromValue functionRecord

                    else
                        Err "Is not tagged as 'Function'"

                _ ->
                    Err
                        ("List does not have the expected number of items: "
                            ++ String.fromInt (List.length listItems)
                        )


parseFunctionRecordFromValue :
    Pine.Value
    ->
        Result
            String
            { innerFunctionValue : Pine.Value
            , innerFunction : Pine.Expression
            , parameterCount : Int
            , envFunctions : List Pine.Value
            , argumentsAlreadyCollected : List Pine.Value
            }
parseFunctionRecordFromValue value =
    case value of
        Pine.ListValue listItems ->
            case listItems of
                [ innerFunctionValue, parameterCountValue, envFunctionsValue, argumentsAlreadyCollectedValue ] ->
                    case Pine.decodeExpressionFromValue innerFunctionValue of
                        Err err ->
                            Err ("Failed to decode inner function: " ++ err)

                        Ok innerFunction ->
                            case Pine.intFromValue parameterCountValue of
                                Err err ->
                                    Err ("Failed to decode function parameter count: " ++ err)

                                Ok parameterCount ->
                                    case envFunctionsValue of
                                        Pine.ListValue envFunctions ->
                                            case argumentsAlreadyCollectedValue of
                                                Pine.ListValue argumentsAlreadyCollected ->
                                                    Ok
                                                        { innerFunctionValue = innerFunctionValue
                                                        , innerFunction = innerFunction
                                                        , parameterCount = parameterCount
                                                        , envFunctions = envFunctions
                                                        , argumentsAlreadyCollected = argumentsAlreadyCollected
                                                        }

                                                _ ->
                                                    Err "argumentsAlreadyCollectedValue is not a list"

                                        _ ->
                                            Err "envFunctionsValue is not a list"

                _ ->
                    Err
                        ("List does not have the expected number of items: "
                            ++ String.fromInt (List.length listItems)
                        )

        Pine.BlobValue _ ->
            Err "Is not a list but a blob"


attemptReduceDecodeAndEvaluateExpressionRecursiveWithDefaultDepth :
    Pine.DecodeAndEvaluateExpressionStructure
    -> Pine.Expression
attemptReduceDecodeAndEvaluateExpressionRecursiveWithDefaultDepth originalExpression =
    let
        sizeBeforeReduction =
            countPineExpressionSize estimatePineValueSize originalExpression.expression
                + countPineExpressionSize estimatePineValueSize originalExpression.environment

        reductionMaxDepth =
            if sizeBeforeReduction < 10 * 1000 then
                2

            else
                1
    in
    attemptReduceDecodeAndEvaluateExpressionRecursive
        { maxDepth = reductionMaxDepth }
        originalExpression


attemptReduceDecodeAndEvaluateExpressionRecursive :
    { maxDepth : Int }
    -> Pine.DecodeAndEvaluateExpressionStructure
    -> Pine.Expression
attemptReduceDecodeAndEvaluateExpressionRecursive { maxDepth } originalExpression =
    let
        default =
            Pine.DecodeAndEvaluateExpression originalExpression
    in
    if maxDepth < 1 then
        default

    else
        case searchReductionForDecodeAndEvaluateExpression originalExpression of
            Nothing ->
                default

            Just reduced ->
                case reduced of
                    Pine.DecodeAndEvaluateExpression reducedDecodeAndEval ->
                        attemptReduceDecodeAndEvaluateExpressionRecursive
                            { maxDepth = maxDepth - 1 }
                            reducedDecodeAndEval

                    _ ->
                        reduced


searchReductionForDecodeAndEvaluateExpression :
    Pine.DecodeAndEvaluateExpressionStructure
    -> Maybe Pine.Expression
searchReductionForDecodeAndEvaluateExpression originalExpression =
    if pineExpressionIsIndependent originalExpression.expression then
        case Pine.evaluateExpression Pine.emptyEvalContext originalExpression.expression of
            Err _ ->
                Nothing

            Ok expressionValue ->
                case Pine.decodeExpressionFromValue expressionValue of
                    Err _ ->
                        Nothing

                    Ok decodedExpression ->
                        let
                            findReplacementForExpression expression =
                                if expression == Pine.EnvironmentExpression then
                                    Just originalExpression.environment

                                else
                                    Nothing

                            ( reducedExpr, transformResult ) =
                                transformPineExpressionWithOptionalReplacement
                                    findReplacementForExpression
                                    decodedExpression
                        in
                        if transformResult.referencesOriginalEnvironment then
                            Nothing

                        else
                            Just
                                (searchForExpressionReductionRecursive { maxDepth = 5 } reducedExpr)

    else
        Nothing


searchForExpressionReductionRecursive : { maxDepth : Int } -> Pine.Expression -> Pine.Expression
searchForExpressionReductionRecursive { maxDepth } expression =
    if maxDepth < 1 then
        expression

    else
        let
            transformed =
                expression
                    |> transformPineExpressionWithOptionalReplacement searchForExpressionReduction
                    |> Tuple.first
        in
        if transformed == expression then
            transformed

        else
            searchForExpressionReductionRecursive { maxDepth = maxDepth - 1 } transformed


reduceExpressionToLiteralIfIndependent : Pine.Expression -> Pine.Expression
reduceExpressionToLiteralIfIndependent expression =
    if pineExpressionIsIndependent expression then
        case Pine.evaluateExpression Pine.emptyEvalContext expression of
            Err _ ->
                expression

            Ok expressionValue ->
                Pine.LiteralExpression expressionValue

    else
        expression


searchForExpressionReduction : Pine.Expression -> Maybe Pine.Expression
searchForExpressionReduction expression =
    let
        attemptReduceViaEval () =
            if pineExpressionIsIndependent expression then
                case Pine.evaluateExpression Pine.emptyEvalContext expression of
                    Err _ ->
                        Nothing

                    Ok expressionValue ->
                        Just (Pine.LiteralExpression expressionValue)

            else
                Nothing
    in
    case expression of
        Pine.LiteralExpression _ ->
            Nothing

        Pine.KernelApplicationExpression rootKernelApp ->
            case rootKernelApp.functionName of
                "list_head" ->
                    case rootKernelApp.argument of
                        Pine.ListExpression argumentList ->
                            List.head argumentList

                        _ ->
                            attemptReduceViaEval ()

                "skip" ->
                    case rootKernelApp.argument of
                        Pine.ListExpression [ Pine.LiteralExpression skipCountLiteral, Pine.ListExpression expressionList ] ->
                            case Pine.intFromValue skipCountLiteral of
                                Err _ ->
                                    attemptReduceViaEval ()

                                Ok skipCount ->
                                    expressionList
                                        |> List.drop skipCount
                                        |> Pine.ListExpression
                                        |> Just

                        _ ->
                            attemptReduceViaEval ()

                _ ->
                    attemptReduceViaEval ()

        _ ->
            attemptReduceViaEval ()


transformPineExpressionWithOptionalReplacement :
    (Pine.Expression -> Maybe Pine.Expression)
    -> Pine.Expression
    -> ( Pine.Expression, { referencesOriginalEnvironment : Bool } )
transformPineExpressionWithOptionalReplacement findReplacement expression =
    case findReplacement expression of
        Just replacement ->
            ( replacement, { referencesOriginalEnvironment = False } )

        Nothing ->
            case expression of
                Pine.LiteralExpression _ ->
                    ( expression, { referencesOriginalEnvironment = False } )

                Pine.ListExpression list ->
                    let
                        itemsResults =
                            List.foldr
                                (\item aggregate ->
                                    let
                                        ( itemExpr, itemInspect ) =
                                            transformPineExpressionWithOptionalReplacement findReplacement item
                                    in
                                    { aggregate
                                        | refsOrig = aggregate.refsOrig || itemInspect.referencesOriginalEnvironment
                                        , items = itemExpr :: aggregate.items
                                    }
                                )
                                { refsOrig = False, items = [] }
                                list
                    in
                    ( Pine.ListExpression itemsResults.items
                    , { referencesOriginalEnvironment = itemsResults.refsOrig
                      }
                    )

                Pine.DecodeAndEvaluateExpression decodeAndEvaluate ->
                    let
                        ( exprTransform, exprInspect ) =
                            transformPineExpressionWithOptionalReplacement findReplacement decodeAndEvaluate.expression

                        ( envTransform, envInspect ) =
                            transformPineExpressionWithOptionalReplacement findReplacement decodeAndEvaluate.environment
                    in
                    ( Pine.DecodeAndEvaluateExpression
                        { expression = exprTransform
                        , environment = envTransform
                        }
                    , { referencesOriginalEnvironment =
                            exprInspect.referencesOriginalEnvironment
                                || envInspect.referencesOriginalEnvironment
                      }
                    )

                Pine.KernelApplicationExpression kernelApp ->
                    kernelApp.argument
                        |> transformPineExpressionWithOptionalReplacement findReplacement
                        |> Tuple.mapFirst
                            (\argument ->
                                Pine.KernelApplicationExpression
                                    { argument = argument, functionName = kernelApp.functionName }
                            )

                Pine.ConditionalExpression conditional ->
                    let
                        ( conditionExpr, conditionInspect ) =
                            transformPineExpressionWithOptionalReplacement findReplacement conditional.condition

                        ( ifTrueExpr, ifTrueInspect ) =
                            transformPineExpressionWithOptionalReplacement findReplacement conditional.ifTrue

                        ( ifFalseExpr, ifFalseInspect ) =
                            transformPineExpressionWithOptionalReplacement findReplacement conditional.ifFalse
                    in
                    ( Pine.ConditionalExpression
                        { condition = conditionExpr
                        , ifTrue = ifTrueExpr
                        , ifFalse = ifFalseExpr
                        }
                    , { referencesOriginalEnvironment =
                            conditionInspect.referencesOriginalEnvironment
                                || ifTrueInspect.referencesOriginalEnvironment
                                || ifFalseInspect.referencesOriginalEnvironment
                      }
                    )

                Pine.EnvironmentExpression ->
                    ( Pine.EnvironmentExpression
                    , { referencesOriginalEnvironment = True
                      }
                    )

                Pine.StringTagExpression tag tagged ->
                    tagged
                        |> transformPineExpressionWithOptionalReplacement findReplacement
                        |> Tuple.mapFirst
                            (\taggedMapped ->
                                Pine.StringTagExpression tag taggedMapped
                            )


listFunctionAppExpressions : Expression -> List ( Expression, List Expression )
listFunctionAppExpressions expr =
    case expr of
        FunctionApplicationExpression funcExpr args ->
            List.concat
                [ ( funcExpr, args ) :: listFunctionAppExpressions funcExpr
                , List.concatMap listFunctionAppExpressions args
                ]

        LiteralExpression _ ->
            []

        ListExpression list ->
            List.concatMap listFunctionAppExpressions list

        KernelApplicationExpression application ->
            listFunctionAppExpressions application.argument

        ConditionalExpression conditional ->
            List.concat
                [ listFunctionAppExpressions conditional.condition
                , listFunctionAppExpressions conditional.ifTrue
                , listFunctionAppExpressions conditional.ifFalse
                ]

        FunctionExpression _ functionBody ->
            listFunctionAppExpressions functionBody

        ReferenceExpression _ ->
            []

        DeclarationBlockExpression declarations innerExpression ->
            List.concat
                [ List.concatMap listFunctionAppExpressions (Dict.values declarations)
                , listFunctionAppExpressions innerExpression
                ]

        StringTagExpression _ tagged ->
            listFunctionAppExpressions tagged

        PineFunctionApplicationExpression _ argument ->
            listFunctionAppExpressions argument


evaluateAsIndependentExpression : Pine.Expression -> Result String Pine.Value
evaluateAsIndependentExpression expression =
    if not (pineExpressionIsIndependent expression) then
        Err "Expression is not independent"

    else
        Pine.evaluateExpression
            Pine.emptyEvalContext
            expression
            |> Result.mapError
                (Pine.displayStringFromPineError
                    >> (++) "Expression seems independent but failed to evaluate: "
                )


pineExpressionIsIndependent : Pine.Expression -> Bool
pineExpressionIsIndependent expression =
    case expression of
        Pine.LiteralExpression _ ->
            True

        Pine.ListExpression list ->
            List.all pineExpressionIsIndependent list

        Pine.DecodeAndEvaluateExpression decodeAndEval ->
            [ decodeAndEval.environment, decodeAndEval.expression ]
                |> List.all pineExpressionIsIndependent

        Pine.KernelApplicationExpression kernelApp ->
            pineExpressionIsIndependent kernelApp.argument

        Pine.ConditionalExpression conditional ->
            [ conditional.condition, conditional.ifTrue, conditional.ifFalse ]
                |> List.all pineExpressionIsIndependent

        Pine.EnvironmentExpression ->
            False

        Pine.StringTagExpression _ tagged ->
            pineExpressionIsIndependent tagged


listItemFromIndexExpression : Int -> Expression -> Expression
listItemFromIndexExpression itemIndex listExpression =
    pineKernel_ListHead (listSkipExpression itemIndex listExpression)


countListElementsExpression : Expression -> Expression
countListElementsExpression listExpression =
    KernelApplicationExpression
        { functionName = "length"
        , argument = listExpression
        }


pineKernel_ListHead : Expression -> Expression
pineKernel_ListHead listExpression =
    KernelApplicationExpression
        { functionName = "list_head"
        , argument = listExpression
        }


listSkipExpression : Int -> Expression -> Expression
listSkipExpression numberToDrop listExpression =
    if numberToDrop < 1 then
        listExpression

    else
        applyKernelFunctionWithTwoArguments
            "skip"
            (LiteralExpression (Pine.valueFromInt numberToDrop))
            listExpression


equalCondition : List Expression -> Expression
equalCondition list =
    KernelApplicationExpression
        { functionName = "equal"
        , argument = ListExpression list
        }


applyKernelFunctionWithTwoArguments : String -> Expression -> Expression -> Expression
applyKernelFunctionWithTwoArguments kernelFunctionName argA argB =
    KernelApplicationExpression
        { functionName = kernelFunctionName
        , argument = ListExpression [ argA, argB ]
        }


countListElementsExpression_Pine : Pine.Expression -> Pine.Expression
countListElementsExpression_Pine listExpression =
    Pine.KernelApplicationExpression
        { functionName = "length"
        , argument = listExpression
        }


listItemFromIndexExpression_Pine : Int -> Pine.Expression -> Pine.Expression
listItemFromIndexExpression_Pine itemIndex listExpression =
    pineKernel_ListHead_Pine (listSkipExpression_Pine itemIndex listExpression)


listSkipExpression_Pine : Int -> Pine.Expression -> Pine.Expression
listSkipExpression_Pine numberToDrop listExpression =
    if numberToDrop < 1 then
        listExpression

    else
        applyKernelFunctionWithTwoArguments_Pine
            "skip"
            (Pine.LiteralExpression (Pine.valueFromInt numberToDrop))
            listExpression


pineKernel_ListHead_Pine : Pine.Expression -> Pine.Expression
pineKernel_ListHead_Pine listExpression =
    Pine.KernelApplicationExpression
        { functionName = "list_head"
        , argument = listExpression
        }


equalCondition_Pine : List Pine.Expression -> Pine.Expression
equalCondition_Pine list =
    Pine.KernelApplicationExpression
        { functionName = "equal"
        , argument = Pine.ListExpression list
        }


applyKernelFunctionWithTwoArguments_Pine : String -> Pine.Expression -> Pine.Expression -> Pine.Expression
applyKernelFunctionWithTwoArguments_Pine kernelFunctionName argA argB =
    Pine.KernelApplicationExpression
        { functionName = kernelFunctionName
        , argument = Pine.ListExpression [ argA, argB ]
        }


countPineExpressionSize : (Pine.Value -> Int) -> Pine.Expression -> Int
countPineExpressionSize countValueSize expression =
    case expression of
        Pine.LiteralExpression literal ->
            countValueSize literal

        Pine.ListExpression list ->
            List.foldl (\item sum -> sum + countPineExpressionSize countValueSize item)
                1
                list

        Pine.DecodeAndEvaluateExpression decodeAndEval ->
            countPineExpressionSize countValueSize decodeAndEval.expression
                + countPineExpressionSize countValueSize decodeAndEval.environment

        Pine.KernelApplicationExpression kernelApp ->
            2 + countPineExpressionSize countValueSize kernelApp.argument

        Pine.ConditionalExpression conditional ->
            countPineExpressionSize countValueSize conditional.condition
                + countPineExpressionSize countValueSize conditional.ifTrue
                + countPineExpressionSize countValueSize conditional.ifFalse

        Pine.EnvironmentExpression ->
            1

        Pine.StringTagExpression _ tagged ->
            countPineExpressionSize countValueSize tagged


estimatePineValueSize : Pine.Value -> Int
estimatePineValueSize value =
    case value of
        Pine.BlobValue blob ->
            10 + List.length blob

        Pine.ListValue list ->
            -- Reduce stack depths by matching the most common cases with up to two elements inline.
            case list of
                [] ->
                    10

                [ single ] ->
                    10 + estimatePineValueSize single

                first :: second :: remaining ->
                    10
                        + estimatePineValueSize first
                        + estimatePineValueSize second
                        + List.foldl
                            (\item sum -> sum + estimatePineValueSize item)
                            0
                            remaining
