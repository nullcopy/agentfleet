{
  lib,
  python3,
  stdenvNoCC,
  makeWrapper,
  systemd,
  cacert,
}:

stdenvNoCC.mkDerivation {
  pname = "agentfleet-matrix";
  version = "0.1.0";
  src = ./.;
  dontBuild = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    install -D -m 0755 agentfleet-matrix.py $out/bin/agentfleet-matrix
    patchShebangs $out/bin/agentfleet-matrix
    wrapProgram $out/bin/agentfleet-matrix \
      --set-default SSL_CERT_FILE ${cacert}/etc/ssl/certs/ca-bundle.crt \
      --prefix PATH : ${
        lib.makeBinPath [
          python3
          systemd
        ]
      }
  '';
  meta = {
    description = "Reconciles agentfleet agents with the host's Synapse homeserver";
    mainProgram = "agentfleet-matrix";
    platforms = lib.platforms.linux;
  };
}
