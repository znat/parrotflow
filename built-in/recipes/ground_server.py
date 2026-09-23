"""TinyClick on MLX, as a helper process for `ground.py`. It runs in its own
Python (`scripts/setup-vision.sh`), not the runner's.

It loads the model once and answers one JSON object per line, on stdin and
stdout:

    helper  {"up": <pid>, "load_ms": ..}                       once, when loaded
    runner  {"image": "<path>" | "<base64>", "crop": {"x", "y", "w", "h"}, "text": ".."}
    helper  {"x": .., "y": .., "ms": .., "raw": ".."} | {"abstain": true, "ms": ..} | {"error": ".."}

`crop` is the part of the image to look at, in its pixels: x, y its top left.
The point comes back in the crop's pixels. TinyClick answers the crop's exact
centre when it finds nothing: that is an abstain. It exits on EOF, and after
PARROTFLOW_GROUND_IDLE seconds (300) without a request.

    python ground_server.py --check     loads the model, says how long it took
"""

import base64
import io
import json
import os
import re
import select
import sys
import time

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_VERBOSITY", "error")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
_out = sys.stdout
sys.stdout = sys.stderr

MODEL = os.environ.get("PARROTFLOW_GROUND_MODEL") or os.path.expanduser(
    "~/Library/Application Support/ParrotFlow Dev/models/tinyclick-mlx")
IDLE = float(os.environ.get("PARROTFLOW_GROUND_IDLE") or 300)
LOC = re.compile(r"<loc_(\d+)>")
# `<loc_499><loc_499>`: the centre of the crop, TinyClick's answer when the
# target is not in it.
ABSTAIN = (499, 499)
END = 2
MAX_TOKENS = 24


class TinyClick:
    def __init__(self, folder):
        from pathlib import Path

        import mlx.core as mx
        from mlx_vlm.utils import generate_step, load_model
        from transformers import BartTokenizerFast, CLIPImageProcessor

        self.mx, self.generate_step = mx, generate_step
        # Unbounded, MLX kept 3.7 GB of freed buffers: 4.4 GB footprint and
        # 218 ms a call. At 128 MB: 1.0 GB and 262 ms (09-23).
        mx.set_cache_limit(128 * 1024 * 1024)
        # Not Florence2Processor: its code imports torch. For a prompt without
        # a task token it is these two, and the tokens came out the same.
        # Without False, transformers asks on stdin whether to run the
        # folder's code, and waits 15 s for an answer.
        self.model = load_model(Path(folder), trust_remote_code=False)
        self.tokenizer = BartTokenizerFast.from_pretrained(folder)
        self.images = CLIPImageProcessor.from_pretrained(folder)

    def point(self, image, text):
        """(x, y) in `image`'s pixels or None, the raw answer, ms."""
        mx = self.mx
        prompt = ("What to do to execute the command? click on " + text.strip()).lower()
        started = time.perf_counter()
        ids = mx.array(self.tokenizer(prompt, return_tensors="np")["input_ids"])
        pixels = mx.array(self.images(image, return_tensors="np", do_resize=True)["pixel_values"])
        out = []
        for token, _ in self.generate_step(ids, self.model, pixels, None,
                                           max_tokens=MAX_TOKENS, temperature=0.0):
            token = int(token)
            if token == END:
                break
            out.append(token)
        raw = self.tokenizer.decode(out, skip_special_tokens=False)
        ms = int((time.perf_counter() - started) * 1000)
        locs = [int(v) for v in LOC.findall(raw)]
        if len(locs) < 2 or tuple(locs[:2]) == ABSTAIN:
            return None, raw, ms
        return (locs[0] / 1000 * image.width, locs[1] / 1000 * image.height), raw, ms


def _image(source):
    from PIL import Image

    if source.startswith("data:"):
        source = source.split(",", 1)[1]
    if os.path.exists(source):
        return Image.open(source).convert("RGB")
    return Image.open(io.BytesIO(base64.b64decode(source))).convert("RGB")


def answer(model, request):
    image = _image(str(request.get("image") or ""))
    crop = request.get("crop") or {}
    if crop:
        x, y = round(crop["x"]), round(crop["y"])
        box = (max(0, x), max(0, y), min(image.width, x + round(crop["w"])),
               min(image.height, y + round(crop["h"])))
        if box[2] - box[0] < 2 or box[3] - box[1] < 2:
            return {"error": "the crop is not in the image"}
        image = image.crop(box)
    point, raw, ms = model.point(image, str(request.get("text") or ""))
    if point is None:
        return {"abstain": True, "ms": ms, "raw": raw}
    return {"x": round(point[0], 1), "y": round(point[1], 1), "ms": ms, "raw": raw}


def send(message):
    _out.write(json.dumps(message) + "\n")
    _out.flush()


def main():
    started = time.monotonic()
    model = TinyClick(MODEL)
    from PIL import Image

    # The first generation compiles: 355 ms against 195 warm.
    model.point(Image.new("RGB", (600, 400), "white"), "ok")
    load_ms = int((time.monotonic() - started) * 1000)
    if "--check" in sys.argv:
        import mlx.core as mx

        print(f"Check:   the model loads and answers, {load_ms / 1000:.1f} s, mlx {mx.__version__}",
              file=_out)
        return
    print(f"ground_server: loaded {MODEL} in {load_ms} ms")
    send({"up": os.getpid(), "load_ms": load_ms})
    while True:
        ready, _, _ = select.select([sys.stdin], [], [], IDLE)
        if not ready:
            print(f"ground_server: idle for {IDLE:.0f} s, exiting")
            return
        line = sys.stdin.readline()
        if not line:
            return
        if not line.strip():
            continue
        try:
            send(answer(model, json.loads(line)))
        except Exception as error:
            send({"error": f"{type(error).__name__}: {error}"[:300]})


if __name__ == "__main__":
    main()
