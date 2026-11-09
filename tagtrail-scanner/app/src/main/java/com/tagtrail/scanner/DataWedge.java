package com.tagtrail.scanner;

import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

/**
 * Everything this app says to DataWedge.
 *
 * DataWedge is Zebra's own app, already on the device. It owns the RFID radio and
 * the imager. We never talk to the radio ourselves; we ask DataWedge to send us
 * what it reads, as a broadcast. That is the whole integration.
 *
 * The profile below is created by the app on first run so that nobody has to
 * configure DataWedge by hand before a demo. If Zebra renames a parameter in a
 * future DataWedge version the setup will fail quietly on that one parameter --
 * that is what the "What the reader last sent" screen is for, because DataWedge
 * reports the outcome of every call back to us and we record it.
 */
public final class DataWedge {

    private static final String TAG = "TagTrail/DW";

    /** DataWedge's own API entry point. */
    private static final String DW_ACTION = "com.symbol.datawedge.api.ACTION";
    private static final String DW_PACKAGE = "com.symbol.datawedge";

    /** The action DataWedge will broadcast tag data to. Ours, not Zebra's. */
    public static final String ACTION_SCAN = "com.tagtrail.scanner.RFID_SCAN";

    /** Where DataWedge replies when we ask it to do something. */
    public static final String ACTION_RESULT = "com.symbol.datawedge.api.RESULT_ACTION";

    private static final String PROFILE = "TagTrail";

    private DataWedge() {
    }

    public static void configureOnce(Context c) {
        if (Prefs.dataWedgeNeedsSetup(c)) {
            configure(c);
            Prefs.markDataWedgeConfigured(c);
        }
    }

    /** Create the TagTrail profile and point it at this app. */
    public static void configure(Context c) {
        Intent create = api();
        create.putExtra("com.symbol.datawedge.api.CREATE_PROFILE", PROFILE);
        send(c, create);

        Bundle profile = new Bundle();
        profile.putString("PROFILE_NAME", PROFILE);
        profile.putString("PROFILE_ENABLED", "true");
        // OVERWRITE so pressing "set up again" really does put things back.
        profile.putString("CONFIG_MODE", "OVERWRITE");

        Bundle app = new Bundle();
        app.putString("PACKAGE_NAME", c.getPackageName());
        app.putStringArray("ACTIVITY_LIST", new String[]{"*"});
        profile.putParcelableArray("APP_LIST", new Bundle[]{app});

        profile.putParcelableArray("PLUGIN_CONFIG", new Bundle[]{
                rfidPlugin(), barcodePlugin(), intentPlugin(), keystrokePlugin()
        });

        Intent set = api();
        set.putExtra("com.symbol.datawedge.api.SET_CONFIG", profile);
        set.putExtra("SEND_RESULT", "LAST_RESULT");
        set.putExtra("COMMAND_IDENTIFIER", "TAGTRAIL_SET_CONFIG");
        send(c, set);

        ReaderIntent.note("asked DataWedge to create the TagTrail profile");
    }

    private static Bundle rfidPlugin() {
        Bundle params = new Bundle();
        params.putString("rfid_input_enabled", "true");
        params.putString("rfid_beeper_enable", "true");
        params.putString("rfid_led_enable", "true");
        // The grip trigger should start and stop the sweep, not the screen.
        params.putString("rfid_hardware_trigger_enabled", "true");
        params.putString("rfid_trigger_mode", "IMMEDIATE");
        params.putString("rfid_memory_bank", "MEMORY_BANK_NONE");
        // Session 1 so a tag reports again after it has left and come back.
        params.putString("rfid_session", "SESSION_S1");
        // We want repeat sightings: the console counts how many times it saw a tag
        // and uses that to tell a tag in the room from one bleeding through a wall.
        params.putString("rfid_filter_duplicate_tags", "false");
        params.putString("rfid_report_unique_tags", "false");
        params.putString("rfid_antenna_transmit_power", "27");
        params.putString("rfid_link_profile", "AUTO");
        params.putString("rfid_pre_filter_enabled", "false");

        Bundle p = new Bundle();
        p.putString("PLUGIN_NAME", "RFID");
        p.putString("RESET_CONFIG", "true");
        p.putBundle("PARAM_LIST", params);
        return p;
    }

