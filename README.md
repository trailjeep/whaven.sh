# whaven.sh

Randomized wallpapers from [Wallhaven.cc](https://wallhaven.cc), plus directory/file modes.

Fork/refactor of [whaven](https://github.com/jpatzy/whaven); this version is
shellcheck-clean (0 findings), shfmt-formatted, and reworks the original's
conditionally-defined functions and signal handling into a single flat loop
with poke-able signal handlers.

## Usage

    whaven.sh [-h|-u|-v] [-a key] [-d dir | -f file | -p dir | -k keyword...] [-i seconds] [-q]

| Flag | Meaning |
|------|---------|
| `-h`, `-u` | help |
| `-v` | version |
| `-a` | Wallhaven personal API key (required for NSFW) |
| `-d` | rotate a directory of images |
| `-f` | set one file once |
| `-k` | search keyword(s); repeatable, or `-k "a b"` / `a+b` |
| `-i` | interval seconds, min 60 (default 300) |
| `-p` | pick from a directory with rofi |
| `-q` | overlay a fortune quote |
| `-t` | theme filter: `dark` (default) or `light`; refetches mismatched wallpapers |

Default run: random wallpaper every 5 minutes from built-in keywords.

`-t` samples each fetched image with ImageMagick built-in statistics:
`mean` and `standard_deviation` from one `info:` call, combined into a
darkness score of `mean - 0.5*stdev` (0-100). High-contrast images (bright
sky + dark ground) score darker than flat gray at the same mean, which is
closer to how the eye judges a wallpaper. Measured values are printed to the
terminal on every fetch:

    [brightness] mean=42 stdev=38 score=23

Thresholds: `dark` accepts score < 35, `light` accepts score >= 65. Mismatched
wallpapers are refetched (up to 5 attempts); if none match, keywords rotate
(like SIGUSR2) and it tries again.

Signals: `SIGUSR1` next wallpaper, `SIGUSR2` new keywords + wall,
`SIGRTMIN` show keywords, `SIGRTMAX` save current, `SIGHUP` = SIGUSR1.

API key: `-a KEY`, or `WHAVEN_API_KEY`, or `~/.creds/wallhaven`.

Paths: `WHAVEN_CACHE_DIR`, `WHAVEN_WALLPAPER_DIR` (XDG defaults otherwise).

### Change log
- 1.0/1.1/1.2 — original by JJS
- 1.3 — refactor: shellcheck 0 warnings, signal-safe loop, fixed pidfile
  handling (`pgrep` was matching process names, not PIDs), quoting, dropped
  dead jq-less downloader path, `-k` accumulation no longer appends a stray `+`.
