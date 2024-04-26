module CompilationInterface.ElmMake exposing (..)

{-| For documentation of the compilation interface, see <https://github.com/pine-vm/pine/blob/main/guide/how-to-configure-and-deploy-an-elm-backend-app.md#compilationinterfaceelmmake-elm-module>
-}


elm_make____src_Frontend_Main_elm : { debug : { javascript : { base64 : String } }, javascript : { base64 : String } }
elm_make____src_Frontend_Main_elm =
    { javascript = { base64 = "The compiler replaces this declaration." }
    , debug = { javascript = { base64 = "The compiler replaces this declaration." } }
    }


elm_make____src_LanguageServiceWorker_elm : { javascript : { utf8 : String } }
elm_make____src_LanguageServiceWorker_elm =
    { javascript = { utf8 = "The compiler replaces this declaration." }
    }
