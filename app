from __future__ import annotations

import os
import queue
import threading
import subprocess
import urllib.request
import zipfile
import shutil
from pathlib import Path
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import winreg
from dataclasses import dataclass

# =========================
# ======= CONSTANTES ======
# =========================

APP_NAME = "El CHEFF - Video Splitter"
APP_SLUG = "elcheff"

VIDEO_EXTS: set[str] = {
    ".mp4", ".mov", ".mkv", ".avi", ".m4v", ".webm",
    ".mpg", ".mpeg", ".ts", ".m2ts", ".wmv", ".flv"
}

LOGO_CANDIDATES = ["logo.png", "logo.ico", "logo.jpg", "logo.jpeg"]

# ✅ Descarga oficial de builds para Windows (ZIP “release essentials”)
FFMPEG_RELEASE_ESSENTIALS_ZIP_URL = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"


# =========================
# ======= CONFIG ==========
# =========================

def _app_config_dir() -> Path:
    """Carpeta de app por usuario (siempre escribible)."""
    base = os.environ.get("APPDATA") or str(Path.home())
    p = Path(base) / APP_SLUG
    p.mkdir(parents=True, exist_ok=True)
    return p


def config_path() -> Path:
    return _app_config_dir() / "config.txt"


def ffmpeg_vendor_dir() -> Path:
    """Donde “instalamos” ffmpeg para la app (por usuario)."""
    return _app_config_dir() / "vendor" / "ffmpeg"


def ffmpeg_exe_constant_path() -> Path:
    """✅ RUTA CONSTANTE que usará la app SIEMPRE."""
    return ffmpeg_vendor_dir() / "bin" / "ffmpeg.exe"


@dataclass
class AppConfig:
    # NOTA: ya no dependemos de que el usuario configure ffmpeg_exe manualmente.
    ffmpeg_exe: str = ""
    minutes_per_clip: int = 10
    force_reencode: bool = False
    skip_done_days: bool = True

    @classmethod
    def load(cls) -> "AppConfig":
        p = config_path()
        if not p.exists():
            return cls()
        try:
            data = {}
            for line in p.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip()

            cfg = cls()
            cfg.ffmpeg_exe = data.get("ffmpeg_exe", cfg.ffmpeg_exe)
            cfg.minutes_per_clip = int(data.get("minutes_per_clip", cfg.minutes_per_clip))
            cfg.force_reencode = data.get("force_reencode", str(cfg.force_reencode)).lower() in {"1", "true", "yes", "y"}
            cfg.skip_done_days = data.get("skip_done_days", str(cfg.skip_done_days)).lower() in {"1", "true", "yes", "y"}
            return cfg
        except Exception:
            return cls()

    def save(self) -> None:
        p = config_path()
        content = [
            "# El CHEFF config",
            f"ffmpeg_exe={self.ffmpeg_exe}",
            f"minutes_per_clip={int(self.minutes_per_clip)}",
            f"force_reencode={str(bool(self.force_reencode)).lower()}",
            f"skip_done_days={str(bool(self.skip_done_days)).lower()}",
            "",
        ]
        p.write_text("\n".join(content), encoding="utf-8")


# =========================
# ====== UTILIDADES =======
# =========================

class ToolTip:
    def __init__(self, widget, text: str):
        self.widget = widget
        self.text = text
        self.tip = None
        widget.bind("<Enter>", self.show)
        widget.bind("<Leave>", self.hide)

    def show(self, _=None):
        if self.tip or not self.text:
            return
        x = self.widget.winfo_rootx() + 18
        y = self.widget.winfo_rooty() + 18
        self.tip = tk.Toplevel(self.widget)
        self.tip.wm_overrideredirect(True)
        self.tip.wm_geometry(f"+{x}+{y}")
        ttk.Label(self.tip, text=self.text, padding=8).pack()

    def hide(self, _=None):
        if self.tip:
            self.tip.destroy()
            self.tip = None


def open_in_explorer(path: Path) -> None:
    try:
        if path.exists():
            subprocess.Popen(["explorer", str(path)])
    except Exception:
        pass


