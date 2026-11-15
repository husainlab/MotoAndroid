#!/usr/bin/env bash
# ==============================================================================
# MotoCockpit OS Image Reshaper
# Transforms official LineageOS into a Dedicated Motorcycle Cockpit Appliance
# Target: Motorola Moto G52 (rhode)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKDIR="${ROOT_DIR}/build_workdir"
OUTDIR="${ROOT_DIR}/out"

LINEAGE_API_URL="https://download.lineageos.org/api/v2/devices/rhode/builds"
COCKPIT_RELEASE_URL="https://github.com/husainlab/MotoAndroid/releases/latest/download/Cockpit-release.apk"
COCKPIT_FALLBACK_URL="https://github.com/husainlab/MotoAndroid/releases/download/app-v1.0.11/Cockpit-release.apk"

echo "========================================================"
echo "    MotoCockpit OS - ROM Reshaping Pipeline Starting    "
echo "========================================================"

mkdir -p "${WORKDIR}" "${OUTDIR}"
cd "${WORKDIR}"

# ------------------------------------------------------------------------------
# 1. Fetch Latest LineageOS Build for rhode
# ------------------------------------------------------------------------------
echo "[-] Fetching LineageOS rhode builds metadata..."
BUILDS_JSON=$(curl -sL "${LINEAGE_API_URL}")
LATEST_ZIP_URL=$(echo "${BUILDS_JSON}" | grep -o 'https://mirrorbits.lineageos.org/full/rhode/[^"]*\.zip' | head -n 1)

if [[ -z "${LATEST_ZIP_URL}" ]]; then
    echo "[!] Error: Unable to resolve latest LineageOS build from API."
    exit 1
fi

ZIP_FILENAME=$(basename "${LATEST_ZIP_URL}")
echo "[+] Latest LineageOS zip: ${ZIP_FILENAME}"

if [[ ! -f "${ZIP_FILENAME}" ]]; then
    echo "[-] Downloading ${LATEST_ZIP_URL}..."
    curl -L -C - -o "${ZIP_FILENAME}" "${LATEST_ZIP_URL}"
else
    echo "[+] Using cached ${ZIP_FILENAME}"
fi

# ------------------------------------------------------------------------------
# 2. Extract payload.bin
# ------------------------------------------------------------------------------
echo "[-] Extracting payload.bin from ${ZIP_FILENAME}..."
unzip -p "${ZIP_FILENAME}" payload.bin > payload.bin

echo "[-] Extracting partition images via payload-dumper-go..."
if ! command -v payload-dumper-go &> /dev/null; then
    echo "[-] Installing payload-dumper-go..."
    curl -sL "https://github.com/ssut/payload-dumper-go/releases/download/2.1.0/payload-dumper-go_2.1.0_linux_amd64.tar.gz" | sudo tar -xz -C /usr/local/bin
fi

payload-dumper-go -o extracted_images payload.bin

# ------------------------------------------------------------------------------
# 3. Resolve Cockpit Receiver APK (Local or Remote)
# ------------------------------------------------------------------------------
echo "[-] Resolving Cockpit Receiver APK..."
mkdir -p "${WORKDIR}/prebuilt"

if [[ -f "${WORKDIR}/prebuilt/Cockpit.apk" && -s "${WORKDIR}/prebuilt/Cockpit.apk" ]]; then
    echo "[+] Using existing ${WORKDIR}/prebuilt/Cockpit.apk"
else
    LOCAL_APK=$(find "${ROOT_DIR}/cockpit" -name "*release*.apk" ! -name "*unsigned*" 2>/dev/null | head -n 1 || true)
    if [[ -n "${LOCAL_APK}" && -f "${LOCAL_APK}" ]]; then
        echo "[+] Found local Cockpit APK at ${LOCAL_APK}"
        cp "${LOCAL_APK}" "${WORKDIR}/prebuilt/Cockpit.apk"
    elif curl -sL -f -o "${WORKDIR}/prebuilt/Cockpit.apk" "${COCKPIT_RELEASE_URL}"; then
        echo "[+] Downloaded Cockpit APK from ${COCKPIT_RELEASE_URL}"
    else
        echo "[!] Primary download failed, attempting fallback URL: ${COCKPIT_FALLBACK_URL}..."
        curl -sL -f -o "${WORKDIR}/prebuilt/Cockpit.apk" "${COCKPIT_FALLBACK_URL}" || true
    fi
fi

