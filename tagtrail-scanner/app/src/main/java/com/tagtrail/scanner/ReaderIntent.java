package com.tagtrail.scanner;

import android.content.Intent;
import android.os.Bundle;
import android.os.Parcelable;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Date;
import java.util.Deque;
import java.util.List;
import java.util.Locale;

/**
 * Turns a DataWedge broadcast into tags.
 *
 * This class is deliberately suspicious of its input. Zebra has shipped more than
 * one shape of RFID intent across DataWedge versions, and this was written without
 * the reader in hand, so it tries the shapes it knows, then falls back to looking
 * for anything that resembles an EPC, and records whatever it saw either way.
 * If tags are not reaching the screen, the recording is the answer.
 */
public final class ReaderIntent {

    private static final String TAG = "TagTrail/Intent";

    /** Keys that have carried an array of per-tag bundles. */
    private static final String[] TAG_ARRAY_KEYS = {
            "com.symbol.datawedge.rfid_tag_data",
            "com.symbol.datawedge.rfid.tag_data",
            "com.symbol.datawedge.rfid_tag_list",
            "rfid_tag_data"
    };

    private ReaderIntent() {
    }

    /** One tag sighting. Matches what the console's feed() expects. */
    public static final class Tag {
        public final String epc;
        public final Integer rssi;
        public final Integer count;

        Tag(String epc, Integer rssi, Integer count) {
            this.epc = epc;
            this.rssi = rssi;
            this.count = count;
        }
    }

    /** What arrived: tags, or a barcode, or neither. */
    public static final class Scan {
        public final List<Tag> tags = new ArrayList<>();
        public String barcode;
        public String labelType;

        public boolean isEmpty() {
            return tags.isEmpty() && (barcode == null || barcode.isEmpty());
        }
    }

    public static Scan parse(Intent intent) {
        Scan scan = new Scan();
        if (intent == null) {
            return scan;
        }
        Bundle extras = intent.getExtras();
        if (extras == null) {
            note("intent with no extras at all");
            return scan;
        }

        scan.labelType = str(extras, "com.symbol.datawedge.label_type");

        // 1. The good case: an array of bundles, one per tag, with RSSI and a seen count.
        for (String key : TAG_ARRAY_KEYS) {
            Parcelable[] arr;
            try {
                arr = extras.getParcelableArray(key);
            } catch (Exception e) {
                continue;
            }
            if (arr == null) {
                continue;
            }
            for (Parcelable p : arr) {
                if (p instanceof Bundle) {
                    Tag t = fromTagBundle((Bundle) p);
                    if (t != null) {
                        scan.tags.add(t);
                    }
                }
            }
            if (!scan.tags.isEmpty()) {
                note(scan.tags.size() + " tag(s) from " + key);
                return scan;
            }
        }

        // 2. A single string. Whether that is an EPC or a barcode depends on the label type.
        String data = str(extras, "com.symbol.datawedge.data_string");
        if (data != null && !data.isEmpty()) {
            boolean isRfid = scan.labelType != null
                    && scan.labelType.toUpperCase(Locale.ROOT).contains("RFID");
            if (isRfid) {
                // Several EPCs can arrive in one string, newline separated.
                for (String line : data.split("[\\r\\n]+")) {
                    String epc = clean(line);
                    if (epc != null) {
                        scan.tags.add(new Tag(epc, null, null));
                    }
                }
                if (!scan.tags.isEmpty()) {
                    note(scan.tags.size() + " tag(s) from data_string");
                    return scan;
                }
            } else {
                scan.barcode = data.trim();
                note("barcode: " + scan.barcode + " (" + scan.labelType + ")");
                return scan;
            }
        }

        // 3. Last resort. Walk everything and take anything that looks like an EPC.
        for (String key : extras.keySet()) {
            if (!key.toLowerCase(Locale.ROOT).matches(".*(tag|epc|rfid).*")) {
                continue;
            }
            Object v = extras.get(key);
            if (v instanceof String) {
                String epc = clean((String) v);
                if (epc != null) {
                    scan.tags.add(new Tag(epc, null, null));
                }
            } else if (v instanceof String[]) {
                for (String s : (String[]) v) {
                    String epc = clean(s);
                    if (epc != null) {
                        scan.tags.add(new Tag(epc, null, null));
                    }
                }
            }
        }
        if (!scan.tags.isEmpty()) {
            note(scan.tags.size() + " tag(s) found by guessing. Worth checking the shape: " + describe(intent));
        }
        return scan;
    }

