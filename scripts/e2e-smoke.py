"""End-to-end smoke test: this server wrapping a real jdtls, over a notebook document.

Checks the thing the unit tests cannot: that the projection is something jdtls will actually
compile, and that cell coordinates survive the round trip -- a hover asked for at the line the
user sees comes back about the right symbol, and a diagnostic comes back on the notebook's own
URI at the notebook's own line.

Not part of the test suite yet; it needs a jdtls and a JDK, and wiring those up is the same
work as the integration tests this repo still owes. Run it by hand:

    nix build .#java-parser
    stack build
    python3 scripts/e2e-smoke.py \\
      $(ls .stack-work/install/*/*/*/bin/java-notebook-language-server) \\
      "$(which jdtls)" \\
      ./result/bin/java-parser
"""
import json, os, pathlib, subprocess, sys, tempfile, threading, time

JNLS = sys.argv[1]
JDTLS = sys.argv[2]
JAVA_PARSER = sys.argv[3]

CELLS = """import java.util.List;

int x = 41;

int doubled(int v) {
    return v * 2;
}

System.out.println(doubled(x));
x + 1
"""

WORK = tempfile.mkdtemp(prefix="jnlse2e")
HOME = tempfile.mkdtemp(prefix="jnlshome")
notebook = os.path.join(WORK, "main.ipynb")
open(notebook, "w").write(CELLS)
uri = pathlib.Path(notebook).as_uri()

env = dict(os.environ)
env["HOME"] = HOME

p = subprocess.Popen(
    [JNLS, "--wrapped-server", JDTLS, "--java-parser", JAVA_PARSER, "--log-level", "info"],
    cwd=WORK, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)

lock = threading.Lock()
msgid = [0]
responses = {}
diagnostics = {}
logs = []


def write(obj):
    body = json.dumps(obj).encode()
    p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    p.stdin.flush()


def send(method, params, notify=False):
    with lock:
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notify:
            msgid[0] += 1
            msg["id"] = msgid[0]
        write(msg)
        return msgid[0]


def reader():
    while True:
        length = None
        while True:
            line = p.stdout.readline()
            if not line:
                return
            line = line.strip()
            if not line:
                break
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":", 1)[1])
        if length is None:
            return
        msg = json.loads(p.stdout.read(length))
        m = msg.get("method")
        if m == "textDocument/publishDiagnostics":
            diagnostics[msg["params"]["uri"]] = msg["params"]["diagnostics"]
        elif m == "window/logMessage":
            logs.append(msg["params"]["message"])
        elif "method" in msg and "id" in msg:
            with lock:
                n = len(msg["params"]["items"]) if m == "workspace/configuration" else 0
                write({"jsonrpc": "2.0", "id": msg["id"], "result": [None] * n if n else None})
        elif "id" in msg:
            responses[msg["id"]] = msg.get("result")


threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=lambda: [logs.append("STDERR " + l.decode(errors="replace").strip())
                                 for l in iter(p.stderr.readline, b"")], daemon=True).start()


def request(method, params, timeout=180):
    rid = send(method, params)
    end = time.time() + timeout
    while time.time() < end:
        if rid in responses:
            return responses.pop(rid)
        time.sleep(0.2)
    return "TIMEOUT"


try:
    request("initialize", {
        "processId": os.getpid(),
        "rootUri": pathlib.Path(WORK).as_uri(),
        "workspaceFolders": [{"uri": pathlib.Path(WORK).as_uri(), "name": "e2e"}],
        "capabilities": {
            "textDocument": {
                "synchronization": {"dynamicRegistration": False},
                "publishDiagnostics": {"relatedInformation": True},
                "hover": {"contentFormat": ["markdown", "plaintext"]},
                "completion": {"completionItem": {"snippetSupport": False}},
            },
            "workspace": {"configuration": True, "workspaceFolders": True, "applyEdit": True},
            "window": {"workDoneProgress": True},
        },
        "initializationOptions": {"settings": {"java": {
            "import": {"maven": {"enabled": False}, "gradle": {"enabled": False}},
            "configuration": {"updateBuildConfiguration": "disabled"},
        }}},
    })
    send("initialized", {}, notify=True)
    send("textDocument/didOpen", {"textDocument": {
        "uri": uri, "languageId": "java", "version": 1, "text": CELLS}}, notify=True)

    # Cell line 4 is "int doubled(int v) {"; character 4 is inside the name.
    hover = None
    end = time.time() + 300
    while time.time() < end:
        time.sleep(10)
        hover = request("textDocument/hover", {"textDocument": {"uri": uri},
                                               "position": {"line": 4, "character": 6}})
        if hover and hover != "TIMEOUT" and hover.get("contents"):
            break

    print("HOVER at notebook line 4 (int doubled):")
    print(json.dumps(hover, indent=1)[:700])

    # Cell line 8 is "System.out.println(doubled(x));". Completion after "doubled" prefix.
    completion = request("textDocument/completion", {"textDocument": {"uri": uri},
                                                     "position": {"line": 8, "character": 26}})
    if isinstance(completion, dict):
        labels = [i["label"] for i in completion.get("items", [])][:10]
    else:
        labels = completion
    print("\nCOMPLETION at notebook line 8:", labels)

    print("\nDIAGNOSTIC URIs:", list(diagnostics.keys()))
    for u, ds in diagnostics.items():
        for d in ds:
            print("  ", d["range"], d["message"][:90])

    print("\nLOGS (last 15):")
    for l in logs[-15:]:
        print("  ", l[:160])
finally:
    p.kill()
    p.wait(timeout=10)
