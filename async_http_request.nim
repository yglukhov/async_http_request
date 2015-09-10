type Response* = tuple[status: string, body: string]
type Handler* = proc (data: Response)

when not defined(js):
    import asyncdispatch, httpclient
    when defined(android):
        # For some reason pthread_t is not defined on android
        {.emit: """/*INCLUDESECTION*/
        #include <pthread.h>"""
        .}

    type ThreadArg = object
        url: string
        httpMethod: string
        extraHeaders: string
        body: string
        handler: Handler

    proc ayncHTTPRequest(a: ThreadArg) {.thread.} =
        try:
            let resp = request(a.url, "http" & a.httpMethod, a.extraHeaders, a.body, sslContext = nil)
            a.handler((resp.status, resp.body))
        except:
            echo "Exception caught: ", getCurrentExceptionMsg()
            echo getCurrentException().getStackTrace()

proc sendRequestThreaded*(meth, url, body: string, headers: openarray[(string, string)], handler: Handler) =
    ## handler might not be called on the invoking thread
    when defined(js):
        let cmeth : cstring = meth
        let curl : cstring = url
        var cbody : cstring
        if not body.isNil: cbody = body

        let reqListener = proc (r: cstring) =
            var cbody: cstring
            var cstatus: cstring
            {.emit: """
            `cbody` = `r`.target.responseText;
            `cstatus` = `r`.target.statusText;
            """.}
            handler(($cstatus,  $cbody))

        {.emit: """
        var oReq = new XMLHttpRequest();
        oReq.responseType = "text";
        oReq.addEventListener('load', `reqListener`);
        oReq.open(`cmeth`, `curl`, true);
        if (`cbody` === null) {
            oReq.send();
        } else {
            oReq.send(`cbody`);
        }
        """.}
    else:
        var t : ref Thread[ThreadArg]
        t.new()

        var extraHeaders = ""
        for h in headers:
            extraHeaders &= h[0] & ": " & h[1] & "\r\n"
        createThread(t[], ayncHTTPRequest, ThreadArg(url: url, httpMethod: meth, extraHeaders: extraHeaders, body: body, handler: handler))

when defined(js):
    template sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: Handler) =
        sendRequestThreaded(meth, url, body, headers, handler)

    template sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: proc(body: string)) =
        sendRequestThreaded(meth, url, body, headers, proc(r: Response) = handler(r.body))
