#!/usr/bin/env python3
"""Backlog library sync (Python 3, standard library only). For SteamOS / Steam Deck, Linux, macOS (and Windows).

The Backlog screensaver page runs walled off: no Steam API, no network. This tool reads the user's Steam files
(read only), copies their games' art and newest screenshots into the screensaver folder, and writes
library/library.js, which sets window.BACKLOG_LIBRARY.

Usage:
  python3 sync.py                      sync into the installed screensaver (<Steam>/config/uioverrides/screensavers/backlog)
  python3 sync.py --install            copy this repo's backlog folder into Steam first (keeps your config.js), then sync
  python3 sync.py --uninstall          remove Backlog from Steam and turn the automatic refresh off
  python3 sync.py --scenes mosaic,drift --minutes 5
                                       which scenes play and how long each stays (written into config.js)
  python3 sync.py --clock clock        what the clock corner shows: all, clock (the time and date only) or none
  python3 sync.py --target DIR         sync into another backlog folder
  python3 sync.py --max-screenshots 60 --max-games 0 --include-unplayed --account "persona name" --steam DIR
  python3 sync.py --list-accounts
  python3 sync.py --target DIR --reset   remove the synced library, put back the placeholder library.js
  python3 sync.py --api-key KEY          optional: up-to-date playtime from Steam for every device (your own Web API
                                         key; or STEAM_API_KEY, or ~/.config/backlog/steam-api-key). See tools/README.md.

What is read (nothing else, and nothing private is written out):
  steamapps/libraryfolders.vdf + appmanifest_*.acf    installed games
  userdata/<id>/config/localconfig.vdf                Playtime / LastPlayed per app
  config/loginusers.vdf                               which account logged in last, and its persona name
  appcache/appinfo.vdf (binary)                       names and types (Game / Tool / ...) of apps not installed
  appcache/librarycache/                              art (per-appid folders, hash subfolders, or the old flat names)
  userdata/<id>/config/grid/                          the user's own custom art (wins over Steam's)
  userdata/<id>/config/shortcuts.vdf (binary)         non-Steam games that have custom art
  userdata/<id>/config/cloudstorage/                  the games you hid in Steam (non-Steam ones: in localconfig.vdf),
                                                      left out unless config.js says showHidden: true
  userdata/<id>/760/remote/<appid>/screenshots/       screenshots (newest N)
"""
import argparse, hashlib, json, os, re, shutil, struct, sys, time, zlib

STEAMID64_BASE = 76561197960265728
KEEP_TYPES = {'game', 'demo', 'mod', 'beta'}
# Used only when appinfo.vdf has no type for an app.
NOT_GAME = re.compile(r'^proton\b|steamworks|steam linux runtime|redistributable|\bredist\b|soundtrack|\bost\b|'
                      r'\bsdk\b|dedicated server|^steamvr\b|^steam (?:controller|client|audio)|benchmark tool', re.I)
NOT_GAME_IDS = {7, 760, 228980, 1070560, 1391110, 1628350, 1493710, 1826330, 2180100, 2348590, 2805730, 3658110}
IMG_EXT = ('.jpg', '.jpeg', '.png', '.webp', '.gif')
PLACEHOLDER = ('/* Written by the Backlog sync tool. Until you run it, Backlog shows a demo library. */\n'
               'window.BACKLOG_LIBRARY = null;\n')


def log(*a):
    print(*a, flush=True)


# ------------------------------------------------------------------ text VDF (KeyValues)
def parse_text_vdf(txt):
    """Steam text KeyValues -> nested dicts. Keys keep their case; use get_ci() for lookups."""
    i, n = 0, len(txt)

    def token():
        nonlocal i
        while i < n:
            c = txt[i]
            if c in ' \t\r\n\ufeff':
                i += 1
            elif txt.startswith('//', i):
                j = txt.find('\n', i)
                i = n if j < 0 else j + 1
            else:
                break
        if i >= n:
            return None
        c = txt[i]
        if c in '{}':
            i += 1
            return c
        if c == '"':
            i += 1
            out = []
            while i < n and txt[i] != '"':
                if txt[i] == '\\' and i + 1 < n:
                    nx = txt[i + 1]
                    out.append({'n': '\n', 't': '\t', '\\': '\\', '"': '"'}.get(nx, '\\' + nx))
                    i += 2
                else:
                    out.append(txt[i])
                    i += 1
            i += 1
            return ('s', ''.join(out))
        j = i
        while j < n and txt[j] not in ' \t\r\n{}"':
            j += 1
        s = txt[i:j]
        i = j
        return ('s', s)

    def block():
        d = {}
        key = None
        while True:
            t = token()
            if t is None or t == '}':
                return d
            if t == '{':
                d[key if key is not None else ''] = block()
                key = None
            elif key is None:
                key = t[1]
            else:
                if t[1].startswith('[$') and t[1].endswith(']'):  # conditional after a value
                    continue
                d[key] = t[1]
                key = None
    return block()


def get_ci(d, *path):
    for k in path:
        if not isinstance(d, dict):
            return None
        lk = k.lower()
        nxt = None
        for kk, v in d.items():
            if kk.lower() == lk:
                nxt = v
                break
        d = nxt
        if d is None:
            return None
    return d


