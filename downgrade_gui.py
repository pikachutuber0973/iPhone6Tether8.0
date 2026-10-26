#!/usr/bin/env python3
"""
iPhone6Tether8.0 GUI  -  front-end for downgrade.sh (Linux, iPhone 6 / iPhone7,2 only)

Put this file next to downgrade.sh and run:  python3 downgrade_gui.py
Needs: python3-tk and `script` (util-linux). Debian/Ubuntu: sudo apt install python3-tk
"""
import json
import os
import plistlib
import queue
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import zipfile
from pathlib import Path

try:
    import tkinter as tk
    from tkinter import filedialog, messagebox, simpledialog, ttk
except ImportError:  # pragma: no cover
    sys.exit("tkinter is missing. Install it first (Debian/Ubuntu: sudo apt install python3-tk).")

ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "downgrade.sh"
KEYFILE = ROOT / "keys" / "iPhone7,2.txt"
CONFIG = Path.home() / ".config" / "iphone6tether8" / "config.json"
DEVICE = "iPhone7,2"
REQUIRED_KEYS = ["ibss", "ibec", "dtre", "rdsk", "krnl", "fstm"]
KEY_LABELS = {
    "ibss": "iBSS", "ibec": "iBEC", "dtre": "DeviceTree",
    "rdsk": "Restore ramdisk", "krnl": "Kernelcache", "fstm": "Root filesystem",
}

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07")
PROMPT_PW_RE = re.compile(r"(?i)(password[^\n]*:|passphrase[^\n]*:)\s*$")
PROMPT_ANY_RE = re.compile(r"(?:[:?]|\.\.\.)\s$")


# ----------------------------------------------------------------------------
# IPSW inspection
# ----------------------------------------------------------------------------
def inspect_ipsw(path):
    """Return (version, build, [product types]) from BuildManifest.plist inside an IPSW."""
    with zipfile.ZipFile(path) as z:
        with z.open("BuildManifest.plist") as f:
            m = plistlib.load(f)
    return (
        str(m.get("ProductVersion", "?")),
        str(m.get("ProductBuildVersion", "?")),
        list(m.get("SupportedProductTypes", [])),
    )


def check_ipsw(path, role, target_version):
    """role: 'target' or 'base'. Returns (ok, message)."""
    if not path:
        return False, "No file selected"
    p = Path(path)
    if not p.is_file():
        return False, "File not found"
    try:
        ver, build, types = inspect_ipsw(p)
    except KeyError:
        return False, "Not an IPSW (no BuildManifest.plist)"
    except zipfile.BadZipFile:
        return False, "Corrupt or incomplete download (bad zip)"
    except Exception as e:  # noqa: BLE001
        return False, f"Unreadable: {e}"
    if DEVICE not in types:
        return False, f"Not for {DEVICE} (supports: {', '.join(types[:3]) or 'unknown'})"
    if role == "target" and ver != target_version:
        return False, f"iOS {ver} ({build}) - expected {target_version}"
    if role == "base" and not ver.startswith("12.5"):
        return False, f"iOS {ver} ({build}) - base should be 12.5.x"
    return True, f"OK  -  {DEVICE}, iOS {ver} ({build})"


