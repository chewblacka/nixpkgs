{
  lib,
  buildGoModule,
  fetchFromGitHub,
  jq,
  makeWrapper,
}:

buildGoModule rec {
  pname = "jiq";
  version = "0.7.2";

  src = fetchFromGitHub {
    owner = "fiatjaf";
    repo = "jiq";
    rev = "v${version}";
    sha256 = "sha256-txhttYngN+dofA3Yp3gZUZPRRZWGug9ysXq1Q0RP7ig=";
  };

  vendorHash = "sha256-ZUmOhPGy+24AuxdeRVF0Vnu8zDGFrHoUlYiDdfIV5lc=";

  nativeBuildInputs = [ makeWrapper ];

  nativeCheckInputs = [ jq ];

  postInstall = ''
    wrapProgram $out/bin/jiq \
      --prefix PATH : ${lib.makeBinPath [ jq ]}
  '';

  meta = with lib; {
    homepage = "https://github.com/fiatjaf/jiq";
    license = licenses.mit;
    description = "jid on jq - interactive JSON query tool using jq expressions";
    mainProgram = "jiq";
    maintainers = [ ];
  };
}
