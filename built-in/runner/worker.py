#!/usr/bin/env python3
"""Runs the Python transforms that declare `runner: python`, in one process.

ParrotFlow starts this with the interpreter a `#!/usr/bin/env python3` script
gets, and the paths of the scripts to import first as arguments. Then one JSON
request per line on stdin, one answer per line on stdout, in order:

    {"id": 1, "script": "/abs/en.py", "argv": ["--x"], "env": {...},
     "cwd": "/abs", "envelope": {...}}
    {"id": 1, "result": {"text": "...", "vars": {...}}}
    {"id": 1, "error": "ValueError: ..."}         the step fails, as a crash would
    {"id": 1, "fallback": "has no run(envelope)"}  the app runs it as a process

The first line out is `{"ready": true, ...}`, after the imports. Anything a
script prints goes to stderr, which the app writes to its log.
"""
import importlib.util
import json
import os
import sys
import threading
import time
import traceback

REQUESTS = os.fdopen(os.dup(0), "rb")
ANSWERS = os.fdopen(os.dup(1), "wb")
with open(os.devnull, "rb") as nothing:
    os.dup2(nothing.fileno(), 0)
os.dup2(2, 1)
sys.stdin = open(os.devnull)
sys.stdout = os.fdopen(1, "w", buffering=1)
sys.path = [p for p in sys.path if os.path.abspath(p or ".") != os.path.dirname(os.path.abspath(__file__))]


def say(message):
    ANSWERS.write(json.dumps(message).encode() + b"\n")
    ANSWERS.flush()


def stamp(path):
    try:
        found = os.stat(path)
    except OSError:
        return None
    return found.st_mtime_ns, found.st_size


def inside(module, folder):
    where = getattr(module, "__file__", None)
    return bool(where) and os.path.realpath(where).startswith(folder + os.sep)


class Script:
    """One imported script, with the modules it imported from its own folder.

    Those are kept out of `sys.modules` between calls, so `dates/en.py` and
    `money/en.py` each get their own `engine`.
    """

    def __init__(self, path):
        self.path = path
        self.folder = os.path.dirname(os.path.realpath(path))
        self.name = "parrotflow_%x" % (hash(path) & 0xFFFFFFFFFFFF)
        self.own = {}
        self.module = None
        self.files = {}
        self.loaded = []
        self.problem = None
        with self.installed(), self.watching():
            spec = importlib.util.spec_from_file_location(self.name, path)
            module = importlib.util.module_from_spec(spec)
            sys.modules[self.name] = module
            try:
                spec.loader.exec_module(module)
            except BaseException as error:  # noqa: B036 - SystemExit at import is a refusal too
                sys.modules.pop(self.name, None)
                self.problem = "could not be imported: " + described(error)
                return
        if not callable(getattr(module, "run", None)):
            self.problem = "has no run(envelope)"
            return
        self.module = module

    def installed(self):
        return _Installed(self)

    def watching(self):
        """Records the files a script loads by path, as `dates/engine.py` loads
        `numbers/en.py`, so an edit to one of them imports the script again."""
        script, original = self, importlib.util.spec_from_file_location

        class Watching:
            def __enter__(self):
                def recorded(name, location=None, *args, **kwargs):
                    if location is not None:
                        script.loaded.append(os.fspath(location))
                    return original(name, location, *args, **kwargs)
                importlib.util.spec_from_file_location = recorded

            def __exit__(self, *_):
                importlib.util.spec_from_file_location = original
                script.files.update({path: stamp(path) for path in script.loaded})
                return False

        return Watching()

    def changed(self):
        return any(stamp(path) != seen for path, seen in self.files.items())


class _Installed:
    """The script's own modules in `sys.modules` and its folder first on
    `sys.path`, for an import or a call, and taken out again after."""

    def __init__(self, script):
        self.script = script

    def __enter__(self):
        s = self.script
        self.path = list(sys.path)
        self.before = set(sys.modules)
        self.shadowed = {name: sys.modules[name] for name in s.own if name in sys.modules}
        sys.modules.update(s.own)
        sys.path.insert(0, s.folder)

    def __exit__(self, *_):
        s = self.script
        for name in set(sys.modules) - self.before:
            if name != s.name and inside(sys.modules[name], s.folder):
                s.own[name] = sys.modules[name]
        for name in s.own:
            sys.modules.pop(name, None)
        sys.modules.update(self.shadowed)
        sys.path[:] = self.path
        s.files.update({path: stamp(path) for path in
                        [s.path] + [m.__file__ for m in s.own.values()]})
        return False


def described(error):
    return "".join(traceback.format_exception_only(type(error), error)).strip()


SCRIPTS = {}


def script(path):
    found = SCRIPTS.get(path)
    if found is None or found.changed():
        if found is not None:
            sys.modules.pop(found.name, None)
        found = SCRIPTS[path] = Script(path)
        if found.problem:
            sys.stderr.write("%s %s\n" % (path, found.problem))
    return found


def call(request):
    os.environ.clear()
    os.environ.update(request["env"])
    sys.argv = [request["script"]] + list(request["argv"])
    try:
        os.chdir(request["cwd"])
    except OSError as error:
        return {"error": described(error)}
    found = script(request["script"])
    if found.problem:
        return {"fallback": found.problem}
    with found.installed():
        try:
            result = found.module.run(request["envelope"])
        except SystemExit as stop:
            if isinstance(stop.code, str):
                return {"error": stop.code}
            return {"error": "exited %s" % (stop.code if stop.code is not None else 0)}
        except Exception as error:
            return {"error": described(error)}
        finally:
            sys.stdout.flush()
    if not isinstance(result, dict):
        return {"error": "run() returned %s, not a dict" % type(result).__name__}
    return {"result": result}


def orphaned(parent):
    while os.getppid() == parent:
        time.sleep(1)
    os._exit(0)


def main():
    threading.Thread(target=orphaned, args=(os.getppid(),), daemon=True).start()
    for path in sys.argv[1:]:
        script(path)
    say({"ready": True, "pid": os.getpid(), "python": sys.version.split()[0]})
    for line in REQUESTS:
        request = json.loads(line)
        answer = call(request)
        answer["id"] = request["id"]
        try:
            say(answer)
        except (TypeError, ValueError) as error:
            say({"id": request["id"], "error": "returned what JSON cannot hold: " + described(error)})


if __name__ == "__main__":
    main()
