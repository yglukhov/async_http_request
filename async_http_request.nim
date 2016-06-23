# When compiled to native target, async_http_request will not provide sendRequest proc by default.
# run nim with -d:asyncHttpRequestAsyncIO to enable sendRequest proc, which will call out to asyncio
# loop on the main thread

type Response* = tuple[status: string, body: string]

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

    proc sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: Handler) =
        let oReq = newXMLHTTPRequest()
        var reqListener: proc()
        reqListener = proc () =
            handler(($oReq.statusText,  $oReq.responseText))
            jsUnref(reqListener)
        jsRef(reqListener)
        oReq.responseType = "text"
        oReq.addEventListener("load", reqListener)
        oReq.open(meth, url)
        for h in headers:
            oReq.setRequestHeader(h[0], h[1])
        if body.isNil:
            oReq.send()
        else:
            oReq.send(body)

    template sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: proc(body: string)) =
        sendRequest(meth, url, body, headers, proc(r: Response) = handler(r.body))

elif not defined(js):
    import asyncdispatch, httpclient
    when defined(android):
        # For some reason pthread_t is not defined on android
        {.emit:
        """/*INCLUDESECTION*/
        #include <pthread.h>"""
        .}

    when defined(asyncHttpRequestAsyncIO):
        import strtabs

        proc doAsyncRequest(cl: AsyncHttpClient, meth, url, body: string, handler: Handler) {.async.} =
            let r = await cl.request(url, "http" & meth, body)
            cl.close()
            handler((r.status, r.body))

        proc sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: Handler) =
            var client = newAsyncHttpClient()
            client.headers = newStringTable(headers)
            client.headers["Content-Length"] = $body.len
            client.headers["Connection"] = "close"
            asyncCheck doAsyncRequest(client, meth, url, body, handler)
    else:
        import threadpool
        type ThreadedHandler* = proc(r: Response, ctx: pointer) {.nimcall.}

        proc genHeaders(body: string, headers: openarray[(string, string)]): string =
            result = "Content-Length: " & $(body.len) & "\r\lConnection: close\r\l"
            for h in headers:
                result &= h[0] & ": " & h[1] & "\r\l"

        proc asyncHTTPRequest(url, httpMethod, extraHeaders, body: string, handler: ThreadedHandler, ctx: pointer) =
            try:
                let resp = request(url, "http" & httpMethod, extraHeaders, body, sslContext = nil)
                handler((resp.status, resp.body), ctx)
            except:
                let msg = getCurrentExceptionMsg()
                echo "Exception caught: ", msg
                echo getCurrentException().getStackTrace()
                handler((msg, ""), ctx)

        proc sendRequestThreaded*(meth, url, body: string, headers: openarray[(string, string)], handler: ThreadedHandler, ctx: pointer = nil) =
            ## handler might not be called on the invoking thread
            spawn asyncHTTPRequest(url, meth, genHeaders(body, headers), body, handler, ctx)
