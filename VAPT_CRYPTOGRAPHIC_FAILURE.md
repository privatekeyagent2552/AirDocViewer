# AirDoc Viewer — VAPT Response  
## Finding: Cryptographic Failure (Low)

**App:** AirDoc Viewer (`com.airdocsviewer`)  
**Developer:** Dte of Crypto Sys Dev  
**Date:** August 2026  
**Severity assessed:** Low  
**Our classification:** Accepted residual / third-party format interoperability — **not an application cryptographic failure**

---

## 1. Executive summary

Static analysis (JADX) of the release APK identified algorithm names such as `AES/CBC/PKCS5Padding`, `AES/ECB/NoPadding`, and `MD5`.

These strings **do not exist in AirDoc Viewer application source** (Kotlin under `com.airdocsviewer` or Dart under `lib/`). They originate from **bundled third-party document libraries** required to open password-protected and legacy **PDF / Microsoft Office** files.

AirDoc Viewer:

- Does **not** encrypt user files, passwords, or secrets with these algorithms  
- Stores documents in **private app storage** only  
- Ships **release builds without network upload** (no `INTERNET` in the main release manifest for this product posture)  
- Uses these libraries only to **view / parse** allowlisted documents  

**Remediation by replacing MD5→SHA-256 or AES-CBC→AES-GCM / ChaCha20-Poly1305 inside these libraries is not valid**, because encrypted documents were created with the **file-format** crypto. Changing it would break opening of real PDFs and Office files.

---

## 2. What the assessor observed (mapping)

| Report observation | Actual location | Role |
|--------------------|-----------------|------|
| `AES/CBC/PKCS5Padding` / `createCipher` | PDFBox `SecurityHandler` | Decrypt AES PDF streams (ISO 32000) |
| `AES/ECB/NoPadding` / `validatePerms(PDEncryption…)` | PDFBox `StandardSecurityHandler` | Validate PDF permissions block |
| `MD5` in key derivation | PDFBox + POI | Legacy PDF / Office key setup |
| `SHA-256` / `SHA-384` / `SHA-512` | PDFBox Rev 5/6 path | Newer PDF password schemes (also present) |
| `MessageDigestAlgorithms.MD5` | commons-codec | Digest name constants pulled with POI |
| Obfuscated `Digest username=…` style hits | Transitive client code (if present in DEX) | Not AirDoc Viewer auth; not user-file crypto |

JADX decompiles **all classes in the APK**, including JARs. ProGuard keeps PDFBox/POI readable:

```
-keep class com.tom_roush.pdfbox.** { *; }
-keep class org.apache.poi.** { *; }
-keep class org.apache.commons.** { *; }
```

That is why original class names like `StandardSecurityHandler` and `PDEncryption` appear in the report.

---

## 3. Proof: not in our application code

Repository search of application sources shows **no**:

- `Cipher.getInstance`
- `AES/CBC`, `AES/ECB`, `PKCS5Padding`
- `MessageDigest.getInstance("MD5")`
- `validatePerms` / `PDEncryption` / `createCipher` as our APIs

### Our only call sites (view / parse)

| Our file | Call | Purpose |
|----------|------|---------|
| `android/.../PdfTextExtractor.kt` | `PDDocument.load(file)` + `PDFTextStripper` | PDF text / search |
| `android/.../AirDocsViewerApplication.kt` | `PDFBoxResourceLoader.init` | Init PDFBox |
| `android/.../MainActivity.kt` | MethodChannel → PdfTextExtractor / NativeDocumentParser | Bridge from Flutter |
| `android/.../NativeDocumentParser.kt` | `WorkbookFactory`, `XWPFDocument`, `HWPFDocument`, PPT extractors | Office parse |

We do **not** call `org.apache.poi.poifs.crypt.*` or `com.tom_roush.pdfbox.pdmodel.encryption.*` directly. Those packages load **inside the library** when an encrypted document is opened.

There are **no native `.h` crypto headers** in this project for this finding. Crypto is Java inside JARs.

---

## 4. Libraries in use (versions)

Declared in `android/app/build.gradle.kts`:

| Library | Version | Purpose |
|---------|---------|---------|
| Apache POI (`poi`, `poi-ooxml`, `poi-ooxml-full`, `poi-scratchpad`) | 5.2.3 | `.xls` `.xlsx` `.csv` `.doc` `.ppt` |
| PDFBox Android (`com.tom-roush:pdfbox-android`) | **2.0.27.0** (latest Android port) | PDF text extraction |
| XMLBeans | 5.1.1 | Required by POI |
| Commons Codec | 1.15 | Required by POI |
| Commons IO | 2.11.0 | Required by POI |
| Commons Logging | 1.2 | Required by POI |
| Bouncy Castle (transitive via PDFBox) | 1.72 | Crypto provider for PDFBox |

