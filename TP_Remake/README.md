# ThatPet Remake

Refonte personnelle d'un animal de bureau macOS (ThatPet). Le personnage vit sur le bureau et sert de point d'entrée pour discuter avec des agents IA en ligne de commande : **Claude Code** et **Antigravity** (`agy`).

- Bulles de réponse et fenêtre de chat, avec réponses en flux.
- Approbation des permissions depuis le personnage (Autoriser / Refuser).
- Mode tâches : l'agent travaille dans un dossier choisi, chaque action sensible est validée depuis le personnage.
- Réactions du personnage à l'activité des agents (réflexion, travail, attention, succès, erreur).
- Personnages au format de pack `thatpet-pack/1`.

Application native Swift / AppKit, sans dépendance externe.

## Prérequis

- macOS 13 ou plus
- Swift 5.9 ou plus (outils de ligne de commande Xcode)
- Au moins un agent installé : `claude` (Claude Code) et/ou `agy` (Antigravity)

## Compiler et lancer

```sh
swift build -c release
.build/release/TPRemake
```

Il ne peut y avoir qu'une seule instance : un verrou (`run/pet.pid`) empêche d'en lancer une seconde.

## Connecter un agent

Le personnage reçoit les événements des agents via des hooks, appelés par le binaire `TPRemake hook` et `TPRemake gate`.

```sh
.build/release/TPRemake connect              # Claude Code (~/.claude/settings.json)
.build/release/TPRemake connect antigravity  # Antigravity (~/.gemini/config/hooks.json)
.build/release/TPRemake status               # état de chaque connexion
.build/release/TPRemake disconnect [antigravity]
```

Chaque connexion fait une sauvegarde horodatée du fichier de configuration avant de le modifier.

Les hooks enregistrent le **chemin absolu du binaire**. Si tu le déplaces ou si tu fais un `swift package clean`, relance `connect`.

## Commandes utiles

| Commande | Rôle |
| --- | --- |
| `TPRemake` | Lance le personnage |
| `TPRemake connect` / `disconnect` / `status` | Gère les hooks des agents |
| `TPRemake ask [--agent claude\|antigravity] [--dir dossier] [--model m] [--attach fichier] "message"` | Discute sans interface (utile pour tester) |
| `TPRemake characters` | Liste les personnages trouvés |
| `TPRemake sizes [--screen largeur]` | Tableau des tailles pour une largeur d'écran |
| `TPRemake help` | Aide intégrée |

Les sous-commandes `sim`, `fx-test`, `reactions-test`, `particles-test`, `attach-test` et `md-debug` sont des auto-tests inclus dans le binaire. Il n'y a pas encore de cible XCTest.

## Personnages (packs)

Les packs sont cherchés dans :

- `Resources/packs` (« inclus », relatif au **dossier courant** ; `--packs <dossier>` le remplace)
- `~/Library/Application Support/TPRemake/characters` (« TPRemake »)
- `~/Library/Application Support/ThatPet/characters`, lus sur place si l'application d'origine est installée (« ThatPet »)
- les dossiers listés dans `TPREMAKE_PACKS`, séparés par `:`

Un pack contient un `pack.json` et un dossier `poses/`. `opus55`, fourni dans `Resources/packs`, est une création de ThatLev : ne le redistribue pas sans son accord.

## Données

Tout est dans `~/Library/Application Support/TPRemake` (modifiable avec `TPREMAKE_DATA_DIR`) :

| Fichier | Contenu |
| --- | --- |
| `chat.json` | Conversations, une par agent et dossier de travail |
| `settings.json` | Réglages |
| `log.txt` | Journal des hooks et de l'app |
| `run/` | Socket `pet.sock`, `pet.pid`, `state` |

## Architecture

Code dans `Sources/TPRemake` :

- **Comportement** : `PetBrain` (physique, modes), `AnimationPlayer`, `Fx` / `Effects`, `Particles`, `Reactions`
- **Interface** : `PetView`, `BubbleController`, `ActivityBubble`, `ChatWindowController`, `ApprovalController`, `Markdown`
- **Agents** : `CLIRunner` (base), `ClaudeRunner`, `AgyRunner`, `ChatModel`, `AgentConnector`
- **Hooks** : `HookMode` (`hook` et `gate`), `PetSocket` (socket UNIX datagramme), `AgentEvents`
- **Packs** : `Pack`, `PackLibrary`
- **Point d'entrée** : `main.swift` (ligne de commande et `AppDelegate`)

Les runs lancés par le personnage utilisent `claude -p --output-format stream-json` et `agy --output-format stream-json`. En mode tâches, un hook `PreToolUse` envoie les actions sensibles au personnage ; sans réponse sous 90 s, Antigravity refuse l'action et Claude Code retombe sur sa propre demande de permission.

## Limites connues

Voir [`../ANALYSE.md`](../ANALYSE.md) pour le détail. Les principales :

- Le filtre des commandes jugées inoffensives est trop permissif et la commande affichée à l'approbation peut être tronquée.
- Les packs inclus sont cherchés depuis le dossier courant : lancer l'app depuis un autre dossier ne les trouve pas.
- Arrêter un run ne tue que l'agent, pas ses sous-processus, et il n'y a pas de délai maximum.
- Pas de `.app`, pas de lancement à l'ouverture de session, pas de tests automatisés.
