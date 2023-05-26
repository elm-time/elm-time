﻿using ElmTime.JavaScript;
using JavaScriptEngineSwitcher.V8;
using System;

namespace ElmTime;

public interface IJsEngine : IDisposable
{
    object Evaluate(string expression);

    object CallFunction(string functionName, params object[] args);

    public static IJsEngine DefaultBuildJsEngine() =>
        JsEngineJintOptimizedForElmApps.Create();

    public static Func<IJsEngine>? OverrideDefaultBuildJsEngine { set; get; }

    public static IJsEngine BuildJsEngine() =>
        OverrideDefaultBuildJsEngine?.Invoke() ?? DefaultBuildJsEngine();
}

public class JsEngineFromJavaScriptEngineSwitcher : IJsEngine
{
    private readonly JavaScriptEngineSwitcher.Core.IJsEngine jsEngine;

    public JsEngineFromJavaScriptEngineSwitcher(JavaScriptEngineSwitcher.Core.IJsEngine jsEngine)
    {
        this.jsEngine = jsEngine;
    }

    object IJsEngine.CallFunction(string functionName, params object[] args) =>
        jsEngine.CallFunction(functionName, args);

    object IJsEngine.Evaluate(string expression) =>
        jsEngine.Evaluate(expression);

    void IDisposable.Dispose() =>
        jsEngine.Dispose();

    public static int? OverrideJsEngineSettingsMaxStackSize = null;

    public static IJsEngine ConstructJsEngine() =>
        new JsEngineFromJavaScriptEngineSwitcher(ConstructClearScriptJavaScriptEngine());

    public static JavaScriptEngineSwitcher.Core.IJsEngine ConstructClearScriptJavaScriptEngine()
    {
        ClearScriptV8.SetupTask.Value.Wait();

        return new V8JsEngine(
            new V8Settings
            {
                MaxStackUsage = (nuint)(OverrideJsEngineSettingsMaxStackSize ?? 40_000_000),
            }
        );
    }

}
