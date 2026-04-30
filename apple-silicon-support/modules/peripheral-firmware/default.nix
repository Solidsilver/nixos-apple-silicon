{
  config,
  pkgs,
  lib,
  ...
}:
{
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

    hardware.firmware =
      let
        pkgs' = config.hardware.asahi.pkgs;
        firmwareDir = config.hardware.asahi.peripheralFirmwareDirectory;
        extract = config.hardware.asahi.extractPeripheralFirmware;

        # Eval-time extraction package (opt-in, for declarative/offline management)
        evalTimePkg = pkgs.stdenv.mkDerivation {
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
        };

        # Boot-time runtime symlink package (default)
        runtimePkg = pkgs.runCommand "asahi-firmware-runtime" {} ''
          mkdir -p $out/lib/firmware
          ln -s /run/asahi-firmware $out/lib/firmware/updates
        '';
      in
      lib.mkMerge [
        (lib.mkIf (extract && firmwareDir != null) [ evalTimePkg ])
        (lib.mkIf (!extract) [ runtimePkg ])
      ];

    # Boot-time extraction service: mounts ESP and extracts vendorfw before modules load
    systemd.services.asahi-firmware-extract = lib.mkIf (!config.hardware.asahi.extractPeripheralFirmware) {
      description = "Extract Asahi peripheral firmware from ESP";
      wantedBy = [ "systemd-modules-load.service" ];
      before = [ "systemd-modules-load.service" "systemd-udevd.service" ];
      after = [ "systemd-journald.socket" ];
      unitConfig = {
        DefaultDependencies = false;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "asahi-firmware-extract" ''
          mkdir -p /run/asahi-firmware
          esp_partuuid=$(cat /proc/device-tree/chosen/asahi,efi-system-partition 2>/dev/null || true)
          if [ -n "$esp_partuuid" ]; then
            mkdir -p /tmp/asahi-esp
            if mount /dev/disk/by-partuuid/"$esp_partuuid" /tmp/asahi-esp 2>/dev/null; then
              if [ -f /tmp/asahi-esp/vendorfw/firmware.cpio ]; then
                echo "Extracting Asahi firmware from ESP..."
                ${pkgs.cpio}/bin/cpio -id --quiet --no-absolute-filenames -D /run/asahi-firmware < /tmp/asahi-esp/vendorfw/firmware.cpio
              fi
              umount /tmp/asahi-esp 2>/dev/null || true
            fi
            rmdir /tmp/asahi-esp 2>/dev/null || true
          fi
        '';
      };
    };
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
