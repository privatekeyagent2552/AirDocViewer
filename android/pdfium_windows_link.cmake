# Replaces pdfium_flutter's file(CREATE_LINK) for .lib/latest.
# Windows symlink creation needs Developer Mode. A directory junction does not.
# android/build.gradle.kts inserts this include. flutter pub get restores the
# upstream CMakeLists.txt, and the next configure inserts the include again.
if(CMAKE_HOST_WIN32)
  set(_airdocs_pdfium_link_script "${CMAKE_CURRENT_LIST_DIR}/pdfium_windows_lib_link.ps1")
  execute_process(
    COMMAND powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${_airdocs_pdfium_link_script}" -Link "${PDFIUM_LATEST_DIR}" -Target "${PDFIUM_LIBS_DIR}"
    RESULT_VARIABLE _airdocs_pdfium_link_status
    OUTPUT_VARIABLE _airdocs_pdfium_link_out
    ERROR_VARIABLE _airdocs_pdfium_link_err
  )
  if(NOT _airdocs_pdfium_link_status EQUAL 0)
    message(FATAL_ERROR "Could not link or copy PDFium libs to ${PDFIUM_LATEST_DIR} (${_airdocs_pdfium_link_status}): ${_airdocs_pdfium_link_err} ${_airdocs_pdfium_link_out}")
  endif()
else()
  file(REMOVE "${PDFIUM_LATEST_DIR}")
  file(CREATE_LINK "${PDFIUM_LIBS_DIR}" "${PDFIUM_LATEST_DIR}" SYMBOLIC)
endif()
