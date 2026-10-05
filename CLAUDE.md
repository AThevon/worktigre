# worktigre - Git Worktree Manager

CLI bash interactif (`wt`) pour gérer les git worktrees avec fzf et gum, intégration GitHub/GitLab (gh/glab) et Claude Code.

## Architecture

Pas de framework, pas de build : du bash pur. `wt.sh` est le point d'entrée (installé sous le nom `wt-core`), il source les modules de `lib/`.

| Fichier | Rôle |
|---------|------|
| `wt.sh` | Résolution du chemin réel (symlinks), flags (`--version`, `--help`, `--setup`, `--wizard`, `--update`, `--shell-init`, `--dev`, flags internes `--pr-preview`, `--issue-preview`, `--pr-status-preview`, `--worktree-preview`, `--generate-prompt`), template de la fonction shell `wt`, `main_menu()`, quick switch, `wt -` / `wt .` |
| `lib/core.sh` | Couleurs, thème fzf, `wt_fzf` (wrapper fzf), config (parse sans `source`), messages stderr, détection de plateforme, `open_in_editor` |
| `lib/ui.sh` | Wrappers gum (`ui_input`, `ui_confirm`, `ui_spin_fn`...) et logo responsive |
| `lib/git.sh` | Liste et format des worktrees, icônes de statut, détection merged/squash, preview worktree, créations (nouvelle branche, branche existante, current, issue, PR/MR, forks), copie des `.env`, `setup_cli_auth` |
| `lib/cli.sh` | Abstraction gh/glab : listes PR/MR et issues, état CI, previews |
| `lib/prompts.sh` | Prompts Claude (`issue-auto`, `ci-fix`, `pr-review`, `pr-work`, `issue-work`) |
| `lib/menus.sh` | Menus PR, issues, mode Claude, Create, Delete, Settings, wizards d'installation et de préférences |
| `lib/stash.sh` | Menu stash (keymap unique `_STASH_KEYMAP` partagée par la liste et le sous-menu) |

Emplacements de `lib/` selon l'install : à côté de `wt.sh` (clone, install script dans `~/.local/share/worktigre`), ou `<prefix>/lib/worktigre` (Homebrew). Les assets suivent la même logique.

## Conventions

- **Contrat stdout** : `wt-core` n'écrit sur stdout QUE le chemin du worktree cible, plus éventuellement une ligne `CLAUDE:<type>:<num>[:<mode>]`. Tout le reste va sur stderr (`msg*`, gum), ou sur `/dev/tty` pour `less`, les éditeurs terminal et `claude` lancé depuis le menu stash. La fonction shell `wt` lit stdout, fait le `cd` et lance Claude dans le worktree.
- **fzf** : toujours passer par `wt_fzf`, jamais `fzf` directement. Le wrapper force bash pour les previews (fzf utilise `$SHELL`, souvent zsh ou fish) et transforme `--footer=` en ligne de header sur fzf < 0.63. Écrire `--footer="..."` et `--header="..."` avec `=`. Tout doit s'ouvrir avec fzf 0.29+.
- **Compat** : bash 3.2 (bash système de macOS) et bash 5. Pas de tableaux associatifs, `${x,,}`, `mapfile`, `declare -g`. La fonction générée par `--shell-init` doit marcher sous zsh et bash.
- **Pas de chemins en dur** du type `/usr/bin/git` (cassé sur NixOS).
- **Pas de tiret cadratin** dans le code, les commentaires, les messages et la doc.

### Nommage des worktrees

- `{repo}-{branche}` avec `/` remplacé par `-` (ex : `myapp-feature-auth`), dans `WT_WORKTREE_DIR` ou à côté du repo principal
- Review de PR : `{repo}-reviewing-{branche}`, le marqueur `-reviewing-` identifie un worktree de review
- Issue : branche `{WT_FEATURE_PREFIX}{num}-{slug}`
- PR de fork : branche `pr/{num}-{branche}` (`mr/...` sur GitLab)
- From current : branche `temp/{branche}-{timestamp}`

