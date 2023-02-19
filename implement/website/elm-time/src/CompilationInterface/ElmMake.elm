module CompilationInterface.ElmMake exposing (..)

{-| For documentation of the compilation interface, see <https://github.com/elm-time/elm-time/blob/main/guide/how-to-configure-and-deploy-an-elm-backend-app.md#compilationinterfaceelmmake-elm-module>
-}


elm_make____src_Frontend_Main_elm : { debug : { javascript : { gzip : { base64 : String } } }, javascript : { base64 : String } }
elm_make____src_Frontend_Main_elm =
    { javascript = { base64 = "The compiler replaces this declaration." }
    , debug = { javascript = { gzip = { base64 = "The compiler replaces this declaration." } } }
    }
