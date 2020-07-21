# When compiled to native target, async_http_request will not provide sendRequest proc by default.
# run nim with -d:asyncHttpRequestAsyncIO to enable sendRequest proc, which will call out to asyncio
# loop on the main thread

type Response* = tuple[statusCode: int, status: string, body: string]

type Handler* = proc (data: Response)
type ErrorHandler* = proc (e: ref Exception)

when defined(emscripten) or defined(js):
    import jsbind
    type
        XMLHTTPRequest* = ref object of JSObj

    proc newXMLHTTPRequest*(): XMLHTTPRequest {.jsimportgWithName: "function(){return (window.XMLHttpRequest)?new XMLHttpRequest():new ActiveXObject('Microsoft.XMLHTTP')}".}

    proc open*(r: XMLHTTPRequest, httpMethod, url: cstring) {.jsimport.}
    proc send*(r: XMLHTTPRequest) {.jsimport.}
    proc send*(r: XMLHTTPRequest, body: cstring) {.jsimport.}

    proc addEventListener*(r: XMLHTTPRequest, event: cstring, listener: proc()) {.jsimport.}
    proc setRequestHeader*(r: XMLHTTPRequest, header, value: cstring) {.jsimport.}

    proc responseText*(r: XMLHTTPRequest): jsstring {.jsimportProp.}
    proc statusText*(r: XMLHTTPRequest): jsstring {.jsimportProp.}

    proc `responseType=`*(r: XMLHTTPRequest, t: cstring) {.jsimportProp.}
    proc response*(r: XMLHTTPRequest): JSObj {.jsimportProp.}

    proc status*(r: XMLHTTPRequest): int {.jsimportProp.}
    proc readyState*(r: XMLHTTPRequest): int {.jsimportProp.}

    proc sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: Handler) =
        let oReq = newXMLHTTPRequest()
        var reqListener: proc()
        reqListener = proc () =
            handleJSExceptions:
                jsUnref(reqListener)
                handler((oReq.status, $oReq.statusText,  $oReq.responseText))
        jsRef(reqListener)
        oReq.addEventListener("load", reqListener)
        oReq.addEventListener("error", reqListener)
        oReq.open(meth, url)
        oReq.responseType = "text"
        for h in headers:
            oReq.setRequestHeader(h[0], h[1])
        if body.len == 0:
            oReq.send()
        else:
            oReq.send(body)

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

        type ThreadedHandler* = proc(r: Response, ctx: pointer) {.nimcall.}

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