### Icônes worktree (`format_worktree_line()`)

Ligne : `<icône> <branche>[ *]<TAB><chemin absolu>`.

| Icône | Couleur | Signification |
|-------|---------|---------------|
| `●` | dim | Branche par défaut |
| `◌` | dim | HEAD détachée |
| `★` | jaune | Jamais poussée (pas d'upstream du même nom) |
| `○` | orange | Poussée, non mergée |
| `◎` | magenta | Worktree de review |
| `✓` | vert | Mergée (ancêtre, arbre identique, ou squash détecté via `git cherry` quand l'upstream a disparu) |
| `*` | | Changements non committés |

### Lignes PR (`cli_pr_list()`)

Champs séparés par TAB : `#N` ou `!N` | CI + review | titre | `@auteur` | branche | cross-repo `1`/`0` | état CI `fail|pending|ok|none|draft`. Les menus n'affichent que les 4 premiers champs.

| CI | Review | Signification |
|----|--------|---------------|
| `[ok]` | `✓` vert | CI ok / Approved |
| `[fail]` | `✗` rouge | CI en échec / Changes requested |
| `[..]` | `◀` magenta | CI en cours / Ma review est demandée |
| `[--]` | | Pas de CI trouvée |
| `[draft]` | | Draft |

## Tests

Framework : [BATS](https://github.com/bats-core/bats-core), en submodules (`git submodule update --init --recursive`).

```bash
./tests/run.sh                          # tous les tests
tests/bats/bin/bats tests/07-git.bats   # un fichier
```

| Fichier | Couvre |
|---------|--------|
| `01-config.bats` | Config (lecture, écriture, quoting) |
| `02-editor.bats` | Détection d'éditeur |
| `03-platform.bats` | Détection de plateforme |
| `04-worktree-dir.bats` | Dossier des worktrees |
| `05-claude-mode.bats` | Modes Claude |
| `06-cli-flags.bats` | Flags CLI |
| `07-git.bats` | Worktrees, icônes, créations, forks, `.env` |
| `08-stash.bats` | Menu stash |
| `09-cli.bats` | gh/glab, état CI, prompts |
| `10-menus.bats` | Menus, raccourcis, settings, wizards |
| `11-entry.bats` | Point d'entrée, fonction shell, `wt_fzf`, config |
| `12-packaging.bats` | install.sh, symlinks, complétion zsh, `--shell-init` |
| `13-integration.bats` | Parcours de bout en bout |

Helpers dans `tests/test_helper/common.bash` : `load_wt`, `isolate_home`, `make_git_repo`, `stub_command`, `WT_ROOT`.

## Dépendances

- **git**, **bash** 3.2+
- **fzf** (requis), **gum** (requis), **jq** (requis)
- **gh** / **glab** (optionnel) : intégration GitHub / GitLab
- **claude** (optionnel) : fonctionnalités IA

## Config

Fichier `~/.config/wt/config` (ou `WT_CONFIG_FILE`), lignes `KEY="valeur"`, lu sans `source`. Clés : `WT_EDITOR`, `WT_PLATFORM`, `WT_WORKTREE_DIR`, `WT_AUTO_CD`, `WT_FEATURE_PREFIX`, `WT_AUTO_FETCH`, `WT_CLAUDE_MODE`, `WT_LIST_LIMIT`. Une variable `WT_*` déjà présente dans l'environnement est prioritaire sur le fichier.

## Mode dev

```bash
# Depuis un clone : la fonction wt pointe vers le wt.sh local
eval "$(./wt.sh --dev)"
# ou, avec la fonction déjà chargée, depuis un worktree du repo
wt --dev

# Revenir à wt-core du PATH
wt --release
```

La fonction dev est générée par le même template que `--shell-init`, donc elle gère aussi le `cd`, `WT_AUTO_CD` et le lancement de Claude.