def read_text_vdf(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            return parse_text_vdf(f.read())
    except OSError:
        return {}


def to_int(v, default=0):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return default


def game_achievements(path, older_than=0):
    """(unlocked, total) from Steam's per-game library cache file, if it was written after `older_than` (Unix
    seconds) and counts any achievements; otherwise None. The file is a list of [section, {version, data}]."""
    try:
        if os.path.getmtime(path) <= older_than:
            return None
        with open(path, encoding='utf-8') as f:
            sections = json.load(f)
        for item in sections if isinstance(sections, list) else []:
            if isinstance(item, list) and len(item) == 2 and item[0] == 'achievements' and isinstance(item[1], dict):
                data = item[1].get('data') or {}
                total = to_int(data.get('nTotal'))
                if total > 0:
                    return to_int(data.get('nAchieved')), total
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    return None


# ------------------------------------------------------------------ binary VDF (KeyValues)
T_SECTION, T_STRING, T_INT32, T_FLOAT, T_PTR, T_WSTRING, T_COLOR, T_UINT64, T_END, T_INT64, T_END2 = 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11


class BinKV:
    """Reads binary KeyValues from a bytes buffer. strings: key table (appinfo v29+), else keys are inline."""

    def __init__(self, buf, strings=None):
        self.b, self.strings = buf, strings

    def cstr(self, p):
        e = self.b.index(b'\0', p)
        return self.b[p:e].decode('utf-8', 'replace'), e + 1

    def key(self, p):
        if self.strings is not None:
            return self.strings[struct.unpack_from('<i', self.b, p)[0]], p + 4
        return self.cstr(p)

    def value(self, t, p):
        if t == T_SECTION:
            return self.section(p)
        if t == T_STRING:
            return self.cstr(p)
        if t == T_WSTRING:
            e = p
            while self.b[e:e + 2] != b'\0\0':
                e += 2
            return self.b[p:e].decode('utf-16-le', 'replace'), e + 2
        if t in (T_INT32, T_PTR, T_COLOR):
            return struct.unpack_from('<i', self.b, p)[0], p + 4
        if t == T_FLOAT:
            return struct.unpack_from('<f', self.b, p)[0], p + 4
        if t == T_UINT64:
            return struct.unpack_from('<Q', self.b, p)[0], p + 8
        if t == T_INT64:
            return struct.unpack_from('<q', self.b, p)[0], p + 8
        raise ValueError('unknown KeyValues type %d at %d' % (t, p))

    def section(self, p, stop_after=None):
        """Parse a section body at p. If stop_after (lower-case key) is given, return as soon as it is read."""
        d = {}
        while True:
            t = self.b[p]
            p += 1
            if t in (T_END, T_END2):
                return d, p
            k, p = self.key(p)
            v, p = self.value(t, p)
            d[k] = v
            if stop_after and k.lower() == stop_after:
                return d, p


def read_appinfo(path, wanted):
    """appid -> (name, type) for the appids in `wanted`, from appcache/appinfo.vdf. Skips everything else fast."""
    out = {}
    try:
        with open(path, 'rb') as f:
            buf = f.read()
    except OSError:
        return out, 'missing'
    magic = struct.unpack_from('<I', buf, 0)[0]
    p = 8
    strings = None
    if magic >= 0x07564429:
        table = struct.unpack_from('<q', buf, p)[0]
        p += 8
        count = struct.unpack_from('<i', buf, table)[0]
        strings, q = [], table + 4
        for _ in range(count):
            e = buf.index(b'\0', q)
            strings.append(buf[q:e].decode('utf-8', 'replace'))
            q = e + 1
    elif magic not in (0x07564427, 0x07564428):
        return out, 'unknown format 0x%08X' % magic
    kv = BinKV(buf, strings)
    header = 4 + 4 + 8 + 20 + 4 + (20 if magic >= 0x07564428 else 0)
    try:
        while p + 8 <= len(buf):
            appid, size = struct.unpack_from('<II', buf, p)
            if appid == 0:
                break
            nxt = p + 8 + size
            if appid in wanted:
                q = p + 8 + header
                # root: { "appinfo" { "appid", "common" {...}, ... } }; stop once "common" is read.
                t = buf[q]
                k, q = kv.key(q + 1)
                if t == T_SECTION:
                    info, _ = kv.section(q, stop_after='common')
                    common = get_ci(info, 'common') or {}
                    name = get_ci(common, 'name')
                    typ = get_ci(common, 'type')
                    out[appid] = (name if isinstance(name, str) else None, typ.lower() if isinstance(typ, str) else None)
            p = nxt
    except (ValueError, IndexError, struct.error) as e:
        return out, 'stopped early (%s)' % e
    return out, 'ok'


def read_shortcuts(path):
    try:
        with open(path, 'rb') as f:
            buf = f.read()
    except OSError:
        return []
    kv = BinKV(buf)
    try:
        t = buf[0]
        k, p = kv.key(1)
        root, _ = kv.section(p) if t == T_SECTION else ({}, 0)
    except (ValueError, IndexError, struct.error):
        return []
    out = []
    for entry in root.values():
        if not isinstance(entry, dict):
            continue
        name = get_ci(entry, 'AppName') or get_ci(entry, 'appname')
        exe = get_ci(entry, 'Exe') or ''
        if not isinstance(name, str) or not name.strip():
            continue
        if to_int(get_ci(entry, 'IsHidden')) == 1:
            continue
        aid = get_ci(entry, 'appid')
        if isinstance(aid, int) and aid != 0:
            aid &= 0xFFFFFFFF
        else:  # older shortcuts.vdf: Steam derives the id from the exe and the name
            aid = (zlib.crc32((exe + name).encode('utf-8')) & 0xFFFFFFFF) | 0x80000000
        out.append({'appid': aid, 'name': name.strip(), 'lastPlayed': max(0, to_int(get_ci(entry, 'LastPlayTime')))})
    return out


# ------------------------------------------------------------------ finding things
def find_steam(explicit):
    cands = []
    if explicit:
        cands.append(explicit)
    if sys.platform == 'win32':
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam') as k:
                cands.append(winreg.QueryValueEx(k, 'SteamPath')[0])
        except OSError:
            pass
        cands.append(r'C:\Program Files (x86)\Steam')
    elif sys.platform == 'darwin':
        cands.append('~/Library/Application Support/Steam')
    else:
        cands += ['~/.steam/root', '~/.steam/steam', '~/.local/share/Steam',
                  '~/.var/app/com.valvesoftware.Steam/.local/share/Steam']
    for c in cands:
        c = os.path.realpath(os.path.expanduser(c))
        if os.path.isdir(os.path.join(c, 'steamapps')) or os.path.isdir(os.path.join(c, 'userdata')):
            return c
    return None


def accounts(steam):
    """[(accountid, persona, mostRecent, timestamp)] for accounts that have a userdata folder."""
    users = get_ci(read_text_vdf(os.path.join(steam, 'config', 'loginusers.vdf')), 'users') or {}
    have = set()
    ud = os.path.join(steam, 'userdata')
    if os.path.isdir(ud):
        have = {d for d in os.listdir(ud) if d.isdigit() and d != '0'}
    out, seen = [], set()
    for sid, u in users.items():
        if not isinstance(u, dict) or not sid.isdigit():
            continue
        acc = str(int(sid) - STEAMID64_BASE) if int(sid) > STEAMID64_BASE else sid
        if acc not in have:
            continue
        seen.add(acc)
        out.append((acc, get_ci(u, 'PersonaName') or '', to_int(get_ci(u, 'MostRecent')), to_int(get_ci(u, 'Timestamp')), sid))
    for acc in have - seen:  # a userdata folder with no loginusers entry: rank by its localconfig's age
        lc = os.path.join(ud, acc, 'config', 'localconfig.vdf')
        ts = int(os.path.getmtime(lc)) if os.path.exists(lc) else 0
        out.append((acc, '', 0, ts, ''))
    out.sort(key=lambda a: (a[2], a[3]), reverse=True)
    return out


def library_folders(steam):
    roots = [steam]
    lf = read_text_vdf(os.path.join(steam, 'steamapps', 'libraryfolders.vdf'))
    lf = get_ci(lf, 'libraryfolders') or lf
    for k, v in (lf or {}).items():
        p = get_ci(v, 'path') if isinstance(v, dict) else (v if k.isdigit() else None)
        if isinstance(p, str) and p:
            roots.append(p)
    seen, out = set(), []
    for r in roots:
        key = os.path.normcase(os.path.realpath(r))
        if key not in seen and os.path.isdir(os.path.join(r, 'steamapps')):
            seen.add(key)
            out.append(r)
    return out


def installed_apps(steam):
    apps = {}
    for root in library_folders(steam):
        sa = os.path.join(root, 'steamapps')
        for fn in os.listdir(sa):
            if fn.startswith('appmanifest_') and fn.endswith('.acf'):
                st = get_ci(read_text_vdf(os.path.join(sa, fn)), 'AppState') or {}
                aid = to_int(get_ci(st, 'appid'))
                if aid:
                    apps[aid] = {'name': get_ci(st, 'name') or '', 'lastPlayed': to_int(get_ci(st, 'LastPlayed'))}
    return apps


def pick_newest(paths):
    paths = [p for p in paths if os.path.isfile(p)]
    return max(paths, key=os.path.getmtime) if paths else None


ART_NAMES = {  # best first; each name may sit in the app folder or in a hash-named subfolder
    'cover': ['library_600x900_2x.jpg', 'library_600x900.jpg', 'library_capsule_2x.jpg', 'library_capsule.jpg'],
    'hero': ['library_hero_2x.jpg', 'library_hero.jpg'],
    'logo': ['logo_2x.png', 'logo.png'],
    'header': ['header_2x.jpg', 'header.jpg', 'library_header_2x.jpg', 'library_header.jpg'],
}
FLAT = {'cover': ['library_600x900_2x.jpg', 'library_600x900.jpg'], 'hero': ['library_hero.jpg'],
        'logo': ['logo.png'], 'header': ['header.jpg'], 'icon': ['icon.jpg']}
GRID = {'cover': '{}p', 'hero': '{}_hero', 'logo': '{}_logo', 'header': '{}', 'icon': '{}_icon'}
HASH_JPG = re.compile(r'^[0-9a-f]{40}\.jpg$')


def cache_art(cache, appid):
    """Steam's cached art for one app: {kind: path}. Handles the per-app folder (with hash subfolders) and old flat files."""
    art = {}
    folder = os.path.join(cache, str(appid))
    if os.path.isdir(folder):
        by_name, icons = {}, []
        for entry in os.scandir(folder):
            if entry.is_file():
                if HASH_JPG.match(entry.name) and entry.stat().st_size < 64 * 1024:
                    icons.append(entry.path)
                by_name.setdefault(entry.name.lower(), []).append(entry.path)
            elif entry.is_dir():
                for sub in os.scandir(entry.path):
                    if sub.is_file():
                        by_name.setdefault(sub.name.lower(), []).append(sub.path)
        for kind, names in ART_NAMES.items():
            for nm in names:
                p = pick_newest(by_name.get(nm, []))
                if p:
                    art[kind] = p
                    break
        if icons:
            art['icon'] = pick_newest(icons)
    for kind, names in FLAT.items():
        if kind not in art:
            for nm in names:
                p = os.path.join(cache, '%d_%s' % (appid, nm))
                if os.path.isfile(p):
                    art[kind] = p
                    break
    return art


def grid_art(grid_files, appid):
    art = {}
    for kind, pat in GRID.items():
        stem = pat.format(appid)
        for ext in IMG_EXT:
            p = grid_files.get(stem + ext)
            if p:
                art[kind] = p
                break
    return art


def collection_ids(coll):
    """The app ids in one Steam collection, {"id":..,"added":[ids],"removed":[ids]}: added minus removed. A 64-bit
    game id (a non-Steam shortcut id in the top 32 bits) becomes that 32-bit shortcut id."""
    out = set()
    if not isinstance(coll, dict):
        return out
    removed = {to_int(x) for x in coll.get('removed') or []}
    for x in coll.get('added') or []:
        n = to_int(x)
        if n <= 0 or n in removed:
            continue
        out.add(n if n <= 0xFFFFFFFF else (n >> 32) & 0xFFFFFFFF)
    return out


def find_ci(d, key):
    """The first value anywhere in a nested dict whose key is `key` (any case), else None."""
    if not isinstance(d, dict):
        return None
    for k, v in d.items():
        if k.lower() == key:
            return v
    for v in d.values():
        hit = find_ci(v, key)
        if hit is not None:
            return hit
    return None


def shows_hidden(target):
    """True when the installed config.js turns showHidden on (library: { ..., showHidden: true }). Lines that are
    comments don't count; a missing or unreadable config.js means off."""
    try:
        with open(os.path.join(target, 'config.js'), encoding='utf-8') as f:
            text = f.read()
    except OSError:
        return False
    text = re.sub(r'(?m)^\s*//.*$', '', text)
    return re.search(r'\bshowHidden\s*:\s*true\b', text) is not None


def hidden_apps(userdir, localconfig):
    """App ids of the games hidden in Steam (Manage > Hide this game). Steam keeps them in two places (checked on a
    Steam Deck, 2026-11-21): Steam games in the "Hidden" collection it syncs to the cloud, the 'user-collections.hidden'
    entry of config/cloudstorage/cloud-storage-namespace-1.json (a list of [key, entry] pairs; the entry's value is a
    JSON string), and non-Steam games only on the device, in localconfig.vdf's "user-collections" value (a JSON string
    of collections by id, with a "hidden" one). Anything unreadable adds nothing."""
    out = set()
    try:
        with open(os.path.join(userdir, 'config', 'cloudstorage', 'cloud-storage-namespace-1.json'),
                  encoding='utf-8') as f:
            pairs = json.load(f)
        for item in pairs if isinstance(pairs, list) else []:
            if isinstance(item, list) and len(item) == 2 and item[0] == 'user-collections.hidden':
                entry = item[1] if isinstance(item[1], dict) else {}
                if not entry.get('is_deleted'):
                    out |= collection_ids(json.loads(entry.get('value') or '{}'))
                break
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    try:
        local = find_ci(localconfig, 'user-collections')
        if isinstance(local, str) and local.strip():
            out |= collection_ids((json.loads(local) or {}).get('hidden'))
    except (ValueError, TypeError, AttributeError):
        pass
    return out


SHOT_NAME = re.compile(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})_\d+\.(?:jpe?g|png)$', re.I)