# ----------------------------------------------------------------------------
# Keys: parse pasted theapplewiki / theiphonewiki page text
# ----------------------------------------------------------------------------
def parse_keys_text(text):
    """
    Parse a copied firmware-key page. Returns {'fstm','rdsk','ibss','ibec','dtre','krnl'} -> value
    rdsk/ibss/ibec/dtre/krnl = IV+Key (96 hex), fstm = key only (72 hex).
    """
    lines = [re.sub(r"^[\s\-\u2022*]+", "", ln).strip() for ln in text.splitlines()]
    lines = [ln for ln in lines if ln]
    out = {}
    label, explicit, iv, dmg_i = None, False, None, 0
    dmg_order = ["fstm", "update", "rdsk"]  # wiki order: Root FS, Update RD, Restore RD

    def value_after(i, tag):
        m = re.match(rf"(?i){tag}\s*:?\s*([0-9a-f]*)\s*$", lines[i])
        if not m:
            return None, i
        if m.group(1):
            return m.group(1), i
        if i + 1 < len(lines) and re.fullmatch(r"[0-9a-fA-F]+", lines[i + 1]):
            return lines[i + 1], i + 1
        return None, i

    i = 0
    while i < len(lines):
        ln = re.sub(r"(?i)^filename\s*:\s*", "", lines[i])
        low = ln.lower()
        if re.match(r"(?i)iv\s*:", ln):
            v, i = value_after(i, "iv")
            iv = v if v and len(v) == 32 else iv
        elif re.match(r"(?i)key\s*:", ln):
            k, i = value_after(i, "key")
            if k and label in REQUIRED_KEYS:
                if label == "fstm" and len(k) in (72, 64):
                    out["fstm"] = k.lower()
                elif label != "fstm" and iv and len(k) == 64:
                    out[label] = (iv + k).lower()
            label, explicit, iv = None, False, None
        elif low.startswith("root filesystem"):
            label, explicit = "fstm", True
        elif low.startswith("update ramdisk"):
            label, explicit = "update", True
        elif low.startswith("restore ramdisk"):
            label, explicit = "rdsk", True
        elif re.match(r"\d{3}-\d{5}-\d{3}\.dmg", low):
            if not explicit:
                label = dmg_order[dmg_i] if dmg_i < len(dmg_order) else None
            dmg_i += 1
        elif low.startswith("devicetree"):
            label, explicit = "dtre", True
        elif low.startswith("ibec"):
            label, explicit = "ibec", True
        elif low.startswith("ibss"):
            label, explicit = "ibss", True
        elif low.startswith("kernelcache"):
            label, explicit = "krnl", True
        elif re.match(r"(?i)(iboot|llb|applelogo|battery|glyph|recovery|logo)", low):
            label, explicit = None, True
        i += 1
    return out


def read_keyfile():
    if not KEYFILE.is_file():
        return []
    return KEYFILE.read_text().splitlines()


def keys_status(version):
    have = {}
    for ln in read_keyfile():
        m = re.match(rf"^([a-z]+)-{re.escape(version)}:\s*(\S+)", ln)
        if m:
            have[m.group(1)] = m.group(2)
    return have


def save_keys(version, parsed):
    KEYFILE.parent.mkdir(parents=True, exist_ok=True)
    lines = read_keyfile()
    for k, v in parsed.items():
        lines = [ln for ln in lines if not ln.startswith(f"{k}-{version}:")]
        lines.append(f"{k}-{version}:{v}")
    KEYFILE.write_text("\n".join(lines).rstrip("\n") + "\n")


# ----------------------------------------------------------------------------
# Process runner (uses `script` so sudo / read prompts behave like a real terminal)
# ----------------------------------------------------------------------------
class Runner:
    def __init__(self, argv, cwd, out_queue):
        cmdline = shlex.join(argv)
        env = dict(os.environ, TERM="dumb")
        self.proc = subprocess.Popen(
            ["script", "-q", "-f", "-e", "-c", cmdline, "/dev/null"],
            cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, start_new_session=True, bufsize=0,
        )
        self.q = out_queue
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        fd = self.proc.stdout.fileno()
        while True:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            self.q.put(("out", data.decode("utf-8", "replace")))
        self.q.put(("exit", self.proc.wait()))

    def send(self, text):
        try:
            self.proc.stdin.write(text.encode())
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError):
            pass

    def stop(self):
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGINT)
        except (ProcessLookupError, PermissionError):
            pass

    def running(self):
        return self.proc.poll() is None


