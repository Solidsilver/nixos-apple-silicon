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
      in
      lib.mkIf
        (
          (config.hardware.asahi.peripheralFirmwareDirectory != null)
          && config.hardware.asahi.extractPeripheralFirmware
        )
        [
          (pkgs.stdenv.mkDerivation {
            name = "asahi-peripheral-firmware";

            nativeBuildInputs = [
              pkgs.cpio
            ];

            buildCommand = ''
              mkdir -p $out/lib/firmware
              cat ${config.hardware.asahi.peripheralFirmwareDirectory}/firmware.cpio | cpio -id --quiet --no-absolute-filenames
              mv vendorfw/* $out/lib/firmware
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

      default = lib.findFirst (path: builtins.pathExists (path + "/firmware.cpio")) null [
        # path when the system is operating normally
        /boot/vendorfw
        # path when the system is mounted in the installer
        /mnt/boot/vendorfw
      ];

      description = ''
        Path to the directory containing the non-free non-redistributable
        peripheral firmware necessary for features like Wi-Fi. Ordinarily, this
        will automatically point to the appropriate location on the ESP. Flake
        users and those interested in maximum purity will want to copy those
        files elsewhere and specify this manually.

        The official Asahi Linux installer places these files
        in the `vendorfw` directory of the EFI system partition after extracting them.
      '';
    };
  };
}
