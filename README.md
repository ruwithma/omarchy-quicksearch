# Quick Search (`ruwithma.quicksearch`)

A spotlight search overlay for Omarchy and Quickshell on Wayland desktop environments. Built with multi-engine bang expansion, an interactive GUI engine selector, offline mathematical expression evaluation, intelligent URL/localhost detection, debounced Google Suggest autocomplete with an in-memory LRU cache, and full keyboard navigation.

---

## Visual Design

- **Floating Spotlight Overlay**: Centered at the top quarter of the screen with smooth height transitions as suggestions appear.
- **Theme Integration**: Uses native Omarchy design tokens (`Color.menu.background`, `Color.menu.border`, `Color.accent`, `Color.menu.scrim`, `Style.cornerRadius`, and typography) with `BorderSurface` for full theme fidelity.
- **Frosted Translucency**: Subtle frosted glass effect with balanced dimming scrim backdrop.
- **Multi-Monitor Support**: Outside clicks on any connected display dismiss the overlay.
- **Focus Priming**: Wayland Layer Shell exclusive focus priming on summon before transitioning to on-demand keyboard focus.

---

## Features

- **Pop-in Browser HUD (Peek Mode)**: Searches and URLs pop in directly in a dedicated, floating, hardware-accelerated preview window (`quicksearch-popin-browser`) with navigation controls, address bar, link copy, and Esc to dismiss.
- **GUI Search Engine Selector**: Click the engine badge or press `Ctrl+E` to toggle a visual 2-column engine picker. Selected engine preferences persist across sessions.
- **Multi-Engine Bang Routing**: Switch engines on the fly using bang prefixes (e.g. `!gh`, `!yt`, `!d`, `!w`, `!r`, `!g`) or cycle with `Tab` / `Ctrl+Tab`.
- **Live Offline Math Evaluator**: Computes arithmetic, percentages, trigonometric functions, square roots, and powers instantly. Pressing `Enter` copies the calculated result directly to the Wayland clipboard via `wl-copy`.
- **URL & Localhost Detection**: Automatically detects full URLs, domain names, localhost ports (`localhost:3000`), and private LAN IPs.
- **LRU Autocomplete Cache**: Debounced suggestions powered by an in-memory LRU cache to eliminate unnecessary network requests and latency.
- **Keyboard Navigation**: Complete arrow key navigation, tab completion, engine cycling, and escape cancellation.

---

## Installation

Clone into your Omarchy plugins directory:

```bash
mkdir -p ~/.config/omarchy/plugins
git clone https://github.com/ruwithma/omarchy-quicksearch.git ~/.config/omarchy/plugins/ruwithma.quicksearch
```

Once installed, reload the Omarchy shell:

```bash
omarchy-restart-shell
```

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `Up` / `Down` | Navigate suggestions list or engine grid. Pressing `Up` on the top item restores the typed query. |
| `Tab` | Autocomplete highlighted suggestion into input bar; cycles engines if suggestions are empty. |
| `Shift + Tab` | Reverse navigate suggestions or cycle engines backwards. |
| `Ctrl + Tab` | Cycle to the next search engine. |
| `Ctrl + Shift + Tab` | Cycle to the previous search engine. |
| `Ctrl + E` | Toggle GUI Search Engine Selector. |
| `PageUp` / `PageDown` | Jump to top or bottom of suggestion list. |
| `Enter` | **Search / URL**: Open in floating Pop-in Browser HUD (`popin-browser.py`).<br>**Math**: Copy calculated result to clipboard (`wl-copy`). |
| `Shift + Enter` | **Search / URL**: Open directly in full default browser (`omarchy-launch-browser`). |
| `Esc` | Close GUI engine selector if open; clear query text if typed; dismiss overlay if input is empty. |
| `Click Backdrop` | Dismiss overlay. |

---

## Search Engine Bangs

Prefix your query with any bang to route directly to that search provider:

| Bang Prefix | Aliases | Provider |
| :--- | :--- | :--- |
| `!g` | `!g`, `!google` | Google |
| `!d` | `!d`, `!ddg`, `!duck` | DuckDuckGo |
| `!gh` | `!gh`, `!git`, `!github` | GitHub |
| `!yt` | `!yt`, `!y`, `!youtube` | YouTube |
| `!w` | `!w`, `!wiki`, `!wikipedia` | Wikipedia |
| `!r` | `!r`, `!reddit` | Reddit |