# Hard validation: The build MUST fail if Cockpit.apk is not present or empty
if [[ ! -f "${WORKDIR}/prebuilt/Cockpit.apk" || ! -s "${WORKDIR}/prebuilt/Cockpit.apk" ]]; then
    echo "[!] CRITICAL FAILURE: Cockpit.apk could not be resolved!"
    echo "[!] Cannot produce MotoCockpit OS without the Cockpit appliance APK."
    exit 1
fi

echo "[+] Confirmed Cockpit APK: size=$(wc -c < "${WORKDIR}/prebuilt/Cockpit.apk") bytes"

# ------------------------------------------------------------------------------
# 4. Modify System, System_Ext & Product Partitions
# ------------------------------------------------------------------------------
echo "[-] Preparing partition modification environment..."

modify_partition() {
    local PART_NAME="$1"
    local IMG_FILE="extracted_images/${PART_NAME}.img"
    local EXTRACT_DIR="${WORKDIR}/${PART_NAME}_dir"

    if [[ ! -f "${IMG_FILE}" ]]; then
        echo "[!] Partition ${IMG_FILE} not found, skipping."
        return 0
    fi

    echo "========================================================"
    echo "[-] Processing partition: ${PART_NAME}..."
    echo "========================================================"
    rm -rf "${EXTRACT_DIR}"
    mkdir -p "${EXTRACT_DIR}"

    # Check filesystem type (EROFS or EXT4)
    local FS_TYPE
    FS_TYPE=$(blkid -o value -s TYPE "${IMG_FILE}" || true)

    if [[ "${FS_TYPE}" == "erofs" ]] || file "${IMG_FILE}" | grep -q "erofs"; then
        echo "[+] Detected EROFS filesystem on ${PART_NAME}."
        if command -v fsck.erofs &>/dev/null; then
            fsck.erofs --extract="${EXTRACT_DIR}" "${IMG_FILE}"
        elif command -v extract.erofs &>/dev/null; then
            extract.erofs -i "${IMG_FILE}" -x "${EXTRACT_DIR}"
        else
            echo "[!] Error: No EROFS extraction tool found."
            exit 1
        fi
        
        # Apply Modifications
        apply_partition_mods "${PART_NAME}" "${EXTRACT_DIR}"

        # Re-pack EROFS
        echo "[-] Repacking ${PART_NAME} as EROFS..."
        rm -f "${IMG_FILE}"
        mkfs.erofs -z lz4hc "${IMG_FILE}" "${EXTRACT_DIR}"
    else
        echo "[+] Detected EXT4 / sparse filesystem on ${PART_NAME}."
        mkdir -p "${WORKDIR}/mnt_${PART_NAME}"
        sudo e2fsck -y -f "${IMG_FILE}" || true
        sudo resize2fs "${IMG_FILE}" 3G || true
        sudo mount -o loop,rw "${IMG_FILE}" "${WORKDIR}/mnt_${PART_NAME}"

        apply_partition_mods "${PART_NAME}" "${WORKDIR}/mnt_${PART_NAME}"

        sudo umount "${WORKDIR}/mnt_${PART_NAME}"
        sudo e2fsck -y -f "${IMG_FILE}" || true
        sudo resize2fs -M "${IMG_FILE}" || true
    fi

    echo "[+] Finished processing partition: ${PART_NAME}."
}

