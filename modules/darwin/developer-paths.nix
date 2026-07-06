{
  config,
  ...
}:
{
  environment = {
    systemPath = [
      "/opt/homebrew/bin"
      "/opt/homebrew/sbin"
      "${config.users.users.${config.system.primaryUser}.home}/.bun/bin"
      "${config.users.users.${config.system.primaryUser}.home}/go/bin"
      "/Library/TeX/texbin"
    ];

    pathsToLink = [ "/Applications" ];
  };
}
