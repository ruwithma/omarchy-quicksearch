#!/usr/bin/env python3
"""
Rock-solid Pop-in Browser HUD for Omarchy QuickSearch
Launches a dedicated floating, centered App window using the user's default browser.
Fully compliant with all Omarchy default browsers (Chromium & Firefox families).
"""
import os
import re
import shlex
import shutil
import subprocess
import sys

# Search paths for XDG .desktop files
DESKTOP_DIRS = [
    os.path.expanduser("~/.local/share/applications"),
    os.path.expanduser("~/.nix-profile/share/applications"),
    "/usr/local/share/applications",
    "/usr/share/applications",
]

if os.environ.get("XDG_DATA_DIRS"):
    for dir_path in os.environ["XDG_DATA_DIRS"].split(":"):
        app_dir = os.path.join(dir_path.strip(), "applications")
        if app_dir not in DESKTOP_DIRS:
            DESKTOP_DIRS.append(app_dir)

CHROMIUM_PATTERN = re.compile(
    r"(google-chrome|chromium|brave|microsoft-edge|msedge|vivaldi|helium|opera)", re.IGNORECASE
)
FIREFOX_PATTERN = re.compile(
    r"(firefox|zen|librewolf|floorp|waterfox|tor-browser)", re.IGNORECASE
)

def get_default_browser_desktop():
    """Detects the default browser desktop ID via xdg-settings or xdg-mime."""
    clean_env = {k: v for k, v in os.environ.items() if k != "BROWSER"}

    # 1. Primary: xdg-settings get default-web-browser
    try:
        res = subprocess.run(
            ["xdg-settings", "get", "default-web-browser"],
            capture_output=True,
            text=True,
            env=clean_env,
            timeout=2,
        )
        desktop = res.stdout.strip()
        if desktop and desktop.endswith(".desktop"):
            return desktop
    except Exception:
        pass

    # 2. Secondary: xdg-mime query default x-scheme-handler/https
    try:
        res = subprocess.run(
            ["xdg-mime", "query", "default", "x-scheme-handler/https"],
            capture_output=True,
            text=True,
            env=clean_env,
            timeout=2,
        )
        desktop = res.stdout.strip()
        if desktop and desktop.endswith(".desktop"):
            return desktop
    except Exception:
        pass

    return None

def resolve_exec_from_desktop(desktop_filename):
    """Parses the Exec command from a given .desktop file name."""
    if not desktop_filename:
        return None

    for base_dir in DESKTOP_DIRS:
        desktop_path = os.path.join(base_dir, desktop_filename)
        if os.path.isfile(desktop_path):
            try:
                with open(desktop_path, "r", encoding="utf-8", errors="ignore") as f:
                    in_entry = False
                    for line in f:
                        line = line.strip()
                        if line == "[Desktop Entry]":
                            in_entry = True
                        elif line.startswith("[") and in_entry:
                            break
                        elif in_entry and line.startswith("Exec="):
                            exec_line = line[5:].strip()
                            tokens = shlex.split(exec_line)
                            if tokens:
                                raw_bin = tokens[0]
                                resolved = shutil.which(raw_bin)
                                if resolved:
                                    return resolved
            except Exception:
                pass
    return None

def is_chromium_based(exec_path, desktop_id=""):
    ident = f"{desktop_id} {os.path.basename(exec_path or '')}".lower()
    return bool(CHROMIUM_PATTERN.search(ident))

def is_firefox_based(exec_path, desktop_id=""):
    ident = f"{desktop_id} {os.path.basename(exec_path or '')}".lower()
    if FIREFOX_PATTERN.search(ident):
        return True
    if exec_path:
        try:
            res = subprocess.run(
                [exec_path, "--help"],
                capture_output=True,
                text=True,
                timeout=1,
            )
            if "MOZ_LOG" in res.stdout or "MOZ_LOG" in res.stderr:
                return True
        except Exception:
            pass
    return False

def sanitize_url(raw_url):
    """Sanitizes and validates incoming URL to prevent scheme or argument injection."""
    url = str(raw_url or "").strip()
    if not url or url == "--":
        return "https://duckduckgo.com"

    lower = url.lower()
    # Reject dangerous executable URI schemes
    for dangerous in ["javascript:", "data:", "vbscript:", "blob:"]:
        if lower.startswith(dangerous):
            return "https://duckduckgo.com/?q=" + url

    if lower.startswith("http://") or lower.startswith("https://") or lower.startswith("about:"):
        return url

    return "https://" + url

def build_browser_cmd(exec_path, desktop_id, url):
    safe_url = sanitize_url(url)
    if is_chromium_based(exec_path, desktop_id):
        return [
            exec_path,
            f"--app={safe_url}",
            "--user-data-dir=/tmp/quicksearch-popin-profile",
            "--ozone-platform-hint=auto",
            "--window-size=1170,640",
        ]
    elif is_firefox_based(exec_path, desktop_id):
        return [exec_path, "--new-window", safe_url]
    else:
        return [exec_path, "--", safe_url]

def launch_popin(url):
    """Launches the URL in a dedicated pop-in window using the user's default browser."""
    safe_url = sanitize_url(url)
    cmd = None

    # Step 1: Detect and use configured default browser
    default_desktop = get_default_browser_desktop()
    if default_desktop:
        exec_path = resolve_exec_from_desktop(default_desktop)
        if exec_path:
            cmd = build_browser_cmd(exec_path, default_desktop, safe_url)

    # Step 2: Fallback to scanning installed Chromium browsers
    if not cmd:
        chromium_candidates = [
            "brave-browser",
            "brave",
            "google-chrome-stable",
            "google-chrome",
            "chromium",
            "chromium-browser",
            "microsoft-edge-stable",
            "microsoft-edge",
            "msedge",
            "vivaldi-stable",
            "vivaldi",
            "helium",
        ]
        for b in chromium_candidates:
            path = shutil.which(b)
            if path:
                cmd = [
                    path,
                    f"--app={safe_url}",
                    "--user-data-dir=/tmp/quicksearch-popin-profile",
                    "--ozone-platform-hint=auto",
                    "--window-size=1170,640",
                ]
                break

    # Step 3: Fallback to scanning installed Firefox browsers
    if not cmd:
        firefox_candidates = ["firefox", "zen-browser", "zen", "librewolf", "floorp"]
        for b in firefox_candidates:
            path = shutil.which(b)
            if path:
                cmd = [path, "--new-window", safe_url]
                break

    # Step 4: Ultimate fallback to omarchy-launch-browser or xdg-open
    if not cmd:
        if shutil.which("omarchy-launch-browser"):
            cmd = ["omarchy-launch-browser", "--", safe_url]
        else:
            cmd = ["xdg-open", "--", safe_url]

    # Step 5: Wrap in uwsm-app for native Omarchy Wayland session management
    if shutil.which("uwsm-app"):
        final_cmd = ["uwsm-app", "--"] + cmd
    else:
        final_cmd = cmd

    # Step 6: Spawn cleanly detached
    subprocess.Popen(
        final_cmd,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
    )

    # Step 7: Center the newly spawned floating popin window
    if shutil.which("hyprctl"):
        import time
        time.sleep(0.15)
        try:
            subprocess.run(["hyprctl", "dispatch", "centerwindow"], capture_output=True, timeout=1)
        except Exception:
            pass

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--"]
    target = args[0] if args else "https://duckduckgo.com"
    launch_popin(target)
