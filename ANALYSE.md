# ThatPet Remake : analyse et pistes d'amélioration

Analyse en lecture seule du code (`TP_Remake/Sources/TPRemake`, environ 5 200 lignes), complétée par quelques mesures sur l'instance en cours. L'interface n'a pas été vérifiée visuellement. Les mesures de CPU sont des ordres de grandeur, car l'état du personnage pendant la mesure est inconnu.

## 1. Sécurité des approbations (priorité haute)

Les approbations depuis le personnage sont la fonction centrale du projet, et elles ont des trous.

- **Le filtre « commande inoffensive » est trop permissif** (`HookMode.swift:187-211`). Testé avec `gate` : seul `rm -rf` demande l'accord. Ces commandes passent sans question :
  - `git branch -D main`, `git remote remove origin`
  - `git diff --output=/tmp/x`, `find . -fprint f`, `tree -o f`
  - `rg --pre sh` (exécute une commande)
  - `cat ~/.ssh/id_rsa`, `head ~/.aws/credentials`
- **Une commande peut être approuvée sans être vue en entier.** `describe()` coupe à 500 caractères (`HookMode.swift:224`) et la bulle à 7 lignes (`ApprovalController.swift:57`), mais la commande complète s'exécute.
- **Les éditions s'approuvent à l'aveugle.** Pour `Edit` et `Write`, seul le chemin du fichier est affiché, sans le diff. Le dossier de travail (`cwd`) est reçu mais jamais montré.
- **Une pièce jointe ouvre tout son dossier parent** (`ChatModel.swift:150`). Joindre `~/notes.txt` donne `--add-dir ~`. Pour Antigravity, les lectures dans ces dossiers sont même auto-autorisées (`HookMode.swift:171`). Mieux vaut copier chaque fichier joint dans un dossier privé et n'ajouter que celui-là.
- **Le bouton « Voir dans Claude » ne sert à rien dans les chats du personnage** (pas d'interface Claude à ouvrir : l'action est refusée sans explication). Le titre dit aussi « Claude demande… » pour Antigravity, car la demande ne porte pas le nom de l'agent (`main.swift:623`).
- **Pas de « autoriser pour cette session »**, donc risque de cliquer Autoriser sans lire.
- **Fail-open d'Antigravity** si le binaire du hook est absent (`AgentConnector.antigravityGateReady` vérifie le timeout, pas l'existence du binaire).

## 2. Fiabilité

- **Arrêter ne tue que l'agent** (`CLIRunner.swift:137`). Pas de groupe de processus (`killpg`), pas de délai maximum de run, aucun nettoyage à la fermeture de l'app. Un run bloqué garde `isBusy` actif : le personnage se fige et on ne peut plus changer d'agent.
- **Les packs inclus dépendent du dossier courant** (`main.swift:4-10`). Depuis `/tmp`, `TPRemake characters` ne liste plus `opus55`, seulement `sonnet55` de ThatPet. Un lancement depuis le Finder ou à l'ouverture de session casserait le personnage de secours.
- **Les hooks pointent vers `.build/release/TPRemake`.** Un `swift package clean` casse les hooks Claude. Il faut installer le binaire dans un chemin stable.
- **Mode tâche d'Antigravity bloqué pour l'instant.** Le timeout PreToolUse dans `~/.gemini/config/hooks.json` est de 5 s alors qu'il faut au moins 95 s. Relancer `TPRemake connect antigravity`. Côté Claude, le timeout de 105 s est déjà bon.
- **Une faute de frappe lance l'app** : `TPRemake stauts` démarre le personnage au lieu d'afficher une erreur (`main.swift:177`, `default: return nil`).
- **Log fragile** : écritures non atomiques entre l'app et les hooks (`DataDir.appendLog` sans `O_APPEND`), pas de rotation (98 Ko aujourd'hui).
- **`run/state` est écrit à chaque hook mais jamais lu.**
- **Fin du flux** : un délai fixe de 0,15 s (`CLIRunner.swift:105-123`) peut perdre la dernière ligne de résultat quand la machine est chargée. Lire jusqu'à la fin du flux.
- **Conversations** : l'identifiant de session n'est sauvegardé qu'en fin de réponse, « Nouvelle conversation » efface tout sans confirmation, pas d'historique des conversations passées.

## 3. Expérience d'usage

- **Le mode tâche est une boîte noire.** `ClaudeRunner` ignore les événements d'outils (`ClaudeRunner.swift:62-82`) et la bulle d'activité est coupée pour les chats du personnage (`main.swift:671`). Pendant plusieurs minutes de travail, on ne voit que « … ». Afficher les étapes (outil, fichier, commande) serait le plus gros gain.
- **Pas de raccourci clavier global** pour parler au personnage.
- **La fenêtre de chat se reconstruit entièrement à chaque delta** (`ChatWindowController.swift:88-112`), et ramène en bas pendant qu'on relit plus haut. Elle travaille même fermée. Ajouter le texte au fur et à mesure.
- **Markdown partiel** : pas de listes numérotées, de tableaux ni de citations. La coupe à 260 caractères peut casser un balisage (`BubbleController.swift:167`).
- **Liste de modèles en dur** (`main.swift:884`). Utiliser les alias (`opus`, `sonnet`) ou la lire depuis la CLI, comme pour `agy`.
- Multi-écrans, accessibilité : non traités.

## 4. Performance (mesuré sur l'instance en cours)

