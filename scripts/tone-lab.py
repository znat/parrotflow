#!/usr/bin/env python3
"""A local page to try tone instructions on your last spoken Claude lines.

    scripts/tone-lab.py [port]          # then open http://127.0.0.1:8765

Each Play runs the installed dev app's binary (`--claude-say --tone --voice`),
which holds the OpenRouter key and plays on this Mac. The key never reaches the
page. Listens on 127.0.0.1 only and refuses requests from other origins.
"""
import html
import json
import os
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIN = os.environ.get("PF_BIN", "/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow")
LOG = os.environ.get("PF_LOG", os.path.expanduser("~/Library/Logs/ParrotFlow-Dev.log"))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
ORIGIN = f"http://127.0.0.1:{PORT}"

BASE_TONE = ("Speak in a relaxed, friendly, natural tone, like a software engineer colleague "
             "collaborating with a teammate, speaking face to face. Clear and conversational, not performative.")
SHIFTS = ["a little pleased", "calm, a little sorry", "curious", "easy, routine", "upbeat", "warm, unhurried"]
VOICES = ["Achird", "Sulafat", "Zubenelgenubi", "Callirrhoe", "Umbriel", "Aoede", "Zephyr", "Puck", "Charon",
          "Kore", "Fenrir", "Leda", "Orus", "Autonoe", "Enceladus", "Iapetus", "Algieba", "Despina", "Erinome",
          "Algenib", "Rasalgethi", "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima",
          "Vindemiatrix", "Sadachbia", "Sadaltager"]
# Diagnostics the app logs under the same prefix; not spoken text.
NOT_SPOKEN = re.compile(r"^(listening on|PocketTTS|.* spoke \d+ chars|.* explained |explanation took|reminder for|"
                        r".* (rewrote|keep|shorten) \d+ chars|stopped by|dropped|rewrite failed|.* failed|"
                        r".* refused the tone)")
speaking = threading.Lock()


