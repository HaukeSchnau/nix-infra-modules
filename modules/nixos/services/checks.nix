{ pkgs, self, ... }:
{
  service-controller = import ./test.nix { inherit pkgs self; };

  service-controller-unit =
    pkgs.runCommand "service-controller-unit" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        cp ${./controller.py} controller.py
        cp ${./test_controller.py} test_controller.py
        python3 -m unittest -v test_controller
        touch $out
      '';
}
