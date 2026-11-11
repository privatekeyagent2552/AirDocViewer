# VAPT Defense Letter — Cryptographic Failure (Low)

**To:** Security Assessment / VAPT Team  
**From:** Dte of Crypto Sys Dev  
**App:** AirDoc Viewer (`com.airdocsviewer`)  
**Date:** August 2026  
**Subject:** Response to Finding — Cryptographic Failure (Low)

---

Dear Assessors,

We have reviewed the Low finding “Cryptographic Failure” based on JADX static analysis of the release APK (observations such as `AES/CBC/PKCS5Padding`, `AES/ECB/NoPadding`, and `MD5`).

---

## What AirDoc Viewer is (our actual use)

AirDoc Viewer is an **offline document viewer** for Android. It is **not** a file locker, banking app, messaging app, or cloud sync product.

**What the app does:**

- User picks or opens a document from the device (file picker / system “Open with”)
- App **reads and displays** the file locally (PDF, Word, Excel, PowerPoint, CSV, TXT)
- Files are stored in **private app storage** under `Android/data/com.airdocsviewer/`
- User can browse, search, and view — **view only**, no editing or re-encryption by our code

**What the app does not do:**

- Does **not** encrypt user documents before saving them
- Does **not** store user passwords, tokens, or payment data with AES/MD5
- Does **not** send user files to any server (release build has **no INTERNET permission** — removed in manifest)
- Does **not** accept arbitrary file types — only a **strict allowlist** (pdf, doc, docx, ppt, pptx, xls, xlsx, csv, txt); executables, scripts, and other types are blocked

So the flagged crypto is **not** “our app protecting user data with weak algorithms.” It is **library code to open documents that were already encrypted by someone else** (e.g. password-protected PDF from Adobe/Word).

---

## Why JADX shows crypto (not our source code)

**This is not an AirDoc Viewer application cryptographic defect.** The flagged algorithm names and methods (for example `createCipher`, `validatePerms(PDEncryption, …)`) are inside **third-party document libraries** bundled in the APK, not in our Kotlin/Dart product source (`com.airdocsviewer` / `lib/`).

Our code only calls:

- **PDF:** `PDDocument.load()` + text extraction — `PdfTextExtractor.kt`
- **Office:** Apache POI parsers — `NativeDocumentParser.kt`

We do **not** import or call `Cipher.getInstance`, `MessageDigest`, or PDF encryption classes directly. Repository search of our source shows **zero** matches for AES/CBC, AES/ECB, MD5, or PKCS5Padding in application code.

**When does library crypto actually run?**

- Only when the user opens a **password-protected / encrypted** PDF or protected Office file
- Normal unencrypted PDFs → that crypto path usually **does not run**
- The code still **exists inside the JAR** → JADX still reports it

---

## Libraries involved (and versions)

| Library | Version | Why it is in the app |
|---------|---------|----------------------|
| PDFBox Android | 2.0.27.0 (latest Android port) | PDF text / search |
| Apache POI | 5.2.3 | Excel, Word, PowerPoint parse |
| commons-codec | 1.15 | Pulled with POI |
| Bouncy Castle | 1.72 | Pulled with PDFBox |

Password-protected PDFs follow the **PDF file format** (ISO 32000). PDFBox must decrypt using the **same** algorithms the file was saved with (e.g. older PDFs: MD5 + RC4/AES; newer: SHA-256/384/512 + AES-CBC/ECB). Protected Office files follow the same idea via POI.

---

## Why we cannot “fix” this as a code change

We **cannot** replace library crypto with AES-GCM, ChaCha20-Poly1305, or “SHA-256 only” inside these libraries:

1. **Not our source** — it is decompiled third-party JAR code; we do not maintain it as app modules  
2. **Format lock-in** — encrypted files were created with PDF/Office crypto; changing algorithms breaks opening  
3. **Latest PDFBox-Android still uses AES/CBC/ECB + MD5/SHA for PDF open** — upgrade does not remove the finding  

### Why we cannot recompile / change algorithms inside these JARs

The finding points at **pre-built third-party library JARs** (PDFBox, POI, etc.), not at code we wrote or own. We only **reference** those JARs from Gradle. Solid reasons we cannot patch the algorithms ourselves:

1. **No editable source in our project** — We do not ship or maintain PDFBox/POI as our own modules. We pull binary JARs from the official Maven/Google repositories. There is no library source tree in AirDoc Viewer that we can edit and rebuild as “our” crypto.
2. **Changing the JAR would break real documents** — Password-protected PDFs/Office files already use the algorithms defined by the file format. If we rewrote the library to use AES-GCM or drop MD5, existing encrypted files would **fail to open**. Interoperability requires matching the file, not inventing new crypto.
3. **Forking/patching JARs is not a supported product path** — Manually decompiling, editing, and re-signing third-party JARs would create an unsupported fork (no upstream security updates, high regression risk, and licensing/maintenance burden). That is not how this product is built or maintained.
4. **Static analysis will still flag the same strings** — Even after a library upgrade, PDF open still needs AES-CBC/ECB and legacy digests for older PDF revisions. JADX will keep reporting those algorithm names because they remain **required** inside the library JAR.

**Bottom line:** Assessors are seeing crypto **inside third-party library JARs**. We consume those JARs as dependencies; we do not (and should not) recompile them to change PDF/Office crypto algorithms.

---

## User data and risk (plain language)

| Question | Our answer |
|----------|------------|
| Does the app encrypt user files with AES-ECB/MD5? | **No** |
| When do flagged APIs run? | Only to **open an already-encrypted document** for viewing |
| Where do files stay? | **Private app storage** on the device |
| Are files uploaded to the internet? | **No** (INTERNET permission removed in release manifest) |
| Can user import malware as `.exe`? | **No** — strict file allowlist + content checks |

---

## Requested disposition

We request this Low finding be **accepted / closed as third-party document-format interoperability (residual)**, not as an application cryptographic failure.

**Summary in one sentence:**

> JADX found algorithm strings inside PDFBox/POI libraries required to open password-protected PDF/Office files; AirDoc Viewer does not use those algorithms to encrypt user data, and replacing them would break real documents.

Please contact us if you need call-site maps, library class paths, or JAR locations.

Respectfully,  
**Dte of Crypto Sys Dev**  
AirDoc Viewer (`com.airdocsviewer`)

---

© 2026 Dte of Crypto Sys Dev