def screenshots(userdir, limit, skip=frozenset()):
    """The newest `limit` screenshots, leaving out the games in `skip` (the ones hidden in Steam)."""
    base = os.path.join(userdir, '760', 'remote')
    found = []
    if not os.path.isdir(base):
        return found
    for aid in os.listdir(base):
        d = os.path.join(base, aid, 'screenshots')
        if not aid.isdigit() or not os.path.isdir(d):
            continue
        # A non-Steam game is filed under its 64-bit game id (appid << 32 | 0x02000000): use its unsigned 32-bit
        # appid, the id that game has everywhere else here.
        appid = int(aid)
        if appid > 0xFFFFFFFF:
            appid >>= 32
        if appid > 0xFFFFFFFF or appid in skip:
            continue
        for fn in os.listdir(d):
            p = os.path.join(d, fn)
            if not os.path.isfile(p) or not fn.lower().endswith(('.jpg', '.jpeg', '.png')):
                continue
            m = SHOT_NAME.match(fn)
            t = 0
            if m:
                try:
                    t = int(time.mktime(tuple(int(x) for x in m.groups()) + (0, 0, -1)))
                except (OverflowError, ValueError):
                    t = 0
            found.append({'appid': appid, 'src': p, 'time': t or int(os.path.getmtime(p))})
    found.sort(key=lambda s: s['time'], reverse=True)
    return found[:limit]


