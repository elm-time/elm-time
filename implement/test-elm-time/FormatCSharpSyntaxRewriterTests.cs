﻿using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Pine.PineVM;

namespace TestElmTime;

[TestClass]
public class FormatCSharpSyntaxRewriterTests
{
    [TestMethod]
    public void Formats_argument_list_in_invocation_expression()
    {
        var inputSyntaxText =
            """
            Result<string, PineValue>.ok(Pine.PineVM.KernelFunction.list_head(pine_environment).WithDefault(PineValue.EmptyList));
            """.Trim();

        var expectedFormattedText =
            """
            Result<string, PineValue>.ok(
                Pine.PineVM.KernelFunction.list_head(
                    pine_environment).WithDefault(
                    PineValue.EmptyList));
            """.Trim();

        var inputSyntaxTree = SyntaxFactory.ParseSyntaxTree(
            inputSyntaxText,
            options: new CSharpParseOptions().WithKind(SourceCodeKind.Script));

        var formattedSyntaxTree = new FormatCSharpSyntaxRewriter().Visit(inputSyntaxTree.GetRoot());

        var formattedSyntaxText = formattedSyntaxTree.ToFullString();

        StringAssert.Contains(formattedSyntaxText, expectedFormattedText);
    }

    [TestMethod]
    public void Adds_newlines_between_statements_in_method_declaration()
    {
        var inputSyntaxText =
            """
            int method_name()
            {
                var local = 0;
                return local;
            }
            """.Trim();

        var expectedFormattedText =
            """
            int method_name()
            {
                var local = 0;

                return local;
            }
            """.Trim();

        var inputSyntaxTree = SyntaxFactory.ParseSyntaxTree(
            inputSyntaxText,
            options: new CSharpParseOptions().WithKind(SourceCodeKind.Script));

        var formattedSyntaxTree = new FormatCSharpSyntaxRewriter().Visit(inputSyntaxTree.GetRoot());

        var formattedSyntaxText = formattedSyntaxTree.ToFullString();

        StringAssert.Contains(formattedSyntaxText, expectedFormattedText);
    }


    [TestMethod]
    public void Indents_in_arrow_expression_clause()
    {
        var inputSyntaxText =
            """
            int method_declaration() =>
            1;
            """.Trim();

        var expectedFormattedText =
            """
            int method_declaration() =>
                1;
            """.Trim();

        var inputSyntaxTree = SyntaxFactory.ParseSyntaxTree(
            inputSyntaxText,
            options: new CSharpParseOptions().WithKind(SourceCodeKind.Script));

        var formattedSyntaxTree = new FormatCSharpSyntaxRewriter().Visit(inputSyntaxTree.GetRoot());

        var formattedSyntaxText = formattedSyntaxTree.ToFullString();

        StringAssert.Contains(formattedSyntaxText, expectedFormattedText);
    }
}