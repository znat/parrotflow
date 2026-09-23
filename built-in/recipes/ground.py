"""Visual grounding: a point on screen for a target the tree has no ID for,
found in the pixels of the newest read.

PARROTFLOW_GROUND picks how (`actions.ground` in the config):

    tinyclick   TinyClick on MLX, in a helper process (`ground_server.py`)
    luna        the planner's model, shown the crop as a 512 px JPEG
    off         no grounding

TinyClick runs in its own Python, PARROTFLOW_GROUND_PYTHON, with the model at
PARROTFLOW_GROUND_MODEL; `scripts/setup-vision.sh` makes both. Without them
`tinyclick` falls back to `luna`. The helper starts on the first call and
exits after 5 idle minutes; the next call starts it again.

Every crop is 600×400 points at most, and never the whole window: TinyClick
hit 35/42 on crops of that size and 20/42 on whole windows (09-23).
"""

import base64
import io
import json
import os
import queue
import subprocess
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
METHODS = ("tinyclick", "luna", "off")
CROP_W, CROP_H = 600, 400
# Luna's image: 512 px on the long side, `detail: low`. 39/42 at ~300 tokens
# in, ~1.2 s (09-23). 1024 px and `high` did no better.
LUNA_SIDE = 512
START_SECONDS = 30
CALL_SECONDS = 3
POINT = {"name": "point", "strict": True, "schema": {
    "type": "object", "additionalProperties": False,
    "properties": {"found": {"type": "boolean"}, "x": {"type": "integer"},
                   "y": {"type": "integer"}},
    "required": ["found", "x", "y"]}}


class Unavailable(Exception):
    pass


# Geometry. Regions are centre and size in screen points, as items carry
# them; boxes are (left, top, right, bottom).


def box_of(region):
    return (region["x"] - region["w"] / 2, region["y"] - region["h"] / 2,
            region["x"] + region["w"] / 2, region["y"] + region["h"] / 2)


def crop_box(region, frame, anchor="centre"):
    """The part of the window's picture to look at, in points: `region`
    grown or cut to 600×400 and kept inside `frame`. `anchor` keeps one edge
    of the region where it is when it is cut: "top" for a list below a field,
    "bottom" above it, "left" and "right" likewise. None when the region is
    not in the frame."""
    fx0, fy0 = frame["x"], frame["y"]
    fx1, fy1 = fx0 + frame["w"], fy0 + frame["h"]
    x0, y0, x1, y1 = box_of(region)
    if x1 <= fx0 or x0 >= fx1 or y1 <= fy0 or y0 >= fy1:
        return None
    w, h = min(CROP_W, frame["w"]), min(CROP_H, frame["h"])

    def fit(lo, hi, size, keep_lo, keep_hi, low, high):
        if hi - lo > size and keep_lo:
            lo, hi = lo, lo + size
        elif hi - lo > size and keep_hi:
            lo, hi = hi - size, hi
        else:
            middle = (lo + hi) / 2
            lo, hi = middle - size / 2, middle + size / 2
        if lo < low:
            lo, hi = low, low + size
        if hi > high:
            lo, hi = high - size, high
        return lo, hi

    x0, x1 = fit(x0, x1, w, anchor in ("top", "bottom", "left"), anchor == "right", fx0, fx1)
    y0, y1 = fit(y0, y1, h, anchor == "top", anchor == "bottom", fy0, fy1)
    return (x0, y0, x1, y1)


def pixels(box, shot):
    """`box` in points as {x, y, w, h} in the shot's pixels, x, y top left."""
    frame, scale = shot["frame"], float(shot.get("scale") or 1)
    return {"x": round((box[0] - frame["x"]) * scale), "y": round((box[1] - frame["y"]) * scale),
            "w": round((box[2] - box[0]) * scale), "h": round((box[3] - box[1]) * scale)}