- 3,1 à 3,5 % de CPU, environ 1 000 réveils par échantillon de 2 s, 251 Mo de mémoire (`ps`). C'est beaucoup pour un sprite.
- Causes probables : un minuteur à 60 Hz permanent (`main.swift:324`) et `isOpaque` qui découpe l'image à chaque appel (`PetView.swift:118-133`). Un masque d'opacité précalculé règlerait le second point.
- Chargement synchrone des packs au démarrage.
- **Écarté par la mesure :** la latence des hooks. Environ 5 ms par appel, le démarrage du binaire n'est pas en cause.

## 5. Qualité et processus

- **Pas de git.** Aucun historique ni sauvegarde. C'est le risque n°1 en pratique.
- **Pas de cible de tests, de CI ni de README.** Les tests sont des sous-commandes dans le binaire de production (environ 230 lignes dans `main.swift:330-553`, dont un déplacement réel du curseur).
- **`main.swift` fait 981 lignes** et `AppDelegate` fait tout. Le parseur d'options a une liste codée en dur (`main.swift:28`).
- **47 `try?`** : une écriture de réglages ou de config qui échoue passe sans bruit.
- **Code mort** : `AgentEvents.animation` et `AgentEvents.transient`.
- **Packaging** : pas de `.app`, pas de signature, pas de lancement à l'ouverture de session.
- **Licence du pack** : `opus55` (dans `Resources/`) est une création de ThatLev. À exclure de tout dépôt publié.

## Ordre conseillé

1. `git init` avec un `.gitignore`.
2. Durcir le filtre des commandes, afficher le diff et la commande complète dans l'approbation.
3. Tuer le groupe de processus, ajouter un timeout, nettoyer à la fermeture.
4. Binaire installé à un chemin stable, packs indépendants du dossier courant, `.app`.
5. Afficher la progression des tâches.
6. Remplacer les auto-tests par une vraie cible de tests.

## Suivi des corrections (2026-10-29)

Fait et vérifié (`swift test` : 9 tests, auto-tests `attach-test`/`reactions-test`, lancement de l'app avec `TPREMAKE_SELFTEST=react`, build release) :

- **Git** : `.build/` et `.DS_Store` n'étaient pas ignorés (2 687 fichiers suivis) ; ajoutés au `.gitignore` et retirés de l'index (rien n'est commité).
- **Filtre de commandes** (`HookMode.isHarmless`) : `git branch`/`remote` limités au listage, options dangereuses refusées (`--output`, `--pre`, `-fprint`, `tree -o`, `date -s`…), chemins sensibles (`~`, `.ssh`, `.aws`, `.env`, `credentials`…) toujours soumis à l'accord.
- **Approbation complète** : plus de troncature à 500 caractères ; le diff d'une édition (`Edit`), le contenu d'un `Write` et le dossier de travail sont montrés ; la bulle défile au lieu de couper à 7 lignes ; si la demande ne tient pas dans un datagramme (1 800 octets), elle n'est pas approuvée à l'aveugle (l'agent applique sa propre règle).
- **Titre et bouton** : nom de l'agent réel ; « Voir dans … » masqué dans les chats du personnage.
- **Pièces jointes** : copiées dans `sent/<uuid>/` (purgé après 7 jours), plus d'`--add-dir` sur le dossier d'origine.
- **Antigravity** : `antigravityGateReady` exige que le binaire du hook existe.
- **Processus** : arrêt de l'agent et de tous ses descendants (SIGTERM puis SIGKILL), arrêt automatique après 10 min (20 min en mode tâche) sans aucune sortie, nettoyage à la fermeture de l'app, fin de run déclenchée par la fin des flux (plus de délai de 0,15 s).
- **Chemin stable** : `connect` installe une copie du binaire dans `~/Library/Application Support/TPRemake/bin/` (et les packs inclus dans `packs/`) ; les hooks pointent dessus. Les packs se trouvent aussi depuis le dossier du binaire, sans dépendre du dossier courant.
- **CLI** : une commande inconnue (`TPRemake stauts`) affiche une erreur (code 2) au lieu de lancer l'app.
- **Journal** : écriture `O_APPEND` (40 écritures concurrentes testées) et rotation à 512 Ko.
- **Progression des tâches** : les appels d'outils de Claude (« Bash : npm test ») s'affichent dans la bulle d'activité et dans le chat à la place de « … ».
- **Chat** : le défilement n'est plus ramené en bas si l'on relit plus haut.
- **Performance** : masque d'opacité précalculé (`AlphaMask`) à la place d'un `cropping` par test de souris.
- **Tests** : cible `TPRemakeTests` (filtre d'approbation, arrêt des descendants, fin de flux, masque alpha, étapes Claude).

Non fait / à décider :

- Relancer `TPRemake connect antigravity` (timeout PreToolUse de 5 s dans `~/.gemini/config/hooks.json`) : modifie la config réelle de l'utilisateur, non exécuté.
- Liste de modèles : les identifiants en dur sont à jour (famille 5) ; pas de changement.
- « Autoriser pour cette session », raccourci global, `.app` signé, découpage de `main.swift`, retrait des auto-tests du binaire de production, 47 `try?`, Markdown (listes numérotées, tableaux), multi-écrans, accessibilité.
- Antigravity : pas d'étapes de progression (format des événements d'outils non vérifié).
- CPU : la boucle est déjà à 30 Hz à l'arrêt ; l'effet du masque alpha n'a pas été remesuré.
- Licence : `Resources/packs/opus55` (ThatLev) à exclure de tout dépôt publié.
