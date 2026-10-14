"""The 150 canary strings: 25 each of prompts, code, file contents, paths,
names and key shapes. Fixed lists and index arithmetic only: the same 150 strings on
every run. Each canary carries a token (zqx000 to zqx149) found nowhere else."""

TOPICS = ["merger memo", "quarterly forecast", "salary review", "supplier contract", "launch plan",
          "audit findings", "board minutes", "pricing sheet", "layoff list", "patent filing",
          "clinic roster", "tax return", "grant application", "vendor invoice", "hiring offer",
          "security incident", "customer churn", "lease renewal", "budget draft", "press release",
          "insurance claim", "acquisition target", "product roadmap", "legal notice", "pitch deck"]
FIRST = ["Priya", "Bartholomew", "Ingrid", "Tobias", "Marguerite", "Oluwaseun", "Casimir", "Yuki",
         "Evangeline", "Dmitri", "Rosalind", "Anselm", "Fiona", "Leopold", "Saoirse", "Matteo",
         "Henrietta", "Kwame", "Philippa", "Rafael", "Winifred", "Zbigniew", "Annelise", "Cormac", "Imogen"]
LAST = ["Natarajan", "Quillfeather", "Haugen", "Wetherby", "Delacroix", "Adeyemi", "Wojciechowski",
        "Tanaka", "Fairweather", "Volkov", "Ashcroft", "Brennan", "Gallagher", "Hartmann", "Ni Bhriain",
        "Rossi", "Pemberton", "Mensah", "Lindqvist", "Ocampo", "Thackeray", "Nowak", "Eriksen", "Doyle", "Sutherland"]
DIRS = ["clientwork", "payroll", "acme-merger", "secret-sauce", "tax-2026", "medical", "legal-hold",
        "private-notes", "investor-docs", "source-vault", "hr-cases", "credentials", "drafts", "backups",
        "research", "contracts", "design-files", "worksheet", "invoices", "prototype", "roadmap",
        "interviews", "diligence", "keys", "archive"]
KEYS = [
    "sk-ant-api03-{h}AAAAAAAAAAAAAAAAAAAA",
    "sk-proj-{h}BBBBBBBBBBBBBBBBBBBBBB",
    "AKIA{u}ZZZZZZZZ",
    "ghp_{h}CCCCCCCCCCCCCCCCCCCCCC",
    "github_pat_{h}DDDDDDDDDDDDDDDDDDDDDD",
    "xoxb-{n}-{n}-{h}EEEEEEEEEE",
    "sk_live_{h}FFFFFFFFFFFFFFFFFFFF",
    "rk_live_{h}GGGGGGGGGGGGGGGGGGGG",
    "AIza{h}HHHHHHHHHHHHHHHHHHHHHHHHHHHH",
    "eyJhbGciOi{h}.eyJzdWIiOiJ{h}.SflKxwRJSMeKKF2QT4fw{h}",
    "-----BEGIN PRIVATE KEY-----{h}-----END PRIVATE KEY-----",
    "{h}{h}{h}{h}{h}{h}{h}{h}",
    "Bearer {h}IIIIIIIIIIIIIIIIIIIIIIII",
    "SERVICE_API_KEY={h}JJJJJJJJJJJJJJJJJJJJ",
    "sk-ant-oat01-{h}KKKKKKKKKKKKKKKKKKKK",
    "password=Tr0ub4dor{h}",
    "ANTHROPIC_API_KEY=sk-ant-api03-{h}LLLLLLLLLLLLLLLL",
    "glpat-{h}MMMMMMMMMMMMMMMM",
    "npm_{h}NNNNNNNNNNNNNNNNNNNNNNNNNNNN",
    "xoxp-{n}-{h}OOOOOOOOOOOOOOOOOOOO",
    "ghs_{h}PPPPPPPPPPPPPPPPPPPPPP",
    "sk-svcacct-{h}QQQQQQQQQQQQQQQQQQQQ",
    "AKIA{u}YYYYYYYY",
    "ya29.a0{h}RRRRRRRRRRRRRRRRRRRR",
    "shpat_{h}SSSSSSSSSSSSSSSSSSSSSSSS",
]


def _hex(i):
    return ("%08x" % (0x5A5A5A5A ^ (i * 2654435761 % 4294967296)))


def generate():
    """[(category, text, token)] with 150 entries."""
    out = []
    idx = 0
    for k in range(25):
        t = "zqx%03d" % idx
        out.append(("prompt", "Please rewrite my %s for %s %s and send it to the board, ref %s"
                    % (TOPICS[k], FIRST[k], LAST[k], t), t))
        idx += 1
    for k in range(25):
        t = "zqx%03d" % idx
        out.append(("code", "def %s_%d(x): return x ** %d + 0xC0DE%02d  # %s"
                    % (DIRS[k].replace("-", "_"), k, k + 2, k, t), t))
        idx += 1
    for k in range(25):
        t = "zqx%03d" % idx
        out.append(("file contents", "BEGIN FILE %s: invoice 77%02d total due %d.00 EUR; account holder %s"
                    % (t, k, 4100 + k * 17, LAST[k]), t))
        idx += 1
    for k in range(25):
        t = "zqx%03d" % idx
        base = ["/Users/%s/work/%s-%s/src/main.py", "/home/%s/%s/%s/notes.txt",
                "C:\\Users\\%s\\%s\\%s.docx", "~/%s/%s/%s.md", "/Volumes/%s/%s/%s.key"][k % 5]
        out.append(("path", base % (FIRST[k].lower(), DIRS[k], t), t))
        idx += 1
    for k in range(25):
        t = "zqx%03d" % idx
        out.append(("name", "%s %s %s" % (FIRST[k], LAST[k], t), t))
        idx += 1
    for k in range(25):
        t = "zqx%03d" % idx
        h = _hex(idx)
        text = KEYS[k].format(h=h, u=h.upper(), n=str(100000 + k))
        out.append(("key shape", "%s%s" % (text, t), t))
        idx += 1
    return out


if __name__ == "__main__":
    c = generate()
    assert len(c) == 150 and len(set(x[1] for x in c)) == 150
    for cat in ("prompt", "code", "file contents", "path", "name", "key shape"):
        assert sum(1 for x in c if x[0] == cat) == 25
    print("150 canaries, 25 in each of 6 categories")
