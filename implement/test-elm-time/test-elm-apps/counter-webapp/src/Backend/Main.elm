module Backend.Main exposing
    ( State
    , webServiceMain
    )

import Base64
import Bytes
import Bytes.Decode
import Bytes.Encode
import CompilationInterface.GenerateJsonConverters as GenerateJsonConverters
import HttpApi exposing (ClientRequest)
import Json.Decode
import Platform.WebService


type alias State =
    Int


webServiceMain : Platform.WebService.WebServiceConfig State
webServiceMain =
    { init = ( 0, [] )
    , subscriptions = subscriptions
    }


subscriptions : State -> Platform.WebService.Subscriptions State
subscriptions _ =
    { httpRequest = updateForHttpRequestEvent
    , posixTimeIsPast = Nothing
    }


updateForHttpRequestEvent : Platform.WebService.HttpRequestEventStruct -> State -> ( State, Platform.WebService.Commands State )
updateForHttpRequestEvent httpRequestEvent stateBefore =
    let
        ( state, result ) =
            case
                httpRequestEvent.request.bodyAsBase64
                    |> Maybe.map (Base64.toBytes >> Maybe.map (decodeBytesToString >> Maybe.withDefault "Failed to decode bytes to string") >> Maybe.withDefault "Failed to decode from base64")
                    |> Maybe.withDefault "Missing HTTP body"
                    |> Json.Decode.decodeString GenerateJsonConverters.jsonDecodeClientRequest
                    |> Result.mapError Json.Decode.errorToString
            of
                Err error ->
                    ( stateBefore, Err ("Failed to deserialize counter event from HTTP Request content: " ++ error) )

                Ok counterEvent ->
                    stateBefore |> processCounterEvent counterEvent |> Tuple.mapSecond Ok

        ( httpResponseCode, httpResponseBodyString ) =
            case result of
                Err error ->
                    ( 400, error )

                Ok message ->
                    ( 200, message )

        httpResponse =
            { httpRequestId = httpRequestEvent.httpRequestId
            , response =
                { statusCode = httpResponseCode
                , bodyAsBase64 = httpResponseBodyString |> Bytes.Encode.string |> Bytes.Encode.encode |> Base64.fromBytes
                , headersToAdd = []
                }
            }
    in
    ( state
    , [ Platform.WebService.RespondToHttpRequest httpResponse ]
    )


processCounterEvent : ClientRequest -> State -> ( State, String )
processCounterEvent counterEvent stateBefore =
    let
        state =
            stateBefore + counterEvent.addition
    in
    ( state, state |> String.fromInt )


decodeBytesToString : Bytes.Bytes -> Maybe String
decodeBytesToString bytes =
    bytes |> Bytes.Decode.decode (Bytes.Decode.string (bytes |> Bytes.width))
