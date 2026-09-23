# The `project` controller as a Python application; also importable as a
# library (project_controller) by the host's observability tool.
{ python3Packages }:
python3Packages.buildPythonApplication {
  pname = "project-controller";
  version = "2";
  pyproject = true;
  src = ./.;
  build-system = [ python3Packages.setuptools ];
  meta.mainProgram = "project";
  nativeCheckInputs = [ python3Packages.mypy ];
  checkPhase = ''
    runHook preCheck
    mypy project_controller
    python -m unittest discover -s tests -t .
    runHook postCheck
  '';
}