    private static Tag fromTagBundle(Bundle b) {
        String epc = null;
        Integer rssi = null;
        Integer count = null;

        for (String key : b.keySet()) {
            String k = key.toUpperCase(Locale.ROOT);
            Object v = b.get(key);
            if (v == null) {
                continue;
            }
            if (epc == null && (k.contains("TAG_ID") || k.contains("TAGID") || k.endsWith(".EPC") || k.equals("EPC"))) {
                epc = clean(String.valueOf(v));
            } else if (rssi == null && k.contains("RSSI")) {
                rssi = asInt(v);
            } else if (count == null && (k.contains("SEEN_COUNT") || k.contains("TAG_SEEN") || k.endsWith("COUNT"))) {
                count = asInt(v);
            }
        }
        // Some versions put the EPC in the memory bank data instead.
        if (epc == null) {
            for (String key : b.keySet()) {
                if (key.toUpperCase(Locale.ROOT).contains("MEMORY_BANK")) {
                    epc = clean(String.valueOf(b.get(key)));
                    if (epc != null) {
                        break;
                    }
                }
            }
        }
        return epc == null ? null : new Tag(epc, rssi, count);
    }

    /** An EPC is hex, at least 16 characters of it. Anything else is not a tag. */
    private static String clean(String raw) {
        if (raw == null) {
            return null;
        }
        String s = raw.trim().replace(" ", "").toUpperCase(Locale.ROOT);
        if (s.length() < 16 || s.length() > 128) {
            return null;
        }
        if (!s.matches("[0-9A-F]+")) {
            return null;
        }
        return s;
    }

    private static Integer asInt(Object v) {
        try {
            if (v instanceof Number) {
                return ((Number) v).intValue();
            }
            return Integer.valueOf(String.valueOf(v).trim());
        } catch (Exception e) {
            return null;
        }
    }

    private static String str(Bundle b, String key) {
        try {
            Object v = b.get(key);
            return v == null ? null : String.valueOf(v);
        } catch (Exception e) {
            return null;
        }
    }

    public static String toJson(List<Tag> tags) {
        JSONArray arr = new JSONArray();
        for (Tag t : tags) {
            JSONObject o = new JSONObject();
            try {
                o.put("epc", t.epc);
                if (t.rssi != null) {
                    o.put("rssi", (int) t.rssi);
                }
                if (t.count != null) {
                    o.put("count", (int) t.count);
                }
                arr.put(o);
            } catch (Exception ignored) {
                // A malformed tag is not worth losing the sweep over.
            }
        }
        return arr.toString();
    }

    /** Every extra, flattened. This is what you read when nothing is working. */
    public static String describe(Intent intent) {
        if (intent == null) {
            return "(null intent)";
        }
        StringBuilder sb = new StringBuilder();
        sb.append(intent.getAction());
        Bundle ex = intent.getExtras();
        if (ex == null) {
            return sb.append(" (no extras)").toString();
        }
        for (String key : ex.keySet()) {
            Object v;
            try {
                v = ex.get(key);
            } catch (Exception e) {
                v = "(unreadable)";
            }
            sb.append("\n  ").append(key).append(" = ");
            if (v instanceof Parcelable[]) {
                Parcelable[] arr = (Parcelable[]) v;
                sb.append("[").append(arr.length).append("]");
                for (Parcelable p : arr) {
                    if (p instanceof Bundle) {
                        Bundle b = (Bundle) p;
                        for (String bk : b.keySet()) {
                            sb.append("\n      ").append(bk).append(" = ").append(b.get(bk));
                        }
                        sb.append("\n      --");
                    }
                }
            } else if (v instanceof String[]) {
                sb.append(java.util.Arrays.toString((String[]) v));
            } else {
                sb.append(v);
            }
        }
        return sb.toString();
    }

    // ---- the recording -------------------------------------------------------

    private static final int KEEP = 40;
    private static final Deque<String> LOG = new ArrayDeque<>();
    private static final SimpleDateFormat STAMP = new SimpleDateFormat("HH:mm:ss", Locale.UK);

    public static synchronized void note(String line) {
        Log.i(TAG, line);
        LOG.addFirst(STAMP.format(new Date()) + "  " + line);
        while (LOG.size() > KEEP) {
            LOG.removeLast();
        }
    }

    public static synchronized String log() {
        if (LOG.isEmpty()) {
            return "";
        }
        StringBuilder sb = new StringBuilder();
        for (String s : LOG) {
            sb.append(s).append("\n");
        }
        return sb.toString();
    }

    public static synchronized void clearLog() {
        LOG.clear();
    }
}