def last_lines(count):
    try:
        text = open(LOG, encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    said = re.findall(r"claude voice: said: (.*)", text)
    if not said:  # builds before the log kept whole lines: cut to 120 characters
        said = [line for line in re.findall(r"claude voice: (.*)", text) if not NOT_SPOKEN.match(line)]
    return said[-count:]


PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>Tone lab</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{--bg:#fff;--fg:#1d1b26;--muted:#6b6880;--line:#e3e0ee;--accent:#5F46CA;--chip:#f1eefb}
@media (prefers-color-scheme:dark){:root{--bg:#16141d;--fg:#ece9f6;--muted:#9a96ad;--line:#2e2a3b;--accent:#9d8cf2;--chip:#24203a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 -apple-system,system-ui,sans-serif}
main{max-width:860px;margin:0 auto;padding:24px 16px 64px}h1{font-size:20px;margin:0 0 4px}p.sub{color:var(--muted);margin:0 0 20px}
label{display:block;font-weight:600;margin:16px 0 6px}textarea{width:100%;border:1px solid var(--line);border-radius:8px;
padding:10px;background:transparent;color:inherit;font:inherit;resize:vertical}select{font:inherit;padding:6px 8px;border-radius:8px;
border:1px solid var(--line);background:transparent;color:inherit}.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
.chip{border:1px solid var(--line);background:var(--chip);color:inherit;border-radius:999px;padding:4px 10px;cursor:pointer;font:inherit;font-size:13px}
.row{display:flex;gap:10px;align-items:flex-start;margin-top:10px}.row textarea{flex:1;min-height:64px}
button.play{background:var(--accent);color:#fff;border:0;border-radius:8px;padding:9px 14px;font:inherit;font-weight:600;cursor:pointer;white-space:nowrap}
button.play:disabled{opacity:.5;cursor:default}.bar{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
#status{color:var(--muted);font-size:13px;min-height:1.4em;margin-top:12px}
@media (max-width:560px){.row{flex-direction:column}.row button{width:100%}}
</style></head><body><main>
<h1>Tone lab</h1><p class="sub">Your last spoken Claude lines. Edit the tone or the words, then play. Sound comes from this Mac.</p>
<label for="tone">Tone instructions (sent as <code>instructions</code>)</label>
<textarea id="tone" rows="4">__TONE__</textarea>
<div class="chips" id="shifts"></div>
<label for="voice">Voice</label>
<div class="bar"><select id="voice">__VOICES__</select>
<button class="play" id="all">Play all</button></div>
<label>Lines</label><div id="lines"></div>
<div id="status"></div>
</main><script>
const shifts=__SHIFTS__, base=__BASE__;
const tone=document.getElementById('tone'), status=document.getElementById('status');
for(const s of shifts){const b=document.createElement('button');b.className='chip';b.textContent='Right now: '+s;
 b.onclick=()=>{tone.value=base+' Right now: '+s+'.'};document.getElementById('shifts').appendChild(b)}
const reset=document.createElement('button');reset.className='chip';reset.textContent='Base only';reset.onclick=()=>{tone.value=base};
document.getElementById('shifts').appendChild(reset);
let busy=false;
async function say(text){
 const r=await fetch('/say',{method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({text,tone:tone.value,voice:document.getElementById('voice').value})});
 const j=await r.json(); if(!r.ok) throw new Error(j.error||r.status); return j}
async function run(texts){ if(busy) return; busy=true; document.querySelectorAll('button.play').forEach(b=>b.disabled=true);
 try{for(const [i,t] of texts.entries()){status.textContent='Playing '+(i+1)+' of '+texts.length+'…';const j=await say(t);status.textContent=j.output||'Done.'}
  status.textContent+=' ✓'}catch(e){status.textContent='Failed: '+e.message}
 busy=false; document.querySelectorAll('button.play').forEach(b=>b.disabled=false)}
fetch('/lines').then(r=>r.json()).then(lines=>{const box=document.getElementById('lines');
 if(!lines.length){box.textContent='No spoken lines in the log yet.';return}
 for(const l of lines){const row=document.createElement('div');row.className='row';const t=document.createElement('textarea');t.value=l;
  const b=document.createElement('button');b.className='play';b.textContent='Play';b.onclick=()=>run([t.value]);row.append(t,b);box.appendChild(row)}
 document.getElementById('all').onclick=()=>run([...box.querySelectorAll('textarea')].map(t=>t.value))});
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body, kind="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/":
            page = (PAGE.replace("__TONE__", html.escape(BASE_TONE))
                    .replace("__VOICES__", "".join(f"<option>{v}</option>" for v in VOICES))
                    .replace("__SHIFTS__", json.dumps(SHIFTS)).replace("__BASE__", json.dumps(BASE_TONE)))
            self.send(200, page, "text/html; charset=utf-8")
        elif self.path.startswith("/lines"):
            self.send(200, json.dumps(last_lines(6)))
        else:
            self.send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        # Only this page may make the Mac speak.
        if self.path != "/say" or self.headers.get("Origin") not in (ORIGIN, f"http://localhost:{PORT}"):
            return self.send(403, json.dumps({"error": "forbidden"}))
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            text, tone, voice = str(body["text"])[:2000], str(body["tone"])[:1000], str(body["voice"])
        except (ValueError, KeyError):
            return self.send(400, json.dumps({"error": "bad request"}))
        if voice not in VOICES or not text.strip():
            return self.send(400, json.dumps({"error": "bad voice or empty text"}))
        with speaking:
            run = subprocess.run([BIN, "--claude-say", text, "--tone", tone, "--voice", voice],
                                 capture_output=True, text=True, timeout=120)
        output = " ".join(line for line in run.stdout.splitlines() if line.startswith(("voice:", "done in")))
        self.send(200 if run.returncode == 0 else 500, json.dumps({"output": output, "code": run.returncode}))


if __name__ == "__main__":
    if not os.access(BIN, os.X_OK):
        sys.exit(f"no app at {BIN}; run make install first")
    print(f"Tone lab on {ORIGIN}  (Ctrl-C to stop)")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
