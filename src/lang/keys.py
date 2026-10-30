"""Every English interface text that can be translated, in the order it appears in the sources.

    python3 src/lang/keys.py            -> one text per line
    python3 src/lang/keys.py --missing  -> per language, the texts its src/lang/<code>.json does not have yet

Texts come from three places:
  - the XAML of the windows (Text, Content, ToolTip, Header, AutomationProperties.Name),
  - T '...' calls in the GUI code (the texts the code sets: notes, messages, questions),
  - the columns of the lists (New-Table @('Name', 'Size:int', ...)).
Names that are the same in every language (product, tool and file names) are in KEEP.
"""
import html, json, os, re, sys

SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANG = os.path.join(SRC, 'lang')
XAML_FILES = ['40_gui_xaml.ps1', '45_gui_dialogs.ps1']
CODE_FILES = ['48_gui_lang.ps1', '50_gui.ps1', '55_gui_main.ps1']
LANGUAGES = ['pt', 'es', 'fr', 'de', 'it']

# the same in every language - not looked up
KEEP = {
    'Windows ISO Updater', 'English', 'Deutsch', 'Italiano', 'Segoe UI', 'Verdana', 'Tahoma', 'Arial',
    'DISM', 'oscdimg.exe', 'Inf2Cat.exe', 'signtool.exe', 'makecat.exe', 'curl.exe',
    'MakeCat', 'libwdi-style', 'Inf2Cat', 'KB', 'Inf', 'INFs', 'EditionId', 'NVIDIA', 'OK',
    'Portugu\u00eas', 'Espa\u00f1ol', 'Fran\u00e7ais', 'autounattend.xml', 'generate-cat-file (WSL)', 'Windows 10', 'Windows 11',
}


def read(name):
    return open(os.path.join(SRC, name), encoding='ascii').read()


def xaml_texts():
    out = []
    for f in XAML_FILES:
        for block in re.findall(r"\$Script:X\w+ = @'\n(.*?)\n'@", read(f), re.S):
            for m in re.finditer(r'\s(Text|Content|ToolTip|Header|AutomationProperties\.Name)="([^"]*)"', block):
                v = html.unescape(m.group(2))
                if v.startswith('{') or '@@' in v or not re.search('[A-Za-z]{2}', v):
                    continue
                out.append(v)
    return out


def code_texts():
    out = []
    for f in CODE_FILES:
        for m in re.finditer(r"\bT '((?:[^']|'')*)'", read(f)):
            out.append(m.group(1).replace("''", "'"))
        for m in re.finditer(r"New-Table @\(([^)]*)\)", read(f)):
            out += [c for c in re.findall(r"'([^':]+)(?::\w+)?'", m.group(1))]
    return out


def keys():
    seen, out = set(), []
    for k in xaml_texts() + code_texts():
        if k in KEEP or k in seen:
            continue
        seen.add(k)
        out.append(k)
    return out


def load(code):
    p = os.path.join(LANG, code + '.json')
    if not os.path.exists(p):
        return {}
    return json.load(open(p, encoding='utf-8'))


if __name__ == '__main__':
    ks = keys()
    if '--missing' in sys.argv:
        for code in LANGUAGES:
            t = load(code)
            miss = [k for k in ks if k not in t]
            print(f'{code}: {len(miss)} of {len(ks)} missing')
            for k in miss:
                print('   ', k)
    else:
        for k in ks:
            print(k)
