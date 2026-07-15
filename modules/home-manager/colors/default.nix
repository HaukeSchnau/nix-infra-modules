{ lib, ... }:
let
  inherit (lib) mkOption types;

  colorMapType = types.attrsOf types.str;
  preferenceValueType = types.either types.str (types.listOf types.str);

  ghosttyThemeType = types.submodule {
    options = {
      palette = mkOption {
        type = colorMapType;
        description = "Indexed terminal palette.";
      };

      background = mkOption {
        type = types.str;
        description = "Terminal background color.";
      };

      foreground = mkOption {
        type = types.str;
        description = "Terminal foreground color.";
      };

      cursorColor = mkOption {
        type = types.str;
        description = "Terminal cursor color.";
      };

      cursorText = mkOption {
        type = types.str;
        description = "Text color beneath the terminal cursor.";
      };

      selectionBackground = mkOption {
        type = types.str;
        description = "Terminal selection background color.";
      };

      selectionForeground = mkOption {
        type = types.str;
        description = "Terminal selection foreground color.";
      };
    };
  };
in
{
  options.colors = {
    palettes = mkOption {
      type = types.attrsOf (types.attrsOf colorMapType);
      description = "Named families of color palettes.";
    };

    schemes = mkOption {
      type = types.attrsOf (types.attrsOf preferenceValueType);
      description = "Editor and terminal color schemes with their available variants.";
    };

    terminal = {
      ghosttyTheme = mkOption {
        type = types.str;
        description = "Preferred Ghostty theme.";
      };

      weztermScheme = mkOption {
        type = types.str;
        description = "Preferred WezTerm color scheme.";
      };

      ghosttyThemes = mkOption {
        type = types.attrsOf ghosttyThemeType;
        description = "Ghostty themes keyed by display name.";
      };
    };

    editors = mkOption {
      type = types.attrsOf (types.attrsOf preferenceValueType);
      description = "Editor color preferences keyed by editor and setting.";
    };

    fzf.scheme = mkOption {
      type = types.str;
      description = "Fzf scoring scheme.";
    };

    starship = {
      palette = mkOption {
        type = types.str;
        description = "Active Starship palette.";
      };

      palettes = mkOption {
        type = types.attrsOf colorMapType;
        description = "Starship palettes keyed by name.";
      };
    };
  };

  imports = [
    ./palettes.nix
    ./schemes.nix
    ./terminal.nix
    ./editors.nix
    ./starship.nix
  ];
}
