package com.tagtrail.scanner;

import android.app.Activity;
import android.os.Bundle;
import android.widget.Button;
import android.widget.EditText;
import android.widget.TextView;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;

/**
 * Two things to set and one thing to read. Nothing here is needed once the
 * reader is working, which is the point.
 */
public class SettingsActivity extends Activity {

    private EditText url;
    private TextView status;
    private TextView diag;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        setContentView(R.layout.activity_settings);

        url = findViewById(R.id.url);
        status = findViewById(R.id.status);
        diag = findViewById(R.id.diag);

        url.setText(Prefs.serverUrl(this));

        ((Button) findViewById(R.id.btnTest)).setOnClickListener(v -> test());
        ((Button) findViewById(R.id.btnSave)).setOnClickListener(v -> {
            Prefs.setServerUrl(this, url.getText().toString());
            finish();
        });
        ((Button) findViewById(R.id.btnDataWedge)).setOnClickListener(v -> {
            DataWedge.configure(this);
            Prefs.markDataWedgeConfigured(this);
            status.setText("Asked DataWedge to set itself up. Pull the trigger and watch below.");
            showDiagnostics();
        });
        ((Button) findViewById(R.id.btnClear)).setOnClickListener(v -> {
            ReaderIntent.clearLog();
            showDiagnostics();
        });

        DataWedge.requestVersion(this);
    }

    @Override
    protected void onResume() {
        super.onResume();
        showDiagnostics();
    }

    private void showDiagnostics() {
        String log = ReaderIntent.log();
        diag.setText(log.isEmpty() ? getString(R.string.diag_empty) : log);
    }

    /** Ask the register whether it is there, and which console it is serving. */
    private void test() {
        final String base = Prefs.normalise(url.getText().toString());
        if (base.isEmpty()) {
            status.setText("Type an address first.");
            return;
        }
        status.setText("Asking " + base + " ...");
        new Thread(() -> {
            String answer;
            try {
                HttpURLConnection c = (HttpURLConnection) new URL(base + "/api/health").openConnection();
                c.setConnectTimeout(6000);
                c.setReadTimeout(6000);
                c.setRequestMethod("GET");
                int code = c.getResponseCode();
                StringBuilder body = new StringBuilder();
                try (BufferedReader r = new BufferedReader(
                        new InputStreamReader(code < 400 ? c.getInputStream() : c.getErrorStream()))) {
                    String line;
                    while ((line = r.readLine()) != null) {
                        body.append(line);
                    }
                }
                c.disconnect();

                if (code >= 400) {
                    answer = "The register answered " + code + ".";
                } else {
                    answer = "The register is there.";
                    try {
                        JSONObject j = new JSONObject(body.toString());
                        String built = j.optString("consoleBuilt", "");
                        if (!built.isEmpty()) {
                            answer += "\nConsole build: " + built;
                        }
                    } catch (Exception ignored) {
                        // Reached it, could not read the body. Still good news.
                    }
                }
            } catch (Exception e) {
                answer = "No answer from " + base + ".\n" + e
                        + "\n\nCheck the reader is on the same wifi or hotspot as the laptop,"
                        + " and that the laptop firewall is letting port 5000 through.";
            }
            final String shown = answer;
            runOnUiThread(() -> status.setText(shown));
        }).start();
    }
}
