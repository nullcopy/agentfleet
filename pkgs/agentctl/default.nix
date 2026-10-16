{
  lib,
  python3,
  stdenvNoCC,
  makeWrapper,
  installShellFiles,
  systemd,
  git,
}:

stdenvNoCC.mkDerivation {
  pname = "agentctl";
  version = "0.1.0";
  src = ./.;
  dontBuild = true;
  nativeBuildInputs = [
    makeWrapper
    installShellFiles
  ];
  installPhase = ''
    install -D -m 0755 agentctl.py $out/bin/agentctl
    patchShebangs $out/bin/agentctl
    wrapProgram $out/bin/agentctl \
      --prefix PATH : ${
        lib.makeBinPath [
          python3
          systemd
          git
        ]
      }
    installShellCompletion --bash --name agentctl completions/agentctl.bash
    installShellCompletion --zsh --name _agentctl completions/_agentctl
  '';
  meta = {
    description = "Operator CLI for agentfleet: create, destroy and drive per-user AI agents";
    mainProgram = "agentctl";
    platforms = lib.platforms.linux;
  };
}