# ------------------------------------------------------------------ optional online refresh (your own Steam Web API key)
CDN = 'https://shared.steamstatic.com/store_item_assets/steam/apps'
CDN_FILES = {'cover': 'library_600x900.jpg', 'hero': 'library_hero.jpg', 'logo': 'logo.png', 'header': 'header.jpg'}


def key_file():
    """The key file lives in the user's own config folder, never in the screensaver folder."""
    if sys.platform == 'win32':
        return os.path.join(os.environ.get('APPDATA', os.path.expanduser('~')), 'backlog', 'steam-api-key.txt')
    base = os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config')
    return os.path.join(base, 'backlog', 'steam-api-key')


def find_api_key(flag):
    """(key, where) or (None, None). The key itself is never printed or written anywhere."""
    if flag:
        return flag.strip(), '--api-key'
    if os.environ.get('STEAM_API_KEY', '').strip():
        return os.environ['STEAM_API_KEY'].strip(), 'STEAM_API_KEY'
    try:
        with open(key_file(), encoding='utf-8-sig') as f:
            k = f.read().strip()
        if k:
            return k, key_file()
    except OSError:
        pass
    return None, None


def fetch_owned(key, steamid64, response_file=None):
    """Owned games from IPlayerService/GetOwnedGames, or None with a message. Messages never contain the key."""
    import urllib.request, urllib.error, urllib.parse
    if response_file:  # test only: a saved or made-up API response instead of the network
        with open(response_file, encoding='utf-8') as f:
            body = json.load(f)
    else:
        if not re.fullmatch(r'[0-9A-Fa-f]{32}', key):
            return None, "the API key doesn't look like a Steam Web API key (32 letters and digits); skipped"
        q = urllib.parse.urlencode({'key': key, 'steamid': steamid64, 'include_appinfo': 1,
                                    'include_played_free_games': 1, 'format': 'json'})
        req = urllib.request.Request('https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?' + q,
                                     headers={'User-Agent': 'Backlog-sync'})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = json.loads(r.read().decode('utf-8'))
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                return None, 'Steam refused the API key (HTTP %d); using local data only' % e.code
            return None, 'Steam Web API error (HTTP %d); using local data only' % e.code
        except Exception as e:  # network down, timeout, bad JSON: say what kind, not the URL
            return None, 'could not reach the Steam Web API (%s); using local data only' % type(e).__name__
    games = (body.get('response') or {}).get('games') if isinstance(body, dict) else None
    if not games:
        return None, ("Steam returned no games for this account. Its game details are probably private: Steam > "
                      "your profile > Edit Profile > Privacy Settings > Game details: Public. Using local data only.")
    return games, None


def is_image(b):
    return b[:3] == b'\xff\xd8\xff' or b[:8] == b'\x89PNG\r\n\x1a\n'


def cdn_get(url):
    """Bytes of a public Steam CDN image, or None (missing art is normal: skip quietly)."""
    import urllib.request
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'Backlog-sync'}), timeout=20) as r:
            b = r.read(16 * 1024 * 1024)
        return b if is_image(b) else None
    except Exception:
        return None


# ------------------------------------------------------------------ install and write
SCENES = ('mosaic', 'drift', 'flip', 'ripple', 'ripple2')


def parse_scenes(text):
    """'mosaic, drift' -> ['mosaic', 'drift']; stops with a plain message on a name that is not a scene."""
    names = [n.strip().lower() for n in text.split(',') if n.strip()]
    bad = [n for n in names if n not in SCENES]
    if bad or not names:
        sys.exit('--scenes: pick from %s (got %r)' % (', '.join(SCENES), text))
    return [n for i, n in enumerate(names) if n not in names[:i]]


CLOCK_CHOICES = ('all', 'clock', 'none')


def parse_clock(text):
    """'Clock' -> 'clock'; stops with a plain message on a word that is not one of the three choices."""
    name = text.strip().lower()
    if name not in CLOCK_CHOICES:
        sys.exit('--clock: pick from %s (got %r)' % (', '.join(CLOCK_CHOICES), text))
    return name


def put_clock(text, choice, nl):
    """config.js with clock.show set to that choice, or None when its clock setting is not in a shape this knows."""
    value = "'%s'" % choice
    # the setting itself, never the note above it that explains it (a line starting with //)
    out, n = re.subn(r"""^((?![ \t]*//)[^\r\n]*?\bshow:\s*)(?:'[^'\r\n]*'|"[^"\r\n]*"|\{[^{}]*\})""", lambda m: m.group(1) + value, text, count=1, flags=re.M)
    if not n:  # a settings file from before the choice existed: the clock setting is one line, without show
        out, n = re.subn(r'^([ \t]*clock:\s*\{[^{}\r\n]*?)[ \t]*\}', lambda m: m.group(1) + ', show: %s }' % value, text, count=1, flags=re.M)
    if not n and not re.search(r'^[ \t]*clock:', text, flags=re.M):
        out, n = re.subn(r'(BACKLOG_CONFIG\s*=\s*\{[ \t]*\r?\n)', lambda m: m.group(1) + '  clock: { show: %s },%s' % (value, nl), text, count=1)
    return out if n else None