def get_downloads_dir() -> Path:
    """Returns current user's Downloads folder (Windows), even if relocated."""
    try:
        key_path = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path) as key:
            downloads = winreg.QueryValueEx(key, "{374DE290-123F-4565-9164-39C4925E467B}")[0]
            p = Path(downloads)
            if p.exists():
                return p
    except Exception:
        pass
    p = Path.home() / "Downloads"
    return p if p.exists() else Path.home()


def ensure_ffmpeg_installed(log_cb=None) -> Path:
    """
    ✅ Garantiza que exista ffmpeg.exe en la ruta constante:
       %APPDATA%\\elcheff\\vendor\\ffmpeg\\bin\\ffmpeg.exe

    Si no existe:
      - descarga el ZIP release essentials
      - extrae
      - ubica el ffmpeg.exe extraído
      - lo copia a la ruta constante
    """
    target = ffmpeg_exe_constant_path()
    if target.exists():
        return target

    vendor = ffmpeg_vendor_dir()
    vendor.mkdir(parents=True, exist_ok=True)

    tmp_zip = vendor / "ffmpeg-release-essentials.zip"
    tmp_extract = vendor / "_extract"

    def log(msg: str):
        if log_cb:
            log_cb(msg)

    # Limpieza previa
    try:
        if tmp_extract.exists():
            shutil.rmtree(tmp_extract, ignore_errors=True)
        if tmp_zip.exists():
            tmp_zip.unlink(missing_ok=True)
    except Exception:
        pass

    log("⬇️ Descargando FFmpeg (release essentials)...")
    urllib.request.urlretrieve(FFMPEG_RELEASE_ESSENTIALS_ZIP_URL, tmp_zip)

    log("📦 Extrayendo paquete...")
    tmp_extract.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(tmp_zip, "r") as z:
        z.extractall(tmp_extract)

    # Buscar ffmpeg.exe dentro del ZIP (estructura típica: ffmpeg-*/bin/ffmpeg.exe)
    log("🔎 Localizando ffmpeg.exe dentro del paquete...")
    candidates = list(tmp_extract.rglob("ffmpeg.exe"))
    candidates = [p for p in candidates if p.name.lower() == "ffmpeg.exe"]

    if not candidates:
        raise RuntimeError("No encontré ffmpeg.exe dentro del ZIP descargado.")

    # Preferir uno que esté en /bin/
    candidates.sort(key=lambda p: ("/bin/" not in str(p).replace("\\", "/").lower(), len(str(p))))
    found = candidates[0]

    log(f"✅ Encontrado: {found}")

    # Copiar a ruta constante
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(found, target)

    # Limpieza opcional
    try:
        tmp_zip.unlink(missing_ok=True)
        shutil.rmtree(tmp_extract, ignore_errors=True)
    except Exception:
        pass

    log(f"✅ FFmpeg instalado en: {target}")
    return target


# =========================
# ======= CORE ============
# =========================

@dataclass(frozen=True)
class SplitConfig:
    ffmpeg_exe: Path
    minutes_per_clip: int = 10
    force_reencode: bool = False


def is_video_file(p: Path) -> bool:
    return p.is_file() and p.suffix.lower() in VIDEO_EXTS


def folder_has_videos(folder: Path) -> bool:
    if not folder.exists():
        return False
    for p in folder.iterdir():
        if is_video_file(p):
            return True
    return False


def subfolders(folder: Path) -> list[Path]:
    subs = [p for p in folder.iterdir() if p.is_dir()]
    subs.sort()
    return subs


def list_videos(folder: Path) -> list[Path]:
    vids = [p for p in folder.iterdir() if is_video_file(p)]
    vids.sort()
    return vids


def detect_day_folders(root: Path) -> list[Path]:
    if folder_has_videos(root):
        return [root]

    lvl1 = subfolders(root)
    if not lvl1:
        return []

    days_lvl1 = [d for d in lvl1 if folder_has_videos(d)]
    if days_lvl1:
        return sorted(set(days_lvl1))

    days: list[Path] = []
    for maybe_month in lvl1:
        for maybe_day in subfolders(maybe_month):
            if folder_has_videos(maybe_day):
                days.append(maybe_day)

    return sorted(set(days))


