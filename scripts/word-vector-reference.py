"""The reference the Swift path is checked against.

Same weights, same runtime, same token filter. A disagreement is Swift's
packing and nothing else.
"""
import json
import numpy as np
import mlx.core as mx
from mlx_lm import load
from transformers import AutoTokenizer

CASES = [
    ("I deploy my app on Vercel.", "Vercel"),
    ("The old house looked ghostly in the fog.", "ghostly"),
    ("I gave to the Red Cross again last year.", "Red Cross"),
    ("Mik is reviewing the pull request this afternoon.", "Mik"),
    ("Zylbersztejn is hard for any decoder to hear.", "Zylbersztejn"),
    ("Let us praise the team for shipping on time.", "praise"),
]
m, _ = load("mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ")
hf = AutoTokenizer.from_pretrained("Qwen/Qwen3-Embedding-0.6B")
out = []
for text, word in CASES:
    enc = hf(text, add_special_tokens=False, return_offsets_mapping=True,
             truncation=True, max_length=64)
    a = text.index(word); b = a + len(word)
    inw = [i for i, (s, e) in enumerate(enc["offset_mapping"]) if s < b and e > a and e > s]
    outw = [i for i in range(len(enc["input_ids"])) if i not in inw]
    h = m.model(mx.array([enc["input_ids"]]))
    row = {"sentence": text, "word": word, "tokens": len(enc["input_ids"])}
    for name, p in (("inside", inw), ("around", outw)):
        v = np.array(h[0, p, :].astype(mx.float32)).mean(0)
        v = v / np.linalg.norm(v)
        row[name] = {"taken": p, "head": [round(float(x), 4) for x in v[:8]]}
    out.append(row)
print(json.dumps({"model": "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
                  "cases": out}, indent=2))