### Calculation Examples

Type formulas directly into the input bar:
- Basic: `(120 + 45) * 3 / 2`
- Percentage: `15% of 850` or `250 * 20%`
- Exponents & Roots: `2^10`, `sqrt(256)`
- Trigonometry & Constants: `sin(pi / 2)`, `cos(0)`, `log(1000)`

---

## Configuration & Keybinds

### CLI Summon

```bash
# Summon empty search overlay
omarchy-shell shell summon ruwithma.quicksearch '{}'

# Summon pre-populated with a query
omarchy-shell shell summon ruwithma.quicksearch '{"query": "omarchy wayland"}'
```

### Hyprland Setup

Add keybinds to summon Quick Search and window rules for the Pop-in Browser HUD:

#### Omarchy Hyprland Lua (`~/.config/hypr/hyprland.lua`):

```lua
-- QuickSearch Pop-in Browser HUD: STRICTLY ONLY matches QuickSearch search engine peek windows
local quicksearch_popin = "^(brave|chrome|chromium|microsoft-edge|vivaldi)-((www\\.|en\\.)?(duckduckgo|google|github|youtube|wikipedia|reddit)\\.(com|org))__.*$"

o.window({ class = quicksearch_popin }, {
  float = true,
  center = true,
  size = { 1170, 640 },
  border_size = 2,
  rounding = 12,
  dim_around = true,
  opacity = "1.0 1.0",
})
o.window({ class = quicksearch_popin }, { tag = "-default-opacity" })
o.window({ class = quicksearch_popin }, { tag = "-chromium-based-browser" })
```

#### Standard Hyprland (`~/.config/hypr/hyprland.conf`):

```ini
# Keybinds
bind = SUPER, Space, exec, omarchy-shell shell summon ruwithma.quicksearch '{}'
bind = SUPER, S, exec, omarchy-shell shell summon ruwithma.quicksearch '{}'

# Pop-in Browser HUD (Strictly matches search engine pop-in windows)
windowrulev2 = float, class:^(brave|chrome|chromium|microsoft-edge|vivaldi)-((www\.|en\.)?(duckduckgo|google|github|youtube|wikipedia|reddit)\.(com|org))__.*$
windowrulev2 = center, class:^(brave|chrome|chromium|microsoft-edge|vivaldi)-((www\.|en\.)?(duckduckgo|google|github|youtube|wikipedia|reddit)\.(com|org))__.*$
windowrulev2 = size 1170 640, class:^(brave|chrome|chromium|microsoft-edge|vivaldi)-((www\.|en\.)?(duckduckgo|google|github|youtube|wikipedia|reddit)\.(com|org))__.*$
windowrulev2 = bordersize 2, class:^(brave|chrome|chromium|microsoft-edge|vivaldi)-((www\.|en\.)?(duckduckgo|google|github|youtube|wikipedia|reddit)\.(com|org))__.*$
windowrulev2 = rounding 12, class:^(brave|chrome|chromium|microsoft-edge|vivaldi)-((www\.|en\.)?(duckduckgo|google|github|youtube|wikipedia|reddit)\.(com|org))__.*$
windowrulev2 = dimaround, class:^(brave|chrome|chromium|microsoft-edge|vivaldi)-((www\.|en\.)?(duckduckgo|google|github|youtube|wikipedia|reddit)\.(com|org))__.*$
windowrulev2 = opacity 1.0 1.0, class:^(brave|chrome|chromium|microsoft-edge|vivaldi)-((www\.|en\.)?(duckduckgo|google|github|youtube|wikipedia|reddit)\.(com|org))__.*$
```

---

## Roadmap & Upcoming Features

- **Voice Search Integration**: Direct speech-to-text input via local speech models or microphone capture for hands-free searching.
- **Incognito & Private Peek Mode**: Ephemeral private browsing session toggle (`Ctrl+P` / `!private` prefix) where browsing history, cookies, and cache are discarded on close.
- **Custom Search Providers**: User-defined custom search engines and custom bang definitions via local JSON config.

---

## Repository Structure

```text
ruwithma.quicksearch/
├── .gitignore
├── LICENSE
├── QuickSearch.qml
├── README.md
├── manifest.json
└── popin-browser.py
```

---

## License

Distributed under the [MIT License](LICENSE). Copyright (c) 2026 ruwithma.
