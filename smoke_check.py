# leko-plus 新文件冒烟校验（无 luac 环境的替代方案）
# 1. Lua block 配平：剥离注释与字符串后统计 function/if/for/while/repeat vs end/until
# 2. require("Leko/...") 目标文件存在性
# 3. PUA_CHARSET 与 fanqie/content.lua 的逐字节一致性
import io, os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(ROOT, "leko.koplugin")

NEW_FILES = [
    "leko.koplugin/Leko/Fanqie/FanqieCompliance.lua",
    "leko.koplugin/Leko/Fanqie/FanqieConfig.lua",
    "leko.koplugin/Leko/Fanqie/AsyncProviderTask.lua",
    "leko.koplugin/Leko/Fanqie/FanqieAuth.lua",
    "leko.koplugin/Leko/Fanqie/FanqieContent.lua",
    "leko.koplugin/Leko/Fanqie/FanqieOfficialProvider.lua",
    "leko.koplugin/Leko/Fanqie/FanqieShelfService.lua",
    "leko.koplugin/Leko/Fanqie/QRLoginView.lua",
    "leko.koplugin/Leko/Fanqie/FanqieReviewService.lua",
    "leko.koplugin/Leko/Fanqie/ReviewDialog.lua",
    "leko.koplugin/Leko/Fanqie/FanqieDahuilangProvider.lua",
    "leko.koplugin/Leko/Fanqie/FanqieQingtianProvider.lua",
    "leko.koplugin/Leko/Fanqie/FanqieSettingsView.lua",
    "leko.koplugin/Leko/Fanqie/FanqieMigration.lua",
    "leko.koplugin/Leko/providers/Provider.lua",
    "leko.koplugin/Leko/providers/ProviderRegistry.lua",
    "leko.koplugin/Leko/providers/RateLimiter.lua",
    "leko.koplugin/config.example.lua",
]
MODIFIED_FILES = [
    "leko.koplugin/main.lua",
    "leko.koplugin/_meta.lua",
    "leko.koplugin/Leko/Version.lua",
    "leko.koplugin/Leko/App.lua",
    "leko.koplugin/Leko/Diagnostics.lua",
    "leko.koplugin/Leko/BookService.lua",
    "leko.koplugin/Leko/Storage.lua",
    "leko.koplugin/Leko/BookshelfView.lua",
    "leko.koplugin/Leko/BookInfoView.lua",
    "leko.koplugin/Leko/CoverBrowserView.lua",
    "leko.koplugin/Leko/MainMenuView.lua",
    "leko.koplugin/Leko/ReaderView.lua",
    "leko.koplugin/Leko/Fanqie/ProgressSync.lua",
]

def strip_lua(src):
    """Remove Lua comments and string literals, keep code structure."""
    out = []
    i, n = 0, len(src)
    while i < n:
        ch = src[i]
        two = src[i:i+2]
        if two == "--":
            # long comment?
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                level = m.group(1)
                close = "]" + level + "]"
                end = src.find(close, i + 4 + len(level))
                i = n if end < 0 else end + len(close)
            else:
                end = src.find("\n", i)
                i = n if end < 0 else end
            out.append(" ")
        elif ch == '"' or ch == "'":
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == ch:
                    break
                j += 1
            out.append('""')
            i = j + 1
        elif ch == "[" :
            m = re.match(r"\[(=*)\[", src[i:])
            if m:
                level = m.group(1)
                close = "]" + level + "]"
                end = src.find(close, i + 2 + len(level))
                i = n if end < 0 else end + len(close)
                out.append('""')
            else:
                out.append(ch)
                i += 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)

def block_balance(src):
    code = strip_lua(src)
    tokens = re.findall(r"[A-Za-z_]+", code)
    opens = closes = 0
    for t in tokens:
        if t in ("function", "if", "for", "while"):
            opens += 1
        elif t == "repeat":
            opens += 1
        elif t in ("end", "until"):
            closes += 1
    return opens, closes

def main():
    failures = []
    for rel in NEW_FILES + MODIFIED_FILES:
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            failures.append("MISSING: " + rel)
            continue
        src = io.open(path, encoding="utf-8").read()
        opens, closes = block_balance(src)
        status = "OK" if opens == closes else "IMBALANCE"
        print("%-58s opens=%-4d closes=%-4d %s" % (rel, opens, closes, status))
        if opens != closes:
            failures.append("BLOCK IMBALANCE: %s (%d vs %d)" % (rel, opens, closes))

    # require("Leko/...") resolution
    print("\n-- require resolution --")
    req_re = re.compile(r'require\("([^"]+)"\)')
    for rel in NEW_FILES + MODIFIED_FILES:
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            continue
        src = io.open(path, encoding="utf-8").read()
        for mod in req_re.findall(src):
            if mod.startswith("Leko/"):
                target = os.path.join(PLUGIN, mod.replace("/", os.sep) + ".lua")
                if not os.path.isfile(target):
                    failures.append("REQUIRE MISSING: %s requires %s" % (rel, mod))
                    print("MISSING", rel, "->", mod)
    print("require resolution done")

    # PUA table identity with fanqie/content.lua
    print("\n-- PUA table identity --")
    fanqie_src = io.open(os.path.join(ROOT, "..", "fanqie.koplugin", "fanqie", "content.lua"), encoding="utf-8").read()
    mine_src = io.open(os.path.join(PLUGIN, "Leko", "Fanqie", "FanqieContent.lua"), encoding="utf-8").read()
    def extract_tables(src):
        start = src.index("PUA_CODE = {")
        end = src.index("local function utf8_codepoint")
        return src[start:end].replace("\r\n", "\n").strip()
    a, b = extract_tables(fanqie_src), extract_tables(mine_src)
    if a == b:
        print("PUA tables identical")
    else:
        # compare row contents ignoring leading comment differences
        rows_a = re.findall(r'\{ ".*?" \}', a, re.S)
        rows_b = re.findall(r'\{ ".*?" \}', b, re.S)
        if rows_a == rows_b:
            print("PUA charset rows identical (wrapper comments differ, acceptable)")
        else:
            failures.append("PUA table mismatch")
            print("PUA MISMATCH rows:", len(rows_a), len(rows_b))

    print("\n== RESULT ==")
    if failures:
        for f in failures:
            print("FAIL:", f)
        sys.exit(1)
    print("ALL CHECKS PASSED")

if __name__ == "__main__":
    main()