def set_choices(target, scenes, minutes, clock=None):
    """Write the installer's choices into config.js: which scenes play, how many minutes each stays, and what
    the clock corner shows. Only those settings change; a line that is missing is added at the top."""
    path = os.path.join(target, 'config.js')
    with open(path, encoding='utf-8', newline='') as f:
        text = f.read()
    nl = '\r\n' if '\r\n' in text else '\n'

    def put(text, pattern, key, value):
        out, n = re.subn(pattern, lambda m: m.group(1) + value, text, count=1, flags=re.M)
        if not n:
            out, n = re.subn(r'(BACKLOG_CONFIG\s*=\s*\{[ \t]*\r?\n)', lambda m: m.group(1) + '  %s: %s,%s' % (key, value, nl), text, count=1)
        if not n:
            sys.exit('config.js does not look like a Backlog settings file: %s' % path)
        return out

    if scenes:
        text = put(text, r"^([ \t]*scenes:\s*)(?:\[[^\]]*\]|'[^']*'|\"[^\"]*\")", 'scenes', '[%s]' % ', '.join("'%s'" % s for s in scenes))
        log('  scenes:', ', '.join(scenes))
    if minutes:
        text = put(text, r'^([ \t]*minutesPerScene:\s*)[0-9.]+', 'minutesPerScene', ('%g' % minutes))
        log('  minutes per scene: %g' % minutes)
    if clock is not None:
        changed = put_clock(text, clock, nl)
        if changed is None:
            log('  clock: left as it is (the clock setting in config.js is not in a shape the installer knows)')
        else:
            text = changed
            log('  clock corner:', {'all': 'everything', 'clock': 'the time and date only', 'none': 'off'}[clock])
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(text)


def install(src, dst):
    """Copy the backlog folder into Steam. Keeps the user's config.js and leaves library/ to the sync."""
    os.makedirs(dst, exist_ok=True)
    for name in os.listdir(src):
        s, d = os.path.join(src, name), os.path.join(dst, name)
        if name == 'library':
            os.makedirs(d, exist_ok=True)
            continue
        if name == 'config.js' and os.path.exists(d):
            log('  kept your config.js')
            continue
        if os.path.isdir(s):
            if os.path.isdir(d):
                shutil.rmtree(d)
            shutil.copytree(s, d)
        else:
            shutil.copy2(s, d)


def clean_library(lib, keep):
    """Remove app folders an earlier sync wrote for games no longer in the library, nothing else."""
    if not os.path.isdir(lib):
        return
    for name in os.listdir(lib):
        p = os.path.join(lib, name)
        if os.path.isdir(p) and name.isdigit() and name not in keep:
            shutil.rmtree(p, ignore_errors=True)


def in_git_tree(path):
    p = os.path.realpath(path)
    while True:
        if os.path.exists(os.path.join(p, '.git')):
            return p
        up = os.path.dirname(p)
        if up == p:
            return None
        p = up


# ------------------------------------------------------------------ automatic refresh (systemd user timer)
# The screensaver can't read Steam itself, so the library is only as fresh as the last sync. On SteamOS and other
# systemd Linux, --install sets up a user timer that re-runs this sync every 15 minutes and shortly after boot (no root,
# no password). A sync with nothing new takes about a second. --no-schedule skips it; --unschedule removes it.
UNIT = 'backlog-sync'
REFRESH = {'boot': '2min', 'every': '*:0/15'}


def _xdg(var, default):
    return os.environ.get(var) or os.path.expanduser(default)


def schedule_paths():
    share = os.path.join(_xdg('XDG_DATA_HOME', '~/.local/share'), 'backlog')
    units = os.path.join(_xdg('XDG_CONFIG_HOME', '~/.config'), 'systemd', 'user')
    return share, os.path.join(units, UNIT + '.service'), os.path.join(units, UNIT + '.timer')


def _systemd_arg(s):
    """Quote one ExecStart argument the way systemd reads it (and keep % literal)."""
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'


def scheduled_args(argv, target=None):
    """The user's own options for the timed runs: drops one-off flags, never writes an API key into a file, and gives
    --target as a full path (the timed run starts in another folder)."""
    drop_flag = {'--install', '--no-schedule', '--unschedule', '--uninstall', '--reset', '--list-accounts'}
    drop_value = {'--api-key', '--api-response-file', '--cdn-base', '--target'}
    out, skip = [], False
    for x in argv:
        if skip:
            skip = False
            continue
        name = x.split('=', 1)[0]
        if name in drop_flag:
            continue
        if name in drop_value:
            skip = '=' not in x
            continue
        out.append(x)
    if target:
        out += ['--target', target]
    return out


def _systemctl(*args):
    import subprocess
    return subprocess.run(['systemctl', '--user'] + list(args), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          universal_newlines=True)


def schedule(argv, target=None):
    if not sys.platform.startswith('linux') or not shutil.which('systemctl'):
        if sys.platform == 'win32':
            log('Automatic refresh: on Windows, use tools\\sync.ps1 -ScheduleDaily.')
        else:
            log('Automatic refresh is not set up on this system: run sync.py again to show new games and hours.')
        return False
    share, service, timer = schedule_paths()
    os.makedirs(share, exist_ok=True)
    os.makedirs(os.path.dirname(service), exist_ok=True)
    # Run a copy kept in the user's own data folder, so the timer keeps working after the download folder is deleted.
    script = os.path.join(share, 'sync.py')
    if os.path.realpath(__file__) != os.path.realpath(script):
        shutil.copy2(os.path.realpath(__file__), script)
    cmd = ' '.join(_systemd_arg(x) for x in [sys.executable, script] + scheduled_args(argv, target))
    with open(service, 'w', encoding='utf-8', newline='\n') as f:
        f.write('[Unit]\nDescription=Refresh the Backlog screensaver library from Steam\n\n'
                '[Service]\nType=oneshot\nExecStart=%s\nNice=19\nIOSchedulingClass=idle\nTimeoutStartSec=15min\n' % cmd)
    with open(timer, 'w', encoding='utf-8', newline='\n') as f:
        f.write('[Unit]\nDescription=Refresh the Backlog screensaver library every 15 minutes\n\n'
                '[Timer]\nOnBootSec=%s\nOnCalendar=%s\nPersistent=true\nAccuracySec=1min\n\n'
                '[Install]\nWantedBy=timers.target\n' % (REFRESH['boot'], REFRESH['every']))
    r1 = _systemctl('daemon-reload')
    r2 = _systemctl('enable', '--now', UNIT + '.timer')
    if r1.returncode or r2.returncode:
        log('Automatic refresh could not be turned on:', (r1.stdout + r2.stdout).strip())
        log('  Backlog still works; run sync.py again to refresh it by hand.')
        return False
    log('Automatic refresh is on: your games, hours and achievements update every 15 minutes and after a restart.')
    log('  Turn it off with:  python3 %s --unschedule' % script)
    return True


class _NoLock:
    def close(self):
        pass


def lock_library(lib):
    """One sync at a time per library: two at once delete each other's files. Waits for a running one to finish."""
    try:
        import fcntl
    except ImportError:  # Windows: no timer runs this script there
        return _NoLock()
    f = open(os.path.join(lib, '.lock'), 'w')
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


