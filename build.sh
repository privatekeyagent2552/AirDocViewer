#!/bin/bash

# Air Docs Viewer — build & run (arm64-only)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    clear
    echo ""
    echo -e "${BLUE}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║${NC}  Air Docs Viewer Build Script (arm64-only)                  ${BLUE}${BOLD}║${NC}"
    echo -e "${BLUE}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() { echo -e "\n${CYAN}${BOLD}▶ $1${NC}"; }

run_release_build() {
    print_section "Building release APK"
    flutter build apk --release --split-per-abi --target-platform android-arm64
    echo -e "${GREEN}✓ APK: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk${NC}"
}

run_debug_build() {
    print_section "Building debug APK"
    flutter build apk --debug --split-per-abi --target-platform android-arm64
    echo -e "${GREEN}✓ APK: build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk${NC}"
}

run_dev() {
    print_section "Running debug (hot reload)"
    flutter run
}

install_release() {
    run_release_build
    adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
}

uninstall_app() {
    print_section "Uninstalling com.airdocsviewer"
    adb uninstall com.airdocsviewer || true
}

while true; do
    print_header
    echo -e "${GREEN}${BOLD}BUILD${NC}"
    echo "  1) Build & install release"
    echo "  2) Build release only"
    echo ""
    echo -e "${YELLOW}${BOLD}DEVELOPMENT${NC}"
    echo "  3) flutter run (debug + hot reload)"
    echo "  4) Build debug APK only"
    echo ""
    echo -e "${RED}${BOLD}MANAGE${NC}"
    echo "  5) Uninstall app"
    echo "  q) Exit"
    echo ""
    read -rp "Choice: " choice
    case "$choice" in
        1) install_release ;;
        2) run_release_build ;;
        3) run_dev ;;
        4) run_debug_build ;;
        5) uninstall_app ;;
        q|Q) exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    read -rp "Press Enter to continue..."
done
