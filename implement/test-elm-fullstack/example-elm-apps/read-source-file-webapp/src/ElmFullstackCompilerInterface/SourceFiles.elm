module ElmFullstackCompilerInterface.SourceFiles exposing (..)

import Bytes
import Bytes.Encode


file____static_content_demo_file_mp3 : Bytes.Bytes
file____static_content_demo_file_mp3 =
    "The Elm-fullstack compiler replaces this value."
        |> Bytes.Encode.string
        |> Bytes.Encode.encode
