#!/usr/bin/env bash
# The warm Python worker that runs `runner: python` transforms, driven through
# `--pipeline` with scripts written into a temporary directory.
#
#   scripts/check-python-runner.sh
#
# Each script appends a mark to the text, so the finished line says which
# steps ran where: `n` is how many calls that script's module has seen, and the
# pid says which process answered. A script imported once in the worker counts
# up; a script started per step always says 1.
#
# Runs under a scratch HOME and config dir: the log it reads is its own.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-runner)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" CFFIXED_USER_HOME="$WORK/home" PARROTFLOW_CONFIG_DIR="$WORK/config"
mkdir -p "$HOME/Library/Logs" "$PARROTFLOW_CONFIG_DIR"

pass=0; total=0; failed=""

check() {  # check <name> <got> <want>
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1"
    printf '  ✗ %s\n      got   %s\n      want  %s\n' "$1" "$2" "$3"
  fi
}

script() {  # script <folder> <header> <body of run(envelope)>
  mkdir -p "$WORK/transforms/$1"
  cat > "$WORK/transforms/$1/$1.py" <<PY
#!/usr/bin/env python3
# parrotflow: $2
import json, os, signal, sys, time
N = 0
def run(envelope):
    global N
    N += 1
$3
def main():
    print(json.dumps(run(json.loads(sys.stdin.read()))))
if __name__ == "__main__":
    main()
PY
  chmod +x "$WORK/transforms/$1/$1.py"
}

WARM='{returns: json, runner: python}'
mark() { printf '    return {"text": envelope["text"] + " %s" %% (%s)}' "$1" "$2"; }

script probe "$WARM" "$(printf '    leak = os.environ.get("PROBE_LEAK", "-")
    seen = "%%s:%%s:%%s:%%s" %% (N, " ".join(sys.argv[1:]), os.path.basename(os.getcwd()), leak)
    os.environ["PROBE_LEAK"] = "leaked"
    sys.argv.append("junk")
    os.chdir("/")
')
$(mark 'probe=%s pid=%s' 'seen, os.getpid()')"
mkdir -p "$WORK/transforms/other"
script plain '{returns: json}' "$(mark 'plain=%s' 'N')"
script raises "$WARM" '    raise ValueError("boom")'
script exits "$WARM" '    sys.exit(3)'
script hangs "$WARM" "$(printf '    if N > 1:\n        time.sleep(30)\n')
$(mark 'hangs=%s pid=%s' 'N, os.getpid()')"
script dies "$WARM" "$(printf '    if N > 1:\n        os.kill(os.getpid(), signal.SIGKILL)\n')
$(mark 'dies=%s pid=%s' 'N, os.getpid()')"
script edited "$WARM" "$(mark 'version=1 n=%s' 'N')"
script editor '{returns: json}' "$(printf '    path = os.path.join(os.path.dirname(os.getcwd()), "edited", "edited.py")
    with open(path) as f:
        code = f.read()
    with open(path, "w") as f:
        f.write(code.replace("version=1", "version=2"))
')
$(mark 'edit' '()')"
script norun "$WARM" '    pass'
sed -i '' 's/^def run(envelope):/def ran(envelope):/; s/run(json.loads/ran(json.loads/' "$WORK/transforms/norun/norun.py"
sed -i '' 's/    pass/    return {"text": envelope["text"] + " norun"}/' "$WORK/transforms/norun/norun.py"

cat > "$WORK/fixture.yaml" <<'YAML'
languages: [en]
transforms:
  - { name: probe, description: d, command: probe.py alpha }
  - { name: other, description: d, command: probe/probe.py beta }
  - { name: plain, description: d, command: plain.py }
  - { name: raises, description: d, command: raises.py }
  - { name: exits, description: d, command: exits.py }
  - { name: hangs, description: d, command: hangs.py, timeout_seconds: 1 }
  - { name: dies, description: d, command: dies.py }
  - { name: edited, description: d, command: edited.py }
  - { name: editor, description: d, command: editor.py }
  - { name: norun, description: d, command: norun.py }
