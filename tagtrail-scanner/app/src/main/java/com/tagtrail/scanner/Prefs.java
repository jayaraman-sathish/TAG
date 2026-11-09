package com.tagtrail.scanner;

import android.content.Context;
import android.content.SharedPreferences;

/** The two things worth remembering: where the register is, and whether DataWedge has been set up. */
public final class Prefs {

    private static final String FILE = "tagtrail";
    private static final String KEY_URL = "server_url";
    private static final String KEY_DW = "datawedge_configured_for";

    private Prefs() {
    }

    private static SharedPreferences sp(Context c) {
        return c.getApplicationContext().getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    public static String serverUrl(Context c) {
        return sp(c).getString(KEY_URL, "");
    }

    public static void setServerUrl(Context c, String raw) {
        sp(c).edit().putString(KEY_URL, normalise(raw)).apply();
    }

    /**
     * People type "192.168.1.20:5000" and expect it to work, so make it work.
     * Also strips a trailing slash so the URL joins cleanly with /api/health.
     */
    public static String normalise(String raw) {
        if (raw == null) {
            return "";
        }
        String s = raw.trim();
        if (s.isEmpty()) {
            return "";
        }
        if (!s.matches("(?i)^https?://.*")) {
            s = "http://" + s;
        }
        while (s.endsWith("/")) {
            s = s.substring(0, s.length() - 1);
        }
        return s;
    }

    /**
     * DataWedge is configured once per app version, not once ever: a new version of
     * TagTrail may want a different profile, and re-running it on every launch would
     * wipe any power or antenna change made on the device.
     */
    public static boolean dataWedgeNeedsSetup(Context c) {
        return !BuildConfig.VERSION_NAME.equals(sp(c).getString(KEY_DW, ""));
    }

    public static void markDataWedgeConfigured(Context c) {
        sp(c).edit().putString(KEY_DW, BuildConfig.VERSION_NAME).apply();
    }
}