def jpeg(path, crop, side=LUNA_SIDE):
    """The crop of the picture at `path`, at most `side` px on its long side,
    as JPEG bytes, and its size."""
    from PIL import Image

    image = Image.open(path).convert("RGB")
    image = image.crop((crop["x"], crop["y"], crop["x"] + crop["w"], crop["y"] + crop["h"]))
    k = side / max(image.size)
    if k < 1:
        image = image.resize((round(image.width * k), round(image.height * k)), Image.LANCZOS)
    out = io.BytesIO()
    image.save(out, "JPEG", quality=70)
    return out.getvalue(), image.size


# The helper


class Helper:
    """`ground_server.py` in its own Python. Started on the first call; a
    helper that exited (idle, crashed) is started again on the next."""

    def __init__(self, python, model, log, server=None):
        self.python = python
        self.model = model
        self.server = server or os.path.join(HERE, "ground_server.py")
        self.log = log
        self.process = None
        self.lines = None
        self.load_ms = None

    def ready(self):
        return bool(self.python) and os.path.isfile(self.python) \
            and os.path.isdir(self.model or "") and os.path.isfile(self.server)

    def _start(self):
        env = dict(os.environ, PARROTFLOW_GROUND_MODEL=self.model, PYTHONIOENCODING="utf-8")
        for name in list(env):
            if name.endswith("_KEY") and name.startswith("PARROTFLOW_"):
                del env[name]
        started = time.monotonic()
        try:
            self.process = subprocess.Popen(
                [self.python, "-u", self.server], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                env=env, text=True, encoding="utf-8")
        except OSError as error:
            raise Unavailable(f"could not start TinyClick: {error}")
        self.lines = queue.Queue()
        threading.Thread(target=self._read, args=(self.process, self.lines), daemon=True).start()
        up = self._next(START_SECONDS)
        if not up or "up" not in up:
            self.stop()
            raise Unavailable("TinyClick did not start" + (f": {up.get('error')}" if up else
                                                           f" in {START_SECONDS} s"))
        self.load_ms = up.get("load_ms")
        self.log(f"ground: TinyClick up in {int((time.monotonic() - started) * 1000)} ms "
                 f"(model {self.load_ms} ms)")

    @staticmethod
    def _read(process, lines):
        for line in process.stdout:
            try:
                lines.put(json.loads(line))
            except ValueError:
                pass
        lines.put(None)

    def _next(self, seconds):
        try:
            return self.lines.get(timeout=seconds)
        except queue.Empty:
            return None

    def ask(self, image, crop, text):
        """The helper's answer, or Unavailable."""
        if self.process is None or self.process.poll() is not None:
            self._start()
        try:
            self.process.stdin.write(json.dumps({"image": image, "crop": crop, "text": text}) + "\n")
            self.process.stdin.flush()
        except OSError:
            self.stop()
            raise Unavailable("TinyClick exited")
        reply = self._next(CALL_SECONDS)
        if reply is None:
            self.stop()
            raise Unavailable(f"TinyClick did not answer in {CALL_SECONDS} s")
        return reply

    def stop(self):
        if self.process is not None and self.process.poll() is None:
            self.process.kill()
        self.process = None


