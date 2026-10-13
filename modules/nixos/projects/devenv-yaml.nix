# Reads devenv.yaml during evaluation. Nix has no YAML parser, and converting
# the file with a YAML tool would build a derivation while evaluating, which
# needs a builder for every host platform. So this reads only the subset the
# Projects use: nested `key:` blocks, `key: value` with unquoted strings that
# start with a letter, `true` and `false`, and comments. Anything else throws
# rather than risk reading the file differently from devenv.
{ lib }:
text:
let
  fail = number: message: throw "devenv.yaml line ${toString number}: ${message}";
  token = "[^#[:space:]][[:graph:]]*";
  entry =
    number: line:
    let
      match = builtins.match "( *)([A-Za-z_][A-Za-z0-9_-]*):( +(${token}( +${token})*))?( +#.*)? *" line;
    in
    if builtins.match " *(#.*)?" line != null then
      [ ]
    else if match == null then
      fail number "expected `key:` or `key: value`"
    else
      [
        {
          inherit number;
          indent = builtins.stringLength (builtins.elemAt match 0);
          key = builtins.elemAt match 1;
          value = builtins.elemAt match 3;
        }
      ];

  scalar =
    { number, value, ... }:
    if value == "true" then
      true
    else if value == "false" then
      false
    else if
      builtins.match "[A-Za-z].*" value == null
      || builtins.match ".*:( .*)?" value != null
      # YAML 1.1 reads these as booleans or null.
      || builtins.elem (lib.toLower value) [
        "y"
        "yes"
        "n"
        "no"
        "on"
        "off"
        "null"
      ]
    then
      fail number "unsupported value `${value}`; use an unquoted string that starts with a letter, true or false"
    else
      value;

  # Entries at the first entry's indentation are keys; deeper entries belong
  # to the key above them.
  mapping =
    entries:
    let
      indent = (builtins.head entries).indent;
      groups = builtins.foldl' (
        groups: entry:
        if entry.indent == indent then
          groups ++ [ [ entry ] ]
        else if entry.indent > indent then
          lib.init groups ++ [ (lib.last groups ++ [ entry ]) ]
        else
          fail entry.number "indentation matches no enclosing key"
      ) [ ] entries;
      value =
        group:
        let
          key = builtins.head group;
          nested = builtins.tail group;
        in
        if key.value == null then
          if nested == [ ] then fail key.number "`${key.key}` has no value" else mapping nested
        else if nested != [ ] then
          fail (builtins.head nested).number "`${key.key}` has a value and nested keys"
        else
          scalar key;
    in
    builtins.foldl' (
      attrs: group:
      let
        key = builtins.head group;
      in
      if attrs ? ${key.key} then
        fail key.number "duplicate key `${key.key}`"
      else
        attrs // { ${key.key} = value group; }
    ) { } groups;

  entries = lib.concatLists (lib.imap1 entry (lib.splitString "\n" text));
in
if entries == [ ] then { } else mapping entries
