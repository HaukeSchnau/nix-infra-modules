{ ... }:
{
  config.colors.editors = {
    neovim = {
      activeScheme = "carbonfox";
      fallbackSchemes = [
        "tokyonight"
        "habamax"
      ];
    };
    vscode = {
      preferredDark = "Catppuccin Mocha";
      preferredLight = "Catppuccin Mocha";
    };
  };

  config.colors.fzf = {
    scheme = "history";
  };
}
