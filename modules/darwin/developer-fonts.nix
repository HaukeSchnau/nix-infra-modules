{
  pkgs,
  ...
}:
{
  fonts = {
    packages = with pkgs; [
      nerd-fonts.meslo-lg
      nerd-fonts.intone-mono
      nerd-fonts.fira-code
      nerd-fonts.jetbrains-mono
      nerd-fonts.monaspace
      nerd-fonts.iosevka
      newcomputermodern
    ];
  };
}
