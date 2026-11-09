package com.tagtrail.scanner;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.Uri;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.webkit.ConsoleMessage;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.TextView;

import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/**
 * The whole app: a WebView showing the TagTrail console, and a receiver that
 * hands DataWedge's tag reads to the console's own feed() function.
 *
 * The console is NOT bundled in here. It is fetched from the server over wifi,
 * so a change to the console reaches every reader on the next refresh and this
 * APK does not need reinstalling.
 */
public class MainActivity extends Activity {

    private static final String LOG = "TagTrail";

    private WebView web;
    private View errorPanel;
    private TextView errorText;

    private boolean pageReady;
    private String loadedUrl = "";
    private final List<String> waiting = new ArrayList<>();
    private BroadcastReceiver reader;

    /** Battery is worth telling the console about: the header shows it mid-sweep. */
    private static final long BATTERY_EVERY_MS = 120000L;
    private final Handler clock = new Handler(Looper.getMainLooper());
    private final Runnable batteryTick = new Runnable() {
        @Override
        public void run() {
            sayStatus();
            clock.postDelayed(this, BATTERY_EVERY_MS);
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        setContentView(R.layout.activity_main);
        // A scanner walking a plant should not have to keep waking the screen.
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        web = findViewById(R.id.web);
        errorPanel = findViewById(R.id.errorPanel);
        errorText = findViewById(R.id.errorText);
        findViewById(R.id.btnRetry).setOnClickListener(v -> load());
        findViewById(R.id.btnSettings).setOnClickListener(v -> openSettings());

        setUpWebView();

        // No address yet means a reader straight out of the box. Ask, then onResume
        // picks it up and loads.
        if (Prefs.serverUrl(this).isEmpty()) {
            openSettings();
        } else {
            load();
        }
    }

    private void setUpWebView() {
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        // The console keeps unsent sweeps in localStorage. Without this they are lost.
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setUseWideViewPort(true);
        s.setLoadWithOverviewMode(false);
        s.setTextZoom(100);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
        s.setUserAgentString(s.getUserAgentString() + " TagTrailScanner/" + BuildConfig.VERSION_NAME);

        if (BuildConfig.DEBUG) {
            // Lets you open chrome://inspect on the laptop and see the console's own console.
            WebView.setWebContentsDebuggingEnabled(true);
        }

        // The name matters: the console looks for window.TagTrailHost.postMessage.
        web.addJavascriptInterface(new Bridge(this), "TagTrailHost");

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest req) {
                // Never leave the register. The console loads nothing from outside,
                // so anything pointing elsewhere is a mistake or worse, and the
                // JavaScript bridge must not be handed to a page we did not serve.
                String here = Uri.parse(Prefs.serverUrl(MainActivity.this)).getHost();
                String there = req.getUrl().getHost();
                return !(there == null || here == null || there.equalsIgnoreCase(here));
            }

            @Override
            public void onPageFinished(WebView v, String url) {
                pageReady = true;
                sayHello();
                flush();
            }

            @Override
            public void onReceivedError(WebView v, WebResourceRequest req, WebResourceError err) {
                if (req != null && req.isForMainFrame()) {
                    showError(err == null ? "no answer" : String.valueOf(err.getDescription()));
                }
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage m) {
                Log.d(LOG, "console: " + m.message() + " (" + m.lineNumber() + ")");
                return true;
            }
        });
    }

    private void load() {
        String url = Prefs.serverUrl(this);
        if (url.isEmpty()) {
            openSettings();
            return;
        }
        DataWedge.configureOnce(this);
        pageReady = false;
        loadedUrl = url;
        errorPanel.setVisibility(View.GONE);
        web.setVisibility(View.VISIBLE);
        web.loadUrl(url);
    }

    private void showError(String why) {
        web.setVisibility(View.GONE);
        errorText.setText(getString(R.string.cannot_reach, Prefs.serverUrl(this), why));
        errorPanel.setVisibility(View.VISIBLE);
    }

    public void openSettings() {
        startActivity(new Intent(this, SettingsActivity.class));
    }

    // ---- the reader ----------------------------------------------------------

    @Override
    protected void onResume() {
        super.onResume();
        web.onResume();
        if (reader == null) {
            reader = new BroadcastReceiver() {
                @Override
                public void onReceive(Context c, Intent i) {
                    handle(i);
                }
            };
            IntentFilter f = new IntentFilter();
            f.addAction(DataWedge.ACTION_SCAN);
            f.addAction(DataWedge.ACTION_RESULT);
            f.addCategory(Intent.CATEGORY_DEFAULT);
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(reader, f, Context.RECEIVER_EXPORTED);
            } else {
                registerReceiver(reader, f);
            }
        }
        // Coming back from the setup screen. Reload only if the address actually changed,
        // so a trip to settings mid-audit does not throw away the page.
        String want = Prefs.serverUrl(this);
        if (!want.isEmpty() && !want.equals(loadedUrl)) {
            load();
        } else {
            sayStatus();
        }
        clock.removeCallbacks(batteryTick);
        clock.postDelayed(batteryTick, BATTERY_EVERY_MS);
    }

    @Override
    protected void onPause() {
        super.onPause();
        web.onPause();
        clock.removeCallbacks(batteryTick);
        if (reader != null) {
            try {
                unregisterReceiver(reader);
            } catch (Exception ignored) {
                // Already gone. Nothing to do.
            }
            reader = null;
        }
    }

    @Override
    protected void onDestroy() {
        // Say goodbye only on the way out, not every time the setup screen opens,
        // so the console does not flash "reader lost" for a trip to settings.
        if (pageReady) {
            try {
                web.evaluateJavascript("window.TagTrail&&window.TagTrail.bye&&window.TagTrail.bye();", null);
            } catch (Exception ignored) {
                // Shutting down anyway.
            }
        }
        clock.removeCallbacks(batteryTick);
        super.onDestroy();
    }

    private void handle(Intent i) {
        if (i == null) {
            return;
        }
        if (DataWedge.ACTION_RESULT.equals(i.getAction())) {
            ReaderIntent.note("DataWedge replied: " + ReaderIntent.describe(i));
            return;
        }
        ReaderIntent.Scan scan = ReaderIntent.parse(i);
        if (!scan.tags.isEmpty()) {
            feedTags(ReaderIntent.toJson(scan.tags));
        } else if (scan.barcode != null && !scan.barcode.isEmpty()) {
            feedBarcode(scan.barcode);
        } else {
            ReaderIntent.note("nothing usable in: " + ReaderIntent.describe(i));
        }
    }

    /** The one contract with the console. */
    private void feedTags(final String json) {
        runOnUiThread(() -> {
            if (!pageReady) {
                synchronized (waiting) {
                    if (waiting.size() < 200) {
                        waiting.add(json);
                    }
                }
                return;
            }
            web.evaluateJavascript(
                    "window.TagTrail&&window.TagTrail.feed&&window.TagTrail.feed(" + json + ");", null);
        });
    }

    /**
     * A barcode or QR read. The console may take it directly; if not, it goes into
     * whatever box has focus, which is what you want on the tagging screen.
     */
    private void feedBarcode(final String text) {
        final String quoted = JSONObject.quote(text);
        runOnUiThread(() -> {
            if (!pageReady) {
                return;
            }
            web.evaluateJavascript(
                    "(function(t){"
                            + " if(window.TagTrail&&window.TagTrail.barcode){window.TagTrail.barcode(t);return;}"
                            + " var el=document.activeElement;"
                            + " if(el&&(el.tagName==='INPUT'||el.tagName==='TEXTAREA')){"
                            + "  el.value=t;"
                            + "  el.dispatchEvent(new Event('input',{bubbles:true}));"
                            + "  el.dispatchEvent(new Event('change',{bubbles:true}));"
                            + " }"
                            + "})(" + quoted + ");", null);
        });
    }

    private void flush() {
        List<String> queued;
        synchronized (waiting) {
            if (waiting.isEmpty()) {
                return;
            }
            queued = new ArrayList<>(waiting);
            waiting.clear();
        }
        for (String json : queued) {
            web.evaluateJavascript(
                    "window.TagTrail&&window.TagTrail.feed&&window.TagTrail.feed(" + json + ");", null);
        }
    }

    // ---- talking to the console ---------------------------------------------

    /** Introduce the reader. The console header then names it instead of saying "Typed in". */
    private void sayHello() {
        JSONObject o = new JSONObject();
        try {
            o.put("device", Build.MANUFACTURER + " " + Build.MODEL);
            o.put("app", "TagTrail Scanner " + BuildConfig.VERSION_NAME);
            int b = batteryPercent();
            if (b >= 0) {
                o.put("battery", b);
            }
        } catch (Exception ignored) {
            // An introduction is not worth failing over.
        }
        web.evaluateJavascript(
                "window.TagTrail&&window.TagTrail.hello&&window.TagTrail.hello(" + o + ");", null);
    }

    /** Same again without the greeting, for the battery reading. */
    private void sayStatus() {
        if (!pageReady) {
            return;
        }
        int b = batteryPercent();
        if (b < 0) {
            return;
        }
        JSONObject o = new JSONObject();
        try {
            o.put("battery", b);
            o.put("device", Build.MANUFACTURER + " " + Build.MODEL);
        } catch (Exception ignored) {
            return;
        }
        web.evaluateJavascript(
                "window.TagTrail&&window.TagTrail.status&&window.TagTrail.status(" + o + ");", null);
    }

    private int batteryPercent() {
        try {
            // A sticky broadcast: no receiver needed, the last value is handed straight back.
            Intent i = registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (i == null) {
                return -1;
            }
            int level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
            int scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, -1);
            if (level < 0 || scale <= 0) {
                return -1;
            }
            return Math.round(level * 100f / scale);
        } catch (Exception e) {
            return -1;
        }
    }

    /**
     * The console's half of the conversation: it tells us when a sweep starts and
     * stops, and what antenna power the settings screen asks for. That is how the
     * power slider in the console reaches the radio -- there is no second place to
     * set it on the device.
     */
    void onConsoleEvent(String json) {
        try {
            JSONObject evt = new JSONObject(json);
            String type = evt.optString("type", "");
            JSONObject data = evt.optJSONObject("data");
            if (data == null) {
                data = new JSONObject();
            }
            ReaderIntent.note("console said: " + type);

            if ("audit_started".equals(type)) {
                JSONObject profile = data.optJSONObject("profile");
                applyProfile(profile == null ? data : profile);
            } else if ("settings".equals(type)) {
                applyProfile(data);
            } else if ("audit_finished".equals(type) || "audit_cancelled".equals(type)) {
                DataWedge.softRfidTrigger(this, false);
            }
        } catch (Exception e) {
            ReaderIntent.note("could not read what the console sent: " + e);
        }
    }

    private void applyProfile(JSONObject p) {
        if (p == null) {
            return;
        }
        int power = p.optInt("power", -1);
        if (power > 0) {
            DataWedge.setPower(this, power);
        }
    }

    // ---- hardware keys -------------------------------------------------------

    @Override
    public boolean onKeyDown(int code, KeyEvent e) {
        if (DataWedge.isTriggerKey(code)) {
            DataWedge.softRfidTrigger(this, true);
            return true;
        }
        return super.onKeyDown(code, e);
    }

    @Override
    public boolean onKeyUp(int code, KeyEvent e) {
        if (DataWedge.isTriggerKey(code)) {
            DataWedge.softRfidTrigger(this, false);
            return true;
        }
        return super.onKeyUp(code, e);
    }

    /**
     * Back never navigates. Half a sweep is easy to lose that way, and the console
     * has its own way back out of a room.
     */
    @Override
    public void onBackPressed() {
        new AlertDialog.Builder(this)
                .setTitle(R.string.menu_title)
                .setItems(new CharSequence[]{
                        getString(R.string.reload),
                        getString(R.string.settings),
                        getString(R.string.exit)
                }, (d, which) -> {
                    if (which == 0) {
                        load();
                    } else if (which == 1) {
                        openSettings();
                    } else {
                        finish();
                    }
                })
                .setNegativeButton(android.R.string.cancel, null)
                .show();
    }
}
