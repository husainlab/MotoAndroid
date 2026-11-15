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
COCKPIT_RELEASE_URL="https://github.com/husainlab/Cockpit/releases/latest/download/Cockpit-release.apk"
COCKPIT_FALLBACK_URL="https://github.com/husainlab/Bike_Companion_app/releases/latest/download/Cockpit-release.apk"

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
    curl -sL "https://github.com/ssut/payload-dumper-go/releases/download/1.2.2/payload-dumper-go_1.2.2_linux_amd64.tar.gz" | tar -xz -C /usr/local/bin
fi

payload-dumper-go -o extracted_images payload.bin

# ------------------------------------------------------------------------------
# 3. Download Latest Cockpit Receiver APK
# ------------------------------------------------------------------------------
echo "[-] Downloading latest Cockpit Receiver APK..."
mkdir -p "${WORKDIR}/prebuilt"
if ! curl -sL -f -o "${WORKDIR}/prebuilt/Cockpit.apk" "${COCKPIT_RELEASE_URL}"; then
    echo "[!] Primary URL failed, trying fallback URL..."
    curl -sL -f -o "${WORKDIR}/prebuilt/Cockpit.apk" "${COCKPIT_FALLBACK_URL}" || true
fi

if [[ -f "${WORKDIR}/prebuilt/Cockpit.apk" ]]; then
    echo "[+] Cockpit APK size: $(wc -c < "${WORKDIR}/prebuilt/Cockpit.apk") bytes"
fi

# ------------------------------------------------------------------------------
# 4. Modify System & Product Partitions
# ------------------------------------------------------------------------------
echo "[-] Preparing partition modification environment..."
sudo apt-get update -y && sudo apt-get install -y erofs-utils e2fsprogs simg2img img2simg

modify_partition() {
    local PART_NAME="$1"
    local IMG_FILE="extracted_images/${PART_NAME}.img"
    local EXTRACT_DIR="${WORKDIR}/${PART_NAME}_dir"

    if [[ ! -f "${IMG_FILE}" ]]; then
        echo "[!] Partition ${IMG_FILE} not found, skipping."
        return 0
    fi

    echo "[-] Processing partition: ${PART_NAME}..."
    mkdir -p "${EXTRACT_DIR}"

    # Check filesystem type (EROFS or EXT4)
    local FS_TYPE
    FS_TYPE=$(blkid -o value -s TYPE "${IMG_FILE}" || true)

    if [[ "${FS_TYPE}" == "erofs" ]] || file "${IMG_FILE}" | grep -q "erofs"; then
        echo "[+] Detected EROFS filesystem on ${PART_NAME}."
        extract.erofs -i "${IMG_FILE}" -x "${EXTRACT_DIR}"
        
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

    echo "[+] Finished processing ${PART_NAME}."
}

apply_partition_mods() {
    local PART="$1"
    local TARGET_DIR="$2"

    echo "[-] Debloating ${PART}..."
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Ignore comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue

        local APP_PATH="${TARGET_DIR}/${line}"
        if [[ -e "${APP_PATH}" ]]; then
            echo "    [x] Removing ${line}"
            sudo rm -rf "${APP_PATH}"
        fi
    done < "${ROOT_DIR}/config/debloat_blacklist.txt"

    if [[ "${PART}" == "system" ]] && [[ -f "${WORKDIR}/prebuilt/Cockpit.apk" ]]; then
        echo "[-] Injecting Cockpit into /system/priv-app/Cockpit/..."
        sudo mkdir -p "${TARGET_DIR}/system/priv-app/Cockpit"
        sudo cp "${WORKDIR}/prebuilt/Cockpit.apk" "${TARGET_DIR}/system/priv-app/Cockpit/Cockpit.apk"
        sudo chmod 644 "${TARGET_DIR}/system/priv-app/Cockpit/Cockpit.apk"

        echo "[-] Injecting privapp-permissions-cockpit.xml..."
        sudo mkdir -p "${TARGET_DIR}/system/etc/permissions"
        sudo cp "${ROOT_DIR}/config/privapp-permissions-cockpit.xml" "${TARGET_DIR}/system/etc/permissions/privapp-permissions-cockpit.xml"
        sudo chmod 644 "${TARGET_DIR}/system/etc/permissions/privapp-permissions-cockpit.xml"

        echo "[-] Appending Cockpit system properties to build.prop..."
        if [[ -f "${TARGET_DIR}/system/build.prop" ]]; then
            sudo cat "${ROOT_DIR}/config/cockpit.prop" | sudo tee -a "${TARGET_DIR}/system/build.prop" > /dev/null
        fi
    fi

    if [[ "${PART}" == "product" ]]; then
        if [[ -f "${TARGET_DIR}/build.prop" ]]; then
            echo "ro.setupwizard.mode=DISABLED" | sudo tee -a "${TARGET_DIR}/build.prop" > /dev/null
        fi
    fi
}

modify_partition "system"
modify_partition "product"
modify_partition "system_ext"

# ------------------------------------------------------------------------------
# 5. Package Fastboot Cockpit OS Distribution
# ------------------------------------------------------------------------------
echo "[-] Creating Fastboot Cockpit OS Flashable Package..."
PACKAGE_NAME="MotoCockpit-OS-v1.0.0-rhode"
DIST_DIR="${WORKDIR}/${PACKAGE_NAME}"
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
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vendor_boot vendor_boot.img
fastboot flash --disable-verity --disable-verification vbmeta vbmeta.img || true
fastboot reboot fastboot
fastboot flash system system.img
fastboot flash product product.img
fastboot flash system_ext system_ext.img
fastboot flash vendor vendor.img
echo "[+] Flash complete. Wipe userdata if performing first-time install: fastboot -w"
echo "[+] Rebooting to Cockpit OS..."
fastboot reboot
EOF
chmod +x "${DIST_DIR}/flash-all.sh"

cat << 'EOF' > "${DIST_DIR}/flash-all.bat"
@echo off
echo =================================================
echo    Flashing MotoCockpit OS to Motorola Moto G52  
echo =================================================
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash vendor_boot vendor_boot.img
fastboot flash --disable-verity --disable-verification vbmeta vbmeta.img
fastboot reboot fastboot
fastboot flash system system.img
fastboot flash product product.img
fastboot flash system_ext system_ext.img
fastboot flash vendor vendor.img
echo [+] Flash complete. Wipe userdata if performing first-time install: fastboot -w
echo [+] Rebooting to Cockpit OS...
fastboot reboot
pause
EOF

cd "${WORKDIR}"
zip -r "${OUTDIR}/${PACKAGE_NAME}.zip" "${PACKAGE_NAME}"

cd "${OUTDIR}"
sha256sum "${PACKAGE_NAME}.zip" > "${PACKAGE_NAME}.zip.sha256"

echo "========================================================"
echo "    MotoCockpit OS Package Created Successfully!        "
echo "    Artifact: ${OUTDIR}/${PACKAGE_NAME}.zip             "
echo "    SHA256:   $(cat "${OUTDIR}/${PACKAGE_NAME}.zip.sha256")"
echo "========================================================"

