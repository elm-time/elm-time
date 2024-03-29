using Pine.PineVM;
using System;
using System.Collections.Immutable;
using System.Linq;
using System.Numerics;

namespace Pine.CompilePineToDotNet;

public class ReducePineExpression
{
    static private readonly CompilerMutableCache compilerCache = new();

    public static Result<string, PineValue> TryEvaluateExpressionIndependent(Expression expression) =>
        expression switch
        {
            Expression.EnvironmentExpression =>
            Result<string, PineValue>.err("Expression depends on environment"),

            Expression.LiteralExpression literal =>
            Result<string, PineValue>.ok(literal.Value),

            Expression.ListExpression list =>
            list.List.Select(TryEvaluateExpressionIndependent)
            .ListCombine()
            .Map(PineValue.List),

            Expression.KernelApplicationExpression kernelApplication =>
            TryEvaluateExpressionIndependent(kernelApplication.argument)
            .MapError(err => "Failed to evaluate kernel application argument independent: " + err)
            .Map(kernelApplication.function),

            Expression.ParseAndEvalExpression parseAndEvalExpr =>
            TryEvaluateExpressionIndependent(parseAndEvalExpr)
            .Map(ok =>
            {
                Console.WriteLine("Successfully evaluated ParseAndEvalExpression independent 🙃");

                return ok;
            }),

            Expression.StringTagExpression stringTag =>
            TryEvaluateExpressionIndependent(stringTag.tagged),

            _ =>
            Result<string, PineValue>.err("Unsupported expression type: " + expression.GetType().FullName)
        };

    public static Result<string, PineValue> TryEvaluateExpressionIndependent(
        Expression.ParseAndEvalExpression parseAndEvalExpr)
    {
        if (TryEvaluateExpressionIndependent(parseAndEvalExpr.environment) is Result<string, PineValue>.Ok envOk)
        {
            return
                new PineVM.PineVM().EvaluateExpression(parseAndEvalExpr, PineValue.EmptyList)
                .MapError(err => "Got independent environment, but failed to evaluated: " + err);
        }

        return
            TryEvaluateExpressionIndependent(parseAndEvalExpr.expression)
            .MapError(err => "Expression is not independent: " + err)
            .AndThen(compilerCache.ParseExpressionFromValue)
            .AndThen(innerExpr => TryEvaluateExpressionIndependent(innerExpr)
            .MapError(err => "Inner expression is not independent: " + err));
    }

    public static Expression? SearchForExpressionReduction(Expression expression)
    {
        if (expression is Expression.LiteralExpression)
            return null;

        Expression? AttemptReduceViaEval()
        {
            if (Expression.IsIndependent(expression))
            {
                return
                    TryEvaluateExpressionIndependent(expression)
                    .Unpack(
                        fromErr: _ => null,
                        fromOk: literalValue => new Expression.LiteralExpression(literalValue));
            }

            return null;
        }

        switch (expression)
        {
            case Expression.KernelApplicationExpression rootKernelApp:
                switch (rootKernelApp.functionName)
                {
                    case "list_head":
                        {
                            if (rootKernelApp.argument is Expression.ListExpression argumentList)
                                return argumentList.List.FirstOrDefault();

                            return AttemptReduceViaEval();
                        }

                    case "skip":
                        {
                            if (rootKernelApp.argument is Expression.ListExpression argumentList && argumentList.List.Length is 2)
                            {
                                if (TryEvaluateExpressionIndependent(argumentList.List[0]) is Result<string, PineValue>.Ok okSkipCountValue)
                                {
                                    if (PineValueAsInteger.SignedIntegerFromValue(okSkipCountValue.Value) is Result<string, BigInteger>.Ok okSkipCount)
                                    {
                                        if (argumentList.List[1] is Expression.ListExpression partiallySkippedList)
                                            return new Expression.ListExpression(
                                                [.. partiallySkippedList.List.Skip((int)okSkipCount.Value)]);
                                    }
                                }

                                return AttemptReduceViaEval();
                            }

                            return AttemptReduceViaEval();
                        }

                    default:
                        return AttemptReduceViaEval();
                }

            case Expression.ConditionalExpression conditional:
                {
                    if (Expression.IsIndependent(conditional.condition))
                    {
                        return
                            TryEvaluateExpressionIndependent(conditional.condition)
                            .Unpack(
                                fromErr: _ =>
                                AttemptReduceViaEval(),

                                fromOk: conditionValue =>
                                conditionValue == PineVM.PineVM.TrueValue
                                ?
                                conditional.ifTrue
                                :
                                conditional.ifFalse);
                    }

                    return AttemptReduceViaEval();
                }

            default:
                return AttemptReduceViaEval();
        }
    }