def unschedule(quiet=False):
    share, service, timer = schedule_paths()
    has = shutil.which('systemctl')
    if has:
        _systemctl('disable', '--now', UNIT + '.timer')
    for p in (service, timer, os.path.join(share, 'sync.py')):
        if os.path.exists(p):
            os.remove(p)
    if has:
        _systemctl('daemon-reload')
    if not quiet:
        log('Automatic refresh is off. The screensaver stays installed; run sync.py to refresh it by hand.')


def uninstall(steam_arg=None):
    """Remove everything the installer added: the automatic refresh, its copy of this script, and the screensaver
    folder in Steam (with the synced library and your config.js). An API key file, if you made one, is left alone."""
    unschedule(quiet=True)
    share = schedule_paths()[0]
    if os.path.isdir(share):
        shutil.rmtree(share, ignore_errors=True)
    steam = find_steam(steam_arg)
    installed = os.path.join(steam, 'config', 'uioverrides', 'screensavers', 'backlog') if steam else None
    if installed and os.path.isdir(installed):
        shutil.rmtree(installed)
        log('Removed', installed)
        log('Backlog is uninstalled. If it was your screensaver, pick another in Settings > Customization > Screensaver.')
    else:
        log('No installed Backlog screensaver was found; the automatic refresh is off.')
    if os.path.isfile(key_file()):
        log('Your Steam Web API key file was left in place:', key_file())


