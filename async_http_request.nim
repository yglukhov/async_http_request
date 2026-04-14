# When compiled to native target, async_http_request will not provide sendRequest proc by default.
# run nim with -d:asyncHttpRequestAsyncIO to enable sendRequest proc, which will call out to asyncio
# loop on the main thread
type Response* = tuple[statusCode: int, status: string, body: string]

type Handler* = proc (data: Response) {.gcsafe.}
type ErrorHandler* = proc (e: ref Exception) {.gcsafe.}

when defined(wasm):
    import wasmrt
    type
        XMLHTTPRequest* {.externref.} = object of JSObject

    proc newXMLHTTPRequest*(): XMLHTTPRequest {.importwasmf: "new XMLHttpRequest".}

    proc open*(r: XMLHTTPRequest, httpMethod, url: JSString) {.importwasmm.}
    proc send*(r: XMLHTTPRequest) {.importwasmm.}
    proc send*(r: XMLHTTPRequest, body: JSString) {.importwasmm.}

    proc uint8MemSlice(s: pointer, length: uint32): JSObject {.importwasmexpr: "new Uint8Array(_nima, $0, $1)".}
    proc uint8MemSlice(c: openarray[char]): JSObject {.inline.} =
      uint8MemSlice(addr c, c.len.uint32)
    proc send*(r: XMLHTTPRequest, body: JSObject) {.importwasmm.}

    proc addEventListener*(r: XMLHTTPRequest, event: JSString, listener: proc(e: JSObject, ctx: pointer) {.cdecl.}, ctx: pointer) {.importwasmraw: "$0.addEventListener($1, e => $2(e, $3))".}
    proc setRequestHeader*(r: XMLHTTPRequest, header, value: JSString) {.importwasmm.}

    proc responseText*(r: XMLHTTPRequest): JSString {.importwasmp.}
    proc statusText*(r: XMLHTTPRequest): JSString {.importwasmp.}

    proc `responseType=`*(r: XMLHTTPRequest, t: JSString) {.importwasmp.}
    proc response*(r: XMLHTTPRequest): JSObject {.importwasmp.}

    proc status*(r: XMLHTTPRequest): int {.importwasmp.}
    proc readyState*(r: XMLHTTPRequest): int {.importwasmp.}

    proc sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: Handler) =
        let oReq = newXMLHTTPRequest()
        var reqListener: proc()
        reqListener = proc () =
            # handleJSExceptions:
            # GC_unref(reqListener)
            handler((oReq.status, $oReq.statusText,  $oReq.responseText))
        # GC_ref(reqListener)
        # oReq.addEventListener("load", reqListener)
        # oReq.addEventListener("error", reqListener)
        oReq.open(meth, url)
        oReq.responseType = "text"
        for h in headers:
            oReq.setRequestHeader(h[0], h[1])
        oReq.send(uint8MemSlice(body))

    template sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: proc(body: string)) =
        sendRequest(meth, url, body, headers, proc(r: Response) = handler(r.body))

elif not defined(js):
    import asyncdispatch, httpclient, parseutils, uri

    type AsyncHttpRequestError* = object of Exception

    when defined(ssl):
        import net
    else:
        type SSLContext = ref object
    var defaultSslContext {.threadvar.}: SSLContext

    proc getDefaultSslContext(): SSLContext =
        when defined(ssl):
            if defaultSslContext.isNil:
                defaultSslContext =
                    when defined(windows) or defined(linux) or defined(ios):
                        newContext(verifyMode = CVerifyNone)
                    else:
                        newContext()
                if defaultSslContext.isNil:
                    raise newException(AsyncHttpRequestError, "Unable to initialize SSL context.")
        result = defaultSslContext

    proc parseStatusCode(s: string): int {.inline.} =
        discard parseInt(s, result)

    when defined(asyncHttpRequestAsyncIO):
        import strtabs

        proc doAsyncRequest(cl: AsyncHttpClient, meth, url, body: string,
                            handler: Handler, onError: ErrorHandler) {.async.} =
            var r: AsyncResponse
            var rBody: string
            try:
                r = await cl.request(url, meth, body)
                rBody = await r.body
                cl.close()
                handler((statusCode: parseStatusCode(r.status), status: r.status, body: rBody))
            except Exception as e:
                if onError != nil:
                    onError(e)
                else:
                    raise e

        proc doSendRequest(meth, url, body: string, headers: openarray[(string, string)],
                           sslContext: SSLContext,
                           handler: Handler, onError: ErrorHandler) =
            when defined(ssl):
                var client = newAsyncHttpClient(sslContext = sslContext)
            else:
                if url.parseUri.scheme == "https":
                    raise newException(AsyncHttpRequestError, "SSL support is not available. Compile with -d:ssl to enable.")
                var client = newAsyncHttpClient()

            client.headers = newHttpHeaders(headers)
            client.headers["Content-Length"] = $body.len
            client.headers["Connection"] = "close"
            asyncCheck doAsyncRequest(client, meth, url, body, handler, onError)

        proc sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: Handler) =
            doSendRequest(meth, url, body, headers, getDefaultSslContext(), handler, nil)

        proc sendRequest*(meth, url, body: string, headers: openarray[(string, string)], sslContext: SSLContext, handler: Handler) =
            doSendRequest(meth, url, body, headers, sslContext, handler, nil)

        proc sendRequestWithErrorHandler*(meth, url, body: string, headers: openarray[(string, string)],
                                          onSuccess: Handler, onError: ErrorHandler) =
            doSendRequest(meth, url, body, headers, getDefaultSslContext(), onSuccess, onError)

        proc sendRequestWithErrorHandler*(meth, url, body: string, headers: openarray[(string, string)], sslContext: SSLContext,
                                          onSuccess: Handler, onError: ErrorHandler) =
            doSendRequest(meth, url, body, headers, sslContext, onSuccess, onError)
    elif compileOption("threads"):
        import threadpool, net

        type ThreadedHandler* = proc(r: Response, ctx: pointer) {.nimcall, gcsafe.}

        proc asyncHTTPRequest(url, httpMethod, body: string, headers: seq[(string, string)], handler: ThreadedHandler,
                              ctx: pointer) {.gcsafe.}=
            try:
                when defined(ssl):
                    var client = newHttpClient(sslContext = getDefaultSslContext())
                else:
                    if url.parseUri.scheme == "https":
                        raise newException(AsyncHttpRequestError, "SSL support is not available. Compile with -d:ssl to enable.")
                    var client = newHttpClient()

                client.headers = newHttpHeaders(headers)
                client.headers["Content-Length"] = $body.len
                # client.headers["Connection"] = "close" # This triggers nim bug #9867
                let resp = client.request(url, httpMethod, body)
                client.close()
                handler((parseStatusCode(resp.status), resp.status, resp.body), ctx)
            except:
                let msg = getCurrentExceptionMsg()
                handler((-1, "Exception caught: " & msg, getCurrentException().getStackTrace()), ctx)

        proc sendRequestThreaded*(meth, url, body: string, headers: openarray[(string, string)], handler: ThreadedHandler,
                                  ctx: pointer = nil) =
            ## handler might not be called on the invoking thread
            spawn asyncHTTPRequest(url, meth, body, @headers, handler, ctx)
    else:
        {.warning: "async_http_requests requires either --threads:on or -d:asyncHttpRequestAsyncIO".}