**Version note:** PDFBox-Android is current at 2.0.27.0. POI could be upgraded (e.g. toward 5.5.x), but **upgrade does not remove** AES/CBC, AES/ECB, MD5, or RC4, because document formats still require them.

JARs live in the Gradle cache (e.g. under `C:\Users\<user>\.gradle\caches\...`), are compiled into the APK, and are **not** edited as product source under `lib/` or `com.airdocsviewer`.

---

## 5. Why encryption code exists in PDFBox (product behaviour)

AirDoc Viewer does **not** invent PDF encryption.

1. User opens a document (allowlisted types only).  
2. For PDF text, app calls `PDDocument.load(file)`.  
3. If the PDF’s Encrypt dictionary is present (password-protected / encrypted PDF), PDFBox runs `StandardSecurityHandler`.  
4. Algorithms used depend on the PDF **security revision (Rev)** stored **in the file**:

| PDF Rev | Typical crypto used by PDFBox |
|---------|-------------------------------|
| Rev 2–4 (older) | **RC4** + **MD5**; Rev 4 may use **AES** |
| Rev 5 | **AES** + **SHA-256** |
| Rev 6 | **AES** + **SHA-256 / SHA-384 / SHA-512** |

Content decrypt also uses **AES/CBC/PKCS5Padding** (parent `SecurityHandler`) and **AES/ECB/NoPadding** for permissions validation (`validatePerms`).

**Password-protected PDF ⇒ encrypted PDF** (ISO 32000). Decrypt must use the **same** algorithms the file was encrypted with.

Same principle applies to password-protected Office files via Apache POI (`poifs.crypt`).

---

## 6. Why we cannot “fix” this as recommended (AES-GCM / ChaCha / SHA-256 only)

Assessor recommendation (use AES-GCM, ChaCha20-Poly1305, replace MD5 with SHA-256) is correct for **new application-designed crypto**.

It is **not applicable** as a drop-in change to PDFBox/POI:

1. **Not our source** — JADX shows decompiled third-party classes; we do not maintain them as app modules.  
2. **Format lock-in** — ISO 32000 PDF and Microsoft Office encryption specify AES-CBC/ECB, RC4, MD5, and (for newer PDFs) SHA-256/384/512. Forcing GCM/ChaCha breaks opening.  
3. **Same algorithm for encrypt and decrypt** — a file encrypted with MD5+AES-CBC must be decrypted with MD5+AES-CBC.  
4. **Latest PDFBox-Android still has no AES-GCM PDF open path** — still AES/CBC (+ ECB for Perms).  
5. **Libraries contain stronger hashes too** (SHA-256/384/512 for Rev 5/6) — scanners still flag legacy strings required for old documents.  
6. **Forking/recompiling JADX output** is not a safe remediation (incomplete decompilation, thousands of warnings, breaks compatibility).

---

## 7. Risk to user data (honest residual)

| Question | Answer |
|----------|--------|
| Does the app encrypt user data at rest with AES-ECB/MD5? | **No** |
| When do flagged APIs run? | When opening an **already encrypted** PDF/Office file for viewing |
| Are user files uploaded? | **No** (offline / private storage posture) |
| Residual? | Third-party parsers must retain format-compatible crypto; static scanners will continue to see algorithm **names** in the APK |

---

## 8. Formal disposition request

We request this finding be closed or accepted as:

> **Third-party document-format interoperability / informational residual (Low)** — not an AirDoc Viewer application cryptographic implementation defect.

**Mitigations already in product (related security posture):**

- Strict document allowlist (PDF, DOC/DOCX, PPT/PPTX, XLS/XLSX, CSV, TXT only)  
- Magic-byte / content checks against type spoofing  
- Private app storage; no external upload in release  

---

## 9. Copy-ready short paragraph (for email / ticket)

> The JADX “Cryptographic Failure” finding matches algorithm strings inside bundled **PDFBox Android 2.0.27.0** and **Apache POI 5.2.3** (plus commons-codec / Bouncy Castle), not AirDoc Viewer source. These libraries implement ISO 32000 PDF and Microsoft Office password/encryption schemes (AES/CBC, AES/ECB, RC4, MD5 for legacy; SHA-256/384/512 for newer PDF revisions) so encrypted documents can be opened for viewing. Our application only calls document load/parse APIs (`PDDocument.load`, POI workbook/document factories). We do not encrypt user files or secrets with these algorithms. Replacing them with AES-GCM or ChaCha20-Poly1305 would break document compatibility and is not a valid remediation. User files remain in private storage without network upload. We ask that this Low finding be accepted as third-party format interoperability.

---

© 2026 Dte of Crypto Sys Dev
