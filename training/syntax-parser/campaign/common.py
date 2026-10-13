import hashlib
import json
from pathlib import Path

LANGUAGES = ('en', 'fr', 'es')
ATTRIBUTES = ('Number', 'Person', 'Tense', 'VerbForm', 'Mood', 'Degree', 'Voice', 'Gender')
UPOS = 'ADJ ADP ADV AUX CCONJ DET INTJ NOUN NUM PART PRON PROPN PUNCT SCONJ SYM VERB X'.split()
TYPES = ['person', 'vendor_platform', 'project', 'location', 'product_tool']
BIO = ['O'] + [f'{p}-{t}' for t in TYPES for p in ('B', 'I')]
ABSENT = '<ABSENT>'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix+'.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n')
    temporary.replace(path)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def normalized(text):
    return ' '.join(text.casefold().split())


def verify_bundle(directory):
    directory = Path(directory)
    manifest = read(directory/'manifest.json')
    for name, expected in manifest['files'].items():
        require(sha(directory/name)==expected, f'Changed prepared input: {name}')
    return manifest