def output_dir_for_video(video_path: Path) -> Path:
    return video_path.parent / "salida"


def output_pattern(video_path: Path) -> Path:
    out_dir = output_dir_for_video(video_path)
    return out_dir / f"{video_path.stem}_part_%03d{video_path.suffix.lower()}"


def video_has_output(video_path: Path) -> bool:
    out_dir = output_dir_for_video(video_path)
    if not out_dir.exists():
        return False
    return any(out_dir.glob(f"{video_path.stem}_part_*"))


def day_status(day_dir: Path) -> tuple[str, int, int]:
    vids = list_videos(day_dir)
    found = len(vids)
    if found == 0:
        return ("SIN VIDEOS", 0, 0)

    processed = sum(1 for v in vids if video_has_output(v))
    if processed == 0:
        return ("PENDIENTE", found, processed)
    if processed == found:
        return ("PROCESADO", found, processed)
    return ("PARCIAL", found, processed)


def build_ffmpeg_cmd(cfg: SplitConfig, video_path: Path) -> list[str]:
    clip_seconds = int(cfg.minutes_per_clip) * 60
    out_dir = output_dir_for_video(video_path)
    out_dir.mkdir(parents=True, exist_ok=True)

    base = [
        str(cfg.ffmpeg_exe),
        "-y",
        "-i", str(video_path),
        "-map", "0",
        "-f", "segment",
        "-segment_time", str(clip_seconds),
        "-reset_timestamps", "1",
    ]

    if cfg.force_reencode:
        base += [
            "-c:v", "libx264",
            "-crf", "18",
            "-preset", "medium",
            "-c:a", "aac",
            "-b:a", "192k",
        ]
    else:
        base += ["-c", "copy"]

    base.append(str(output_pattern(video_path)))
    return base


def run_ffmpeg(cmd: list[str]) -> None:
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or "FFmpeg error desconocido")


def split_one_video(cfg: SplitConfig, video_path: Path) -> None:
    cmd = build_ffmpeg_cmd(cfg, video_path)
    run_ffmpeg(cmd)


# =========================
# ========= UI ============
# =========================

