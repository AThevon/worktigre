{ lib, stdenvNoCC, makeWrapper, fzf, gum, gh, jq, glab, git }:

let
  # Single source of truth: VERSION="x.y.z" in wt.sh (matched line by line,
  # a regex over the whole file can overflow std::regex on Linux)
  versionLine = lib.findFirst
    (l: builtins.match "VERSION=\"[^\"]+\"" l != null)
    (throw "worktigre: no VERSION=\"...\" line in wt.sh")
    (lib.splitString "\n" (builtins.readFile ./wt.sh));
  version = builtins.head (builtins.match "VERSION=\"([^\"]+)\"" versionLine);
in
stdenvNoCC.mkDerivation {
  pname = "worktigre";
  inherit version;

  # Only what the package installs: editing the README or the tests
  # doesn't trigger a rebuild
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./wt.sh
      ./lib
      ./completions
      (lib.fileset.fileFilter (f: lib.hasSuffix ".ansi" f.name) ./assets)
    ];
  };

  nativeBuildInputs = [ makeWrapper ];

  # Same layout as install.sh: wt.sh finds lib/ and assets/ next to itself
  installPhase = ''
    runHook preInstall
    install -Dm755 wt.sh $out/share/worktigre/wt.sh
    install -Dm644 -t $out/share/worktigre/lib lib/*.sh
    install -Dm644 -t $out/share/worktigre/assets assets/logo*.ansi
    install -Dm644 completions/wt.zsh $out/share/worktigre/completions/wt.zsh
    install -Dm644 completions/wt.zsh $out/share/zsh/site-functions/_wt
    makeWrapper $out/share/worktigre/wt.sh $out/bin/wt-core \
      --prefix PATH : ${lib.makeBinPath [ fzf gum gh jq glab ]} \
      --suffix PATH : ${lib.makeBinPath [ git ]}
    runHook postInstall
  '';

  # --version exits before lib/ is loaded: --get-pr-term in a scratch repo
  # also checks that the wrapped script finds its modules
  doInstallCheck = true;
  nativeInstallCheckInputs = [ git ];
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME="$TMPDIR"
    $out/bin/wt-core --version 2>&1 | grep -qF "wt ${version}"
    git init -q "$TMPDIR/check-repo"
    [ "$(cd "$TMPDIR/check-repo" && $out/bin/wt-core --get-pr-term)" = "PR" ]
    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "Git worktree manager with fzf integration and GitHub/GitLab support";
    homepage = "https://github.com/AThevon/worktigre";
    license = licenses.gpl3Plus;
    platforms = platforms.unix;
    mainProgram = "wt-core";
  };
}
