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
      in
      lib.mkIf
        (
          (firmwareDir != null)
          && config.hardware.asahi.extractPeripheralFirmware
        )
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
                echo "asahi-peripheral-firmware: using pre-extracted vendorfw format (Asahi installer 0.8.0+)..."
                cat ${firmwareDir}/firmware.cpio | cpio -id --quiet --no-absolute-filenames
                mv vendorfw/* $out/lib/firmware

              elif [ -f ${firmwareDir}/all_firmware.tar.gz ]; then
                echo "asahi-peripheral-firmware: using legacy raw firmware format..."
                mkdir extracted
                ${pkgs'.asahi-fwextract}/bin/asahi-fwextract ${firmwareDir} extracted
                cat extracted/firmware.cpio | cpio -id --quiet --no-absolute-filenames
                mv vendorfw/* $out/lib/firmware

              else
                echo "ERROR: No recognized Asahi firmware format found in ${firmwareDir}" >&2
                echo "Expected: firmware.cpio (vendorfw, installer 0.8.0+) or all_firmware.tar.gz (legacy)" >&2
                exit 1
              fi
            '';
          })
        ];
  };

  options.hardware.asahi = {
    extractPeripheralFirmware = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Automatically extract the non-free non-redistributable peripheral
        firmware necessary for features like Wi-Fi.
      '';
    };

    peripheralFirmwareDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.path;

      default = lib.findFirst
        (path:
          builtins.pathExists (path + "/firmware.cpio") ||
          builtins.pathExists (path + "/all_firmware.tar.gz")
        )
        null
        [
          # pre-extracted vendorfw format (Asahi installer 0.8.0+)
          /boot/vendorfw
          # legacy raw firmware format: normal boot path
          /boot/asahi
          # legacy raw firmware format: installer mount path
          /mnt/boot/asahi
        ];

      description = ''
        Path to the directory containing the non-free non-redistributable
        peripheral firmware necessary for features like Wi-Fi. Ordinarily, this
        will automatically point to the appropriate location on the ESP. Flake
        users and those interested in maximum purity will want to copy those
        files elsewhere and specify this manually.

        Starting with Asahi installer 0.8.0, the firmware is stored on the ESP
        as pre-extracted `firmware.cpio` (and `firmware.tar`) in the `vendorfw`
        directory. Older installations use raw `all_firmware.tar.gz` and
        `kernelcache*` files in the `asahi` directory.
      '';
    };
  };
}