    public static (Expression expr, bool referencesOriginalEnv) TransformPineExpressionWithOptionalReplacement(
        Func<Expression, Expression?> findReplacement,
        Expression expression)
    {
        if (findReplacement(expression) is { } fromReplacement)
            return (fromReplacement, false);

        switch (expression)
        {
            case Expression.LiteralExpression _:
                return (expression, false);

            case Expression.ListExpression list:
                {
                    var itemsResults =
                        list.List
                        .Select(item =>
                        TransformPineExpressionWithOptionalReplacement(findReplacement, item))
                        .Aggregate(
                            seed: new { refsOrig = false, items = (IImmutableList<Expression>)[] },
                            (aggregate, itemResult) =>
                            {
                                return
                                new
                                {
                                    refsOrig = aggregate.refsOrig || itemResult.referencesOriginalEnv,
                                    items = aggregate.items.Add(itemResult.expr)
                                };
                            });

                    return (new Expression.ListExpression([.. itemsResults.items]), itemsResults.refsOrig);
                }

            case Expression.ParseAndEvalExpression parseAndEval:
                {
                    var exprTransform = TransformPineExpressionWithOptionalReplacement(findReplacement, parseAndEval.expression);
                    var envTransform = TransformPineExpressionWithOptionalReplacement(findReplacement, parseAndEval.environment);

                    return
                        (
                        new Expression.ParseAndEvalExpression
                        (
                            expression: exprTransform.expr,
                            environment: envTransform.expr
                        ),
                        exprTransform.referencesOriginalEnv || envTransform.referencesOriginalEnv);
                }

            case Expression.KernelApplicationExpression kernelApp:
                {
                    var argumentTransform = TransformPineExpressionWithOptionalReplacement(findReplacement, kernelApp.argument);

                    return
                        (
                        kernelApp
                        with
                        {
                            argument = argumentTransform.expr
                        },
                        argumentTransform.referencesOriginalEnv);
                }

            case Expression.ConditionalExpression conditional:
                {
                    var conditionTransform = TransformPineExpressionWithOptionalReplacement(findReplacement, conditional.condition);
                    var ifTrueTransform = TransformPineExpressionWithOptionalReplacement(findReplacement, conditional.ifTrue);
                    var ifFalseTransform = TransformPineExpressionWithOptionalReplacement(findReplacement, conditional.ifFalse);

                    return (
                        new Expression.ConditionalExpression
                        (
                            condition: conditionTransform.expr,
                            ifTrue: ifTrueTransform.expr,
                            ifFalse: ifFalseTransform.expr
                            ),
                            conditionTransform.referencesOriginalEnv ||
                            ifTrueTransform.referencesOriginalEnv ||
                            ifFalseTransform.referencesOriginalEnv);
                }

            case Expression.EnvironmentExpression _:
                return (expression, true);

            case Expression.StringTagExpression stringTagExpr:
                {
                    var taggedTransform = TransformPineExpressionWithOptionalReplacement(findReplacement, stringTagExpr.tagged);

                    return (
                        new Expression.StringTagExpression
                        (
                            stringTagExpr.tag,
                            taggedTransform.expr
                        ),
                        taggedTransform.referencesOriginalEnv);
                }
        }

        throw new NotImplementedException("Expression type not implemented: " + expression.GetType().FullName);
    }

    public static Expression SearchForExpressionReductionRecursive(int maxDepth, Expression expression)
    {
        if (maxDepth < 1)
            return expression;

        var transformed =
            TransformPineExpressionWithOptionalReplacement(SearchForExpressionReduction, expression).expr;

        if (transformed == expression)
            return transformed;

        return SearchForExpressionReductionRecursive(maxDepth - 1, transformed);
    }
}

