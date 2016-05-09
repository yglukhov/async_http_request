# When compiled to native target, async_http_request will not provide sendRequest proc by default.
# run nim with -d:asyncHttpRequestAsyncIO to enable sendRequest proc, which will call out to asyncio
# loop on the main thread

type Response* = tuple[status: string, body: string]

type Handler* = proc (data: Response)

when defined(emscripten):
    import emscripten

    type Context = ref object
        handler: Handler
        resp: Response

    proc allocHttpResponse(hw: pointer, statusSize, bodySize: cint) {.EMSCRIPTEN_KEEPALIVE.} =
        let ctx = cast[Context](hw)
        ctx.resp.status = newString(statusSize)
        ctx.resp.body = newString(bodySize)
    proc getHttpResponseStatusPtr(hw: pointer): pointer {.EMSCRIPTEN_KEEPALIVE.} =
        addr(cast[Context](hw).resp.status[0])
    proc getHttpResponseBodyPtr(hw: pointer): pointer {.EMSCRIPTEN_KEEPALIVE.} =
        addr(cast[Context](hw).resp.body[0])
    proc onAsyncHttpRequestLoad(hw: pointer) {.EMSCRIPTEN_KEEPALIVE.} =
        let ctx = cast[Context](hw)
        ctx.handler(ctx.resp)
        GC_unref(ctx)

    proc sendRequest*(meth, url, body: string, headers: openarray[(string, string)], handler: Handler) =
        var h = ""
        for kv in headers:
            h &= kv[0]
            h &= ":"
            h &= kv[1]
            h &= "\l"
        var hw = Context.new()
        hw.handler = handler
        GC_ref(hw)

        discard EM_ASM_INT("""
        var meth = Pointer_stringify($0);
        var url = Pointer_stringify($1);
        var body = ($2 === 0) ? null : Pointer_stringify($2);
        var h = Pointer_stringify($3);
        var hw = $4;

        var oReq;
        if (window.XMLHttpRequest)
            oReq = new XMLHttpRequest();
        else
            oReq = new ActiveXObject("Microsoft.XMLHTTP");
        oReq.responseType = "arraybuffer";

        oReq.open(meth, url);
        var headers = h.split("\n");
        for(var i = 0; i < headers.length; i++) {
            if (headers[i].length != 0) {
                var kv = headers[i].split(":");
                oReq.setRequestHeader(kv[0], kv[1]);
            }
        }

        oReq.addEventListener("load", function(e) {
            var byteArray = new Uint8Array(oReq.response);
            _allocHttpResponse(hw, 5, byteArray.length); // TODO: Complete Status!
            var dataPtr = _getHttpResponseBodyPtr(hw);
            HEAPU8.set(byteArray, dataPtr);
            _onAsyncHttpRequestLoad(hw);
        });
        if (body === null)
            oReq.send();
        else
            oReq.send(body);

        """, meth.cstring, url.cstring, body.cstring, h.cstring, cast[pointer](hw))

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
