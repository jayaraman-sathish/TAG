package com.tagtrail.scanner;

import android.webkit.JavascriptInterface;

/**
 * The console's outbound channel.
 *
 * The console already has a host contract and this is the whole of its page-to-host
 * half: it calls window.TagTrailHost.postMessage(json) with audit_started,
 * audit_finished, audit_cancelled and settings events. Injecting an object under
 * that exact name is all that is needed for it to start talking.
 *
 * Deliberately one method. Everything on this class is reachable by any JavaScript
 * on the page, so there is nothing here worth abusing.
 */
public class Bridge {

    private final MainActivity act;

    Bridge(MainActivity a) {
        this.act = a;
    }

    @JavascriptInterface
    public void postMessage(String json) {
        act.onConsoleEvent(json);
    }
}
