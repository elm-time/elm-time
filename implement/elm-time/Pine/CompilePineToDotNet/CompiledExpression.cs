using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.Linq;

namespace Pine.CompilePineToDotNet;

public partial class CompileToCSharp
{
    public record CompiledExpression(
        ExpressionSyntax Syntax,

        /*
         * true if the type of the expression is Result<string, PineValue>
         * false if the type of the expression is PineValue
         * */
        bool IsTypeResult,

        ImmutableDictionary<PineVM.Expression, LetBinding> LetBindings)
    {
        public ImmutableDictionary<PineVM.Expression, LetBinding> EnumerateLetBindingsTransitive() =>
            Union([LetBindings, .. LetBindings.Values.Select(binding => binding.Expression.EnumerateLetBindingsTransitive())]);

        public static CompiledExpression WithTypePlainValue(ExpressionSyntax syntax) =>
            WithTypePlainValue(syntax, NoLetBindings);

        public static CompiledExpression WithTypePlainValue(
            ExpressionSyntax syntax,
            ImmutableDictionary<PineVM.Expression, LetBinding> letBindings) =>
            new(
                syntax,
                IsTypeResult: false,
                LetBindings: letBindings);

        public static CompiledExpression WithTypeResult(ExpressionSyntax syntax) =>
            WithTypeResult(syntax, NoLetBindings);

        public static CompiledExpression WithTypeResult(
            ExpressionSyntax syntax,
            ImmutableDictionary<PineVM.Expression, LetBinding> letBindings) =>
            new(
                syntax,
                IsTypeResult: true,
                LetBindings: letBindings);

        public static readonly ImmutableDictionary<PineVM.Expression, LetBinding> NoLetBindings =
            ImmutableDictionary<PineVM.Expression, LetBinding>.Empty;

        public CompiledExpression MergeBindings(IReadOnlyDictionary<PineVM.Expression, LetBinding> bindings) =>
            this
            with
            {
                LetBindings = LetBindings.SetItems(bindings)
            };

        public CompiledExpression MapSyntax(Func<ExpressionSyntax, ExpressionSyntax> map) =>
            this
            with
            {
                Syntax = map(Syntax)
            };

        public CompiledExpression MapOrAndThen(
            EnvironmentConfig environment,
            Func<ExpressionSyntax, CompiledExpression> continueWithPlainValue)
        {
            if (!IsTypeResult)
            {
                return
                    continueWithPlainValue(Syntax)
                    .MergeBindings(LetBindings);
            }

            var syntaxName = GetNameForExpression(Syntax);

            var okIdentifier = SyntaxFactory.Identifier("ok_of_" + syntaxName);

            var combinedExpression =
                continueWithPlainValue(SyntaxFactory.IdentifierName(okIdentifier))
                .MergeBindings(LetBindings);

            var mapErrorExpression =
                SyntaxFactory.InvocationExpression(
                    SyntaxFactory.MemberAccessExpression(
                        SyntaxKind.SimpleMemberAccessExpression,
                        Syntax,
                        SyntaxFactory.IdentifierName("MapError")))
                .WithArgumentList(
                    SyntaxFactory.ArgumentList(
                        SyntaxFactory.SingletonSeparatedList(
                            SyntaxFactory.Argument(
                                SyntaxFactory.SimpleLambdaExpression(
                                        SyntaxFactory.Parameter(
                                            SyntaxFactory.Identifier("err")))
                                    .WithExpressionBody(
                                        SyntaxFactory.BinaryExpression(
                                            SyntaxKind.AddExpression,
                                            SyntaxFactory.LiteralExpression(
                                                SyntaxKind.StringLiteralExpression,
                                                SyntaxFactory.Literal(
                                                    "Failed to evaluate expression " + syntaxName + ":")),
                                            SyntaxFactory.IdentifierName("err")))))));

            var combinedExpressionSyntax =
                ExpressionBodyOrBlock(environment, combinedExpression);

            return
                WithTypeResult(
                    SyntaxFactory.InvocationExpression(
                        SyntaxFactory.MemberAccessExpression(
                            SyntaxKind.SimpleMemberAccessExpression,
                            mapErrorExpression,
                            SyntaxFactory.IdentifierName(combinedExpression.IsTypeResult ? "AndThen" : "Map")))
                    .WithArgumentList(
                        SyntaxFactory.ArgumentList(
                            SyntaxFactory.SingletonSeparatedList(
                                SyntaxFactory.Argument(
                                    SyntaxFactory.SimpleLambdaExpression(SyntaxFactory.Parameter(okIdentifier))
                                    .WithBody(combinedExpressionSyntax))))));
        }

        static CSharpSyntaxNode ExpressionBodyOrBlock(
            EnvironmentConfig environment,
            CompiledExpression compiledExpression)
        {
            var letBindingsAvailableFromParentKeys =
                environment.EnumerateLetBindingsTransitive().Keys.ToImmutableHashSet();

            var letBindingsTransitive =
                compiledExpression.EnumerateLetBindingsTransitive();

            var variableDeclarations =
                VariableDeclarationsForLetBindings(
                    letBindingsTransitive,
                    usagesSyntaxes: [compiledExpression.Syntax],
                    excludeBinding: letBindingsAvailableFromParentKeys.Contains);

            if (variableDeclarations is [])
                return compiledExpression.Syntax;

            return
                SyntaxFactory.Block(
                    (StatementSyntax[])
                    ([.. variableDeclarations,
                        SyntaxFactory.ReturnStatement(compiledExpression.Syntax)])
                    );
        }

        public static IReadOnlyList<LocalDeclarationStatementSyntax> VariableDeclarationsForLetBindings(
            IReadOnlyDictionary<PineVM.Expression, LetBinding> availableLetBindings,
            IReadOnlyCollection<ExpressionSyntax> usagesSyntaxes,
            Func<PineVM.Expression, bool>? excludeBinding)
        {
            var usedLetBindings =
                usagesSyntaxes
                .SelectMany(usageSyntax => EnumerateUsedLetBindingsTransitive(usageSyntax, availableLetBindings))
                .Where(b => excludeBinding is null || !excludeBinding(b.Key))
                .Distinct()
                .ToImmutableDictionary();

            var orderedBindingsExpressions =
                CSharpDeclarationOrder.OrderExpressionsByContainment(
                    usedLetBindings
                    .OrderBy(b => b.Value.DeclarationName)
                    .Select(b => b.Key));

            var orderedBindings =
                orderedBindingsExpressions
                .Select(bindingExpression => usedLetBindings[bindingExpression])
                .ToImmutableArray();

            return
                orderedBindings
                .Select(letBinding =>
                SyntaxFactory.LocalDeclarationStatement(
                    SyntaxFactory.VariableDeclaration(
                        SyntaxFactory.IdentifierName(
                            SyntaxFactory.Identifier(
                                SyntaxFactory.TriviaList(),
                                SyntaxKind.VarKeyword,
                                "var",
                                "var",
                                SyntaxFactory.TriviaList())))
                    .WithVariables(
                        variables: SyntaxFactory.SingletonSeparatedList(
                            SyntaxFactory.VariableDeclarator(
                                SyntaxFactory.Identifier(letBinding.DeclarationName))
                            .WithInitializer(
                                SyntaxFactory.EqualsValueClause(letBinding.Expression.AsCsWithTypeResult()))))))
                .ToImmutableArray();
        }

        public static IEnumerable<KeyValuePair<PineVM.Expression, LetBinding>> EnumerateUsedLetBindingsTransitive(
            ExpressionSyntax usageRoot,
            IReadOnlyDictionary<PineVM.Expression, LetBinding> availableBindings)
        {
            foreach (var identiferName in usageRoot.DescendantNodesAndSelf().OfType<IdentifierNameSyntax>())
            {
                var matchingBinding =
                    availableBindings
                    .Where(binding => binding.Value.DeclarationName == identiferName.Identifier.ValueText)
                    .FirstOrDefault();

                if (matchingBinding.Key is null)
                    continue;

                yield return matchingBinding;

                foreach (var binding in EnumerateUsedLetBindingsTransitive(matchingBinding.Value.Expression.Syntax, availableBindings))
                    yield return binding;
            }
        }

        public CompiledExpression Map(
            EnvironmentConfig environment,
            Func<ExpressionSyntax, ExpressionSyntax> map)
        {
            return MapOrAndThen(
                environment,
                inner => new CompiledExpression(
                map(inner),
                IsTypeResult: false,
                LetBindings: NoLetBindings));
        }

        public ExpressionSyntax AsCsWithTypeResult()
        {
            if (IsTypeResult)
                return Syntax;

            return WrapExpressionInPineValueResultOk(Syntax);
        }

        public static CompiledExpression ListMapOrAndThen(
            EnvironmentConfig environment,
            Func<IReadOnlyList<ExpressionSyntax>, CompiledExpression> combine,
            IReadOnlyList<CompiledExpression> compiledList)
        {
            CompiledExpression recursive(
                Func<IReadOnlyList<ExpressionSyntax>, CompiledExpression> combine,
                ImmutableList<CompiledExpression> compiledList,
                ImmutableList<ExpressionSyntax> syntaxesCs)
            {
                if (compiledList.IsEmpty)
                    return combine(syntaxesCs);

                return
                    compiledList.First().MapOrAndThen(
                        environment,
                        itemCs => recursive(
                            combine,
                            compiledList.RemoveAt(0),
                            syntaxesCs.Add(itemCs)));
            }

            return
                recursive(
                    combine,
                    [.. compiledList],
                    []);
        }

        public static ImmutableDictionary<KeyT, ValueT> Union<KeyT, ValueT>(
            IEnumerable<IReadOnlyDictionary<KeyT, ValueT>> dictionaries)
            where KeyT : notnull
            =>
            dictionaries.Aggregate(
                seed: ImmutableDictionary<KeyT, ValueT>.Empty,
                func: (aggregate, next) => aggregate.SetItems(next));
    }

    public record LetBinding(
        string DeclarationName,
        CompiledExpression Expression,
        DependenciesFromCompilation Dependencies);
}