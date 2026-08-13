{
  lib,
  schema,
  identityVersion ? schema.version,
}:
let
  rawCharacters = [
    "%"
    "/"
    ":"
    "#"
    "?"
    " "
    "\n"
    "\t"
    "@"
    "+"
    "="
    "["
    "]"
    ","
    ";"
    "&"
    "!"
    "$"
    "'"
    "("
    ")"
    "*"
    "\\"
  ];
  encodedCharacters = [
    "%25"
    "%2F"
    "%3A"
    "%23"
    "%3F"
    "%20"
    "%0A"
    "%09"
    "%40"
    "%2B"
    "%3D"
    "%5B"
    "%5D"
    "%2C"
    "%3B"
    "%26"
    "%21"
    "%24"
    "%27"
    "%28"
    "%29"
    "%2A"
    "%5C"
  ];
  forbidden =
    value:
    let
      lower = lib.toLower value;
    in
    lib.hasInfix "/nix/store" lower
    || lib.hasInfix "/run/secrets" lower
    || lib.hasInfix "%2fnix%2fstore" lower
    || lib.hasInfix "%2frun%2fsecrets" lower;
  checked =
    name: value:
    if !builtins.isString value || value == "" || builtins.hasContext value then
      throw "fleet topology identity ${name} must be a non-empty context-free string"
    else if forbidden value then
      throw "fleet topology identity ${name} contains a forbidden secret or store path"
    else
      value;
  escape = value: lib.replaceStrings rawCharacters encodedCharacters value;
  unescape = value: lib.replaceStrings encodedCharacters rawCharacters value;
  canonicalSegment =
    value:
    builtins.isString value
    && builtins.match "^([A-Za-z0-9._~-]|%[0-9A-F]{2})+$" value != null
    && value == escape (unescape value)
    && !forbidden value
    && !forbidden (unescape value);
  parseId =
    value:
    if !builtins.isString value || builtins.hasContext value then
      null
    else
      let
        parts = lib.splitString "/" value;
        prefix = if builtins.length parts == 4 then lib.splitString ":" (builtins.head parts) else [ ];
        kind = if builtins.length prefix == 3 then builtins.elemAt prefix 2 else "";
        segments = if builtins.length parts == 4 then lib.tail parts else [ ];
      in
      if
        builtins.length prefix != 3
        || builtins.elemAt prefix 0 != "ft"
        || builtins.elemAt prefix 1 != "v${toString identityVersion}"
        || !(builtins.hasAttr kind schema.nodeKinds)
        || !(lib.all canonicalSegment segments)
      then
        null
      else
        {
          inherit kind;
          fleetId = unescape (builtins.elemAt segments 0);
          scope = unescape (builtins.elemAt segments 1);
          key = unescape (builtins.elemAt segments 2);
        };
  encodeSegment =
    name: value:
    let
      encoded = escape (checked name value);
    in
    if canonicalSegment encoded then
      encoded
    else
      throw "fleet topology identity ${name} contains unsupported characters";
in
{
  inherit parseId;

  mkId =
    {
      fleetId,
      kind,
      key,
      scope ? "fleet",
    }:
    let
      checkedKind = checked "kind" kind;
    in
    if !(builtins.hasAttr checkedKind schema.nodeKinds) then
      throw "fleet topology identity has unknown node kind ${checkedKind}"
    else
      "ft:v${toString identityVersion}:${checkedKind}/${encodeSegment "fleetId" fleetId}/${encodeSegment "scope" scope}/${encodeSegment "key" key}";

  validId =
    kind: value:
    let
      parsed = parseId value;
    in
    parsed != null && parsed.kind == kind;
}
