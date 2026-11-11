# AirDoc Viewer — App Use & Crypto Context (VAPT)

**App:** AirDoc Viewer (`com.airdocsviewer`)  
**Package:** `com.airdocsviewer`  
**Date:** August 2026  

---

## What AirDoc Viewer is (our actual use)

AirDoc Viewer is an offline document viewer for Android. It is not a file locker, banking app, messaging app, or cloud sync product.

**What the app does:**

- User picks or opens a document from the device (file picker / system “Open with”)
- App reads and displays the file locally (PDF, Word, Excel, PowerPoint, CSV, TXT)
- Files are stored in private app storage under `Android/data/com.airdocsviewer/`
- User can browse, search, and view — view only, no editing or re-encryption by our code

**What the app does not do:**

- Does not encrypt user documents before saving them
- Does not store user passwords, tokens, or payment data with AES/MD5
- Does not send user files to any server (release build has no INTERNET permission)
- Does not accept arbitrary file types — only a strict allowlist (pdf, doc, docx, ppt, pptx, xls, xlsx, csv, txt); executables, scripts, and other types are blocked

So the flagged crypto is not “our app protecting user data with weak algorithms.” It is library code to open documents that were already encrypted by someone else (e.g. password-protected PDF from Adobe/Word).

---

## Defense for assessors — SecurityHandler (JADX reverse)

> `SecurityHandler` is PDFBox’s PDF-standard decrypt/encrypt handler (RC4 / AES-CBC / MD5 per object as required by the file); AirDoc Viewer only uses it indirectly when opening already-encrypted PDFs for viewing.

**JAR / reverse path (what the screenshot shows):**  
`loaded from: pdfbox-android-2.0.27.0-api.jar:com/tom_roush/pdfbox/pdmodel/encryption/SecurityHandler.class`

---

## Password-protected PDFs — which algorithms run?

AirDoc Viewer does not encrypt PDFs with any of our own tools or crypto. Encryption (if any) was already applied when the file was created (e.g. Adobe Acrobat, Microsoft Word, or another PDF tool).

When the user opens a password-protected PDF, the library only decrypts to view, and it must use whatever the file itself requires:

| File was saved with… | Library uses… |
|----------------------|---------------|
| Older PDF encryption (legacy revisions) | Older algorithms (e.g. MD5 + RC4/AES-CBC/ECB as defined by that PDF) |
| Newer PDF encryption (later revisions) | Newer algorithms (e.g. SHA-256/384/512 + AES as defined by that PDF) |

The app does not choose “weak” or “strong” crypto for the user. It follows the document’s own encryption revision. Unencrypted PDFs do not need this path at all.

---

## Why static analysis still flags the same strings

Static analysis will still flag the same strings — even after a library upgrade, PDF open still needs AES-CBC/ECB and legacy digests for older PDF revisions. JADX will keep reporting those algorithm names because they remain required inside the library JAR (to open real-world password-protected files of all ages).

---

© 2026 Dte of Crypto Sys Dev · AirDoc Viewer (`com.airdocsviewer`)
