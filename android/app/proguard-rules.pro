# ProGuard rules for Air Docs Viewer - R8 Minification with Selective Keeps

# ── CRITICAL: Keep reflective entrypoints used from MainActivity ──
-keep class com.airdocsviewer.NativeDocumentParser { *; }
-keep class com.airdocsviewer.PdfTextExtractor { *; }

# ── CRITICAL: Apache POI / XMLBeans / OOXML schemas (reflection-heavy) ──
# These must be kept unobfuscated because POI uses reflection to load schemas
# and XMLBeans uses ServiceLoader to discover type systems
-keep class org.apache.poi.** { *; }
-keep class org.apache.poi.hslf.extractor.** { *; }
-keep class org.apache.poi.xslf.extractor.** { *; }
-keep class org.apache.poi.sl.extractor.** { *; }
-keep class org.apache.poi.openxml4j.opc.** { *; }
-keep class org.apache.xmlbeans.** { *; }
-keep class org.openxmlformats.schemas.** { *; }
-keep class schemaorg_apache_xmlbeans.** { *; }
-keep class org.apache.poi.schemas.** { *; }

# ── CRITICAL: Logging bootstrap (used by POI IOUtils static initialization) ──
# Log4j uses reflection to load providers and appenders
-keep class org.apache.logging.log4j.** { *; }
-keep class org.apache.logging.slf4j.** { *; }
-keep class org.slf4j.** { *; }

# ── CRITICAL: Commons libs used by POI ──
-keep class org.apache.commons.** { *; }
-keep class com.graphbuilder.** { *; }

# ── CRITICAL: PDFBox (reflection-based) ──
-keep class com.tom_roush.pdfbox.** { *; }

# ── CRITICAL: Flutter / Android embedding ──
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.editing.** { *; }

# ── AGGRESSIVE: Minify everything else ──
# Remove unused code, inline methods, rename classes/methods/fields
-optimizationpasses 5
-allowaccessmodification
-mergeinterfacesaggressively

# ── Release: strip verbose logs (reduces sensitive path leakage) ──
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}

# ── WARNINGS: Suppress known safe warnings ──
-dontwarn org.apache.poi.**
-dontwarn org.apache.xmlbeans.**
-dontwarn org.apache.logging.log4j.**
-dontwarn org.apache.commons.**
-dontwarn org.apache.commons.logging.**
-dontwarn com.graphbuilder.**
-dontwarn com.tom_roush.pdfbox.**
-dontwarn java.awt.**
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.android.FlutterPlayStoreSplitApplication
-dontwarn javax.xml.**
-dontwarn org.w3c.dom.**
-dontwarn org.xml.sax.**
