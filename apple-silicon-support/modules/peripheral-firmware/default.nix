{
  config,
  pkgs,
  lib,
  ...
}:

let
  asahiFirmwareExtractScript = pkgs.writeShellScript "asahi-firmware-extract-initrd" ''
    set -u
    mkdir -p /run/asahi-firmware

    esp_partuuid=""
    read -r -d ''' esp_partuuid < /proc/device-tree/chosen/asahi,efi-system-partition 2>/dev/null || true
    if [ -z "$esp_partuuid" ]; then
      echo "Warning: could not determine Asahi ESP partition UUID"
      exit 0
    fi

    esp_dev="/dev/disk/by-partuuid/$esp_partuuid"

    # Wait up to 3 seconds for udev to create the block device symlink
    i=0
    while [ $i -lt 30 ]; do
      if [ -e "$esp_dev" ]; then
        break
      fi
      sleep 0.1
      i=$((i + 1))
    done
    if [ ! -e "$esp_dev" ]; then
      echo "Warning: ESP block device $esp_dev not found, skipping firmware extraction"
      exit 0
    fi

    mkdir -p /tmp/asahi-esp
    if ! mount -t vfat "$esp_dev" /tmp/asahi-esp; then
      echo "Warning: failed to mount ESP, skipping firmware extraction"
      rmdir /tmp/asahi-esp 2>/dev/null || true
      exit 0
    fi

    cleanup() {
      umount /tmp/asahi-esp 2>/dev/null || true
      rmdir /tmp/asahi-esp 2>/dev/null || true
    }
    trap cleanup EXIT

    if [ -f /tmp/asahi-esp/vendorfw/firmware.cpio ]; then
      echo "Extracting Asahi firmware from ESP..."
      mkdir -p /tmp/asahi-fwextract
      pushd /tmp/asahi-fwextract
      ${pkgs.cpio}/bin/cpio -id --quiet --no-absolute-filenames < /tmp/asahi-esp/vendorfw/firmware.cpio
      if [ -d vendorfw ]; then
        mv vendorfw/* /run/asahi-firmware/
        echo "Asahi firmware extracted successfully"
      else
        echo "Warning: firmware archive did not contain vendorfw/ directory"
      fi
      popd
      rm -rf /tmp/asahi-fwextract
      if [ -f /sys/module/firmware_class/parameters/path ]; then
        echo "/run/asahi-firmware" > /sys/module/firmware_class/parameters/path
        echo "Registered /run/asahi-firmware as kernel firmware search path"
      fi
    elif [ -f /tmp/asahi-esp/asahi/all_firmware.tar.gz ]; then
      echo "Warning: legacy all_firmware.tar.gz found on ESP but boot-time extraction only supports vendorfw/firmware.cpio"
    else
      echo "Warning: vendorfw/firmware.cpio not found on ESP"
    fi
    exit 0
  '';
in {
  config = lib.mkIf config.hardware.asahi.enable {
    assertions = lib.mkIf config.hardware.asahi.extractPeripheralFirmware [
      {
        assertion = config.hardware.asahi.peripheralFirmwareDirectory != null;
        message = ''
          Asahi peripheral firmware extraction is enabled but the firmware
          location appears incorrect.
        '';
      }
    ];

    hardware.firmware = lib.mkIf config.hardware.asahi.extractPeripheralFirmware
      (let
        pkgs' = config.hardware.asahi.pkgs;
        firmwareDir = config.hardware.asahi.peripheralFirmwareDirectory;
      in
      lib.mkIf (firmwareDir != null)
        [
          (pkgs.stdenv.mkDerivation {
            name = "asahi-peripheral-firmware";

            nativeBuildInputs = [
              pkgs'.asahi-fwextract
              pkgs.cpio
            ];

            buildCommand = ''
              mkdir -p $out/lib/firmware

              if [ -f ${firmwareDir}/firmware.cpio ]; then
                cpio_src=${firmwareDir}/firmware.cpio

              elif [ -f ${firmwareDir}/all_firmware.tar.gz ]; then
                mkdir extracted
                ${pkgs'.asahi-fwextract}/bin/asahi-fwextract ${firmwareDir} extracted
                cpio_src=extracted/firmware.cpio

              else
                echo "ERROR: No recognized Asahi firmware format found in ${firmwareDir}" >&2
                echo "Expected: firmware.cpio (vendorfw, installer 0.8.0+) or all_firmware.tar.gz (legacy)" >&2
                exit 1
              fi

              cat "$cpio_src" | cpio -id --quiet --no-absolute-filenames
              mv vendorfw/* $out/lib/firmware
            '';
          })
        ]);

    # Add vfat modules to initrd for ESP mounting
    boot.initrd.availableKernelModules = lib.mkIf (!config.hardware.asahi.extractPeripheralFirmware) [
      "vfat"
      "nls_cp437"
      "nls_iso8859-1"
    ];

    # Systemd stage 1 initrd service: mount ESP, extract vendorfw, register firmware path
    boot.initrd.systemd.storePaths = lib.mkIf (!config.hardware.asahi.extractPeripheralFirmware) [
      pkgs.cpio
      asahiFirmwareExtractScript
    ];

    boot.initrd.systemd.services.asahi-firmware-extract = lib.mkIf (!config.hardware.asahi.extractPeripheralFirmware) {
      description = "Extract Asahi peripheral firmware from ESP";
      wantedBy = [ "initrd.target" ];
      after = [ "systemd-udevd.service" ];
      before = [ "systemd-modules-load.service" "initrd-switch-root.target" ];
      unitConfig = {
        DefaultDependencies = false;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = asahiFirmwareExtractScript;
      };
    };

    # NixOS's udev activation script unconditionally overwrites
    # /sys/module/firmware_class/parameters/path with the Nix store
    # combined firmware directory. Re-point it at the initrd-extracted
    # firmware so Wi-Fi/Bluetooth drivers find their blobs.
    system.activationScripts.asahi-firmware-path =
      lib.mkIf (!config.hardware.asahi.extractPeripheralFirmware)
        (lib.stringAfter [ "udevd" ] ''
          if [ -d /run/asahi-firmware ] && [ -e /sys/module/firmware_class/parameters/path ]; then
            echo -n "/run/asahi-firmware" > /sys/module/firmware_class/parameters/path
          fi
        '');
  };

  options.hardware.asahi = {
    extractPeripheralFirmware = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        When enabled, automatically extract the non-free non-redistributable
        Asahi peripheral firmware into the Nix store at evaluation time.

        Enable this if you want declarative/offline firmware management, are
        using flakes with pure evaluation, or need to use the legacy
        <filename>asahi/all_firmware.tar.gz</filename> format.

        The default (disabled) loads firmware from the ESP at boot time, which
        is the recommended approach and matches upstream Fedora Asahi Linux.
      '';
    };

    peripheralFirmwareDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.path;

      default = lib.findFirst
        (path: builtins.pathExists (path + "/all_firmware.tar.gz"))
        null
        [
          # Legacy path when the system is operating normally
          /boot/asahi
          # Legacy path when the system is mounted in the installer
          /mnt/boot/asahi
        ];

      description = ''
        Path to the directory containing the non-free non-redistributable
        peripheral firmware necessary for features like Wi-Fi.

        This option is only used when <option>extractPeripheralFirmware</option>
        is enabled. When boot-time loading is used (the default), firmware is read
        directly from the ESP and this option is ignored.

        For declarative management, copy the firmware files elsewhere and
        specify this path manually.
      '';
    };
  };
}