# ----------------------------------------------------------------------------
# GUI
# ----------------------------------------------------------------------------
class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("iPhone6Tether8.0 - iPhone 6 tethered downgrader")
        self.geometry("900x680")
        self.minsize(760, 560)
        self.q = queue.Queue()
        self.runner = None
        self.tail = ""
        self.asked_tail = None
        self.cfg = self.load_cfg()

        self.target_var = tk.StringVar(value=self.cfg.get("target", ""))
        self.base_var = tk.StringVar(value=self.cfg.get("base", ""))
        self.ver_var = tk.StringVar(value=self.cfg.get("version", "8.3"))
        self.target_msg = tk.StringVar()
        self.base_msg = tk.StringVar()
        self.key_msg = tk.StringVar()

        self.build_ui()
        for v in (self.target_var, self.base_var, self.ver_var):
            v.trace_add("write", lambda *_: self.refresh_status())
        self.refresh_status()
        self.after(50, self.pump)
        self.protocol("WM_DELETE_WINDOW", self.on_close)
        self.log("Ready. Pick your IPSWs, import the keys, then run the steps top to bottom.\n")
        if not SCRIPT.is_file():
            self.log(f"[!] downgrade.sh not found next to this file ({SCRIPT})\n")
        if not shutil.which("script"):
            self.log("[!] 'script' (util-linux) not found - install it, the console needs it.\n")

    # -- config --
    def load_cfg(self):
        try:
            return json.loads(CONFIG.read_text())
        except Exception:  # noqa: BLE001
            return {}

    def save_cfg(self):
        CONFIG.parent.mkdir(parents=True, exist_ok=True)
        CONFIG.write_text(json.dumps({
            "target": self.target_var.get(), "base": self.base_var.get(),
            "version": self.ver_var.get(),
        }))

    # -- ui --
    def build_ui(self):
        pad = {"padx": 8, "pady": 4}
        top = ttk.LabelFrame(self, text="1. Import IPSWs")
        top.pack(fill="x", padx=10, pady=(10, 4))
        top.columnconfigure(1, weight=1)

        ttk.Label(top, text="iOS version").grid(row=0, column=0, sticky="w", **pad)
        ttk.Entry(top, textvariable=self.ver_var, width=8).grid(row=0, column=1, sticky="w", **pad)

        ttk.Label(top, text="Target IPSW (iOS 8.3)").grid(row=1, column=0, sticky="w", **pad)
        ttk.Entry(top, textvariable=self.target_var).grid(row=1, column=1, sticky="ew", **pad)
        ttk.Button(top, text="Browse...", command=lambda: self.browse(self.target_var)).grid(row=1, column=2, **pad)
        self.target_lbl = ttk.Label(top, textvariable=self.target_msg)
        self.target_lbl.grid(row=2, column=1, sticky="w", padx=8)

        ttk.Label(top, text="Base IPSW (iOS 12.5.x)").grid(row=3, column=0, sticky="w", **pad)
        ttk.Entry(top, textvariable=self.base_var).grid(row=3, column=1, sticky="ew", **pad)
        ttk.Button(top, text="Browse...", command=lambda: self.browse(self.base_var)).grid(row=3, column=2, **pad)
        self.base_lbl = ttk.Label(top, textvariable=self.base_msg)
        self.base_lbl.grid(row=4, column=1, sticky="w", padx=8, pady=(0, 6))

        keys = ttk.LabelFrame(self, text="2. Firmware keys")
        keys.pack(fill="x", padx=10, pady=4)
        self.key_lbl = ttk.Label(keys, textvariable=self.key_msg, justify="left")
        self.key_lbl.pack(side="left", padx=8, pady=6)
        ttk.Button(keys, text="Import keys...", command=self.import_keys_dialog).pack(side="right", padx=8)

        act = ttk.LabelFrame(self, text="3. Run")
        act.pack(fill="x", padx=10, pady=4)
        self.buttons = []
        for text, cmd in [
            ("Build custom IPSW", self.do_build),
            ("Restore (DFU)", self.do_restore),
            ("Fix iOS 8 / Setup.app / no-sleep", self.do_fix),
            ("Tethered boot", self.do_boot),
        ]:
            b = ttk.Button(act, text=text, command=cmd)
            b.pack(side="left", padx=6, pady=8)
            self.buttons.append(b)
        self.stop_btn = ttk.Button(act, text="Stop", command=self.do_stop, state="disabled")
        self.stop_btn.pack(side="right", padx=6)

        logf = ttk.LabelFrame(self, text="Console")
        logf.pack(fill="both", expand=True, padx=10, pady=4)
        self.text = tk.Text(logf, wrap="word", bg="#101418", fg="#d8dee9", insertbackground="#d8dee9",
                            font=("monospace", 10), state="disabled")
        sb = ttk.Scrollbar(logf, command=self.text.yview)
        self.text.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        self.text.pack(fill="both", expand=True)
        self.text.tag_configure("err", foreground="#ff6b6b")
        self.text.tag_configure("ok", foreground="#7ee787")

        inp = ttk.Frame(self)
        inp.pack(fill="x", padx=10, pady=(0, 10))
        self.input_var = tk.StringVar()
        self.entry = ttk.Entry(inp, textvariable=self.input_var)
        self.entry.pack(side="left", fill="x", expand=True)
        self.entry.bind("<Return>", lambda _e: self.send_input())
        ttk.Button(inp, text="Send", command=self.send_input).pack(side="left", padx=4)
        ttk.Button(inp, text="Enter \u23ce", command=lambda: self.send_raw("\n")).pack(side="left")

    # -- status --
    def refresh_status(self):
        ver = self.ver_var.get().strip() or "8.3"
        for var, role, msg, lbl in (
            (self.target_var, "target", self.target_msg, self.target_lbl),
            (self.base_var, "base", self.base_msg, self.base_lbl),
        ):
            ok, text = check_ipsw(var.get().strip(), role, ver)
            msg.set(("\u2714 " if ok else "\u2718 ") + text)
            lbl.configure(foreground="#2e8b57" if ok else "#c0392b")
        have = keys_status(ver)
        missing = [KEY_LABELS[k] for k in REQUIRED_KEYS if k not in have]
        if missing:
            self.key_msg.set(f"\u2718 Missing for iOS {ver}: {', '.join(missing)}")
            self.key_lbl.configure(foreground="#c0392b")
        else:
            self.key_msg.set(f"\u2714 All {len(REQUIRED_KEYS)} keys for iOS {ver} present")
            self.key_lbl.configure(foreground="#2e8b57")

    def browse(self, var):
        start = os.path.dirname(var.get()) if var.get() else str(Path.home())
        p = filedialog.askopenfilename(
            title="Select IPSW", initialdir=start,
            filetypes=[("IPSW firmware", "*.ipsw"), ("All files", "*")])
        if p:
            var.set(p)
            self.save_cfg()

    # -- keys dialog --
    def import_keys_dialog(self):
        ver = self.ver_var.get().strip() or "8.3"
        win = tk.Toplevel(self)
        win.title(f"Import keys for iOS {ver}")
        win.geometry("720x520")
        ttk.Label(win, justify="left", text=(
            "Open the key page in your browser (theapplewiki: Keys:Stowe_12F70_(iPhone7,2)),\n"
            "select all, copy, and paste below - or load a saved text/HTML file."
        )).pack(anchor="w", padx=10, pady=8)
        box = tk.Text(win, wrap="word", height=14)
        box.pack(fill="both", expand=True, padx=10)
        preview = tk.StringVar()
        ttk.Label(win, textvariable=preview, justify="left").pack(anchor="w", padx=10, pady=6)
        state = {}

        def parse(*_):
            txt = box.get("1.0", "end")
            txt = re.sub(r"<[^>]+>", "\n", txt) if "<html" in txt.lower() or "</" in txt else txt
            state["keys"] = parse_keys_text(txt)
            got = state["keys"]
            tick, cross = "\u2714", "\u2718"
            preview.set("\n".join(
                f"{tick if k in got else cross} {KEY_LABELS[k]}" for k in REQUIRED_KEYS))

        def load_file():
            p = filedialog.askopenfilename(parent=win)
            if p:
                box.delete("1.0", "end")
                box.insert("1.0", Path(p).read_text(errors="replace"))
                parse()

        def save():
            parse()
            if not state.get("keys"):
                messagebox.showwarning("Nothing found", "No keys could be parsed from that text.", parent=win)
                return
            save_keys(ver, state["keys"])
            self.refresh_status()
            self.log(f"[+] Saved {len(state['keys'])} key(s) to {KEYFILE}\n", "ok")
            win.destroy()

        box.bind("<<Paste>>", lambda _e: win.after(50, parse))
        bar = ttk.Frame(win)
        bar.pack(fill="x", padx=10, pady=8)
        ttk.Button(bar, text="Load file...", command=load_file).pack(side="left")
        ttk.Button(bar, text="Parse", command=parse).pack(side="left", padx=6)
        ttk.Button(bar, text="Save to keys file", command=save).pack(side="right")
        ttk.Button(bar, text="Cancel", command=win.destroy).pack(side="right", padx=6)

    # -- running --
    def log(self, s, tag=None):
        self.text.configure(state="normal")
        parts = s.split("\r")
        for idx, part in enumerate(parts):
            if idx > 0:  # carriage return: overwrite current line (progress bars)
                self.text.delete("end-1c linestart", "end-1c")
            if part:
                self.text.insert("end", part, tag)
        self.text.see("end")
        self.text.configure(state="disabled")

    def busy(self, on):
        for b in self.buttons:
            b.configure(state="disabled" if on else "normal")
        self.stop_btn.configure(state="normal" if on else "disabled")

    def run(self, args):
        if self.runner and self.runner.running():
            return
        if not SCRIPT.is_file():
            messagebox.showerror("Missing", "downgrade.sh not found next to the GUI.")
            return
        if not shutil.which("script"):
            messagebox.showerror("Missing", "'script' (util-linux) is required.")
            return
        os.chmod(SCRIPT, 0o755)
        self.save_cfg()
        self.log(f"\n$ ./downgrade.sh {' '.join(shlex.quote(a) for a in args)}\n", "ok")
        self.tail, self.asked_tail = "", None
        self.runner = Runner([str(SCRIPT), *args], str(ROOT), self.q)
        self.busy(True)
        self.entry.focus_set()

    def need_ipsws(self, base=True):
        ver = self.ver_var.get().strip() or "8.3"
        ok_t, msg_t = check_ipsw(self.target_var.get().strip(), "target", ver)
        if not ok_t:
            messagebox.showerror("Target IPSW", msg_t)
            return None
        if base:
            ok_b, msg_b = check_ipsw(self.base_var.get().strip(), "base", ver)
            if not ok_b:
                messagebox.showerror("Base IPSW", msg_b)
                return None
        return ver

    def do_build(self):
        ver = self.need_ipsws(True)
        if ver:
            if keys_status(ver).keys() >= set(REQUIRED_KEYS):
                self.run(["--ipsw", self.target_var.get().strip(), self.base_var.get().strip(),
                          ver, "--stitch-activation"])
            else:
                messagebox.showerror("Keys", "Import the missing firmware keys first (step 2).")

    def do_restore(self):
        if messagebox.askyesno("Restore", "This ERASES the iPhone 6. Continue?"):
            self.run(["--restore", self.ver_var.get().strip() or "8.3"])

    def do_fix(self):
        self.run(["--fix-ios8"])

    def do_boot(self):
        ver = self.need_ipsws(False)
        if ver:
            self.run(["boot", ver, self.target_var.get().strip()])

    def do_stop(self):
        if self.runner:
            self.runner.stop()
            self.log("\n[!] Sent Ctrl+C\n", "err")

    def send_raw(self, s):
        if self.runner and self.runner.running():
            self.runner.send(s)

    def send_input(self):
        self.send_raw(self.input_var.get() + "\n")
        self.input_var.set("")

    # -- output pump --
    def pump(self):
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "out":
                    clean = ANSI_RE.sub("", payload).replace("\r\n", "\n")
                    tag = "err" if clean.lstrip().startswith("[!]") else None
                    self.log(clean, tag)
                    self.tail = (self.tail + clean).rsplit("\n", 1)[-1]
                    self.check_prompt()
                else:
                    self.log(f"\n[exit {payload}]\n", "ok" if payload == 0 else "err")
                    self.busy(False)
        except queue.Empty:
            pass
        self.after(50, self.pump)

    def check_prompt(self):
        tail = self.tail
        if not tail or tail == self.asked_tail:
            return
        if PROMPT_PW_RE.search(tail):
            self.asked_tail = tail
            pw = simpledialog.askstring("Password required", tail.strip(), show="*", parent=self)
            self.send_raw((pw or "") + "\n")
            self.tail = ""
        elif PROMPT_ANY_RE.search(tail):
            self.entry.focus_set()

    def on_close(self):
        if self.runner and self.runner.running():
            if not messagebox.askyesno("Quit", "A step is still running. Stop it and quit?"):
                return
            self.runner.stop()
        self.destroy()


if __name__ == "__main__":
    App().mainloop()
