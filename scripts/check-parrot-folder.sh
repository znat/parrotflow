#!/usr/bin/env bash
# Checks a `.parrot/` folder — the vocabulary and transforms a team shares
# through its repository.
#
#   scripts/check-parrot-folder.sh                 # every .parrot/ in this tree
#   scripts/check-parrot-folder.sh path/to/.parrot
#
# The folder is read by an agent, never by the app, so nothing else parses it
# and a key that quietly stops meaning what it meant is invisible. Four kinds
# of fault, and they are all about what does not travel:
#
#   the reader's numbers   `offer_below` and `decide_above` are measured on one
#                          machine over one set. A folder that carries them
#                          hands its author's tuning to everyone who imports.
#   one person's evidence  a rendering `from: correction` is somebody fixing
#                          their own transcript. It says how one mouth on one
#                          microphone says a word — see docs/sharing.md.
#   speaker audio          same rule as scripts/check-no-voice.sh, applied to
#                          the folder rather than the whole tree.
#   a path that leaves     a `command:` naming a file outside the folder is a
#                          transform nobody can copy and run.
#
# It also prints every `command:` the folder would have someone run. A config
# that executes code says so out loud, and a folder proposing one is the same
# rule one step earlier.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

folders=("$@")
if [ ${#folders[@]} -eq 0 ]; then
  while IFS= read -r found; do folders+=("$found"); done < <(
    find . -name .parrot -type d -not -path '*/.git/*' | sed 's|^\./||' | sort
  )
fi

if [ ${#folders[@]} -eq 0 ]; then
  printf '  · no .parrot/ folder in this tree — nothing to check\n'
  exit 0
fi

python3 - "${folders[@]}" <<'PY'
import pathlib, sys, yaml

ok = True
checked = 0

def fault(message, detail=""):
    global ok
    ok = False
    print(f"  ✗ {message}")
    if detail:
        print(f"      {detail}")

for name in sys.argv[1:]:
    folder = pathlib.Path(name)
    if not folder.is_dir():
        fault(f"{name} is not a directory")
        continue
    checked += 1
    print(f"  · {folder}")

    # Speaker audio. The same rule as check-no-voice.sh, one folder deep.
    for pattern in ("**/*.wav", "**/observations.jsonl", "voice/**/*"):
        for stray in sorted(folder.glob(pattern)):
            fault(f"{stray} is one speaker's voice", "it belongs in voice/ beside the config, never in git")

    vocabulary = folder / "vocabulary.yaml"
    if vocabulary.exists():
        try:
            doc = yaml.safe_load(vocabulary.read_text()) or {}
        except yaml.YAMLError as error:
            fault(f"{vocabulary} is not valid YAML", str(error))
            doc = {}
        if not isinstance(doc, dict):
            fault(f"{vocabulary} is not a mapping")
            doc = {}

        # `acoustic:` switches the sound pass on for a machine; the two numbers
        # are that machine's tuning. None of the three is the folder's to set.
        for key in ("offer_below", "decide_above", "min_similarity", "acoustic"):
            if key in doc:
                fault(f"{vocabulary} sets `{key}:`", "that is the reader's setting — drop it, see docs/sharing.md")
        for key in doc:
            if key not in ("terms", "offer_below", "decide_above", "min_similarity", "acoustic"):
                fault(f"{vocabulary} has an unknown key `{key}:`", "a shared file carries `terms:` and nothing else")

        terms = doc.get("terms") or {}
        if not isinstance(terms, dict):
            fault(f"{vocabulary} `terms:` is not a mapping")
            terms = {}

        rules_only = []
        for term, entry in terms.items():
            term = str(term)
            if len(term) < 5 or not term.isalpha():
                rules_only.append(term)
            entry = entry or {}
            if not isinstance(entry, dict):
                fault(f"{vocabulary} term `{term}` is not a mapping or empty")
                continue
            for key in entry:
                if key not in ("kind", "floor", "pronunciations", "heard"):
                    fault(f"{vocabulary} term `{term}` has an unknown key `{key}:`")
            said = entry.get("pronunciations") or []
            if isinstance(said, dict):
                said = [said]
            for rendering in said:
                if isinstance(rendering, dict) and rendering.get("from") == "correction":
                    fault(
                        f"{vocabulary} term `{term}` carries a rendering `from: correction`",
                        "that is one person fixing their own transcript — publish it as `from: mined` or not at all",
                    )

        print(f"      {len(terms)} term(s)")
        if rules_only:
            # Not a fault. Config.vocabularyTerms drops these from sound
            # matching; their renderings still work as exact rules.
            print(f"      exact rules only, never searched for by sound: {', '.join(sorted(rules_only))}")

    fragment = folder / "config.yaml"
    if fragment.exists():
        try:
            doc = yaml.safe_load(fragment.read_text()) or {}
        except yaml.YAMLError as error:
            fault(f"{fragment} is not valid YAML", str(error))
            doc = {}
        if not isinstance(doc, dict):
            fault(f"{fragment} is not a mapping")
            doc = {}
        for key in doc:
            if key not in ("transforms", "lists"):
                fault(
                    f"{fragment} has `{key}:`",
                    "a shared fragment carries `transforms:` and `lists:` — nothing else travels",
                )
        for entry in doc.get("transforms") or []:
            if not isinstance(entry, dict):
                fault(f"{fragment} has a transform that is not a mapping")
                continue
            transform = entry.get("name", "?")
            for key in ("command", "prompt", "replace", "tests"):
                body = entry.get(key)
                path = body.get("path") if isinstance(body, dict) else (body if key == "command" else None)
                if not isinstance(path, str):
                    continue
                # The program of a `command:` is its first word; the rest are
                # arguments, and `command: sed -e ...` names nothing local.
                program = path.split()[0] if key == "command" else path
                if key == "command":
                    print(f"      runs: {program}")
                    # A bare word with no extension is a program on PATH, which
                    # the folder neither carries nor has to.
                    if "/" not in program and "." not in program:
                        continue
                if "/" not in program:
                    program = f"transforms/{transform}/{program}"
                target = (folder / program).resolve()
                if not str(target).startswith(str(folder.resolve()) + "/"):
                    fault(f"{fragment} transform `{transform}` names `{program}`, outside the folder")
                elif not target.exists():
                    fault(f"{fragment} transform `{transform}` names `{program}`, which is not in the folder")

if ok:
    print(f"\n  ✓ {checked} .parrot/ folder(s): nothing personal, nothing untuned, every path inside")
sys.exit(0 if ok else 1)
PY
