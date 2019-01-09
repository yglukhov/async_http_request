# When compiled to native target, async_http_request will not provide sendRequest proc by default.
# run nim with -d:asyncHttpRequestAsyncIO to enable sendRequest proc, which will call out to asyncio
# loop on the main thread

type Response* = tuple[statusCode: int, status: string, body: string]

type Handler* = proc (data: Response)

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
    import asyncdispatch, httpclient, parseutils

    proc parseStatusCode(s: string): int {.inline.} =
        discard parseInt(s, result)

    when defined(asyncHttpRequestAsyncIO):
        import strtabs

        proc doAsyncRequest(cl: AsyncHttpClient, meth, url, body: string, handler: Handler) {.async.} =
            let r = await cl.request(url, meth, body)
            cl.close()
            let rBody = await r.body
            handler((statusCode: parseStatusCode(r.status), status: r.status, body: rBody))

        proc sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: Handler) =
            var client = newAsyncHttpClient()
            client.headers = newHttpHeaders(headers)
            client.headers["Content-Length"] = $body.len
            client.headers["Connection"] = "close"
            asyncCheck doAsyncRequest(client, meth, url, body, handler)
    else:
        import threadpool, net

        type ThreadedHandler* = proc(r: Response, ctx: pointer) {.nimcall.}

        proc asyncHTTPRequest(url, httpMethod, body: string, headers: seq[(string, string)], handler: ThreadedHandler, ctx: pointer) {.gcsafe.}=
            try:
                when defined(ssl):
                    when defined(windows) or defined(linux):
                        let sslCtx = newContext(verifyMode = CVerifyNone)
                    else:
                        let sslCtx = newContext()
                    let client = newHttpClient(sslContext = sslCtx)
                else:
                    let client = newHttpClient(sslContext = nil)

                client.headers = newHttpHeaders(headers)
                client.headers["Content-Length"] = $body.len
                client.headers["Connection"] = "close"
                let resp = client.request(url, httpMethod, body)
                client.close()
                when defined(ssl):
                    sslCtx.destroyContext()
                handler((parseStatusCode(resp.status), resp.status, resp.body), ctx)
            except:
                let msg = getCurrentExceptionMsg()
                handler((-1, "Exception caught: " & msg, getCurrentException().getStackTrace()), ctx)

        proc sendRequestThreaded*(meth, url, body: string, headers: openarray[(string, string)], handler: ThreadedHandler, ctx: pointer = nil) =
            ## handler might not be called on the invoking thread
            spawn asyncHTTPRequest(url, meth, body, @headers, handler, ctx)