apply_partition_mods() {
    local PART="$1"
    local TARGET_DIR="$2"

    echo "[-] Debloating ${PART} in ${TARGET_DIR}..."
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        local TARGET_NAME
        TARGET_NAME=$(basename "$line" | tr -d '\r')
        [[ -z "$TARGET_NAME" ]] && continue

        # Aggressively remove matching packages across directory tree
        sudo find "${TARGET_DIR}" -maxdepth 5 \( -type d -o -type f \) -iname "${TARGET_NAME}" -exec rm -rf {} + 2>/dev/null || true
        sudo find "${TARGET_DIR}" -maxdepth 5 \( -type d -o -type f \) -iname "${TARGET_NAME}.apk" -exec rm -rf {} + 2>/dev/null || true
    done < "${ROOT_DIR}/config/debloat_blacklist.txt"

    # Aggressive purge of Setup Wizard and Stock Launchers across all partitions
    echo "[-] Purging all SetupWizard, Trebuchet, and Launcher3 traces in ${PART}..."
    sudo find "${TARGET_DIR}" -maxdepth 5 \( -type d -o -type f \) -iname "*SetupWizard*" -exec rm -rf {} + 2>/dev/null || true
    sudo find "${TARGET_DIR}" -maxdepth 5 \( -type d -o -type f \) -iname "*Trebuchet*" -exec rm -rf {} + 2>/dev/null || true
    sudo find "${TARGET_DIR}" -maxdepth 5 \( -type d -o -type f \) -iname "*Launcher3*" -exec rm -rf {} + 2>/dev/null || true

    # Inject Cockpit APK, permissions, and default-permissions into system partition
    if [[ "${PART}" == "system" ]]; then
        echo "[-] Injecting Cockpit Appliance into ${PART} priv-app..."
        local PRIV_DIRS=()
        [[ -d "${TARGET_DIR}/system/priv-app" ]] && PRIV_DIRS+=("${TARGET_DIR}/system/priv-app")
        [[ -d "${TARGET_DIR}/priv-app" ]] && PRIV_DIRS+=("${TARGET_DIR}/priv-app")
        if [[ ${#PRIV_DIRS[@]} -eq 0 ]]; then
            if [[ -d "${TARGET_DIR}/system" ]]; then
                PRIV_DIRS+=("${TARGET_DIR}/system/priv-app")
            else
                PRIV_DIRS+=("${TARGET_DIR}/priv-app")
            fi
        fi

        for PRIV_DIR in "${PRIV_DIRS[@]}"; do
            echo "    -> Injecting into ${PRIV_DIR}/Cockpit/Cockpit.apk"
            sudo mkdir -p "${PRIV_DIR}/Cockpit"
            sudo cp "${WORKDIR}/prebuilt/Cockpit.apk" "${PRIV_DIR}/Cockpit/Cockpit.apk"
            sudo chmod 755 "${PRIV_DIR}/Cockpit"
            sudo chmod 644 "${PRIV_DIR}/Cockpit/Cockpit.apk"
        done

        # Inject Privileged Permissions
        echo "[-] Injecting privapp-permissions-cockpit.xml..."
        local PERM_DIRS=()
        [[ -d "${TARGET_DIR}/system/etc/permissions" ]] && PERM_DIRS+=("${TARGET_DIR}/system/etc/permissions")
        [[ -d "${TARGET_DIR}/etc/permissions" ]] && PERM_DIRS+=("${TARGET_DIR}/etc/permissions")
        if [[ ${#PERM_DIRS[@]} -eq 0 ]]; then
            if [[ -d "${TARGET_DIR}/system" ]]; then
                PERM_DIRS+=("${TARGET_DIR}/system/etc/permissions")
            else
                PERM_DIRS+=("${TARGET_DIR}/etc/permissions")
            fi
        fi

        for PERM_DIR in "${PERM_DIRS[@]}"; do
            echo "    -> Injecting into ${PERM_DIR}/privapp-permissions-cockpit.xml"
            sudo mkdir -p "${PERM_DIR}"
            sudo cp "${ROOT_DIR}/config/privapp-permissions-cockpit.xml" "${PERM_DIR}/privapp-permissions-cockpit.xml"
            sudo chmod 644 "${PERM_DIR}/privapp-permissions-cockpit.xml"
        done

        # Inject Default Permissions (pre-grant location, bluetooth, phone)
        echo "[-] Injecting default-permissions-cockpit.xml..."
        local DEF_PERM_DIRS=()
        [[ -d "${TARGET_DIR}/system/etc/default-permissions" ]] && DEF_PERM_DIRS+=("${TARGET_DIR}/system/etc/default-permissions")
        [[ -d "${TARGET_DIR}/etc/default-permissions" ]] && DEF_PERM_DIRS+=("${TARGET_DIR}/etc/default-permissions")
        if [[ ${#DEF_PERM_DIRS[@]} -eq 0 ]]; then
            if [[ -d "${TARGET_DIR}/system" ]]; then
                DEF_PERM_DIRS+=("${TARGET_DIR}/system/etc/default-permissions")
            else
                DEF_PERM_DIRS+=("${TARGET_DIR}/etc/default-permissions")
            fi
        fi

        for DEF_PERM_DIR in "${DEF_PERM_DIRS[@]}"; do
            echo "    -> Injecting into ${DEF_PERM_DIR}/default-permissions-cockpit.xml"
            sudo mkdir -p "${DEF_PERM_DIR}"
            sudo cp "${ROOT_DIR}/config/default-permissions-cockpit.xml" "${DEF_PERM_DIR}/default-permissions-cockpit.xml"
            sudo chmod 644 "${DEF_PERM_DIR}/default-permissions-cockpit.xml"
        done
    fi

    # Inject cockpit system properties into all build.prop & prop.default files found
    echo "[-] Appending Cockpit properties to build.prop in ${PART}..."
    local PROP_FILES
    PROP_FILES=$(sudo find "${TARGET_DIR}" -type f \( -name "build.prop" -o -name "prop.default" \) 2>/dev/null || true)
    if [[ -n "${PROP_FILES}" ]]; then
        for PROP_FILE in ${PROP_FILES}; do
            echo "    -> Appending cockpit.prop to ${PROP_FILE}"
            sudo cat "${ROOT_DIR}/config/cockpit.prop" | sudo tee -a "${PROP_FILE}" > /dev/null
        done
    fi
}

modify_partition "system"
modify_partition "system_ext"
modify_partition "product"

# ------------------------------------------------------------------------------
# 5. Package Fastboot Cockpit OS Distribution
# ------------------------------------------------------------------------------
echo "[-] Creating Fastboot Cockpit OS Flashable Package..."
PACKAGE_NAME="MotoCockpit-OS-v1.0.0-rhode"
DIST_DIR="${WORKDIR}/${PACKAGE_NAME}"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

cp extracted_images/boot.img "${DIST_DIR}/"
cp extracted_images/dtbo.img "${DIST_DIR}/"
cp extracted_images/vendor_boot.img "${DIST_DIR}/"
cp extracted_images/system.img "${DIST_DIR}/"
cp extracted_images/product.img "${DIST_DIR}/"
cp extracted_images/system_ext.img "${DIST_DIR}/"
cp extracted_images/vendor.img "${DIST_DIR}/"
[[ -f extracted_images/vbmeta.img ]] && cp extracted_images/vbmeta.img "${DIST_DIR}/"

# Write Flash Scripts
cat << 'EOF' > "${DIST_DIR}/flash-all.sh"
#!/usr/bin/env bash
set -e
echo "================================================="
echo "   Flashing MotoCockpit OS to Motorola Moto G52  "
echo "================================================="

# Verify device in bootloader
if ! fastboot devices | grep -q "[a-zA-Z0-9]"; then
    echo "[!] Error: No device detected in fastboot mode."
    echo "[!] Put Moto G52 into bootloader (Hold Volume Down + Power) and connect USB."
    exit 1
fi

echo "[-] Flashing bootloader & kernel images..."
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vendor_boot vendor_boot.img
fastboot flash vbmeta vbmeta.img

echo "[-] Rebooting into userspace fastbootd..."
fastboot reboot fastboot
sleep 5

echo "[-] Flashing dynamic system partitions..."
fastboot flash system system.img
fastboot flash product product.img
fastboot flash system_ext system_ext.img
fastboot flash vendor vendor.img

echo "[-] Wiping userdata for clean appliance launch..."
fastboot -w || true

echo "================================================="
echo "[+] MotoCockpit OS flash complete!"
echo "[+] Rebooting into Cockpit OS..."
echo "================================================="
fastboot reboot
EOF
chmod +x "${DIST_DIR}/flash-all.sh"

cat << 'EOF' > "${DIST_DIR}/flash-all.bat"
@echo off
echo =================================================
echo    Flashing MotoCockpit OS to Motorola Moto G52  
echo =================================================

echo [-] Flashing bootloader & kernel images...
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vendor_boot vendor_boot.img
fastboot flash vbmeta vbmeta.img

echo [-] Rebooting into userspace fastbootd...
fastboot reboot fastboot
timeout /t 5 /nobreak >nul

echo [-] Flashing dynamic system partitions...
fastboot flash system system.img
fastboot flash product product.img
fastboot flash system_ext system_ext.img
fastboot flash vendor vendor.img

echo [-] Wiping userdata for clean appliance launch...
fastboot -w

echo =================================================
echo [+] MotoCockpit OS flash complete!
echo [+] Rebooting into Cockpit OS...
echo =================================================
fastboot reboot
pause
EOF

cd "${WORKDIR}"
rm -f "${OUTDIR}/${PACKAGE_NAME}.zip" "${OUTDIR}/${PACKAGE_NAME}.zip.sha256"
zip -r "${OUTDIR}/${PACKAGE_NAME}.zip" "${PACKAGE_NAME}"

cd "${OUTDIR}"
sha256sum "${PACKAGE_NAME}.zip" > "${PACKAGE_NAME}.zip.sha256"

echo "========================================================"
echo "    MotoCockpit OS Package Created Successfully!        "
echo "    Artifact: ${OUTDIR}/${PACKAGE_NAME}.zip             "
echo "    SHA256:   $(cat "${OUTDIR}/${PACKAGE_NAME}.zip.sha256")"
echo "========================================================"
