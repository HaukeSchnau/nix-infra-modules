{
  home-manager,
  pkgs,
  self,
  ...
}:
let
  mkHome =
    extraModules:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeManagerModules.colors
        {
          home = {
            username = "colors-test";
            homeDirectory = "/home/colors-test";
            stateVersion = "25.05";
          };
        }
      ]
      ++ extraModules;
    };
  baseline = mkHome [ ];
  extended = mkHome [
    {
      colors.palettes.custom.example.accent = "#abcdef";
    }
  ];
  invalid = mkHome [
    {
      colors.palettes.custom.example.accent = 42;
    }
  ];
  invalidSucceeds = (builtins.tryEval (builtins.deepSeq invalid.config.colors true)).success;
  colorsJson = builtins.toJSON baseline.config.colors;
in
{
  colors-contract = pkgs.runCommand "colors-contract" { } ''
    test '${builtins.hashString "sha256" "${colorsJson}\n"}' = \
      c8f178074351bd6c515de495925fa9d5b3eaf559254cc0cb7e71401d1008b96b
    test '${extended.config.colors.palettes.custom.example.accent}' = '#abcdef'
    test '${if invalidSucceeds then "accepted" else "rejected"}' = rejected
    touch $out
  '';
}
