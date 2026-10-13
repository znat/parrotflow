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
    """Raise a descriptive validation error when a campaign invariant fails."""
    if not condition:
        raise ValueError(message)


def read(path):
    """Read a UTF-8 JSON artifact."""
    return json.loads(Path(path).read_text())


def write(path, value):
    """Atomically replace a JSON artifact through a sibling temporary file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix+'.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n')
    temporary.replace(path)


def sha(path):
    """Hash the bytes of a source or artifact file."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fingerprint(value):
    """Hash a canonical JSON representation for compatibility checks."""
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def normalized(text):
    """Normalize case and whitespace for train/heldout collision checks."""
    return ' '.join(text.casefold().split())


def verify_bundle(directory):
    """Reject any prepared input whose content no longer matches its manifest."""
    directory = Path(directory)
    manifest = read(directory/'manifest.json')
    for name, expected in manifest['files'].items():
        require(sha(directory/name)==expected, f'Changed prepared input: {name}')
    return manifest
