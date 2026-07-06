{ config, ... }:
let
  vercelGhostty = config.colors.terminal.ghosttyThemes.Vercel;
  catppuccinPalettes = config.colors.palettes.catppuccin;
in
{
  config.colors.starship = {
    palette = "vercel";
    palettes = catppuccinPalettes // {
      vercel = {
        teal = vercelGhostty.palette."4";
        peach = vercelGhostty.background;
        sky = vercelGhostty.palette."12";
        sapphire = vercelGhostty.palette."14";
        lavender = vercelGhostty.palette."8";
        crust = vercelGhostty.foreground;
        green = vercelGhostty.palette."2";
        red = vercelGhostty.palette."1";
        yellow = vercelGhostty.palette."3";
      };
    };
  };
}
