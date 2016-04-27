# When compiled to native target, async_http_request will not provide sendRequest proc by default.
# run nim with -d:asyncHttpRequestAsyncIO to enable sendRequest proc, which will call out to asyncio
# loop on the main thread

type Response* = tuple[status: string, body: string]

type Handler* = proc (data: Response)

when defined(emscripten):
    type em_async_wget2_onload_func = proc(p: pointer, s: cstring) {.cdecl.}
    type em_async_wget2_onstatus_func = proc(p: pointer, s: cint) {.cdecl.}
    proc emscripten_async_wget2(url, file, requesttype, param: cstring,
        arg: pointer, onload: em_async_wget2_onload_func,
        onerror, onprogress: em_async_wget2_onstatus_func): cint {.importc.}

    proc sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: Handler) =
        echo "sendRequest"

elif not defined(js):
    import asyncdispatch, httpclient, threadpool
    when defined(android):
        # For some reason pthread_t is not defined on android
        {.emit:
        """/*INCLUDESECTION*/
        #include <pthread.h>"""
        .}

    proc genHeaders(body: string, headers: openarray[(string, string)]): string =
        result = "Content-Length: " & $(body.len) & "\r\lConnection: close\r\l"
        for h in headers:
            result &= h[0] & ": " & h[1] & "\r\l"

    when defined(asyncHttpRequestAsyncIO):
        const kAsyncPollTimeout = 500
    
        var ch: Channel[tuple[r: Response, rp, re: pointer]]

        open(ch)

        proc asyncHTTPRequest(url, httpMethod, extraHeaders, body: string, rp, re: pointer) =
            try:
                let resp = request(url, "http" & httpMethod, extraHeaders, body, sslContext = nil)
                ch.send(((resp.status, resp.body), rp, re))
            except:
                let msg = getCurrentExceptionMsg()
                echo "Exception caught: ", msg
                echo getCurrentException().getStackTrace()
                ch.send(((msg, ""), rp, re))

        proc sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: Handler) =
            let rp = rawProc(handler)
            let re = rawEnv(handler)
            #GC_ref(cast[ref RootObj](re))
            spawn asyncHTTPRequest(url, meth, genHeaders(body, headers), body, rp, re)

        proc closureFromRawProcAndEnv[T](rp, re: pointer): T =
            {.emit: """
            `result`->ClPrc = `rp`;
            `result`->ClEnv = `re`;
            """.}

        proc waitForEvents() {.async.} =
            while true:
                if ch.peek() > 0:
                    let m = ch.recv()
                    let rp = m.rp
                    let re = m.re
                    #GC_unref(cast[ref RootObj](re))
                    let handler = closureFromRawProcAndEnv[proc(r: Response)](rp, re)
                    handler(m.r)
                else:
                    await sleepAsync(kAsyncPollTimeout)

        asyncCheck waitForEvents()
    else:
        type ThreadedHandler* = proc(r: Response, ctx: pointer) {.nimcall.}

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

when defined(js):
    type
        XMLHTTPRequest* = ref XMLHTTPRequestObj
        XMLHTTPRequestObj {.importc.} = object
            responseType*: cstring

    proc open*(r: XMLHTTPRequest, httpMethod, url: cstring) {.importcpp.}
    proc send*(r: XMLHTTPRequest) {.importcpp.}
    proc send*(r: XMLHTTPRequest, body: cstring) {.importcpp.}
    proc addEventListener*(r: XMLHTTPRequest, event: cstring, listener: proc(e: ref RootObj)) {.importcpp.}
    proc addEventListener*(r: XMLHTTPRequest, event: cstring, listener: proc()) {.importcpp.}
    proc setRequestHeader*(r: XMLHTTPRequest, header, value: cstring) {.importcpp.}

    proc newXMLHTTPRequest*(): XMLHTTPRequest =
        {.emit: """
        if (window.XMLHttpRequest)
            `result` = new XMLHttpRequest();
        else
            `result` = new ActiveXObject("Microsoft.XMLHTTP");
        """.}

    proc sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: Handler) =
        let reqListener = proc (r: ref RootObj) =
            var cbody: cstring
            var cstatus: cstring
            {.emit: """
            `cbody` = `r`.target.responseText;
            `cstatus` = `r`.target.statusText;
            """.}
            handler(($cstatus,  $cbody))

        let oReq = newXMLHTTPRequest()
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