    private static Bundle barcodePlugin() {
        Bundle params = new Bundle();
        params.putString("scanner_selection", "auto");
        params.putString("scanner_input_enabled", "true");
        params.putString("decoder_code128", "true");
        params.putString("decoder_code39", "true");
        params.putString("decoder_ean13", "true");
        params.putString("decoder_qrcode", "true");
        params.putString("decoder_datamatrix", "true");

        Bundle p = new Bundle();
        p.putString("PLUGIN_NAME", "BARCODE");
        p.putString("RESET_CONFIG", "true");
        p.putBundle("PARAM_LIST", params);
        return p;
    }

    private static Bundle intentPlugin() {
        Bundle params = new Bundle();
        params.putString("intent_output_enabled", "true");
        params.putString("intent_action", ACTION_SCAN);
        params.putString("intent_category", "android.intent.category.DEFAULT");
        // 2 = broadcast. 0 would start an activity and 1 would start a service,
        // both of which would fight the WebView for the foreground.
        params.putString("intent_delivery", "2");

        Bundle p = new Bundle();
        p.putString("PLUGIN_NAME", "INTENT");
        p.putString("RESET_CONFIG", "true");
        p.putBundle("PARAM_LIST", params);
        return p;
    }

    /**
     * Keyboard output off. This is the important one. With it on, DataWedge types
     * each EPC as keystrokes with a 50ms gap per character -- about one tag a
     * second, which is useless for a room with three hundred tags in it.
     */
    private static Bundle keystrokePlugin() {
        Bundle params = new Bundle();
        params.putString("keystroke_output_enabled", "false");

        Bundle p = new Bundle();
        p.putString("PLUGIN_NAME", "KEYSTROKE");
        p.putString("RESET_CONFIG", "true");
        p.putBundle("PARAM_LIST", params);
        return p;
    }

    /** Start or stop a sweep from the screen, for readers whose grip trigger is not wired. */
    public static void softRfidTrigger(Context c, boolean start) {
        Intent i = api();
        i.putExtra("com.symbol.datawedge.api.SOFT_RFID_TRIGGER",
                start ? "START_SCANNING" : "STOP_SCANNING");
        send(c, i);
    }

    /** One barcode or QR read. */
    public static void softScanTrigger(Context c) {
        Intent i = api();
        i.putExtra("com.symbol.datawedge.api.SOFT_SCAN_TRIGGER", "TOGGLE_SCANNING");
        send(c, i);
    }

    /** Antenna power, in dBm. Lower it in a tight room so tags next door stay quiet. */
    public static void setPower(Context c, int dbm) {
        if (dbm < 5) {
            dbm = 5;
        }
        if (dbm > 30) {
            dbm = 30;
        }
        Bundle params = new Bundle();
        params.putString("rfid_antenna_transmit_power", String.valueOf(dbm));

        Bundle plugin = new Bundle();
        plugin.putString("PLUGIN_NAME", "RFID");
        plugin.putString("RESET_CONFIG", "false");
        plugin.putBundle("PARAM_LIST", params);

        Bundle profile = new Bundle();
        profile.putString("PROFILE_NAME", PROFILE);
        profile.putString("PROFILE_ENABLED", "true");
        profile.putString("CONFIG_MODE", "UPDATE");
        profile.putBundle("PLUGIN_CONFIG", plugin);

        Intent i = api();
        i.putExtra("com.symbol.datawedge.api.SET_CONFIG", profile);
        i.putExtra("SEND_RESULT", "LAST_RESULT");
        i.putExtra("COMMAND_IDENTIFIER", "TAGTRAIL_POWER");
        send(c, i);
        ReaderIntent.note("asked for " + dbm + " dBm");
    }

    /** Ask DataWedge which version it is, so the setup screen can say. */
    public static void requestVersion(Context c) {
        Intent i = api();
        i.putExtra("com.symbol.datawedge.api.GET_VERSION_INFO", "");
        send(c, i);
    }

    /**
     * On most MC3300 series readers the grip trigger is handled by DataWedge and
     * never reaches us. Where it has been mapped to a key instead, these are the
     * codes it tends to arrive as. Harmless if none of them ever fire.
     */
    public static boolean isTriggerKey(int code) {
        return code == 102 || code == 103 || code == 280 || code == 281
                || code == 10036 || code == 10037;
    }

    private static Intent api() {
        Intent i = new Intent();
        i.setAction(DW_ACTION);
        i.setPackage(DW_PACKAGE);
        return i;
    }

    private static void send(Context c, Intent i) {
        try {
            c.sendBroadcast(i);
        } catch (Exception e) {
            Log.w(TAG, "DataWedge did not take that", e);
            ReaderIntent.note("DataWedge refused a call: " + e);
        }
    }
}