class Grounder:
    """One per runner. `method` is what the setting asked for; `using` is
    what runs, after the fallback."""

    def __init__(self, method, helper=None, log=None):
        self.method = method if method in METHODS else "off"
        self.helper = helper
        self.log = log or (lambda line: None)
        self.fell_back = False

    @classmethod
    def from_env(cls):
        env = os.environ
        support = env.get("PARROTFLOW_SUPPORT") or os.path.expanduser(
            "~/Library/Application Support/ParrotFlow Dev")
        python = env.get("PARROTFLOW_GROUND_PYTHON") or os.path.join(
            support, "vision-venv", "bin", "python")
        model = env.get("PARROTFLOW_GROUND_MODEL") or os.path.join(
            support, "models", "tinyclick-mlx")
        helper = Helper(python, model, None, env.get("PARROTFLOW_GROUND_SERVER") or None)
        return cls((env.get("PARROTFLOW_GROUND") or "off").strip().lower(), helper)

    @property
    def on(self):
        return self.method != "off"

    @property
    def using(self):
        if self.method == "tinyclick" and not (self.helper and self.helper.ready()):
            return "luna"
        return self.method

    def point(self, shot, box, text, planner, log):
        """Where `text` is inside `box` (points), in the picture of `shot`.
        A dict: `point` [x, y] in screen points or None (not found),
        `method`, `crop` (pixels), `ms`, `tokens`, `raw`, and `error` when
        it could not look. `image`: the JPEG shown to Luna."""
        self.log = log
        if self.helper is not None:
            self.helper.log = log
        crop = pixels(box, shot)
        method = self.using
        if method != self.method and not self.fell_back:
            self.fell_back = True
            log(f"ground: TinyClick is not set up ({self.helper.python}), using luna — "
                "run scripts/setup-vision.sh")
        out = {"method": method, "crop": crop, "point": None, "ms": 0, "tokens": None}
        started = time.monotonic()
        try:
            if method == "tinyclick":
                try:
                    reply = self.helper.ask(shot["file"], crop, text)
                except Unavailable as error:
                    log(f"ground: {error}, using luna")
                    out["method"] = method = "luna"
                    reply = None
                if reply is not None:
                    out["raw"] = reply.get("raw")
                    if reply.get("error"):
                        out["error"] = str(reply["error"])
                    elif not reply.get("abstain"):
                        out["point"] = self._screen(box, crop, reply["x"], reply["y"], shot)
            if method == "luna":
                out.update(self._luna(shot, box, crop, text, planner))
        except Unavailable as error:
            out["error"] = str(error)
        out["ms"] = int((time.monotonic() - started) * 1000)
        return out

    @staticmethod
    def _screen(box, crop, x, y, shot, size=None):
        """A point in the crop's pixels, or in an image of `size` made from
        it, as screen points."""
        w, h = size or (crop["w"], crop["h"])
        return [round(box[0] + x / w * (box[2] - box[0]), 1),
                round(box[1] + y / h * (box[3] - box[1]), 1)]

    def _luna(self, shot, box, crop, text, planner):
        if planner is None or not planner.key:
            raise Unavailable("no planner to ask")
        try:
            data, size = jpeg(shot["file"], crop)
        except ImportError:
            raise Unavailable("the runner's Python has no PIL to cut the picture")
        except OSError as error:
            raise Unavailable(f"could not read the picture: {error}")
        prompt = (f"This image is {size[0]}x{size[1]} pixels. Return the centre of {text.strip()} "
                  "as x,y in this image's pixels. Set found to false if it is not visible.")
        messages = [{"role": "user", "content": [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {
                "url": "data:image/jpeg;base64," + base64.b64encode(data).decode(),
                "detail": "low"}}]}]
        import planner as planning

        try:
            message, usage, _ = planner.chat(messages, response_format={
                "type": "json_schema", "json_schema": POINT})
            answer = json.loads(message.get("content") or "{}")
        except planning.Failure as error:
            raise Unavailable(str(error))
        except ValueError:
            raise Unavailable("Luna's answer could not be read")
        out = {"image": data, "raw": json.dumps(answer),
               "tokens": {"in": usage.get("prompt_tokens", 0),
                          "out": usage.get("completion_tokens", 0)}}
        if answer.get("found") and isinstance(answer.get("x"), int) \
                and isinstance(answer.get("y"), int) \
                and 0 <= answer["x"] <= size[0] and 0 <= answer["y"] <= size[1]:
            out["point"] = self._screen(box, crop, answer["x"], answer["y"], shot, size)
        return out

    def stop(self):
        if self.helper is not None:
            self.helper.stop()