YAML

run() {  # run <transform names> [PATH] -> the out: line
  { cat "$WORK/fixture.yaml"; echo "pipeline:"; for name in $1; do echo "  - transform: $name"; done; } \
    > "$WORK/run.yaml"
  rm -f "$HOME"/Library/Logs/*.log
  PATH="${2:-$PATH}" "$BIN" --pipeline "$WORK/run.yaml" "x" 2>/dev/null | sed -n 's/^out:  //p'
}
log() { cat "$HOME"/Library/Logs/*.log 2>/dev/null; }
nopid() { sed -E 's/ pid=[0-9]+//g'; }

echo "env, argv and cwd per call"
out=$(run 'probe other probe')
check "each call sees its own argv, folder and env" \
  "$(nopid <<<"$out")" "x probe=1:alpha:probe:- probe=2:beta:other:- probe=3:alpha:probe:-"
check "one worker answered all three" "$(grep -o 'pid=[0-9]*' <<<"$out" | sort -u | wc -l | tr -d ' ')" 1

echo "a script without the opt-in"
check "runs as a process each time" "$(run 'plain plain')" "x plain=1 plain=1"

echo "a script that raises, then one that exits"
out=$(run 'probe raises exits probe')
check "the text is kept and the worker lives on" "$(nopid <<<"$out")" \
  "x probe=1:alpha:probe:- probe=2:alpha:probe:-"
check "the raise is logged" "$(log | grep -c 'raises.py" failed in the Python worker: ValueError: boom')" 1
check "the exit is logged" "$(log | grep -c 'exits.py" failed in the Python worker: exited 3')" 1

echo "a script that hangs past its timeout"
out=$(run 'probe hangs hangs probe')
check "the hung step falls back to a process" "$(nopid <<<"$out")" \
  "x probe=1:alpha:probe:- hangs=1 hangs=1 probe=1:alpha:probe:-"
check "the hung worker is killed and replaced" \
  "$(log | grep -c 'python worker: took longer than 1s on "hangs.py"; killed pid')" 1
first=$(sed -n 's/^x probe=[^ ]* pid=\([0-9]*\).*/\1/p' <<<"$out")
last=$(sed -n 's/.* probe=[^ ]* pid=\([0-9]*\)$/\1/p' <<<"$out")
[ -n "$first" ] && [ "$first" != "$last" ] && fresh=yes || fresh=no
check "the next step runs in a new worker" "$fresh" yes

echo "a worker killed mid-session"
out=$(run 'dies dies probe')
check "the step falls back and a new worker takes the next" "$(nopid <<<"$out")" \
  "x dies=1 dies=1 probe=1:alpha:probe:-"
check "the death is logged" "$(log | grep -c 'python worker: stopped during "dies.py"')" 1

echo "a script edited between two calls"
check "the new code runs" "$(run 'edited editor edited')" "x version=1 n=1 edit version=2 n=1"

echo "a script with no run(envelope)"
check "runs as a process" "$(run 'norun')" "x norun"
check "and says why once" "$(log | grep -c 'norun.py" runs as a process: the Python worker says it has no run(envelope)')" 1

echo "the worker turned off"
sed -i '' 's/version=2/version=1/' "$WORK/transforms/edited/edited.py"
out=$(PARROTFLOW_PYTHON_WORKER=off run 'probe probe')
check "every step is a process" "$(nopid <<<"$out")" \
  "x probe=1:alpha:probe:- probe=1:alpha:probe:-"

echo "no python3 on PATH"
out=$(run 'probe' /bin)
check "the step fails as a process would" "$out" "x"
check "and the log says so once" "$(log | grep -c 'python worker: no python3 on PATH')" 1

echo
if [ "$pass" = "$total" ]; then
  echo "python runner: $pass/$total"
else
  echo "python runner: $pass/$total — failed:$failed"
  exit 1
fi
