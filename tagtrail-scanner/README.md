# TagTrail Scanner — the Zebra MC3330xR wrapper

An Android app that puts the TagTrail console on the handheld and feeds it tag
reads from the RFID radio. About 700 lines of Java, no libraries.

## What it is, and what it is not

It is **not** a copy of TagTrail. The console is fetched from the server over
wifi every time the app opens, exactly as a browser would. So:

* a change to the console reaches every reader on the next refresh,
* this APK is installed once and then left alone,
* a reader with no network shows "Can't reach the register", not a stale copy.

What the app adds to a plain browser is the one thing a browser cannot do: talk
to the RFID radio. It does that through **DataWedge**, Zebra's own app, which is
already on the device.

```
  grip trigger
       |
       v
  DataWedge  (owns the radio and the imager)
       |  broadcast intent, com.tagtrail.scanner.RFID_SCAN
       v
  TagTrail Scanner  (this app)
       |  window.TagTrail.feed([{epc, rssi, count}])
       v
  TagTrail console  (a web page from the server)
       |  window.TagTrailHost.postMessage(json)
       v
  TagTrail Scanner  -> antenna power, stop scanning
```

Both directions already existed in the console. This app is the piece in the
middle.

## Building it

Open the `tagtrail-scanner` folder in Android Studio and press Run. That is the
whole of it — Android Studio fetches Gradle and the Android SDK itself. There
are no dependencies to resolve beyond the Android Gradle plugin.

From a command line, with the SDK already installed:

```
./gradlew assembleDebug
# app/build/outputs/apk/debug/app-debug.apk
```

## Installing it

With the reader on USB and developer options on:

```
adb devices                      # the reader should be listed
adb install -r app-debug.apk
```

`-r` replaces an existing copy and keeps the saved server address.

## First run

1. The app asks for the **address of the register** — the laptop or server
   running TagTrail, e.g. `http://192.168.1.20:5000`. Typing
   `192.168.1.20:5000` is fine; the `http://` is added.
2. Press **Test**. It calls `/api/health` and reports back, including which
   console build the server is serving. If that answers, everything else will
   work.
3. Press **Save and open**.

On that first run the app also creates its own DataWedge profile: RFID input on,
intent output on, **keyboard output off**, the imager on for barcodes and QR. No
one has to configure DataWedge by hand.

Keyboard output being off is the important part. With it on, DataWedge types each
EPC as keystrokes with a 50 ms gap per character — roughly one tag a second,
which is useless in a room with three hundred tags in it.

## Using it

Sign in once, when the reader is issued for the day. Then, in each room:

**Point at the door tag and pull the trigger.** The console opens that area and
starts counting. Sweep the room, press Finish, walk to the next door.

There is nothing to choose and nothing to type, which is the point: the person
holding the reader is often a contractor who was handed it this morning.

A barcode or QR read goes into whichever field on screen is waiting for one, so
the imager works on the tagging screen without any mode switch.

## When it does not work

Everything DataWedge sends is recorded, understood or not. Back button →
**Reader setup** → **What the reader last sent**. That screen is the first place
to look, before anything else.

| What you see | Where to look |
|---|---|
| "Can't reach the register" | Reader and laptop on the same wifi or hotspot. Windows firewall allowing port 5000. The address in setup. |
| Trigger does nothing, setup screen stays empty | DataWedge → Settings → Key Programmer → `GRIP_TRIGGER` → `SYMBOL_RFID`. Then press **Set up DataWedge again**. |
| Tags arrive but the console ignores them | The setup screen will show the intent with its extras. If the tag data is under a key this app does not know, add it to `TAG_ARRAY_KEYS` in `ReaderIntent.java`. |
| Tags from the next room keep appearing | Lower the antenna power in the console's settings. It reaches the radio from there; there is no separate setting on the device. |
| Console header says "Typed in" | The app never introduced itself, which means the page did not finish loading. Reload from the back menu. |

## Things written without the device in hand

This was written before the reader arrived, so three things are informed guesses
rather than verified facts. All three fail visibly, not silently, and all three
are one edit away from being right.

1. **The shape of the RFID intent.** `ReaderIntent.parse()` tries the three
   shapes Zebra has shipped, then falls back to looking for anything that is
   16 or more hex characters, and records what it saw either way.
2. **DataWedge parameter names** in `DataWedge.java`. If Zebra has renamed one,
   that parameter is ignored and DataWedge says so in its reply, which is
   recorded on the setup screen.
3. **Trigger key codes** in `DataWedge.isTriggerKey()`, which only matter if the
   grip trigger is mapped to a key rather than handled by DataWedge.

## The files

| File | What it does |
|---|---|
| `MainActivity.java` | The WebView, the receiver, and both halves of the console conversation |
| `DataWedge.java` | Every intent this app sends to DataWedge, including the profile |
| `ReaderIntent.java` | Turns a broadcast into tags; keeps the recording |
| `Bridge.java` | `window.TagTrailHost.postMessage` — one method |
| `SettingsActivity.java` | Server address, the DataWedge button, the recording |
| `Prefs.java` | The two things worth remembering |

## For production

* `usesCleartextTraffic="true"` in the manifest is there because the register
  runs as plain `http` on the local network. Turn it off once there is a real
  server with a certificate.
* The app is unsigned debug. Sign it before it goes on more than a handful of
  readers, or push it through Zebra's StageNow.
* Honeywell IH40 would be a second reader source feeding the same
  `window.TagTrail.feed`. Nothing in the console changes.