class App(tk.Tk):
    def __init__(self):
        super().__init__()

        self.title(APP_NAME)
        self.geometry("1180x760")
        self.minsize(1100, 700)

        style = ttk.Style(self)
        try:
            style.theme_use("vista")
        except Exception:
            pass

        style.configure("Treeview", rowheight=24)
        style.configure("Card.TLabelframe", padding=10)

        self.cfg = AppConfig.load()
        self.stop_flag = threading.Event()
        self.worker: threading.Thread | None = None
        self.day_cache: list[Path] = []

        self.uiq: "queue.Queue[tuple[str, object]]" = queue.Queue()

        # ✅ Siempre arranca en Descargas
        self.var_root = tk.StringVar(value=str(get_downloads_dir()))

        self.var_mode = tk.StringVar(value="MES")
        self.var_minutes = tk.IntVar(value=int(self.cfg.minutes_per_clip or 10))
        self.var_exact = tk.BooleanVar(value=bool(self.cfg.force_reencode))
        self.var_skip_done = tk.BooleanVar(value=bool(self.cfg.skip_done_days))
        self.var_filter = tk.StringVar(value="TODOS")

        # ✅ Ya no le pedimos ruta al usuario: la constante manda
        self.ffmpeg_path: Path | None = None

        self._build_ui()

        self.after(120, self._drain_ui_queue)

        # ✅ Primer arranque: instala ffmpeg si no existe
        self.after(250, self._ensure_ffmpeg_ready)

    # -----------------
    # Queue -> UI
    # -----------------
    def _drain_ui_queue(self):
        try:
            while True:
                kind, payload = self.uiq.get_nowait()
                if kind == "log":
                    self._log_now(str(payload))
                elif kind == "status":
                    self.status.set(str(payload))
                elif kind == "progress":
                    val, maxv, label = payload
                    if maxv is not None:
                        self.progress["maximum"] = max(1, int(maxv))
                    if val is not None:
                        self.progress["value"] = int(val)
                    if label is not None:
                        self.progress_label.set(str(label))
                elif kind == "row":
                    dia_path, estado, encontrados, ya_proc, errores = payload
                    self._add_or_update_row(dia_path, estado, encontrados, ya_proc, errores)
        except queue.Empty:
            pass
        self.after(120, self._drain_ui_queue)

    def _log_now(self, msg: str):
        self.txt.insert("end", msg + "\n")
        self.txt.see("end")

    def log(self, msg: str):
        self.uiq.put(("log", msg))

    def _persist_config(self):
        self.cfg.minutes_per_clip = int(self.var_minutes.get())
        self.cfg.force_reencode = bool(self.var_exact.get())
        self.cfg.skip_done_days = bool(self.var_skip_done.get())
        # guardamos la ruta efectiva por si quieres verla/debug
        self.cfg.ffmpeg_exe = str(self.ffmpeg_path) if self.ffmpeg_path else ""
        self.cfg.save()

    # -----------------
    # Ensure FFmpeg
    # -----------------
    def _ensure_ffmpeg_ready(self):
        """✅ Si no está instalado en la ruta constante, lo baja y lo instala."""
        self.txt.delete("1.0", "end")
        self.status.set("Preparando dependencias...")
        try:
            self.lbl_ffmpeg.configure(text="FFmpeg: verificando...", foreground="orange")
        except Exception:
            pass

        def worker():
            try:
                self.uiq.put(("progress", (0, None, "Instalando/validando FFmpeg...")))
                ff = ensure_ffmpeg_installed(log_cb=self.log)
                self.ffmpeg_path = ff
                self._persist_config()
                self.uiq.put(("status", f"Listo. FFmpeg: {ff}"))
                self.uiq.put(("progress", (0, None, "FFmpeg listo ✅")))
                self.after(0, lambda: self.lbl_ffmpeg.configure(text="FFmpeg: OK ✅", foreground="green"))
            except Exception as e:
                self.uiq.put(("status", "Error preparando FFmpeg ❌"))
                self.uiq.put(("progress", (0, None, "Error ❌")))
                self.log(f"❌ No pude preparar FFmpeg: {e}")
                try:
                    self.after(0, lambda: self.lbl_ffmpeg.configure(text="FFmpeg: ERROR ❌", foreground="red"))
                except Exception:
                    pass
                messagebox.showerror(
                    "FFmpeg",
                    "No pude descargar/instalar FFmpeg.\n\n"
                    "Verifica internet y permisos, y vuelve a abrir la app.\n\n"
                    f"Detalle: {e}"
                )

        threading.Thread(target=worker, daemon=True).start()

    # -----------------
    # UI (MEJORADA)
    # -----------------
    def _build_ui(self):
        root = ttk.Frame(self, padding=10)
        root.pack(fill="both", expand=True)

        # ================= HEADER =================
        header = ttk.Frame(root)
        header.pack(fill="x", pady=(0, 8))

        ttk.Label(header, text="🍳 El CHEFF", font=("Segoe UI", 20, "bold")).pack(side="left")
        ttk.Label(header, text="Video Splitter", font=("Segoe UI", 10)).pack(side="left", padx=10)

        self.lbl_ffmpeg = ttk.Label(header, text="FFmpeg: verificando...", foreground="orange")
        self.lbl_ffmpeg.pack(side="right")

        # ================= MAIN AREA =================
        main = ttk.Frame(root)
        main.pack(fill="both", expand=True)

        left = ttk.Frame(main)
        left.pack(side="left", fill="y", padx=(0, 10))

        right = ttk.Frame(main)
        right.pack(side="right", fill="both", expand=True)

        # ========= CONFIG PANEL =========
        cfg_card = ttk.LabelFrame(left, text="Configuración", padding=10, style="Card.TLabelframe")
        cfg_card.pack(fill="x", pady=(0, 10))

        ttk.Label(cfg_card, text="Carpeta raíz").pack(anchor="w")
        entry = ttk.Entry(cfg_card, textvariable=self.var_root, width=38)
        entry.pack(fill="x", pady=4)

        btn_pick = ttk.Button(cfg_card, text="📁 Seleccionar carpeta", command=self.pick_root)
        btn_pick.pack(fill="x")
        ToolTip(btn_pick, "Elige la carpeta raíz.\nPuede ser un día, un mes o un año.")

        ttk.Separator(cfg_card).pack(fill="x", pady=8)

        ttk.Label(cfg_card, text="Modo").pack(anchor="w")
        ttk.Radiobutton(cfg_card, text="Procesar en lote (MES/AÑO)", variable=self.var_mode, value="MES").pack(anchor="w")
        ttk.Radiobutton(cfg_card, text="Solo carpeta seleccionada (DÍA)", variable=self.var_mode, value="DIA").pack(anchor="w")

        ttk.Separator(cfg_card).pack(fill="x", pady=8)

        ttk.Label(cfg_card, text="Minutos por clip").pack(anchor="w")
        ttk.Spinbox(cfg_card, from_=1, to=240, textvariable=self.var_minutes).pack(fill="x", pady=(2, 6))

        ttk.Checkbutton(cfg_card, text="Corte exacto (re-encode)", variable=self.var_exact).pack(anchor="w")
        ttk.Checkbutton(cfg_card, text="Omitir días ya procesados", variable=self.var_skip_done).pack(anchor="w")

        # ========= ACTIONS =========
        actions = ttk.LabelFrame(left, text="Acciones", padding=10, style="Card.TLabelframe")
        actions.pack(fill="x")

        ttk.Button(actions, text="🔍 Analizar (Resumen)", command=self.preview_summary).pack(fill="x", pady=2)
        ttk.Button(actions, text="▶ Iniciar", command=self.start).pack(fill="x", pady=2)
        ttk.Button(actions, text="⛔ Detener", command=self.stop).pack(fill="x", pady=2)
        ttk.Button(actions, text="📂 Abrir salida del día", command=self.open_selected_output).pack(fill="x", pady=(8, 2))

        # ========= FILTER =========
        filt = ttk.LabelFrame(left, text="Filtro", padding=10, style="Card.TLabelframe")
        filt.pack(fill="x", pady=(10, 0))
        ttk.Label(filt, text="Mostrar:").pack(anchor="w")
        cmb = ttk.Combobox(
            filt,
            textvariable=self.var_filter,
            width=18,
            state="readonly",
            values=["TODOS", "PENDIENTE", "PARCIAL", "PROCESADO", "SIN VIDEOS"]
        )
        cmb.pack(fill="x", pady=4)
        cmb.bind("<<ComboboxSelected>>", lambda _e: self.apply_filter())

        # ========= TABLE =========
        table_card = ttk.LabelFrame(right, text="Resumen por DÍA (carpetas)", padding=6, style="Card.TLabelframe")
        table_card.pack(fill="both", expand=True)

        self.tree = ttk.Treeview(
            table_card,
            columns=("dia", "estado", "encontrados", "ya_proc", "errores"),
            show="headings",
            height=12
        )
        self.tree.pack(fill="both", expand=True)

        self.tree.heading("dia", text="Carpeta Día")
        self.tree.heading("estado", text="Estado")
        self.tree.heading("encontrados", text="Encontrados")
        self.tree.heading("ya_proc", text="Ya procesados")
        self.tree.heading("errores", text="Errores (run)")

        self.tree.column("dia", width=560)
        self.tree.column("estado", width=120, anchor="center")
        self.tree.column("encontrados", width=110, anchor="center")
        self.tree.column("ya_proc", width=120, anchor="center")
        self.tree.column("errores", width=110, anchor="center")

        # colores semáforo
        self.tree.tag_configure("PENDIENTE", background="#ffd6d6")
        self.tree.tag_configure("PARCIAL", background="#fff4c2")
        self.tree.tag_configure("PROCESADO", background="#d6ffd6")
        self.tree.tag_configure("SIN VIDEOS", background="#eeeeee")

        # ========= PROGRESS =========
        prog_card = ttk.LabelFrame(right, text="Progreso", padding=8, style="Card.TLabelframe")
        prog_card.pack(fill="x", pady=8)

        self.progress = ttk.Progressbar(prog_card, mode="determinate")
        self.progress.pack(fill="x")

        self.progress_label = tk.StringVar(value="Sin ejecutar.")
        ttk.Label(prog_card, textvariable=self.progress_label).pack(anchor="w", pady=(6, 0))

        # ========= LOG =========
        log_card = ttk.LabelFrame(right, text="Log", padding=6, style="Card.TLabelframe")
        log_card.pack(fill="both", expand=True)

        self.txt = tk.Text(log_card, height=8, wrap="word")
        self.txt.pack(fill="both", expand=True)

        # ========= STATUS =========
        self.status = tk.StringVar(value="Listo.")
        ttk.Label(root, textvariable=self.status).pack(anchor="w", pady=(8, 0))

    # -----------------
    # UX helpers
    # -----------------
    def pick_root(self):
        initial = Path(self.var_root.get().strip().strip('"')) if self.var_root.get().strip() else get_downloads_dir()
        folder = filedialog.askdirectory(
            title="Selecciona la carpeta raíz (DÍA / MES / AÑO)",
            initialdir=str(initial)
        )
        if folder:
            self.var_root.set(folder)

    def stop(self):
        self.stop_flag.set()
        self.status.set("Deteniendo...")

    # -----------------
    # Table helpers
    # -----------------
    def _clear_table(self):
        for item in self.tree.get_children():
            self.tree.delete(item)

    def _add_or_update_row(self, dia_path: Path, estado: str, encontrados: int, ya_proc: int, errores: int):
        tag = estado
        for item in self.tree.get_children():
            vals = self.tree.item(item, "values")
            if vals and Path(vals[0]) == dia_path:
                self.tree.item(item, values=(str(dia_path), estado, encontrados, ya_proc, errores), tags=(tag,))
                return
        self.tree.insert("", "end", values=(str(dia_path), estado, encontrados, ya_proc, errores), tags=(tag,))

    def _collect_day_folders(self, root: Path, mode: str) -> list[Path]:
        dias = detect_day_folders(root)
        if mode == "DIA":
            if folder_has_videos(root):
                return [root]
            return dias
        return dias

    def apply_filter(self):
        if not self.day_cache:
            return
        self._render_summary(self.day_cache)

    def _render_summary(self, dias: list[Path]):
        self._clear_table()
        filtro = self.var_filter.get()

        total_vids = 0
        total_proc = 0

        for d in dias:
            est, encontrados, ya_proc = day_status(d)
            if filtro != "TODOS" and est != filtro:
                continue
            total_vids += encontrados
            total_proc += ya_proc
            self._add_or_update_row(d, est, encontrados, ya_proc, 0)

        self.status.set(f"Resumen: {len(dias)} día(s) | Videos: {total_vids} | Ya procesados: {total_proc}")

    def preview_summary(self):
        root_txt = self.var_root.get().strip().strip('"')
        root = Path(root_txt) if root_txt else Path()
        if not root_txt or not root.exists():
            messagebox.showerror("Error", f"No existe la carpeta:\n{root_txt or '(vacío)'}")
            return

        self.progress["value"] = 0
        self.progress_label.set("Analizando...")

        dias = self._collect_day_folders(root, self.var_mode.get())
        self.day_cache = dias

        if not dias:
            self._clear_table()
            self._log_now("⚠️ No encontré carpetas con videos pa' resumir.")
            self.status.set("Sin carpetas con videos.")
            self.progress_label.set("Sin carpetas con videos.")
            return

        self._render_summary(dias)
        self.progress_label.set("Resumen listo.")

    def open_selected_output(self):
        sel = self.tree.selection()
        if not sel:
            messagebox.showinfo("Selecciona un día", "Selecciona una fila de la tabla primero.")
            return
        vals = self.tree.item(sel[0], "values")
        dia = Path(vals[0])
        out_dir = dia / "salida"
        if not out_dir.exists():
            messagebox.showinfo("Sin salida", "Ese día todavía no tiene carpeta 'salida'.")
            return
        open_in_explorer(out_dir)

    # -----------------
    # Run
    # -----------------
    def start(self):
        if self.worker and self.worker.is_alive():
            messagebox.showinfo("En ejecución", "Ya hay un proceso corriendo.")
            return

        if not self.ffmpeg_path or not self.ffmpeg_path.exists():
            messagebox.showerror(
                "FFmpeg no listo",
                "Todavía no está listo FFmpeg. Reabre la app o revisa el log."
            )
            return

        root_txt = self.var_root.get().strip().strip('"')
        root = Path(root_txt) if root_txt else Path()
        if not root_txt or not root.exists():
            messagebox.showerror("Error", f"No existe la carpeta:\n{root_txt or '(vacío)'}")
            return

        cfg = SplitConfig(
            ffmpeg_exe=self.ffmpeg_path,
            minutes_per_clip=int(self.var_minutes.get()),
            force_reencode=bool(self.var_exact.get())
        )

        self._persist_config()
        self.stop_flag.clear()
        self.txt.delete("1.0", "end")
        self.status.set("Procesando...")

        self.preview_summary()
        dias = self.day_cache
        if not dias:
            return

        ok = messagebox.askyesno("Confirmar", f"Se detectaron {len(dias)} día(s). ¿Quieres iniciar?")
        if not ok:
            self.status.set("Cancelado.")
            return

        skip_done = bool(self.var_skip_done.get())
        self.worker = threading.Thread(
            target=self._run_job_worker,
            args=(cfg, root, self.var_mode.get(), skip_done),
            daemon=True
        )
        self.worker.start()

    def _run_job_worker(self, cfg: SplitConfig, root: Path, mode: str, skip_done: bool):
        dias = self._collect_day_folders(root, mode)
        self.day_cache = dias

        if not dias:
            self.log("⚠️ No hay carpetas con videos pa' procesar.")
            self.uiq.put(("status", "Sin trabajo."))
            return

        self.uiq.put(("progress", (0, len(dias), "Iniciando...")))

        total_found = 0
        total_processed_now = 0
        total_errors = 0

        for idx, d in enumerate(dias, start=1):
            if self.stop_flag.is_set():
                self.log("\n⛔ Proceso detenido por el usuario.")
                self.uiq.put(("status", "Detenido."))
                return

            est, found, already = day_status(d)
            total_found += found

            self.uiq.put(("progress", (idx - 1, None, f"Día {idx}/{len(dias)} - {d.name} | Estado: {est}")))

            if est == "SIN VIDEOS":
                self.uiq.put(("row", (d, est, 0, 0, 0)))
                continue

            if skip_done and est == "PROCESADO":
                self.log(f"🟢 {d} | Ya procesado (saltado)")
                self.uiq.put(("row", (d, est, found, already, 0)))
                self.uiq.put(("progress", (idx, None, None)))
                continue

            vids = list_videos(d)
            errors_run = 0

            for v in vids:
                if self.stop_flag.is_set():
                    self.log("\n⛔ Proceso detenido por el usuario.")
                    self.uiq.put(("status", "Detenido."))
                    return

                if video_has_output(v):
                    continue

                try:
                    self.log(f"   ▶ {v.name}")
                    split_one_video(cfg, v)
                    total_processed_now += 1
                    self.log("   ✅ OK")
                except Exception as e:
                    errors_run += 1
                    total_errors += 1
                    self.log(f"   ❌ ERROR: {e}")

                est2, enc2, ya2 = day_status(d)
                self.uiq.put(("row", (d, est2, enc2, ya2, errors_run)))

            self.uiq.put(("progress", (idx, None, None)))

        self.uiq.put(("progress", (len(dias), None, "Completado ✅")))
        self.uiq.put(("status", f"Completado ✅ | Encontrados: {total_found} | Procesados ahora: {total_processed_now} | Errores: {total_errors}"))


def main():
    App().mainloop()


if __name__ == "__main__":
    main()
