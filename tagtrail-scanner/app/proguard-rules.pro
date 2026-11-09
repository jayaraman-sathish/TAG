# The JavaScript bridge is called by name from the console's JavaScript,
# so its methods must survive shrinking.
-keepclassmembers class com.tagtrail.scanner.Bridge {
    public *;
}
-keepattributes JavascriptInterface