def main():
    ap = argparse.ArgumentParser(description='Sync your Steam library into the Backlog screensaver.')
    ap.add_argument('--target', help='backlog folder to write into (default: the one installed in Steam)')
    ap.add_argument('--install', action='store_true', help="copy this repo's backlog folder into Steam first")
    ap.add_argument('--max-screenshots', type=int, default=60)
    ap.add_argument('--account', help='persona name, account id or SteamID64 (default: the last account to log in)')
    ap.add_argument('--list-accounts', action='store_true')
    ap.add_argument('--include-unplayed', action='store_true',
                    help='also add owned games you have never played (art cached by the library view)')
    ap.add_argument('--max-games', type=int, default=0, help='keep only the N most recently played (0 = all)')
    ap.add_argument('--no-shortcuts', action='store_true', help='leave out non-Steam games')
    ap.add_argument('--steam', help='Steam folder (default: found automatically)')
    ap.add_argument('--reset', action='store_true', help='remove the synced library and put back the placeholder library.js')
    ap.add_argument('--no-schedule', action='store_true', help='with --install: skip the automatic refresh')
    ap.add_argument('--unschedule', action='store_true', help='turn the automatic refresh off and stop')
    ap.add_argument('--uninstall', action='store_true', help='remove Backlog from Steam and turn the automatic refresh off')
    ap.add_argument('--scenes', help='which scenes play, in order, as a comma list: ' + ', '.join(SCENES))
    ap.add_argument('--minutes', type=float, default=0, help='minutes each scene stays (for example 5)')
    ap.add_argument('--clock', help='what the clock corner shows: all, clock (the time and date only) or none')
    ap.add_argument('--api-key', help='your Steam Web API key, for up-to-date playtime from every device (optional; '
                    'also read from STEAM_API_KEY or %s)' % key_file())
    ap.add_argument('--api-response-file', help=argparse.SUPPRESS)  # test only: a JSON file in place of the API call
    ap.add_argument('--cdn-base', default=CDN, help=argparse.SUPPRESS)  # test only: where missing art is fetched from
    a = ap.parse_args()
    scenes = parse_scenes(a.scenes) if a.scenes else None
    clock = parse_clock(a.clock) if a.clock else None
    if a.minutes and not 0.25 <= a.minutes <= 240:
        sys.exit('--minutes: between 0.25 and 240')
    if a.uninstall:
        uninstall(a.steam)
        return
    if a.unschedule:
        unschedule()
        return

    steam = find_steam(a.steam)
    if not steam:
        sys.exit('Steam was not found. Pass --steam <folder>.')
    log('Steam:', steam)

    accs = accounts(steam)
    if a.list_accounts:
        for acc, persona, recent, _, _ in accs:
            log('  %s  %s%s' % (acc, persona or '(no name)', '  (last logged in)' if recent else ''))
        return
    if not accs:
        sys.exit('No Steam account with a userdata folder was found.')
    acc = accs[0]
    if a.account:
        want = a.account.strip().lower()
        m = [x for x in accs if want in (x[0], x[4], x[1].lower())]
        if not m:
            sys.exit('No account matches %r. Try --list-accounts.' % a.account)
        acc = m[0]
    accountid, persona = acc[0], acc[1]
    userdir = os.path.join(steam, 'userdata', accountid)
    log('Account:', persona or '(no name)')

    here = os.path.dirname(os.path.realpath(__file__))
    installed_dir = os.path.join(steam, 'config', 'uioverrides', 'screensavers', 'backlog')
    target = os.path.realpath(os.path.expanduser(a.target)) if a.target else installed_dir
    if a.install:
        src = os.path.join(os.path.dirname(here), 'backlog')
        if not os.path.isfile(os.path.join(src, 'index.html')):
            sys.exit('--install: no backlog folder next to tools/ (%s)' % src)
        log('Installing Backlog into', target)
        install(src, target)
    if not os.path.isfile(os.path.join(target, 'index.html')):
        sys.exit('No Backlog screensaver at %s. Run with --install, or pass --target.' % target)
    if scenes or a.minutes or clock is not None:
        set_choices(target, scenes, a.minutes, clock)
    lib = os.path.join(target, 'library')
    os.makedirs(lib, exist_ok=True)
    lock = lock_library(lib)  # held until this run ends; a timed refresh that starts meanwhile waits its turn
    if a.reset:
        clean_library(lib, set())
        for n in ('shots',):
            shutil.rmtree(os.path.join(lib, n), ignore_errors=True)
        if os.path.exists(os.path.join(lib, '.sources')):
            os.remove(os.path.join(lib, '.sources'))
        with open(os.path.join(lib, 'library.js'), 'w', encoding='utf-8', newline='\n') as f:
            f.write(PLACEHOLDER)
        log('Reset %s to the placeholder: Backlog shows its demo library until the next sync.' % lib)
        return

    # Playtime and last played.
    lc = read_text_vdf(os.path.join(userdir, 'config', 'localconfig.vdf'))
    apps_cfg = get_ci(lc, 'UserLocalConfigStore', 'Software', 'Valve', 'Steam', 'apps') or {}
    played, sc_played = {}, {}
    for k, v in apps_cfg.items():
        if not isinstance(v, dict) or not re.fullmatch(r'-?\d+', k):
            continue
        pt, lp = to_int(get_ci(v, 'Playtime')), to_int(get_ci(v, 'LastPlayed'))
        if not (pt or lp):
            continue
        n = int(k)
        if 0 < n < 0x80000000:
            played[n] = {'playtime': pt, 'lastPlayed': lp}
        else:
            # A non-Steam shortcut, keyed by its unsigned 32-bit appid, the signed value, or the 64-bit game id
            # (appid << 32 | 0x02000000). Normalize to the unsigned appid; keep the biggest numbers seen.
            sid = (n >> 32) if n > 0xFFFFFFFF else (n & 0xFFFFFFFF)
            old = sc_played.get(sid, {'playtime': 0, 'lastPlayed': 0})
            sc_played[sid] = {'playtime': max(pt, old['playtime']), 'lastPlayed': max(lp, old['lastPlayed'])}
    installed = installed_apps(steam)
    cache = os.path.join(steam, 'appcache', 'librarycache')
    cached_ids = {int(n) for n in os.listdir(cache) if n.isdigit()} if os.path.isdir(cache) else set()
    if os.path.isdir(cache):  # old flat layout: <appid>_library_600x900.jpg
        cached_ids |= {int(m.group(1)) for m in (re.match(r'^(\d+)_', n) for n in os.listdir(cache)) if m}
    log('Found: %d installed, %d with playtime, %d with cached art' % (len(installed), len(played), len(cached_ids)))

    # Optional: this computer's numbers go stale when you play elsewhere (a Steam Deck, another PC). With your own
    # Web API key, Steam's totals for every device win (the larger number, in case this PC played offline since).
    api_names, api_owned = {}, set()
    key, key_from = find_api_key(a.api_key)
    if key or a.api_response_file:
        steamid64 = acc[4] or str(int(accountid) + STEAMID64_BASE)
        owned, msg = fetch_owned(key or '', steamid64, a.api_response_file)
        if a.api_response_file:
            log('Online: TEST response from', a.api_response_file)
        if msg:
            log('Online:', msg)
        else:
            changed = added = 0
            for o in owned:
                aid = to_int(o.get('appid'))
                if not 0 < aid < 0x80000000:
                    continue
                api_owned.add(aid)
                if isinstance(o.get('name'), str) and o['name'].strip():
                    api_names[aid] = o['name'].strip()
                pt, lp = to_int(o.get('playtime_forever')), to_int(o.get('rtime_last_played'))
                if not (pt or lp):
                    continue
                old = played.get(aid)
                if old is None:
                    added += 1
                    played[aid] = {'playtime': pt, 'lastPlayed': lp}
                else:
                    new = {'playtime': max(pt, old['playtime']), 'lastPlayed': max(lp, old['lastPlayed'])}
                    changed += new != old
                    played[aid] = new
            log('Online: %d owned games from Steam (key from %s); %d updated, %d this computer never saw'
                % (len(owned), key_from or 'test file', changed, added))

    wanted = set(installed) | set(played) | cached_ids | (api_owned if a.include_unplayed else set())
    info, status = read_appinfo(os.path.join(steam, 'appcache', 'appinfo.vdf'), wanted)
    log('appinfo.vdf: %s, %d of %d apps named' % (status, len(info), len(wanted)))

    grid_dir = os.path.join(userdir, 'config', 'grid')
    grid_files = {fn.lower(): os.path.join(grid_dir, fn) for fn in os.listdir(grid_dir)} if os.path.isdir(grid_dir) else {}

    games, skipped = [], {'not a game': 0, 'no name': 0, 'no art': 0, 'unplayed': 0}
    for aid in sorted(wanted):
        name, typ = info.get(aid, (None, None))
        name = name or installed.get(aid, {}).get('name') or api_names.get(aid) or ''
        is_known = aid in installed or aid in played
        if aid in NOT_GAME_IDS or (typ and typ not in KEEP_TYPES) or (not typ and name and NOT_GAME.search(name)):
            skipped['not a game'] += 1
            continue
        if not is_known:
            # Owned but never played: only with a confirmed game type (appinfo, or Steam's owned-games list).
            if not a.include_unplayed or (typ not in KEEP_TYPES and aid not in api_owned):
                skipped['unplayed'] += 1
                continue
        art = cache_art(cache, aid)
        art.update(grid_art(grid_files, aid))
        if not name:
            skipped['no name'] += 1  # without appinfo there is no trustworthy name; the logo alone can't be read
            continue
        cdn = False
        if not any(k in art for k in ('cover', 'hero', 'logo', 'header')):
            if aid not in api_owned:
                skipped['no art'] += 1
                continue
            cdn = True  # owned per Steam, never shown on this computer: fetch its public store art below
        pl = played.get(aid, {})
        games.append({'appid': aid, 'name': name, 'playtime': pl.get('playtime', 0),
                      'lastPlayed': pl.get('lastPlayed') or installed.get(aid, {}).get('lastPlayed', 0), '_art': art,
                      '_cdn': cdn})

    shortcuts = [] if a.no_shortcuts else read_shortcuts(os.path.join(userdir, 'config', 'shortcuts.vdf'))
    ns = 0
    for s in shortcuts:
        # Each shortcut stays its own entry (core.js joins same-name entries). Playtime is in localconfig.vdf.
        art = grid_art(grid_files, s['appid'])
        pl = sc_played.get(s['appid'], {})
        pt, lp = pl.get('playtime', 0), max(s['lastPlayed'], pl.get('lastPlayed', 0))
        if any(k in art for k in ('cover', 'hero', 'logo', 'header')) or pt or lp:
            games.append({'appid': s['appid'], 'name': s['name'], 'playtime': pt, 'lastPlayed': lp,
                          'nonSteam': True, '_art': art})
            ns += 1
    if shortcuts:
        log('Non-Steam games: %d of %d kept (custom art or played)' % (ns, len(shortcuts)))

    # Games hidden in Steam stay hidden here too, unless config.js says showHidden: true.
    if shows_hidden(target):
        hidden = set()
        log('Hidden in Steam: shown (showHidden is on in config.js)')
    else:
        hidden = hidden_apps(userdir, lc)
        kept = [g for g in games if g['appid'] not in hidden]
        if len(kept) < len(games):
            log('Hidden in Steam: %d left out (showHidden in config.js shows them)' % (len(games) - len(kept)))
        games = kept

    games.sort(key=lambda g: (g['lastPlayed'], g['playtime']), reverse=True)
    if a.max_games > 0:
        games = games[:a.max_games]

    # Achievements: Steam keeps a summary of each game's progress (unlocked of total) in achievement_progress.json,
    # but only updates it now and then, so it goes stale (a newer device may have only a few games in it). Steam
    # also writes one file per game (librarycache/<appid>.json) whenever that game's library page is shown; where
    # that file is newer than the summary's entry, its counts win.
    cache = os.path.join(userdir, 'config', 'librarycache')
    try:
        with open(os.path.join(cache, 'achievement_progress.json'), encoding='utf-8') as f:
            ach = {int(k): v for k, v in json.load(f).get('mapCache', [])}
    except (OSError, ValueError, TypeError):
        ach = {}
    newer = 0
    for g in games:
        if not isinstance(g['appid'], int) or g.get('nonSteam'):
            continue
        p = ach.get(g['appid']) or {}
        unlocked, total = to_int(p.get('unlocked')), to_int(p.get('total'))
        own = game_achievements(os.path.join(cache, '%d.json' % g['appid']), to_int(p.get('cache_time')))
        if own:
            if own != (unlocked, total):
                newer += 1
            unlocked, total = own
        if total > 0:
            g['achievements'] = {'unlocked': min(unlocked, total), 'total': total}
    n = sum(1 for g in games if 'achievements' in g)
    if n:
        log('Achievements: %d games' % n + (' (%d newer than Steam\'s summary)' % newer if newer else ''))

    # Write. Folders of games that are gone are removed; files whose source is unchanged are reused.
    clean_library(lib, {str(g['appid']) for g in games})
    src_file = os.path.join(lib, '.sources')
    prev = {}
    try:
        with open(src_file, encoding='ascii') as f:
            prev = dict(line.split(' ', 1) for line in f.read().split('\n') if ' ' in line)
    except OSError:
        pass
    new = {}

    def put(src, folder, stem):
        """Copy src to library/<folder>/<stem><ext> unless the same source is already there. Returns the file name."""
        st = os.stat(src)
        fp = hashlib.md5(('%s|%d|%d' % (os.path.realpath(src), st.st_mtime_ns, st.st_size)).encode('utf-8')).hexdigest()
        key = folder + '/' + stem
        new[key] = fp
        ext = os.path.splitext(src)[1].lower() or '.jpg'
        d = os.path.join(lib, folder)
        os.makedirs(d, exist_ok=True)
        old = [n for n in os.listdir(d) if os.path.splitext(n)[0] == stem]
        if old == [stem + ext] and prev.get(key) == fp:
            return old[0]
        for n in old:
            os.remove(os.path.join(d, n))
        shutil.copyfile(src, os.path.join(d, stem + ext))
        return stem + ext

    def fetch(url, folder, stem):
        """Public store art for a game this computer has no art for. Kept between runs; None if Steam has none."""
        key = folder + '/' + stem
        fp = hashlib.md5(('cdn|' + url).encode('utf-8')).hexdigest()
        ext = os.path.splitext(url)[1].lower()
        d = os.path.join(lib, folder)
        if prev.get(key) == fp and os.path.isfile(os.path.join(d, stem + ext)):
            new[key] = fp
            return stem + ext
        b = cdn_get(url)
        if not b:
            return None
        os.makedirs(d, exist_ok=True)
        ext = '.png' if b[:4] == b'\x89PNG' else '.jpg'
        with open(os.path.join(d, stem + ext), 'wb') as f:
            f.write(b)
        new[key] = fp
        return stem + ext

    total, fetched, dropped = 0, 0, []
    for g in games:
        out = {}
        folder = str(g['appid'])
        if g.pop('_cdn', False):
            for kind, fn in CDN_FILES.items():
                name = fetch('%s/%d/%s' % (a.cdn_base.rstrip('/'), g['appid'], fn), folder, kind)
                if name:
                    g['_art'][kind] = os.path.join(lib, folder, name)  # already in place; put() leaves it be
                    fetched += 1
            if not g['_art']:
                dropped.append(g)
                continue
        for kind in ('cover', 'hero', 'logo', 'header', 'icon'):
            src = g['_art'].get(kind)
            if src and os.path.dirname(src) == os.path.join(lib, folder):
                out[kind] = 'library/%s/%s' % (folder, os.path.basename(src))
                total += os.path.getsize(src)
                continue
            if not src:
                out[kind] = None
                d = os.path.join(lib, folder)
                for n in (os.listdir(d) if os.path.isdir(d) else []):
                    if os.path.splitext(n)[0] == kind:
                        os.remove(os.path.join(d, n))
                continue
            name = put(src, folder, kind)
            total += os.path.getsize(os.path.join(lib, folder, name))
            out[kind] = 'library/%s/%s' % (folder, name)
        del g['_art']
        g.update(out)
    if dropped:  # Steam's store had no art for these either
        ids = {id(g) for g in dropped}
        games = [g for g in games if id(g) not in ids]
    if fetched or dropped:
        log('Store art: %d images for games this computer never showed; %d games had none' % (fetched, len(dropped)))

    shots = []
    for s in screenshots(userdir, max(0, a.max_screenshots), hidden):
        stem = '%d_%s' % (s['appid'], os.path.splitext(os.path.basename(s['src']))[0])
        name = put(s['src'], 'shots', stem)
        total += os.path.getsize(os.path.join(lib, 'shots', name))
        shots.append({'appid': s['appid'], 'path': 'library/shots/' + name, 'time': s['time']})
    shot_dir = os.path.join(lib, 'shots')
    if os.path.isdir(shot_dir):  # drop screenshots that fell out of the newest N
        keep = {os.path.basename(s['path']) for s in shots}
        for n in os.listdir(shot_dir):
            if n not in keep:
                os.remove(os.path.join(shot_dir, n))
    with open(src_file, 'w', encoding='ascii', newline='\n') as f:
        f.write(''.join('%s %s\n' % (k, new[k]) for k in sorted(new)))

    data = {'generated': int(time.time()), 'user': {'name': persona}, 'games': games, 'screenshots': shots}
    js = ('/* Written by the Backlog sync tool (tools/sync.py). Run it again to refresh. */\n'
          'window.BACKLOG_LIBRARY = ' + json.dumps(data, ensure_ascii=True, separators=(',', ':')) + ';\n')
    # Written whole, then swapped in, so a screensaver starting mid-refresh never reads half a file.
    tmp = os.path.join(lib, 'library.js.tmp')
    with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
        f.write(js)
    os.replace(tmp, os.path.join(lib, 'library.js'))
    total += len(js)

    log('Games: %d (%d non-Steam). Skipped: %s' % (len(games), sum(1 for g in games if g.get('nonSteam')), ', '.join('%d %s' % (v, k) for k, v in skipped.items() if v)))
    log('Screenshots: %d. Output: %.1f MB in %s' % (len(shots), total / 1048576, lib))
    repo = in_git_tree(target)
    if repo:
        log('Note: %s is a git work tree. Keep your real library.js out of commits with:\n'
            '  git -C "%s" update-index --skip-worktree backlog/library/library.js' % (repo, repo))
    # Only now, with the library written: turning the timer on can start a refresh straight away (its after-boot time
    # has already passed), and that run must not overlap this one.
    if a.install and not a.no_schedule:
        lock.close()
        schedule(sys.argv[1:], target if a.target else None)


if __name__ == '__main__':
    main()
