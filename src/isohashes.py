"""Collects the SHA-256 values Microsoft publishes for its Windows ISOs into src/iso-hashes.json.

    python3 src/isohashes.py

    python3 src/isohashes.py --archive     # also the copies of those pages kept by the Internet Archive

Microsoft's download pages for Windows 11 (x64), Windows 11 Arm64 and Windows 10 have a "Verify your
download" table with the SHA-256 of every language's ISO. The tool reads those pages when it checks an ISO;
this file keeps every value they ever showed (new ones are added, none are removed), so an ISO stays
verifiable after Microsoft replaces it with a newer one. Run it before a release; build.py puts the list
into Get-KnownIsoHashes.

--archive reads the monthly copies of the same pages at web.archive.org (Microsoft's own tables, as they
were then), for ISOs Microsoft listed before this file existed. Copies from before July 2024 are not read: the
pages then loaded the table only after a language was picked, so the copies don't have it. The archive limits how fast it may be read,
so this takes a while; pages already read are kept in a cache folder (default: .isohash-cache, not in git).

The Windows 10 page lists the ISOs only for browsers that are not on Windows (on Windows it offers the
Media Creation Tool), hence the user agent.
"""
import datetime, html, json, os, re, sys, time, urllib.error, urllib.parse, urllib.request

SRC = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(SRC, 'iso-hashes.json')
UA = 'Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0'
PAGES = [
    ('Windows 11', 'x64', 'https://www.microsoft.com/en-us/software-download/windows11'),
    ('Windows 11', 'Arm64', 'https://www.microsoft.com/en-us/software-download/windows11arm64'),
    ('Windows 10', '', 'https://www.microsoft.com/en-us/software-download/windows10ISO'),
]
ROW = re.compile(r'<tr>\s*<td>([^<]+)</td>\s*<td>\s*([0-9A-Fa-f]{64})\s*</td>\s*</tr>', re.I)
VERSION = re.compile(r'Version (\d{2}H\d)')


def read_page(url):
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept-Language': 'en-US,en;q=0.8'})
    return urllib.request.urlopen(req, timeout=90).read().decode('utf-8', 'replace')


def read_archived(url, cache):
    """One copy per month of url from the Internet Archive -> [(yyyy-mm-dd, html)]."""
    os.makedirs(cache, exist_ok=True)
    cdx = 'https://web.archive.org/cdx/search/cdx?' + urllib.parse.urlencode(
        {'url': url.split('://', 1)[1], 'output': 'json', 'filter': 'statuscode:200', 'collapse': 'timestamp:6', 'from': '202407'})
    snaps = json.loads(read_page(cdx))[1:]
    out = []
    for snap in snaps:
        ts, orig = snap[1], snap[2]
        f = os.path.join(cache, f'{ts}_{re.sub(r"[^A-Za-z0-9]+", "_", orig)[-40:]}.html')
        if not os.path.exists(f):
            for wait in (0, 30, 90, 180):
                time.sleep(wait or 6)
                try:
                    text = read_page(f'https://web.archive.org/web/{ts}id_/{orig}')
                    break
                except urllib.error.HTTPError as e:
                    if e.code != 429:
                        text = ''
                        break
            else:
                print(f'  {ts}: the archive keeps refusing, skipped')
                continue
            with open(f, 'w', encoding='utf-8') as h:
                h.write(text)
        out.append((f'{ts[:4]}-{ts[4:6]}-{ts[6:8]}', open(f, encoding='utf-8').read()))
    return out


def rows(text):
    return [(re.sub(r'\s+', ' ', html.unescape(m.group(1))).strip(), m.group(2).upper()) for m in ROW.finditer(text)]


def product(name, arch, text):
    m = VERSION.search(text)
    p = name + (' ' + m.group(1) if m else '')
    return p + (' ' + arch if arch == 'Arm64' else '')


def main():
    known = json.load(open(OUT, encoding='utf-8')) if os.path.exists(OUT) else []
    have = {k['sha256']: k for k in known}
    today = datetime.date.today().isoformat()
    added = 0

    def add(name, arch, text, when):
        nonlocal added
        found = rows(text)
        prod = product(name, arch, text)
        for label, sha in found:
            k = have.get(sha)
            if k is None:
                k = {'sha256': sha, 'product': prod, 'label': label, 'listed': when}
                known.append(k)
                have[sha] = k
                added += 1
            elif when < k['listed']:
                k['listed'] = when          # the first day it was seen
        return found, prod

    if '--archive' in sys.argv:
        cache = os.path.join(os.path.dirname(SRC), '.isohash-cache')
        for name, arch, url in PAGES:
            pages = read_archived(url, cache)
            n = sum(len(add(name, arch, text, when)[0]) for when, text in pages)
            print(f'{name} {arch}: {len(pages)} archived copies, {n} table rows')
    for name, arch, url in PAGES:
        found, prod = add(name, arch, read_page(url), today)
        if not found:
            sys.exit(f'no hash table on {url} - the page changed, check the parser')
        print(f'{prod}: {len(found)} on the page')
    known.sort(key=lambda k: (k['product'], k['listed'], k['label']))
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(known, f, indent=1)
        f.write('\n')
    print(f'{added} new, {len(known)} in {os.path.basename(OUT)}')


if __name__ == '__main__':
    main()
